import SwiftUI
import UIKit
import iAgentCore

enum PanelTheme {
  static let canvas = Color.black
  static let sheet = Color(red: 0.105, green: 0.105, blue: 0.11)
  static let sheetRaised = Color(red: 0.145, green: 0.145, blue: 0.15)
  static let surface = Color.white.opacity(0.055)
  static let raisedSurface = Color.white.opacity(0.09)
  static let selectedSurface = Color.white.opacity(0.12)
  static let border = Color.white.opacity(0.075)
  static let strongBorder = Color.white.opacity(0.15)
  static let primary = Color.white.opacity(0.96)
  static let secondary = Color.white.opacity(0.48)
  static let tertiary = Color.white.opacity(0.25)

  static let coral = Color(red: 1.0, green: 0.32, blue: 0.29)
  static let sun = Color(red: 1.0, green: 0.74, blue: 0.25)
  static let green = Color(red: 0.2, green: 0.84, blue: 0.5)
  static let amber = Color(red: 0.96, green: 0.72, blue: 0.25)
  static let blue = Color(red: 0.16, green: 0.62, blue: 1.0)
  static let violet = Color(red: 0.46, green: 0.39, blue: 1.0)

  static let horizontalPadding: CGFloat = 24
  static let sheetRadius: CGFloat = 42
  static let quick = Animation.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.2)
  static let shimmer = Animation.linear(duration: 1.35).repeatForever(autoreverses: false)
  static let disclosure = Animation.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.3)
  static let pageTransition = Animation.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.3)
  static let drawerSnap = Animation.smooth(duration: 0.34, extraBounce: 0)
  static let dockSelection = Animation.smooth(duration: 0.24, extraBounce: 0)
  static let dockExpand = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.28)
  static let dockCollapse = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
}

struct PanelScreen<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(PanelTheme.canvas.ignoresSafeArea())
      .foregroundStyle(PanelTheme.primary)
      .toolbarBackground(PanelTheme.canvas, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
  }
}

struct JoiDayMasthead: View {
  let date: Date
  var action: (() -> Void)?

  @State private var flowDirection: CGFloat = 1

  var body: some View {
    Button { action?() } label: { masthead }
    .buttonStyle(.plain)
    .allowsHitTesting(action != nil)
  }

  private var masthead: some View {
    HStack(alignment: .center) {
      HStack(alignment: .lastTextBaseline, spacing: 8) {
        MobileNumberFlowText(
          dayNumber,
          fontSize: 52,
          weight: .bold,
          color: PanelTheme.primary,
          reservedWidth: 74,
          alignment: .leading,
          direction: flowDirection,
          lineHeight: 64
        )

        Circle()
          .fill(PanelTheme.coral)
          .frame(width: 12, height: 12)
          .padding(.bottom, 5)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 0) {
        MobileNumberFlowText(
          monthAndYear,
          fontSize: 17,
          weight: .semibold,
          color: PanelTheme.secondary,
          reservedWidth: 76,
          alignment: .trailing,
          direction: flowDirection,
          lineHeight: 22
        )
        Text(date.formatted(.dateTime.weekday(.wide)))
      }
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(PanelTheme.secondary)
      .multilineTextAlignment(.trailing)
    }
    .contentShape(Rectangle())
    .onChange(of: date) { previous, next in
      flowDirection = next >= previous ? 1 : -1
    }
  }

  private var dayNumber: String {
    String(format: "%02d", Calendar.autoupdatingCurrent.component(.day, from: date))
  }

  private var monthAndYear: String {
    let calendar = Calendar.autoupdatingCurrent
    let month = date.formatted(.dateTime.month(.abbreviated))
    let year = calendar.component(.year, from: date) % 100
    return "\(month)'\(String(format: "%02d", year))"
  }
}

struct JoiPageMasthead: View {
  let title: String
  let metric: String
  let metricLabel: String
  var accent = PanelTheme.coral

  var body: some View {
    HStack(alignment: .center) {
      HStack(alignment: .lastTextBaseline, spacing: 8) {
        Text(title)
          .font(.system(size: 45, weight: .bold))
          .foregroundStyle(PanelTheme.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)

        Circle()
          .fill(accent)
          .frame(width: 11, height: 11)
          .padding(.bottom, 5)
      }

      Spacer(minLength: 16)

      VStack(alignment: .trailing, spacing: 0) {
        MobileNumberFlowText(
          metric,
          fontSize: 16,
          weight: .semibold,
          color: PanelTheme.primary,
          alignment: .trailing,
          direction: 1,
          lineHeight: 20
        )
        Text(metricLabel)
          .foregroundStyle(PanelTheme.secondary)
      }
      .font(.system(size: 16, weight: .semibold))
      .multilineTextAlignment(.trailing)
    }
  }
}

private enum JoiHeroMetricIcon {
  case system(String)
  case asset(String)
}

