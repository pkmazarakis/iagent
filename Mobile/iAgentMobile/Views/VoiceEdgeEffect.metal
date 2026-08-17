#include <metal_stdlib>
using namespace metal;

struct VoiceEdgeUniforms {
    float4 viewportAndScale;
    float4 sourceCenterAndHalfSize;
    float4 timing;
    float4 geometryAndAccessibility;
    float4 visualState;
};

struct VoiceParticleSeed {
    float4 originPhaseSpeedSize;
    float4 dynamics;
};

struct VoiceEdgeVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct VoiceParticleVertexOut {
    float4 position [[position]];
    float2 localPosition;
    float4 color;
};

constant float kPi = 3.14159265358979323846;
constant float kTwoPi = 6.28318530717958647692;

float saturateValue(float value) {
    return clamp(value, 0.0, 1.0);
}

float easeOutQuint(float value) {
    float inverse = 1.0 - saturateValue(value);
    return 1.0 - inverse * inverse * inverse * inverse * inverse;
}

float roundedBoxDistance(float2 position, float2 halfSize, float radius) {
    float safeRadius = max(radius, 0.001);
    float2 offset = abs(position) - halfSize + safeRadius;
    return min(max(offset.x, offset.y), 0.0)
        + length(max(offset, float2(0.0))) - safeRadius;
}

float3 voicePalette(float value) {
    float wrapped = fract(value);
    float scaled = wrapped * 5.0;
    uint segment = min(uint(floor(scaled)), 4u);
    float amount = smoothstep(0.0, 1.0, fract(scaled));

    // Voice mode deliberately stays inside the cool Siri-like family requested
    // for iAgent. Broad neighboring lobes interpolate electric blue → indigo →
    // violet → soft purple, with no red, cyan, green, amber, or gold excursions.
    const float3 colors[6] = {
        float3(0.090, 0.430, 1.000),
        float3(0.235, 0.205, 0.965),
        float3(0.475, 0.205, 0.985),
        float3(0.675, 0.290, 0.980),
        float3(0.390, 0.285, 1.000),
        float3(0.090, 0.430, 1.000)
    };
    return mix(colors[segment], colors[segment + 1], amount);
}

float rayDistanceToViewport(float2 origin, float2 direction, float2 viewport, float inset) {
    float2 minimumBound = float2(inset);
    float2 maximumBound = viewport - float2(inset);
    float xDistance = direction.x >= 0.0
        ? (maximumBound.x - origin.x) / max(direction.x, 0.0001)
        : (minimumBound.x - origin.x) / min(direction.x, -0.0001);
    float yDistance = direction.y >= 0.0
        ? (maximumBound.y - origin.y) / max(direction.y, 0.0001)
        : (minimumBound.y - origin.y) / min(direction.y, -0.0001);
    return max(min(xDistance, yDistance), 1.0);
}

