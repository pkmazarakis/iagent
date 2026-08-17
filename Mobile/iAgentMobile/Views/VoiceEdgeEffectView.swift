import MetalKit
import SwiftUI
import UIKit

/// A thread-safe audio handoff for the voice renderer.
///
/// This deliberately isn't an `ObservableObject`: recorder metering can update it
/// without invalidating the SwiftUI view hierarchy. The Metal render loop samples
/// and smooths the latest value once per display frame.
final class VoiceEdgeEffectSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTargetAudioLevel: Float = 0

    init() {
        // Session construction happens before the root becomes interactive.
        // Pay the one-time immutable pipeline cost there, so even an immediate
        // first press cannot suspend the launch animation waiting for Metal.
        VoiceEdgeEffectResourceCache.shared.prewarmSynchronously()
    }

    func setTargetAudioLevel(_ level: CGFloat) {
        lock.lock()
        storedTargetAudioLevel = Float(min(max(level, 0), 1))
        lock.unlock()
    }

    fileprivate func targetAudioLevel() -> Float {
        lock.lock()
        let level = storedTargetAudioLevel
        lock.unlock()
        return level
    }
}

/// GPU-backed voice activation feedback.
///
/// Keep this view mounted while the low-frequency `phaseProgress` target moves
/// from zero to one. The renderer owns display-synced interpolation; callers
/// should update the target only when gesture/session state changes. The
/// normalized phases are intentionally explicit so touch-down can immediately
/// seed the trigger border before the hold gesture commits:
///
/// - `0`: localized source-border seed
/// - `0.10`: charged border releases the solar front
/// - `0.68`: the propagated front has wrapped the full display
/// - `1`: interior energy has drained into the shifting perimeter
///
/// `sourceFrame` is expressed in this view's local point coordinate space.
struct VoiceEdgeEffectView: UIViewRepresentable {
    let sourceFrame: CGRect
    let phaseProgress: CGFloat
    let signal: VoiceEdgeEffectSignal
    var effectOpacity: CGFloat = 1
    var screenCornerRadius: CGFloat = 54
    var reduceMotion = false
    var reduceTransparency = false
    var isActive = true
    var debugFrozenTime: TimeInterval? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(signal: signal)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.enableSetNeedsDisplay = false
        view.presentsWithTransaction = false
        // This is an intentionally defocused light field, not text or line art.
        // Render it at one point per pixel and let the compositor upscale the
        // analytic falloff. That removes 75% of the fragment work versus 2x
        // while the 1–2 pt luminous core still spans multiple display pixels.
        view.contentScaleFactor = 1
        view.layer.magnificationFilter = .linear
        // The primed and steady states only need a stable 60 Hz clock. The
        // renderer temporarily raises this to the display maximum during the
        // measured 775 ms launch, then drops it again to save fill-rate and
        // energy while the palette continues its slow perimeter drift.
        view.preferredFramesPerSecond = min(60, UIScreen.main.maximumFramesPerSecond)
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        context.coordinator.attach(to: view)
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.detach()
    }

    private func update(_ view: MTKView, coordinator: Coordinator) {
        let configuration = VoiceEdgeEffectConfiguration(
            sourceFrame: sourceFrame,
            phaseProgress: Float(min(max(phaseProgress, 0), 1)),
            effectOpacity: Float(min(max(effectOpacity, 0), 1)),
            screenCornerRadius: Float(max(screenCornerRadius, 0)),
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            isActive: isActive,
            debugFrozenTime: debugFrozenTime
        )
        coordinator.update(configuration: configuration)

        view.isHidden = !isActive
        view.isPaused = !isActive || coordinator.renderingUnavailable
        if isActive, view.isPaused == false, view.drawableSize.width > 0 {
            view.draw()
        }
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?

        var renderingUnavailable: Bool {
            renderer == nil
        }

        private let signal: VoiceEdgeEffectSignal
        private var renderer: VoiceEdgeEffectRenderer?

        init(signal: VoiceEdgeEffectSignal) {
            self.signal = signal
            device = MTLCreateSystemDefaultDevice()
            if let device {
                renderer = try? VoiceEdgeEffectRenderer(device: device, signal: signal)
            }
            super.init()
        }

        func attach(to view: MTKView) {
            renderer?.attach(to: view)
        }

        func detach() {
            renderer?.detach()
        }

        fileprivate func update(configuration: VoiceEdgeEffectConfiguration) {
            renderer?.update(configuration: configuration)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer?.drawableSizeDidChange(size)
        }

        func draw(in view: MTKView) {
            renderer?.draw(in: view)
        }
    }
}