struct JoiHeroMetric: View {
  private let icon: JoiHeroMetricIcon
  let value: String
  var color = PanelTheme.primary
  var direction: CGFloat = 1

  init(
    symbol: String,
    value: String,
    color: Color = PanelTheme.primary,
    direction: CGFloat = 1
  ) {
    icon = .system(symbol)
    self.value = value
    self.color = color
    self.direction = direction
  }

  init(
    assetName: String,
    value: String,
    color: Color = PanelTheme.primary,
    direction: CGFloat = 1
  ) {
    icon = .asset(assetName)
    self.value = value
    self.color = color
    self.direction = direction
  }

  var body: some View {
    HStack(spacing: 6) {
      metricIcon
      MobileNumberFlowText(
        value,
        fontSize: 12,
        weight: .semibold,
        color: PanelTheme.primary,
        alignment: .leading,
        direction: direction,
        lineHeight: 16
      )
    }
  }

  @ViewBuilder
  private var metricIcon: some View {
    switch icon {
    case let .system(symbol):
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(color)
    case let .asset(assetName):
      Image(assetName)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 13, height: 13)
        .foregroundStyle(color)
    }
  }
}

struct JoiTimelineSheet<Content: View>: View {
  let minHeight: CGFloat
  @ViewBuilder let content: Content

  init(minHeight: CGFloat = 620, @ViewBuilder content: () -> Content) {
    self.minHeight = minHeight
    self.content = content()
  }

  var body: some View {
    content
      .frame(
        maxWidth: .infinity,
        maxHeight: minHeight == 0 ? .infinity : nil,
        alignment: .topLeading
      )
      .frame(minHeight: minHeight, alignment: .top)
      .background {
        UnevenRoundedRectangle(
          topLeadingRadius: PanelTheme.sheetRadius,
          bottomLeadingRadius: 0,
          bottomTrailingRadius: 0,
          topTrailingRadius: PanelTheme.sheetRadius,
          style: .continuous
        )
        .fill(PanelTheme.sheet)
      }
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: PanelTheme.sheetRadius,
          bottomLeadingRadius: 0,
          bottomTrailingRadius: 0,
          topTrailingRadius: PanelTheme.sheetRadius,
          style: .continuous
        )
      )
  }
}

private struct JoiDrawerActivationGateKey: EnvironmentKey {
  static let defaultValue: DrawerActivationGate? = nil
}

private struct JoiDrawerNavigationActionKey: EnvironmentKey {
  nonisolated(unsafe) static let defaultValue: ((AnyView) -> Void)? = nil
}

extension EnvironmentValues {
  /// Reference-semantic so UIKit can close the gate synchronously before the
  /// SwiftUI button action produced by the same touch is evaluated.
  var joiDrawerActivationGate: DrawerActivationGate? {
    get { self[JoiDrawerActivationGateKey.self] }
    set { self[JoiDrawerActivationGateKey.self] = newValue }
  }

  fileprivate var joiDrawerNavigationAction: ((AnyView) -> Void)? {
    get { self[JoiDrawerNavigationActionKey.self] }
    set { self[JoiDrawerNavigationActionKey.self] = newValue }
  }
}

/// A drawer-aware button that preserves its label's appearance while suppressing
/// actions from the touch currently being used to pan the shared sheet.
struct JoiDrawerButton<Label: View>: View {
  @Environment(\.joiDrawerActivationGate) private var activationGate

  let role: ButtonRole?
  let action: () -> Void
  @ViewBuilder let label: Label

  init(
    role: ButtonRole? = nil,
    action: @escaping () -> Void,
    @ViewBuilder label: () -> Label
  ) {
    self.role = role
    self.action = action
    self.label = label()
  }

  var body: some View {
    Button(role: role) {
      if let activationGate {
        activationGate.performIfAllowed(action)
      } else {
        action()
      }
    } label: {
      label
    }
  }
}

/// Navigation counterpart to ``JoiDrawerButton``. The drawer owns the actual
/// NavigationStack presentation so this control can gate its action without
/// disabling, recoloring, or removing the label during a pan.
struct JoiDrawerNavigationLink<Destination: View, Label: View>: View {
  @Environment(\.joiDrawerActivationGate) private var activationGate
  @Environment(\.joiDrawerNavigationAction) private var navigate

  @ViewBuilder let destination: Destination
  @ViewBuilder let label: Label

  init(
    @ViewBuilder destination: () -> Destination,
    @ViewBuilder label: () -> Label
  ) {
    self.destination = destination()
    self.label = label()
  }

  var body: some View {
    Button {
      let navigationAction: () -> Void = {
        navigate?(AnyView(destination))
      }
      if let activationGate {
        activationGate.performIfAllowed(navigationAction)
      } else {
        navigationAction()
      }
    } label: {
      label
    }
  }
}