float roundedPerimeterCoordinate(float2 position, float2 halfSize, float radius) {
    float horizontalLength = max(2.0 * (halfSize.x - radius), 0.001);
    float verticalLength = max(2.0 * (halfSize.y - radius), 0.001);
    float cornerLength = 0.5 * kPi * radius;
    float perimeter = 2.0 * horizontalLength + 2.0 * verticalLength + 4.0 * cornerLength;

    float rightTangent = halfSize.x - radius;
    float bottomTangent = halfSize.y - radius;

    if (position.x > rightTangent && position.y < -bottomTangent) {
        float2 local = position - float2(rightTangent, -bottomTangent);
        float angle = clamp(atan2(local.y, local.x), -0.5 * kPi, 0.0);
        return (horizontalLength + radius * (angle + 0.5 * kPi)) / perimeter;
    }
    if (position.x > rightTangent && position.y > bottomTangent) {
        float2 local = position - float2(rightTangent, bottomTangent);
        float angle = clamp(atan2(local.y, local.x), 0.0, 0.5 * kPi);
        return (horizontalLength + cornerLength + verticalLength + radius * angle) / perimeter;
    }
    if (position.x < -rightTangent && position.y > bottomTangent) {
        float2 local = position - float2(-rightTangent, bottomTangent);
        float angle = clamp(atan2(local.y, local.x), 0.5 * kPi, kPi);
        return (
            horizontalLength + 2.0 * cornerLength + verticalLength
            + horizontalLength + radius * (angle - 0.5 * kPi)
        ) / perimeter;
    }
    if (position.x < -rightTangent && position.y < -bottomTangent) {
        float2 local = position - float2(-rightTangent, -bottomTangent);
        float angle = atan2(local.y, local.x);
        if (angle < 0.0) {
            angle += kTwoPi;
        }
        angle = clamp(angle, kPi, 1.5 * kPi);
        return (
            2.0 * horizontalLength + 3.0 * cornerLength + 2.0 * verticalLength
            + radius * (angle - kPi)
        ) / perimeter;
    }

    float topDistance = abs(position.y + halfSize.y);
    float rightDistance = abs(position.x - halfSize.x);
    float bottomDistance = abs(position.y - halfSize.y);
    float leftDistance = abs(position.x + halfSize.x);
    float closest = min(min(topDistance, rightDistance), min(bottomDistance, leftDistance));

    if (closest == topDistance) {
        return clamp(position.x + rightTangent, 0.0, horizontalLength) / perimeter;
    }
    if (closest == rightDistance) {
        return (
            horizontalLength + cornerLength
            + clamp(position.y + bottomTangent, 0.0, verticalLength)
        ) / perimeter;
    }
    if (closest == bottomDistance) {
        return (
            horizontalLength + 2.0 * cornerLength + verticalLength
            + clamp(rightTangent - position.x, 0.0, horizontalLength)
        ) / perimeter;
    }
    return (
        2.0 * horizontalLength + 3.0 * cornerLength + verticalLength
        + clamp(bottomTangent - position.y, 0.0, verticalLength)
    ) / perimeter;
}

vertex VoiceEdgeVertexOut voiceEdgeVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };
    float2 position = positions[vertexID];

    VoiceEdgeVertexOut output;
    output.position = float4(position, 0.0, 1.0);
    output.uv = float2((position.x + 1.0) * 0.5, (1.0 - position.y) * 0.5);
    return output;
}