private struct VoiceEdgeEffectConfiguration: Sendable {
    var sourceFrame: CGRect = .zero
    var phaseProgress: Float = 0
    var effectOpacity: Float = 1
    var screenCornerRadius: Float = 54
    var reduceMotion = false
    var reduceTransparency = false
    var isActive = false
    var debugFrozenTime: TimeInterval?
}

private struct VoiceEdgeUniforms {
    // xy: drawable size in pixels, zw: point-to-pixel scale
    var viewportAndScale = SIMD4<Float>(repeating: 0)
    // xy: source center in pixels, zw: source half-size in pixels
    var sourceCenterAndHalfSize = SIMD4<Float>(repeating: 0)
    // x: time, y: normalized phase, z: opacity, w: smoothed audio
    var timing = SIMD4<Float>(repeating: 0)
    // x: screen corner radius, y: source corner radius, z: reduced motion, w: reduced transparency
    var geometryAndAccessibility = SIMD4<Float>(repeating: 0)
    // x: palette phase, y: particle intensity, z: launch energy, w: reserved
    var visualState = SIMD4<Float>(repeating: 0)
}

private struct VoiceParticleSeed {
    // x: horizontal origin, y: lifecycle phase, z: speed, w: size in points
    var originPhaseSpeedSize: SIMD4<Float>
    // x: signed drift amplitude, y: drift rate, z: opacity, w: drift phase
    var dynamics: SIMD4<Float>
}

/// Canonical measured launch curve and its presentation-value inverse.
///
/// Keeping both directions in one pure value type lets a recommit resume from
/// the exact on-screen phase instead of restarting or switching to a generic
/// duration. That preserves spatial continuity through cancel/recommit input.
private enum VoiceEdgeLaunchTimeline {
    static let chargeEnd: Float = 0.248
    static let wrapEnd: Float = 0.515
    static let drainEnd: Float = 0.998

    static func progress(at elapsed: Float) -> Float {
        let time = max(elapsed, 0)
        if time < chargeEnd {
            return 0.10 * smoothStep(time / chargeEnd)
        }
        if time < wrapEnd {
            let amount = (time - chargeEnd) / (wrapEnd - chargeEnd)
            return 0.10 + 0.58 * min(max(amount, 0), 1)
        }
        if time < drainEnd {
            let amount = (time - wrapEnd) / (drainEnd - wrapEnd)
            return 0.68 + 0.32 * smoothStep(amount)
        }
        return 1
    }

    static func elapsed(for progress: Float) -> Float {
        let phase = min(max(progress, 0), 1)
        if phase < 0.10 {
            return chargeEnd * inverseSmoothStep(phase / 0.10)
        }
        if phase < 0.68 {
            let amount = (phase - 0.10) / 0.58
            return chargeEnd + (wrapEnd - chargeEnd) * amount
        }
        if phase < 1 {
            let amount = (phase - 0.68) / 0.32
            return wrapEnd + (drainEnd - wrapEnd) * inverseSmoothStep(amount)
        }
        return drainEnd
    }

#if DEBUG
    static var contractIsValid: Bool {
        let milestones: [(Float, Float)] = [
            (0, 0), (chargeEnd, 0.10), (wrapEnd, 0.68), (drainEnd, 1)
        ]
        let milestonesMatch = milestones.allSatisfy { elapsed, phase in
            abs(progress(at: elapsed) - phase) < 0.0001
                && abs(Self.elapsed(for: phase) - elapsed) < 0.0001
        }
        let roundTripsMatch = stride(from: Float(0), through: 1, by: 0.025).allSatisfy { phase in
            abs(progress(at: elapsed(for: phase)) - phase) < 0.0002
        }
        return milestonesMatch && roundTripsMatch
    }
#endif