struct JoiDrawerPage<Hero: View, DrawerContent: View>: View {
  let restingFraction: CGFloat
  let expandedTop: CGFloat
  @ViewBuilder let hero: Hero
  @ViewBuilder let drawerContent: DrawerContent

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isExpanded: Bool
  @State private var drawerTranslation: CGFloat = 0
  @State private var activationGate = DrawerActivationGate()
  @State private var navigationDestination: AnyView?

  init(
    restingFraction: CGFloat = 0.54,
    expandedTop: CGFloat = 82,
    @ViewBuilder hero: () -> Hero,
    @ViewBuilder drawer: () -> DrawerContent
  ) {
    self.restingFraction = restingFraction
    self.expandedTop = expandedTop
    self.hero = hero()
    self.drawerContent = drawer()
    _isExpanded = State(
      initialValue: ProcessInfo.processInfo.arguments.contains("--drawer-expanded")
    )
  }

  var body: some View {
    GeometryReader { proxy in
      let upperDetent = min(expandedTop, max(0, proxy.size.height - 190))
      let lowerDetent = restingTop(in: proxy.size.height, upperDetent: upperDetent)
      let detentTravel = lowerDetent - upperDetent
      let drawerTop = clamped(
        (isExpanded ? upperDetent : lowerDetent) + drawerTranslation,
        lower: upperDetent,
        upper: lowerDetent
      )

      ZStack(alignment: .top) {
        hero
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .frame(height: lowerDetent, alignment: .top)

        drawer(
          height: proxy.size.height - upperDetent,
          detentTravel: detentTravel
        )
          .offset(y: drawerTop)
          .zIndex(1)
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
      .clipped()
    }
    .accessibilityAction(named: isExpanded ? "Collapse list" : "Expand list") {
      settleDrawer(at: !isExpanded)
    }
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .sensoryFeedback(.impact(weight: .light, intensity: 0.45), trigger: isExpanded)
    .navigationDestination(
      isPresented: Binding(
        get: { navigationDestination != nil },
        set: { if !$0 { navigationDestination = nil } }
      )
    ) {
      navigationDestination
    }
  }

  private func drawer(height: CGFloat, detentTravel: CGFloat) -> some View {
    JoiTimelineSheet(minHeight: 0) {
      scrollView(detentTravel: detentTravel)
    }
    .frame(height: height, alignment: .top)
    .contentShape(Rectangle())
    .overlay(alignment: .top) {
      Capsule(style: .continuous)
        .fill(PanelTheme.strongBorder)
        .frame(width: 34, height: 4)
        .padding(.top, 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  private func scrollView(detentTravel: CGFloat) -> some View {
    ScrollView {
      Color.clear
        .frame(height: 0)
        .background(
          JoiDrawerScrollConfigurator(
            isExpanded: $isExpanded,
            drawerTranslation: $drawerTranslation,
            activationGate: activationGate,
            detentTravel: detentTravel,
            onSettle: settleDrawer
          )
        )

      drawerContent
        .environment(\.joiDrawerActivationGate, activationGate)
        .environment(\.joiDrawerNavigationAction) { destination in
          navigationDestination = destination
        }
    }
    .scrollDismissesKeyboard(.interactively)
    .scrollIndicators(.hidden)
  }

  private func settleDrawer(at targetIsExpanded: Bool) {
    let animation = reduceMotion ? Animation.linear(duration: 0.12) : PanelTheme.drawerSnap
    withAnimation(animation) {
      isExpanded = targetIsExpanded
      drawerTranslation = 0
    }
  }

  private func restingTop(in height: CGFloat, upperDetent: CGFloat) -> CGFloat {
    let desired = height * restingFraction
    return clamped(desired, lower: upperDetent + 150, upper: max(upperDetent + 150, height - 170))
  }

  private func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }
}

struct JoiWeekStrip: View {
  @Binding var selectedDate: Date
  let onSelect: (Date) -> Void

  private var days: [Date] {
    let calendar = Calendar.autoupdatingCurrent
    let today = calendar.startOfDay(for: Date())
    return (-30 ... 90).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
  }

  init(
    selectedDate: Binding<Date>,
    onSelect: @escaping (Date) -> Void = { _ in }
  ) {
    _selectedDate = selectedDate
    self.onSelect = onSelect
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 4) {
          ForEach(days, id: \.self) { day in
            let selected = Calendar.autoupdatingCurrent.isDate(day, inSameDayAs: selectedDate)
            JoiDrawerButton {
              selectedDate = day
              onSelect(day)
            } label: {
              VStack(spacing: 4) {
                Text(day.formatted(.dateTime.day()))
                  .font(.system(size: 15, weight: selected ? .bold : .semibold))
                  .foregroundStyle(selected ? PanelTheme.primary : PanelTheme.tertiary)
                Text(day.formatted(.dateTime.weekday(.narrow)).uppercased())
                  .font(.system(size: 8, weight: .bold))
                  .foregroundStyle(selected ? PanelTheme.coral : PanelTheme.tertiary)
              }
              .frame(width: 46, height: 48)
              .background {
                if selected {
                  RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(PanelTheme.strongBorder, lineWidth: 1)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(dayID(day))
            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            .accessibilityAddTraits(selected ? .isSelected : [])
          }
        }
        .scrollTargetLayout()
        .padding(.horizontal, 20)
      }
      .scrollIndicators(.hidden)
      .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
      .onAppear {
        proxy.scrollTo(dayID(selectedDate), anchor: .center)
      }
      .onChange(of: selectedDate) { _, date in
        withAnimation(PanelTheme.quick) {
          proxy.scrollTo(dayID(date), anchor: .center)
        }
      }
    }
    .padding(.top, 20)
    .padding(.bottom, 14)
  }

  private func dayID(_ date: Date) -> Int {
    Int(Calendar.autoupdatingCurrent.startOfDay(for: date).timeIntervalSinceReferenceDate)
  }
}

struct JoiDottedDivider: View {
  var inset: CGFloat = 24

  var body: some View {
    Canvas { context, size in
      var path = Path()
      path.move(to: CGPoint(x: 0, y: 0.5))
      path.addLine(to: CGPoint(x: size.width, y: 0.5))
      context.stroke(
        path,
        with: .color(PanelTheme.strongBorder),
        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 6])
      )
    }
    .frame(height: 1)
    .padding(.leading, inset)
    .padding(.trailing, 20)
  }
}

struct JoiSectionHeader: View {
  let title: String
  var count: Int?