fragment float4 voiceEdgeFragment(
    VoiceEdgeVertexOut input [[stage_in]],
    constant VoiceEdgeUniforms &uniforms [[buffer(0)]]
) {
    float2 viewport = uniforms.viewportAndScale.xy;
    float2 pixel = input.uv * viewport;
    float2 sourceCenter = uniforms.sourceCenterAndHalfSize.xy;
    float2 sourceHalfSize = uniforms.sourceCenterAndHalfSize.zw;
    float progress = saturateValue(uniforms.timing.y);
    float effectOpacity = saturateValue(uniforms.timing.z);
    float audio = saturateValue(uniforms.timing.w);
    float screenRadius = max(uniforms.geometryAndAccessibility.x, 1.0);
    float sourceRadius = max(uniforms.geometryAndAccessibility.y, 1.0);
    bool reducedMotion = uniforms.geometryAndAccessibility.z > 0.5;
    bool reducedTransparency = uniforms.geometryAndAccessibility.w > 0.5;
    float palettePhase = uniforms.visualState.x;
    float launchEnergy = saturateValue(uniforms.visualState.z);

    float averageScale = 0.5 * (uniforms.viewportAndScale.z + uniforms.viewportAndScale.w);
    float perimeterInset = max(3.0 * averageScale, 2.0);
    float2 screenCenter = viewport * 0.5;
    float2 screenHalfSize = max(screenCenter - float2(perimeterInset), float2(2.0));

    float sourceSignedDistance = roundedBoxDistance(
        pixel - sourceCenter,
        sourceHalfSize,
        min(sourceRadius, min(sourceHalfSize.x, sourceHalfSize.y))
    );
    float sourceOutsideDistance = max(sourceSignedDistance, 0.0);
    float sourceBorderDistance = abs(sourceSignedDistance);

    float sourcePresence = reducedMotion
        ? 1.0 - smoothstep(0.0, 0.88, progress)
        : 1.0 - smoothstep(0.18, 0.78, progress);
    float sourceCore = 0.0;
    float sourceBloom = 0.0;
    if (sourcePresence > 0.0001) {
        // Source light only contributes near the trigger. During committed
        // launch the rest of the screen still needs ray/dim evaluation, but it
        // should not pay two exponentials whose result is effectively zero.
        if (sourceBorderDistance <= 24.0 * averageScale) {
            // The held control is the first visible geometry. Keep both the
            // luminous core and its halo attached to the rounded border: a
            // wide exponential here reads as a detached radial disk before
            // the propagation front has even started moving.
            sourceCore = exp(-sourceBorderDistance / max(0.82 * averageScale, 0.75));
            float sourceBloomWidth = 2.4 + launchEnergy * 2.2 + audio * 0.55;
            sourceBloom = exp(-sourceBorderDistance / max(sourceBloomWidth * averageScale, 2.0));
        } else if (progress < 0.10) {
            return float4(0.0);
        }
    }

    float screenDistance = abs(roundedBoxDistance(
        pixel - screenCenter,
        screenHalfSize,
        min(screenRadius, min(screenHalfSize.x, screenHalfSize.y))
    ));
    float coreWidth = max((1.15 + audio * 0.45) * averageScale, 1.0);
    float bloomWidth = max((6.5 + audio * 1.3) * averageScale, 3.0);
    if (reducedTransparency) {
        bloomWidth *= 0.56;
    }
    float2 delta = pixel - sourceCenter;
    float distanceFromSource = max(length(delta), 0.001);
    float2 direction = delta / distanceFromSource;
    float angle = 0.0;
    float angleUnit = 0.0;
    float launchProgress = 0.0;
    float directionVariation = 1.0;
    float directionalArrival = 0.0;
    float broadStreak = 0.0;
    float rayEnergy = 0.0;
    float engulfCoverage = reducedMotion ? progress : 0.0;
    if (!reducedMotion && progress < 0.999) {
        angle = atan2(direction.y, direction.x);
        angleUnit = fract(angle / kTwoPi + 1.0);
        float rayLimit = rayDistanceToViewport(sourceCenter, direction, viewport, perimeterInset);
        launchProgress = saturateValue((progress - 0.10) / 0.58);
        // Begin as one circular front, grow a restrained oval plus two low
        // harmonics, then resolve those lobes as the viewport itself becomes
        // the final rounded rectangle. Tying deformation to launch progress
        // keeps the shape coherent and fully deterministic under interruption.
        float organicRise = smoothstep(0.035, 0.30, launchProgress);
        float organicSettle = smoothstep(0.54, 0.94, launchProgress);
        float organicAmount = organicRise * (1.0 - 0.72 * organicSettle);
        float ovalWindow = smoothstep(0.08, 0.30, launchProgress)
            * (1.0 - smoothstep(0.58, 0.92, launchProgress));
        float organicPhase = launchProgress * 1.35 + uniforms.timing.x * 0.22;
        float ovalLobe = cos(angle * 2.0 - 0.42) * 0.075 * ovalWindow;
        float softLobes = (
            sin(angle * 3.0 + organicPhase + 0.65) * 0.038
            + sin(angle * 5.0 - organicPhase * 0.72 - 1.20) * 0.021
        ) * organicAmount;
        directionVariation = 1.0 + ovalLobe + softLobes;
        // Advance one physical wavefront across the viewport instead of
        // normalizing every direction to its own edge. Normalized rays made
        // every side light almost simultaneously; absolute distance lets the
        // plus/menu origin visibly lash into nearby edges before far corners.
        float rayFront = length(viewport) * launchProgress * directionVariation;
        directionalArrival = rayFront / max(rayLimit, 1.0);
        // A connected rounded wave leaves the source border and expands as one
        // surface. Its first frame is intentionally compact; the prior 64 pt
        // Gaussian made a 400+ px disk appear around the plus and could touch
        // the nearby screen edges before the front had propagated there.
        float frontCoreWidth = max((5.0 + 13.0 * launchProgress) * averageScale, 3.0);
        float frontHaloWidth = max((11.0 + 25.0 * launchProgress) * averageScale, 6.0);
        float narrowBase = 0.5 + 0.5 * sin(
            angle * 13.0 + sin(angle * 4.0 + organicPhase * 0.24) * 1.7
        );
        float narrowSquared = narrowBase * narrowBase;
        float narrowFourth = narrowSquared * narrowSquared;
        float narrowStreak = narrowFourth * narrowFourth * narrowSquared;
        float broadBase = 0.5 + 0.5 * sin(angle * 5.0 - 0.8);
        broadStreak = broadBase * broadBase * broadBase;
        float uniformity = 0.88 + 0.07 * narrowStreak + 0.05 * broadStreak;
        float distanceToFront = sourceOutsideDistance - rayFront;
        float frontCore = exp(-pow(distanceToFront / frontCoreWidth, 2.0));
        float frontHalo = exp(-pow(distanceToFront / frontHaloWidth, 2.0));

        // Do not let the zero-distance wave evaluate as a large launch disk.
        // During the measured charge interval the source-border field above is
        // the only visible energy; this branch becomes spatial only once the
        // front has physically left that border.
        float propagationGate = smoothstep(0.0, 0.022, launchProgress);
        float wavefront = (frontCore * 0.82 + frontHalo * 0.22) * propagationGate;

        // Deposit the opaque reading plane directly behind the same local
        // wavefront. This avoids a delayed global fade: every reached region is
        // solid, and the full display is opaque when the visual wrap closes.
        float coverageTransition = max(3.5 * averageScale, 2.5);
        engulfCoverage = launchProgress > 0.0001
            ? 1.0 - smoothstep(
                rayFront - coverageTransition,
                rayFront + coverageTransition,
                sourceOutsideDistance
            )
            : 0.0;

        // Retain a subtle connected tail without filling the whole interior
        // with the angle palette. Most energy stays on the moving solar front;
        // the long bridge is deliberately faint and drains after edge contact.
        float trailingDistance = max(rayFront - sourceOutsideDistance, 0.0);
        float nearFrontWake = engulfCoverage
            * exp(-trailingDistance / max(34.0 * averageScale, 12.0));
        float connectedBridge = engulfCoverage * 0.035 * (1.0 - launchProgress * 0.45);
        float rayFade = 1.0 - smoothstep(0.72, 0.96, progress);
        rayEnergy = (wavefront + nearFrontWake * 0.13 + connectedBridge)
            * uniformity * rayFade;
    } else if (progress >= 0.999) {
        engulfCoverage = 1.0;
    }

    // The black reading plane follows the expanding energy sheath instead of
    // globally fading ahead of it. Once the display is engulfed it completes
    // to a truly opaque surface while broad color drains into the perimeter.
    float dimAlpha = reducedMotion
        ? smoothstep(0.0, 1.0, progress)
        : engulfCoverage;

    // Once settled, most pixels are only the solid reading plane. Avoid all
    // perimeter-coordinate and palette work across that large interior area.
    if (progress >= 0.999 && screenDistance > 55.0 * averageScale) {
        return float4(0.0, 0.0, 0.0, effectOpacity);
    }

    float edgeTravel = reducedMotion ? 0.0 : palettePhase;
    float edgeEnergy = 0.0;
    float3 edgeColor = float3(0.0);
    if (screenDistance <= 55.0 * averageScale) {
        // Perimeter coordinate and palette math are only useful in the narrow
        // illuminated edge band. During launch this avoids evaluating several
        // atan2/sin/exp operations for the broad screen interior, where only
        // the analytic ray field and dim layer can contribute.
        float perimeterCoordinate = roundedPerimeterCoordinate(
            pixel - screenCenter,
            screenHalfSize,
            min(screenRadius, min(screenHalfSize.x, screenHalfSize.y))
        );
        float directionalContact = smoothstep(0.90, 1.02, directionalArrival);
        float settledContact = reducedMotion
            ? smoothstep(0.10, 1.0, progress)
            : smoothstep(0.64, 0.68, progress);
        float edgeContact = max(
            directionalContact * (0.62 + 0.38 * broadStreak),
            settledContact
        );
        float edgeCore = exp(-screenDistance / coreWidth);
        float edgeBloom = exp(-screenDistance / bloomWidth);
        edgeEnergy = edgeContact * (0.70 * edgeCore + 0.72 * edgeBloom);

        // The reference lobes drift at about one lap every 26.5 seconds, but
        // do not rotate as a perfectly rigid strip. Two subtle harmonics create
        // the measured deformation without another render pass.
        float paletteWarp = reducedMotion ? 0.0
            : 0.012 * sin(perimeterCoordinate * kTwoPi * 2.0 + uniforms.timing.x * 0.11)
              + 0.006 * sin(perimeterCoordinate * kTwoPi * 5.0 - uniforms.timing.x * 0.07);
        float lobeBrightness = reducedMotion ? 1.0
            : 0.96 + 0.06 * sin(perimeterCoordinate * kTwoPi * 3.0 + uniforms.timing.x * 0.09);
        edgeColor = voicePalette(perimeterCoordinate + edgeTravel + paletteWarp)
            * lobeBrightness;
    }

    // A minimal radial field lives only inside the evolving launch surface.
    // It shares the same angular/progress phase as the shape deformation, so
    // it reads as color moving within one soft material—not a second overlay.
    // The field drains before the final perimeter state and is never spatially
    // animated when Reduced Motion is enabled.
    float interiorEnergy = 0.0;
    float3 interiorColor = float3(0.0);
    if (!reducedMotion && launchProgress > 0.0001 && rayEnergy > 0.0001) {
        float radialUnit = saturateValue(
            sourceOutsideDistance / max(length(viewport) * launchProgress, 1.0)
        );
        float interiorWindow = smoothstep(0.035, 0.24, launchProgress)
            * (1.0 - smoothstep(0.70, 0.96, progress));
        // Reuse the front's deformation rather than evaluating more
        // trigonometry across the covered screen interior. A smoothed triangle
        // wave supplies the soft radial variation at substantially lower cost.
        float radialWarp = (directionVariation - 1.0) * 0.22;
        float radialCycle = fract(
            (1.0 - radialUnit) * 0.68 + angleUnit * 2.0 + launchProgress * 0.28
        );
        float softRadialLobe = smoothstep(
            0.12,
            0.88,
            1.0 - abs(radialCycle * 2.0 - 1.0)
        );
        interiorEnergy = engulfCoverage * interiorWindow
            * (0.024 + 0.026 * softRadialLobe);
        interiorColor = voicePalette(
            angleUnit * 0.46 + radialUnit * 0.22 + edgeTravel * 0.24 + radialWarp
        );
    }
    float3 rayColor = rayEnergy > 0.0001
        ? voicePalette(angleUnit + edgeTravel * 0.7 + 0.08)
        : float3(0.0);
    float sourceCoreWeight = 0.48 + launchEnergy * 0.26;
    float sourceBloomWeight = 0.30 + launchEnergy * 0.34;
    float sourceEnergy = sourcePresence
        * (sourceCoreWeight * sourceCore + sourceBloomWeight * sourceBloom);
    float3 sourceColor = float3(0.0);
    if (sourceEnergy > 0.0001) {
        // Keep the charge attached to the actual rounded source border. An
        // angle-from-center palette made the seed read as a detached pinwheel;
        // perimeter coordinates preserve the plus/menu item's spatial identity
        // and also avoid a full-screen palette lookup once its energy is zero.
        float sourcePerimeterCoordinate = roundedPerimeterCoordinate(
            pixel - sourceCenter,
            sourceHalfSize,
            min(sourceRadius, min(sourceHalfSize.x, sourceHalfSize.y))
        );
        sourceColor = voicePalette(sourcePerimeterCoordinate + edgeTravel * 0.4);
    }

    float3 glow = sourceColor * sourceEnergy
        + rayColor * rayEnergy * 0.92
        + interiorColor * interiorEnergy
        + edgeColor * edgeEnergy * (1.0 + audio * 0.14);
    float glowAlpha = saturateValue(
        sourceEnergy * 0.72 + rayEnergy * 0.74
        + interiorEnergy * 0.55 + edgeEnergy * 0.86
    );
    float outputAlpha = saturateValue(dimAlpha + (1.0 - dimAlpha) * glowAlpha) * effectOpacity;
    float3 premultipliedColor = glow * effectOpacity;
    premultipliedColor = min(premultipliedColor, float3(outputAlpha));
    return float4(premultipliedColor, outputAlpha);
}