    private static func smoothStep(_ value: Float) -> Float {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func inverseSmoothStep(_ value: Float) -> Float {
        let clamped = min(max(value, 0), 1)
        return 0.5 - sin(asin(1 - 2 * clamped) / 3)
    }
}

private struct VoiceEdgeEffectResources {
    let edgePipeline: MTLRenderPipelineState
    let particlePipeline: MTLRenderPipelineState
    let particleBuffer: MTLBuffer
}

private final class VoiceEdgeEffectResourceCache: @unchecked Sendable {
    static let shared = VoiceEdgeEffectResourceCache()

    private let condition = NSCondition()
    private var cachedDeviceIdentifier: ObjectIdentifier?
    private var cachedResources: VoiceEdgeEffectResources?
    private var buildingDeviceIdentifier: ObjectIdentifier?

    func prewarmSynchronously() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        _ = try? resources(for: device)
    }

    func resources(for device: MTLDevice) throws -> VoiceEdgeEffectResources {
        let identifier = ObjectIdentifier(device as AnyObject)
        condition.lock()
        if cachedDeviceIdentifier == identifier, let cachedResources {
            condition.unlock()
            return cachedResources
        }

        // Prewarming normally finishes long before the first gesture. If an
        // unusually fast first invocation overlaps it, wait for that one build
        // instead of compiling a duplicate pipeline synchronously on the main
        // thread. This also keeps all later MTKView instances on the cache path.
        while buildingDeviceIdentifier == identifier {
            condition.wait()
            if cachedDeviceIdentifier == identifier, let cachedResources {
                condition.unlock()
                return cachedResources
            }
        }
        buildingDeviceIdentifier = identifier
        condition.unlock()

        do {
            guard
                let library = device.makeDefaultLibrary(),
                let edgeVertex = library.makeFunction(name: "voiceEdgeVertex"),
                let edgeFragment = library.makeFunction(name: "voiceEdgeFragment"),
                let particleVertex = library.makeFunction(name: "voiceParticleVertex"),
                let particleFragment = library.makeFunction(name: "voiceParticleFragment")
            else {
                throw VoiceEdgeEffectRendererError.shaderUnavailable
            }
            let edgePipeline = try Self.makePipeline(
                device: device,
                vertex: edgeVertex,
                fragment: edgeFragment,
                label: "Voice solar-ray edge"
            )
            let particlePipeline = try Self.makePipeline(
                device: device,
                vertex: particleVertex,
                fragment: particleFragment,
                label: "Voice instanced particles"
            )
            let seeds = VoiceEdgeEffectRenderer.makeParticleSeeds(
                count: VoiceEdgeEffectRenderer.particleCount
            )
            guard let particleBuffer = device.makeBuffer(
                bytes: seeds,
                length: MemoryLayout<VoiceParticleSeed>.stride * seeds.count,
                options: .storageModeShared
            ) else {
                throw VoiceEdgeEffectRendererError.bufferUnavailable
            }
            particleBuffer.label = "Voice particle seeds"
            let resources = VoiceEdgeEffectResources(
                edgePipeline: edgePipeline,
                particlePipeline: particlePipeline,
                particleBuffer: particleBuffer
            )

            condition.lock()
            cachedDeviceIdentifier = identifier
            cachedResources = resources
            buildingDeviceIdentifier = nil
            condition.broadcast()
            condition.unlock()
            return resources
        } catch {
            condition.lock()
            if buildingDeviceIdentifier == identifier {
                buildingDeviceIdentifier = nil
            }
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    private static func makePipeline(
        device: MTLDevice,
        vertex: MTLFunction,
        fragment: MTLFunction,
        label: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

@MainActor
private final class VoiceEdgeEffectRenderer {
    private static let maximumInflightFrames = 3
    // Eighteen stratified instances leave roughly sixteen dots visible after
    // lifecycle fading. Their seeded differences keep the faster stream
    // organic without making it crowded or adding per-frame CPU work.
    nonisolated fileprivate static let particleCount = 18

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let edgePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let particleBuffer: MTLBuffer
    private let uniformBuffers: [MTLBuffer]
    private let inflightSemaphore = DispatchSemaphore(value: maximumInflightFrames)
    private let signal: VoiceEdgeEffectSignal
    private let configurationLock = NSLock()

    private weak var attachedView: MTKView?
    private var configuration = VoiceEdgeEffectConfiguration()
    private var frameIndex = 0
    private var firstFrameTime: CFTimeInterval?
    private var previousFrameTime: CFTimeInterval?
    private var smoothedAudioLevel: Float = 0
    private var drawableSize = CGSize.zero
    private var displayedPhaseProgress: Float = 0
    private var phaseAnimationStartProgress: Float = 0
    private var phaseAnimationTarget: Float = 0
    private var phaseAnimationStartTime: CFTimeInterval?
    private var displayedEffectOpacity: Float = 1
    private var opacityAnimationStart: Float = 1
    private var opacityAnimationTarget: Float = 1
    private var opacityAnimationStartTime: CFTimeInterval?
    private var hasRenderedFrame = false

    init(device: MTLDevice, signal: VoiceEdgeEffectSignal) throws {
        self.device = device
        self.signal = signal

#if DEBUG
        assert(VoiceEdgeLaunchTimeline.contractIsValid)
#endif

        guard let commandQueue = device.makeCommandQueue() else {
            throw VoiceEdgeEffectRendererError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue

        let resources = try VoiceEdgeEffectResourceCache.shared.resources(for: device)
        edgePipeline = resources.edgePipeline
        particlePipeline = resources.particlePipeline
        particleBuffer = resources.particleBuffer

        var buffers: [MTLBuffer] = []
        for index in 0..<Self.maximumInflightFrames {
            guard let buffer = device.makeBuffer(
                length: MemoryLayout<VoiceEdgeUniforms>.stride,
                options: .storageModeShared
            ) else {
                throw VoiceEdgeEffectRendererError.bufferUnavailable
            }
            buffer.label = "Voice uniforms \(index)"
            buffers.append(buffer)
        }
        uniformBuffers = buffers
    }

    func attach(to view: MTKView) {
        attachedView = view
        drawableSize = view.drawableSize
        firstFrameTime = nil
        previousFrameTime = nil
    }

    func detach() {
        attachedView = nil
    }

    func update(configuration: VoiceEdgeEffectConfiguration) {
        configurationLock.lock()
        self.configuration = configuration
        configurationLock.unlock()
    }

    func drawableSizeDidChange(_ size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView) {
        let currentConfiguration = readConfiguration()
        guard currentConfiguration.isActive else { return }
        guard inflightSemaphore.wait(timeout: .now()) == .success else { return }
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            inflightSemaphore.signal()
            return
        }

        let semaphore = inflightSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        let now = CACurrentMediaTime()
        let elapsedTime = renderTime(now: now, frozenTime: currentConfiguration.debugFrozenTime)
        updateAudioLevel(now: now, frozenTime: currentConfiguration.debugFrozenTime)
        let renderedProgress = updatePhaseProgress(
            now: now,
            target: currentConfiguration.phaseProgress,
            reduceMotion: currentConfiguration.reduceMotion,
            frozenTime: currentConfiguration.debugFrozenTime
        )
        let renderedOpacity = updateEffectOpacity(
            now: now,
            target: currentConfiguration.effectOpacity,
            frozenTime: currentConfiguration.debugFrozenTime
        )
        updatePreferredFrameRate(
            view: view,
            targetProgress: currentConfiguration.phaseProgress,
            renderedProgress: renderedProgress,
            reduceMotion: currentConfiguration.reduceMotion
        )

        let uniforms = makeUniforms(
            view: view,
            configuration: currentConfiguration,
            elapsedTime: elapsedTime,
            renderedProgress: renderedProgress,
            renderedOpacity: renderedOpacity
        )
        let uniformBuffer = uniformBuffers[frameIndex % uniformBuffers.count]
        frameIndex &+= 1
        withUnsafeBytes(of: uniforms) { bytes in
            guard let source = bytes.baseAddress else { return }
            uniformBuffer.contents().copyMemory(from: source, byteCount: bytes.count)
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.commit()
            return
        }
        encoder.label = "Voice edge effect pass"

        // Draw call one: analytic dim, source seed, ray wavefront, and deposited perimeter.
        encoder.setRenderPipelineState(edgePipeline)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Draw call two, same pass: pre-seeded instanced quads. No per-frame CPU paths or allocations.
        encoder.setRenderPipelineState(particlePipeline)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: Self.particleCount
        )
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        if currentConfiguration.reduceMotion,
           abs(renderedProgress - currentConfiguration.phaseProgress) < 0.001,
           abs(renderedOpacity - currentConfiguration.effectOpacity) < 0.001 {
            // Reduced Motion has no spatial, palette, particle, or audio loop.
            // Once an optional opacity cross-fade lands, one submitted frame is enough.
            view.isPaused = true
        }
    }

    private func updatePreferredFrameRate(
        view: MTKView,
        targetProgress: Float,
        renderedProgress: Float,
        reduceMotion: Bool
    ) {
        let maximum = max(view.window?.screen.maximumFramesPerSecond ?? 60, 60)
        let isLaunching = !reduceMotion
            && targetProgress >= 0.999
            && renderedProgress < 0.999
        let desired = isLaunching ? maximum : min(60, maximum)
        guard view.preferredFramesPerSecond != desired else { return }
        view.preferredFramesPerSecond = desired
    }

    private func readConfiguration() -> VoiceEdgeEffectConfiguration {
        configurationLock.lock()
        let value = configuration
        configurationLock.unlock()
        return value
    }

    private func renderTime(now: CFTimeInterval, frozenTime: TimeInterval?) -> Float {
#if DEBUG
        if let frozenTime {
            return Float(max(frozenTime, 0))
        }
#endif
        if firstFrameTime == nil {
            firstFrameTime = now
        }
        return Float(now - (firstFrameTime ?? now))
    }

    private func updateAudioLevel(now: CFTimeInterval, frozenTime: TimeInterval?) {
        let frameDelta: Float
#if DEBUG
        if frozenTime != nil {
            frameDelta = 1 / 60
        } else {
            let rawDelta = now - (previousFrameTime ?? now)
            let clampedDelta = min(max(rawDelta, 1.0 / 240.0), 1.0 / 15.0)
            frameDelta = Float(clampedDelta)
        }
#else
        let rawDelta = now - (previousFrameTime ?? now)
        let clampedDelta = min(max(rawDelta, 1.0 / 240.0), 1.0 / 15.0)
        frameDelta = Float(clampedDelta)
#endif
        previousFrameTime = now

        let target = signal.targetAudioLevel()
        let response: Float = target > smoothedAudioLevel ? 0.060 : 0.180
        let blend = 1 - exp(-frameDelta / response)
        smoothedAudioLevel += (target - smoothedAudioLevel) * blend
    }

    /// Advances the solar-ray launch without requiring SwiftUI to publish every frame.
    /// The piecewise timing mirrors the supplied Siri recording: a restrained 248 ms
    /// source-border charge, a rapidly accelerating wrap completed at 515 ms, then
    /// an interior-energy drain into the perimeter completed at about one second.
    private func updatePhaseProgress(
        now: CFTimeInterval,
        target: Float,
        reduceMotion: Bool,
        frozenTime: TimeInterval?
    ) -> Float {
#if DEBUG
        if frozenTime != nil {
            displayedPhaseProgress = target
            phaseAnimationTarget = target
            return target
        }
#endif
        if !hasRenderedFrame {
            hasRenderedFrame = true
            displayedPhaseProgress = min(target, 0)
            phaseAnimationTarget = target
            phaseAnimationStartProgress = displayedPhaseProgress
            phaseAnimationStartTime = canonicalStartTimeIfNeeded(
                now: now,
                target: target,
                reduceMotion: reduceMotion
            )
        } else if abs(target - phaseAnimationTarget) > 0.0001 {
            phaseAnimationStartProgress = displayedPhaseProgress
            phaseAnimationTarget = target
            phaseAnimationStartTime = canonicalStartTimeIfNeeded(
                now: now,
                target: target,
                reduceMotion: reduceMotion
            )
        }

        guard let startTime = phaseAnimationStartTime else {
            displayedPhaseProgress = target
            return target
        }

        let elapsed = Float(max(now - startTime, 0))
        if reduceMotion {
            // Accessibility equivalent: a brief non-spatial cross-fade from
            // the trigger seed to a static perimeter. The shader suppresses
            // rays, particle motion, audio response, and palette travel.
            let amount = Self.easeOutQuint(elapsed / 0.180)
            displayedPhaseProgress = phaseAnimationStartProgress
                + (target - phaseAnimationStartProgress) * amount
            if amount >= 1 {
                displayedPhaseProgress = target
                phaseAnimationStartTime = nil
            }
        } else if target >= 0.999 {
            // Resume the same measured timeline after interruption. The start
            // time was inverse-mapped from the current presentation phase, so
            // no restart, jump, or generic-duration shortcut is introduced.
            displayedPhaseProgress = VoiceEdgeLaunchTimeline.progress(at: elapsed)
            if elapsed >= VoiceEdgeLaunchTimeline.drainEnd {
                displayedPhaseProgress = 1
                phaseAnimationStartTime = nil
            }
        } else {
            let duration: Float = target < phaseAnimationStartProgress ? 0.180 : 0.280
            let amount = Self.easeOutQuint(elapsed / duration)
            displayedPhaseProgress = phaseAnimationStartProgress
                + (target - phaseAnimationStartProgress) * amount
            if amount >= 1 {
                displayedPhaseProgress = target
                phaseAnimationStartTime = nil
            }
        }
        return min(max(displayedPhaseProgress, 0), 1)
    }

    private func canonicalStartTimeIfNeeded(
        now: CFTimeInterval,
        target: Float,
        reduceMotion: Bool
    ) -> CFTimeInterval {
        guard !reduceMotion, target >= 0.999 else { return now }
        let elapsed = VoiceEdgeLaunchTimeline.elapsed(for: displayedPhaseProgress)
        return now - CFTimeInterval(elapsed)
    }

    private func updateEffectOpacity(
        now: CFTimeInterval,
        target: Float,
        frozenTime: TimeInterval?
    ) -> Float {
#if DEBUG
        if frozenTime != nil {
            displayedEffectOpacity = target
            opacityAnimationTarget = target
            return target
        }
#endif
        if abs(target - opacityAnimationTarget) > 0.0001 {
            opacityAnimationStart = displayedEffectOpacity
            opacityAnimationTarget = target
            opacityAnimationStartTime = now
        }
        guard let startTime = opacityAnimationStartTime else {
            displayedEffectOpacity = target
            return target
        }
        let elapsed = Float(max(now - startTime, 0))
        let duration: Float = target < opacityAnimationStart ? 0.180 : 0.120
        let amount = Self.easeOutQuint(elapsed / duration)
        displayedEffectOpacity = opacityAnimationStart + (target - opacityAnimationStart) * amount
        if amount >= 1 {
            displayedEffectOpacity = target
            opacityAnimationStartTime = nil
        }
        return min(max(displayedEffectOpacity, 0), 1)
    }

    private func makeUniforms(
        view: MTKView,
        configuration: VoiceEdgeEffectConfiguration,
        elapsedTime: Float,
        renderedProgress: Float,
        renderedOpacity: Float
    ) -> VoiceEdgeUniforms {
        let drawableWidth = Float(max(view.drawableSize.width, 1))
        let drawableHeight = Float(max(view.drawableSize.height, 1))
        let pointWidth = Float(max(view.bounds.width, 1))
        let pointHeight = Float(max(view.bounds.height, 1))
        let xScale = drawableWidth / pointWidth
        let yScale = drawableHeight / pointHeight

        let source = configuration.sourceFrame
        let sourceCenter = SIMD2<Float>(
            Float(source.midX) * xScale,
            Float(source.midY) * yScale
        )
        let sourceHalfSize = SIMD2<Float>(
            max(Float(source.width) * xScale * 0.5, 1),
            max(Float(source.height) * yScale * 0.5, 1)
        )
        let averageScale = (xScale + yScale) * 0.5
        let sourceCornerRadius = min(sourceHalfSize.x, sourceHalfSize.y)
        let progress = min(max(renderedProgress, 0), 1)

        return VoiceEdgeUniforms(
            viewportAndScale: SIMD4<Float>(drawableWidth, drawableHeight, xScale, yScale),
            sourceCenterAndHalfSize: SIMD4<Float>(
                sourceCenter.x,
                sourceCenter.y,
                sourceHalfSize.x,
                sourceHalfSize.y
            ),
            timing: SIMD4<Float>(
                elapsedTime,
                progress,
                renderedOpacity,
                configuration.reduceMotion ? 0 : smoothedAudioLevel
            ),
            geometryAndAccessibility: SIMD4<Float>(
                configuration.screenCornerRadius * averageScale,
                sourceCornerRadius,
                configuration.reduceMotion ? 1 : 0,
                configuration.reduceTransparency ? 1 : 0
            ),
            visualState: SIMD4<Float>(
                elapsedTime * (configuration.reduceMotion ? 0 : 0.0378),
                configuration.reduceMotion ? 0 : 1,
                configuration.reduceMotion ? 1 : Self.smoothStep(progress / 0.10),
                0
            )
        )
    }

    private static func easeOutQuint(_ value: Float) -> Float {
        let clamped = min(max(value, 0), 1)
        let inverse = 1 - clamped
        return 1 - inverse * inverse * inverse * inverse * inverse
    }

    private static func smoothStep(_ value: Float) -> Float {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    nonisolated fileprivate static func makeParticleSeeds(count: Int) -> [VoiceParticleSeed] {
        var state: UInt64 = 0x6A09_E667_F3BC_C909

        func unitRandom() -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            return Float(value & 0x00FF_FFFF) / Float(0x0100_0000)
        }

        let safeCount = max(count, 1)
        let inverseGoldenRatio: Float = 0.618_033_988_75
        return (0..<count).map { index in
            // A low-discrepancy horizontal sequence paired with gently jittered
            // stratified phases prevents both mechanical rows and random clumps
            // without per-frame sorting, spawning, or allocation.
            let horizontalUnit = (Float(index) * inverseGoldenRatio + 0.5)
                .truncatingRemainder(dividingBy: 1)
            let x = 0.075 + horizontalUnit * 0.85
            let phaseJitter = (unitRandom() - 0.5) * 0.42
            let lifecycle = (
                (Float(index) + 0.5 + phaseJitter) / Float(safeCount)
            ).truncatingRemainder(dividingBy: 1)

            let speed: Float = 0.82 + unitRandom() * 0.42
            let size: Float = 0.90 + unitRandom() * 0.60
            let driftSign: Float = unitRandom() < 0.5 ? -1 : 1
            let drift = driftSign * (0.32 + unitRandom() * 0.76)
            let driftRate = 0.90 + unitRandom() * 0.64
            let opacity = 0.62 + unitRandom() * 0.38
            let driftPhase = unitRandom()
            return VoiceParticleSeed(
                originPhaseSpeedSize: SIMD4<Float>(x, lifecycle, speed, size),
                dynamics: SIMD4<Float>(drift, driftRate, opacity, driftPhase)
            )
        }
    }
}

private enum VoiceEdgeEffectRendererError: Error {
    case commandQueueUnavailable
    case shaderUnavailable
    case bufferUnavailable
}