  var body: some View {
    HStack(spacing: 8) {
      Text(title.uppercased())
      if let count {
        MobileNumberFlowText(
          "\(count)",
          fontSize: 10,
          weight: .bold,
          color: PanelTheme.tertiary,
          direction: 1,
          lineHeight: 14
        )
      }
      Spacer()
    }
    .font(.system(size: 10, weight: .bold))
    .foregroundStyle(PanelTheme.tertiary)
    .padding(.horizontal, 24)
    .frame(height: 38)
  }
}

/// Arbitrates the drawer and content pans at the UIKit recognizer layer.
///
/// The custom drawer pan gets first refusal. It begins only for an upward pan on
/// a collapsed drawer, or a downward pan that starts while expanded content is
/// already at its top boundary. Otherwise it fails and the native UIScrollView
/// pan proceeds. Ownership is fixed for the whole touch sequence, so the sheet
/// and its content can never move simultaneously or hand off with a visual jump.
private struct JoiDrawerScrollConfigurator: UIViewRepresentable {
  @Binding var isExpanded: Bool
  @Binding var drawerTranslation: CGFloat
  let activationGate: DrawerActivationGate
  let detentTravel: CGFloat
  let onSettle: (Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isExpanded: $isExpanded,
      drawerTranslation: $drawerTranslation,
      activationGate: activationGate,
      detentTravel: detentTravel,
      onSettle: onSettle
    )
  }

  func makeUIView(context: Context) -> UIView {
    let view = UIView(frame: .zero)
    DispatchQueue.main.async { context.coordinator.attach(from: view) }
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    context.coordinator.update(
      isExpanded: $isExpanded,
      drawerTranslation: $drawerTranslation,
      activationGate: activationGate,
      detentTravel: detentTravel,
      onSettle: onSettle
    )
    DispatchQueue.main.async { context.coordinator.attach(from: uiView) }
  }

  static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
    coordinator.detach()
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isExpanded: Binding<Bool>
    var drawerTranslation: Binding<CGFloat>
    var activationGate: DrawerActivationGate
    var detentTravel: CGFloat
    var onSettle: (Bool) -> Void

    private weak var scrollView: UIScrollView?
    private weak var interactionScrollView: UIScrollView?
    private var drawerPan: UIPanGestureRecognizer?
    private var activationPan: UIPanGestureRecognizer?
    private var displayLink: CADisplayLink?
    private var releaseWorkItem: DispatchWorkItem?
    private var drawerStartedExpanded = false

    init(
      isExpanded: Binding<Bool>,
      drawerTranslation: Binding<CGFloat>,
      activationGate: DrawerActivationGate,
      detentTravel: CGFloat,
      onSettle: @escaping (Bool) -> Void
    ) {
      self.isExpanded = isExpanded
      self.drawerTranslation = drawerTranslation
      self.activationGate = activationGate
      self.detentTravel = detentTravel
      self.onSettle = onSettle
    }

    func update(
      isExpanded: Binding<Bool>,
      drawerTranslation: Binding<CGFloat>,
      activationGate: DrawerActivationGate,
      detentTravel: CGFloat,
      onSettle: @escaping (Bool) -> Void
    ) {
      self.isExpanded = isExpanded
      self.drawerTranslation = drawerTranslation
      self.activationGate = activationGate
      self.detentTravel = detentTravel
      self.onSettle = onSettle
      configureScrollEnabledState()
    }