vertex VoiceParticleVertexOut voiceParticleVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant VoiceEdgeUniforms &uniforms [[buffer(0)]],
    const device VoiceParticleSeed *seeds [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };

    VoiceParticleSeed seed = seeds[instanceID];
    float2 viewport = uniforms.viewportAndScale.xy;
    float averageScale = 0.5 * (uniforms.viewportAndScale.z + uniforms.viewportAndScale.w);
    float time = uniforms.timing.x;
    float progress = saturateValue(uniforms.timing.y);
    float effectOpacity = saturateValue(uniforms.timing.z);
    float audio = saturateValue(uniforms.timing.w);
    float particleEnabled = uniforms.visualState.y;

    // A 4.65 s base lifecycle across a 320 pt maximum span yields a visibly
    // quicker ~69 pt/s stream. Per-seed speed (0.82–1.24x), phase, scale,
    // opacity, and two-frequency lateral drift are generated once on the CPU;
    // variation is organic but repeatable and requires no runtime spawning.
    float lifecycle = fract(seed.originPhaseSpeedSize.y + time * 0.215 * seed.originPhaseSpeedSize.z);
    float driftPhase = time * seed.dynamics.y + seed.dynamics.w * kTwoPi;
    float horizontalDrift = (
        sin(driftPhase) + 0.34 * sin(driftPhase * 1.73 + seed.dynamics.w * kPi)
    ) * seed.dynamics.x * 7.0 * averageScale;
    float verticalSpan = min(viewport.y * 0.34, 320.0 * averageScale);
    float2 center = float2(
        seed.originPhaseSpeedSize.x * viewport.x + horizontalDrift,
        viewport.y - (18.0 * averageScale + lifecycle * verticalSpan)
    );
    // Audio may gently brighten the stream but never changes geometry.
    // Seeded half-sizes produce crisp 1.8–3.0 pt diameters without blur.
    float size = seed.originPhaseSpeedSize.w * averageScale;
    float2 pixel = center + corners[vertexID] * size;
    float2 clip = float2(
        pixel.x / viewport.x * 2.0 - 1.0,
        1.0 - pixel.y / viewport.y * 2.0
    );

    float appear = smoothstep(0.0, 0.055, lifecycle);
    float disappear = 1.0 - smoothstep(0.60, 0.90, lifecycle);
    float activation = smoothstep(0.48, 0.90, progress);
    float alpha = appear * disappear * activation * particleEnabled * effectOpacity
        * seed.dynamics.z * (0.42 + audio * 0.07);
    // Particles are neutral light rather than miniature palette samples. The
    // solar ray and perimeter carry the color hierarchy; particles stay white.
    float3 color = float3(1.0);

    VoiceParticleVertexOut output;
    output.position = float4(clip, 0.0, 1.0);
    output.localPosition = corners[vertexID];
    output.color = float4(color, alpha);
    return output;
}

fragment float4 voiceParticleFragment(VoiceParticleVertexOut input [[stage_in]]) {
    float radius = length(input.localPosition);
    // Solid white core plus a narrow analytic antialias band. Unlike the old
    // 54%-radius falloff this cannot read as a fuzzy glow, while the small edge
    // transition avoids visibly stair-stepped circles at one point per pixel.
    float coverage = 1.0 - smoothstep(0.82, 1.0, radius);
    float alpha = input.color.a * coverage;
    return float4(input.color.rgb * alpha, alpha);
}