    func attach(from view: UIView) {
      var ancestor = view.superview
      while let current = ancestor {
        if let enclosingScrollView = current as? UIScrollView {
          configure(enclosingScrollView)
          return
        }
        ancestor = current.superview
      }
    }

    func detach() {
      releaseWorkItem?.cancel()
      releaseWorkItem = nil
      displayLink?.invalidate()
      displayLink = nil
      if let scrollView {
        scrollView.panGestureRecognizer.removeTarget(self, action: #selector(contentPanChanged(_:)))
        if let drawerPan {
          scrollView.removeGestureRecognizer(drawerPan)
        }
        if let activationPan {
          scrollView.removeGestureRecognizer(activationPan)
        }
      }
      drawerPan?.delegate = nil
      drawerPan = nil
      activationPan?.delegate = nil
      activationPan = nil
      interactionScrollView = nil
      scrollView = nil
      setDrawerTranslation(0)
      setBlocked(false)
    }

    private func configure(_ scrollView: UIScrollView) {
      scrollView.bounces = false
      scrollView.alwaysBounceVertical = false
      scrollView.isDirectionalLockEnabled = true
      scrollView.contentInsetAdjustmentBehavior = .never
      scrollView.delaysContentTouches = true
      scrollView.canCancelContentTouches = true
      scrollView.panGestureRecognizer.cancelsTouchesInView = true
      scrollView.panGestureRecognizer.delaysTouchesBegan = true
      scrollView.panGestureRecognizer.delaysTouchesEnded = true

      if self.scrollView !== scrollView {
        detach()
        self.scrollView = scrollView

        let drawerPan = UIPanGestureRecognizer(target: self, action: #selector(drawerPanChanged(_:)))
        drawerPan.delegate = self
        drawerPan.maximumNumberOfTouches = 1
        drawerPan.cancelsTouchesInView = true
        drawerPan.delaysTouchesBegan = false
        drawerPan.delaysTouchesEnded = true
        scrollView.addGestureRecognizer(drawerPan)
        self.drawerPan = drawerPan

        // Observe every pan that starts anywhere inside the drawer, including
        // horizontal note actions and nested horizontal date strips. This
        // recognizer never owns movement; it only closes the synchronous action
        // gate and is allowed to recognize alongside the actual gesture owner.
        let activationPan = UIPanGestureRecognizer(
          target: self,
          action: #selector(activationPanChanged(_:))
        )
        activationPan.delegate = self
        activationPan.maximumNumberOfTouches = 1
        activationPan.cancelsTouchesInView = true
        activationPan.delaysTouchesBegan = false
        activationPan.delaysTouchesEnded = true
        scrollView.addGestureRecognizer(activationPan)
        self.activationPan = activationPan

        // Apple documents this failure relationship as the deterministic way to
        // prefer one recognizer. Native scrolling waits only until the drawer
        // recognizer decides whether this touch belongs to the drawer.
        scrollView.panGestureRecognizer.require(toFail: drawerPan)
        scrollView.panGestureRecognizer.addTarget(
          self,
          action: #selector(contentPanChanged(_:))
        )
      }

      configureScrollEnabledState()
    }

    private func configureScrollEnabledState() {
      guard let scrollView else { return }
      // Keep the UIScrollView enabled at both detents. UIKit documents that a
      // disabled scroll view stops accepting touch events, which would also
      // starve the drawer recognizer attached to it. The failure relationship
      // above—not toggling this property—is what prevents content movement:
      // while collapsed an upward pan belongs to `drawerPan`, so the native pan
      // fails before changing contentOffset.
      scrollView.isScrollEnabled = true

      if !isExpanded.wrappedValue {
        let topOffset = -scrollView.adjustedContentInset.top
        if abs(scrollView.contentOffset.y - topOffset) > 0.5 {
          scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: topOffset),
            animated: false
          )
        }
      }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard gestureRecognizer === drawerPan,
            let pan = gestureRecognizer as? UIPanGestureRecognizer,
            let scrollView
      else { return true }

      let velocity = pan.velocity(in: scrollView)
      let topOffset = -scrollView.adjustedContentInset.top
      let owner = DrawerGestureArbitration.owner(
        isExpanded: isExpanded.wrappedValue,
        contentOffset: Double(scrollView.contentOffset.y),
        topOffset: Double(topOffset),
        horizontalVelocity: Double(velocity.x),
        verticalVelocity: Double(velocity.y)
      )

      guard owner == .drawer else { return false }
      drawerStartedExpanded = isExpanded.wrappedValue
      return true
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      gestureRecognizer === activationPan || otherGestureRecognizer === activationPan
    }

    @objc private func activationPanChanged(_ recognizer: UIPanGestureRecognizer) {
      switch recognizer.state {
      case .began:
        releaseWorkItem?.cancel()
        interactionScrollView = scrollViewUnderTouch(recognizer)
        setBlocked(true)
      case .changed:
        releaseWorkItem?.cancel()
        setBlocked(true)
      case .ended, .cancelled, .failed:
        startMonitoring()
        DispatchQueue.main.async { [weak self] in self?.monitorScrollState() }
      default:
        break
      }
    }

    @objc private func drawerPanChanged(_ recognizer: UIPanGestureRecognizer) {
      guard let scrollView else { return }

      switch recognizer.state {
      case .began:
        releaseWorkItem?.cancel()
        setBlocked(true)
        setDrawerTranslation(0)
      case .changed:
        let rawTranslation = recognizer.translation(in: scrollView).y
        let directedTranslation = drawerStartedExpanded
          ? max(0, rawTranslation)
          : min(0, rawTranslation)
        setDrawerTranslation(
          min(max(directedTranslation, -detentTravel), detentTravel)
        )
      case .ended:
        finishDrawerPan(recognizer, cancelled: false)
      case .cancelled, .failed:
        finishDrawerPan(recognizer, cancelled: true)
      default:
        break
      }
    }

    private func finishDrawerPan(_ recognizer: UIPanGestureRecognizer, cancelled: Bool) {
      guard let scrollView else { return }
      let targetIsExpanded: Bool

      if cancelled {
        targetIsExpanded = drawerStartedExpanded
      } else {
        let velocity = recognizer.velocity(in: scrollView).y
        targetIsExpanded = DrawerGestureArbitration.targetIsExpanded(
          startedExpanded: drawerStartedExpanded,
          translation: Double(drawerTranslation.wrappedValue),
          verticalVelocity: Double(velocity),
          detentTravel: Double(detentTravel)
        )
      }

      onSettle(targetIsExpanded)
      scheduleActivationRelease(after: 0.18)
    }

    @objc private func contentPanChanged(_ recognizer: UIPanGestureRecognizer) {

      switch recognizer.state {
      case .began, .changed:
        releaseWorkItem?.cancel()
        setBlocked(true)
        startMonitoring()
      case .ended, .cancelled, .failed:
        startMonitoring()
        DispatchQueue.main.async { [weak self] in self?.monitorScrollState() }
      default:
        break
      }
    }

    private func startMonitoring() {
      guard displayLink == nil else { return }
      let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
      link.add(to: .main, forMode: .common)
      displayLink = link
    }

    @objc private func displayLinkFired() {
      monitorScrollState()
    }

    private func monitorScrollState() {
      guard let scrollView else {
        finishMonitoring()
        return
      }

      let outerScrollIsMoving = scrollView.isTracking
        || scrollView.isDragging
        || scrollView.isDecelerating
      let touchedScrollIsMoving = interactionScrollView?.isTracking == true
        || interactionScrollView?.isDragging == true
        || interactionScrollView?.isDecelerating == true

      if outerScrollIsMoving || touchedScrollIsMoving {
        releaseWorkItem?.cancel()
        setBlocked(true)
        return
      }

      finishMonitoring()
      scheduleActivationRelease(after: 0.12)
    }

    private func finishMonitoring() {
      displayLink?.invalidate()
      displayLink = nil
    }

    private func scheduleActivationRelease(after delay: TimeInterval) {
      releaseWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in self?.setBlocked(false) }
      releaseWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func setDrawerTranslation(_ translation: CGFloat) {
      guard drawerTranslation.wrappedValue != translation else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        drawerTranslation.wrappedValue = translation
      }
    }

    private func setBlocked(_ blocked: Bool) {
      activationGate.setBlocked(blocked)
    }

    private func scrollViewUnderTouch(_ recognizer: UIPanGestureRecognizer) -> UIScrollView? {
      guard let scrollView else { return nil }
      let location = recognizer.location(in: scrollView)
      var candidate = scrollView.hitTest(location, with: nil)

      while let view = candidate, view !== scrollView {
        if let touchedScrollView = view as? UIScrollView {
          return touchedScrollView
        }
        candidate = view.superview
      }
      return scrollView
    }
  }
}

struct JoiAudioWaveform: View {
  let levels: [CGFloat]
  var color = PanelTheme.coral
  var isActive = true

  var body: some View {
    Canvas { context, size in
      let barCount = max(18, Int(size.width / 3.2))
      let samples = resampledLevels(count: barCount)
      let stride = size.width / CGFloat(barCount)
      let barWidth = max(1, min(1.7, stride * 0.48))

      for index in samples.indices {
        let signal = smoothedLevel(at: index, in: samples)
        let normalized = isActive ? min(1, max(0, (signal - 0.06) / 0.5)) : 0
        let height = max(2, 2 + (size.height - 2) * pow(normalized, 0.72))
        let rect = CGRect(
          x: CGFloat(index) * stride + (stride - barWidth) / 2,
          y: (size.height - height) / 2,
          width: barWidth,
          height: height
        )
        context.fill(
          Path(roundedRect: rect, cornerRadius: barWidth / 2),
          with: .color((isActive ? color : PanelTheme.tertiary).opacity(0.82))
        )
      }
    }
    .accessibilityLabel(isActive ? "Live audio level" : "Audio idle")
  }

  private func resampledLevels(count: Int) -> [CGFloat] {
    WaveformSampleProjector.project(
      levels.map { Double($0) },
      count: count,
      baseline: 0.06
    )
    .map { CGFloat($0) }
  }

  private func smoothedLevel(at index: Int, in samples: [CGFloat]) -> CGFloat {
    let previous = samples[max(0, index - 1)]
    let current = samples[index]
    let next = samples[min(samples.count - 1, index + 1)]
    return previous * 0.22 + current * 0.56 + next * 0.22
  }
}

struct MobileNumberFlowText: View {
  let text: String
  let fontSize: CGFloat
  let weight: Font.Weight
  let color: Color
  let reservedWidth: CGFloat?
  let alignment: Alignment
  let direction: CGFloat
  let lineHeight: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var previousText: String
  @State private var currentText: String
  @State private var settled = true

  init(
    _ text: String,
    fontSize: CGFloat,
    weight: Font.Weight = .medium,
    color: Color = .primary,
    reservedWidth: CGFloat? = nil,
    alignment: Alignment = .center,
    direction: CGFloat,
    lineHeight: CGFloat? = nil
  ) {
    self.text = text
    self.fontSize = fontSize
    self.weight = weight
    self.color = color
    self.reservedWidth = reservedWidth
    self.alignment = alignment
    self.direction = direction
    self.lineHeight = lineHeight ?? ceil(fontSize * 1.4)
    _previousText = State(initialValue: text)
    _currentText = State(initialValue: text)
  }

  var body: some View {
    Group {
      if reduceMotion {
        Text(text)
          .font(flowFont)
          .foregroundStyle(color)
      } else {
        flowingGlyphs
      }
    }
    .frame(width: reservedWidth, height: lineHeight, alignment: alignment)
    .clipped()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
    .onChange(of: text) { _, nextText in animate(to: nextText) }
  }

  private var flowingGlyphs: some View {
    let oldGlyphs = paddedGlyphs(previousText)
    let newGlyphs = paddedGlyphs(currentText)

    return HStack(spacing: 0) {
      ForEach(Array(zip(oldGlyphs, newGlyphs).enumerated()), id: \.offset) { _, pair in
        MobileNumberFlowGlyph(
          previous: pair.0,
          current: pair.1,
          settled: settled,
          direction: direction,
          font: flowFont,
          color: color,
          width: glyphWidth,
          height: lineHeight
        )
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var flowFont: Font { .system(size: fontSize, weight: weight, design: .monospaced) }
  private var glyphWidth: CGFloat { ceil(fontSize * 0.64) }

  private func paddedGlyphs(_ value: String) -> [Character?] {
    let width = max(previousText.count, currentText.count)
    let glyphs = Array(value).map(Optional.some)
    return Array(repeating: nil, count: max(0, width - glyphs.count)) + glyphs
  }

  private func animate(to nextText: String) {
    guard nextText != currentText else { return }
    previousText = currentText
    currentText = nextText
    guard !reduceMotion else {
      previousText = nextText
      settled = true
      return
    }

    settled = false
    DispatchQueue.main.async {
      withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.3)) {
        settled = true
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
      guard currentText == nextText else { return }
      previousText = nextText
    }
  }
}

private struct MobileNumberFlowGlyph: View {
  let previous: Character?
  let current: Character?
  let settled: Bool
  let direction: CGFloat
  let font: Font
  let color: Color
  let width: CGFloat
  let height: CGFloat

  var body: some View {
    ZStack {
      if previous == current {
        glyph(current)
      } else if isDigit(previous) || isDigit(current) {
        glyph(previous)
          .offset(y: settled ? -direction * height : 0)
          .opacity(settled ? 0 : 1)
        glyph(current)
          .offset(y: settled ? 0 : direction * height)
          .opacity(settled ? 1 : 0.35)
      } else {
        glyph(previous).opacity(settled ? 0 : 1)
        glyph(current).opacity(settled ? 1 : 0)
      }
    }
    .frame(width: width, height: height)
    .clipped()
  }

  @ViewBuilder
  private func glyph(_ character: Character?) -> some View {
    if let character {
      Text(String(character))
        .font(font)
        .foregroundStyle(color)
        .frame(width: width, height: height)
    }
  }

  private func isDigit(_ character: Character?) -> Bool { character?.isNumber == true }
}

struct JoiTimelineRow<Leading: View, Content: View, Trailing: View>: View {
  let minHeight: CGFloat
  @ViewBuilder let leading: Leading
  @ViewBuilder let content: Content
  @ViewBuilder let trailing: Trailing

  init(
    minHeight: CGFloat = 58,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder content: () -> Content,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.minHeight = minHeight
    self.leading = leading()
    self.content = content()
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: 14) {
      leading
        .frame(width: 24, height: 30)

      content
        .frame(maxWidth: .infinity, alignment: .leading)

      trailing
    }
    .padding(.horizontal, 24)
    .frame(minHeight: minHeight)
    .contentShape(Rectangle())
  }
}

// Legacy names remain as aliases while detail flows adopt the new language.
typealias PanelSectionHeader = JoiSectionHeader
typealias PanelRow = JoiTimelineRow
typealias PanelDivider = JoiDottedDivider

struct PanelIconButton: View {
  let symbol: String
  let label: String
  var color = PanelTheme.secondary
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 38, height: 38)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

struct JoiBackButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.left")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(PanelTheme.primary)
        .frame(width: 42, height: 42)
        .background(PanelTheme.surface, in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Back")
  }
}

struct StatusMark: View {
  let state: SyncedCodexState

  var body: some View {
    Group {
      switch state {
      case .running:
        ProgressView()
          .progressViewStyle(.circular)
          .tint(PanelTheme.green)
      case .waitingForInput:
        Image(systemName: "ellipsis.circle")
          .foregroundStyle(PanelTheme.blue)
      case .needsApproval:
        Image(systemName: "exclamationmark.shield")
          .foregroundStyle(PanelTheme.amber)
      case .completed:
        Circle()
          .fill(PanelTheme.tertiary)
          .frame(width: 6, height: 6)
      case .failed:
        Image(systemName: "xmark.circle")
          .foregroundStyle(PanelTheme.coral)
      }
    }
    .font(.system(size: 14, weight: .medium))
    .frame(width: 20, height: 20)
    .accessibilityLabel(state.accessibilityLabel)
  }
}

struct SyncStatusButton: View {
  let status: IAgentCloudSyncStatus
  let pendingCount: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: statusSymbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(statusColor)
        .frame(width: 38, height: 38)
        .background(PanelTheme.surface, in: Circle())
        .overlay(alignment: .topTrailing) {
          if pendingCount > 0 {
            Text("\(pendingCount)")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.black)
              .frame(width: 15, height: 15)
              .background(PanelTheme.amber, in: Circle())
          }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityText)
    .accessibilityHint("Open sync details")
    .accessibilityIdentifier("sync-status-button")
  }

  private var statusSymbol: String {
    switch status.phase {
    case .idle: pendingCount > 0 ? "icloud.and.arrow.up" : "checkmark.icloud"
    case .syncing: "arrow.triangle.2.circlepath.icloud"
    case .offline: "icloud.slash"
    case .accountUnavailable: "person.crop.circle.badge.exclamationmark"
    case .failed: "exclamationmark.icloud"
    }
  }

  private var statusColor: Color {
    switch status.phase {
    case .idle: pendingCount > 0 ? PanelTheme.amber : PanelTheme.secondary
    case .syncing: PanelTheme.blue
    case .offline: PanelTheme.secondary
    case .accountUnavailable, .failed: PanelTheme.coral
    }
  }

  private var accessibilityText: String {
    if let message = status.message { return message }
    if pendingCount > 0 { return "\(pendingCount) changes waiting to sync" }
    return status.phase == .syncing ? "Syncing" : "Synced"
  }
}

struct SettingsButton: View {
  let showsAttentionBadge: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "gearshape")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
        .frame(width: 44, height: 44)
        .background(PanelTheme.surface, in: Circle())
        .overlay(alignment: .topTrailing) {
          if showsAttentionBadge {
            Circle()
              .fill(PanelTheme.amber)
              .frame(width: 9, height: 9)
              .overlay {
                Circle().stroke(PanelTheme.canvas, lineWidth: 2)
              }
          }
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(showsAttentionBadge ? "Settings, sync needs attention" : "Settings")
    .accessibilityHint("Opens settings and sync controls")
    .accessibilityIdentifier("home.settings")
  }
}

struct EmptyPanelState: View {
  let symbol: String
  let title: String
  let detail: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 19, weight: .regular))
        .foregroundStyle(PanelTheme.tertiary)
      Text(title)
        .font(.system(size: 17, weight: .semibold))
      Text(detail)
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(PanelTheme.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 36)
    .frame(maxWidth: .infinity, minHeight: 170)
  }
}

extension SyncedCodexState {
  var accessibilityLabel: String {
    switch self {
    case .running: "Running"
    case .waitingForInput: "Waiting for input"
    case .needsApproval: "Needs approval"
    case .completed: "Completed"
    case .failed: "Failed"
    }
  }
}

extension Date {
  func compactRelative(to reference: Date = Date()) -> String {
    let elapsed = max(0, reference.timeIntervalSince(self))
    if elapsed < 60 { return "now" }
    if elapsed < 3_600 { return "\(Int(elapsed / 60))m" }
    if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h" }
    if elapsed < 2_592_000 { return "\(Int(elapsed / 86_400))d" }
    return "\(max(1, Int(elapsed / 2_592_000)))mon"
  }
}
