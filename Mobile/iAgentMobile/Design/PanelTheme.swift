import SwiftUI
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
  static let disclosure = Animation.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.3)
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

  var body: some View {
    Button { action?() } label: { masthead }
    .buttonStyle(.plain)
    .allowsHitTesting(action != nil)
  }

  private var masthead: some View {
    HStack(alignment: .center) {
      HStack(alignment: .lastTextBaseline, spacing: 8) {
        Text(dayNumber)
          .font(.system(size: 52, weight: .bold))
          .foregroundStyle(PanelTheme.primary)

        Circle()
          .fill(PanelTheme.coral)
          .frame(width: 12, height: 12)
          .padding(.bottom, 5)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 0) {
        Text(monthAndYear)
        Text(date.formatted(.dateTime.weekday(.wide)))
      }
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(PanelTheme.secondary)
      .multilineTextAlignment(.trailing)
    }
    .contentShape(Rectangle())
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
        Text(metric)
          .foregroundStyle(PanelTheme.primary)
        Text(metricLabel)
          .foregroundStyle(PanelTheme.secondary)
      }
      .font(.system(size: 16, weight: .semibold))
      .multilineTextAlignment(.trailing)
    }
  }
}

struct JoiHeroMetric: View {
  let symbol: String
  let value: String
  var color = PanelTheme.primary

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(color)
      Text(value)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(PanelTheme.primary)
        .contentTransition(.numericText())
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
      .frame(maxWidth: .infinity, alignment: .topLeading)
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
  }
}

private struct JoiDrawerScrollOffsetKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

struct JoiDrawerPage<Hero: View, DrawerContent: View>: View {
  let restingFraction: CGFloat
  let expandedTop: CGFloat
  @ViewBuilder let hero: Hero
  @ViewBuilder let drawerContent: DrawerContent

  @State private var isExpanded: Bool
  @State private var dragTranslation: CGFloat = 0
  @State private var scrollOffset: CGFloat = 0

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
      let drawerTop = clamped(
        (isExpanded ? upperDetent : lowerDetent) + dragTranslation,
        lower: upperDetent,
        upper: lowerDetent
      )

      ZStack(alignment: .top) {
        hero
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .frame(height: lowerDetent, alignment: .top)

        drawer(height: proxy.size.height - upperDetent)
          .offset(y: drawerTop)
          .zIndex(1)
          .simultaneousGesture(
            drawerDragGesture(upperDetent: upperDetent, lowerDetent: lowerDetent)
          )
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
      .clipped()
    }
    .accessibilityAction(named: isExpanded ? "Collapse list" : "Expand list") {
      withAnimation(PanelTheme.disclosure) {
        isExpanded.toggle()
        dragTranslation = 0
      }
    }
  }

  private func drawer(height: CGFloat) -> some View {
    JoiTimelineSheet(minHeight: 0) {
      scrollView
    }
    .frame(height: height, alignment: .top)
    .contentShape(Rectangle())
  }

  private var scrollView: some View {
    ScrollView {
      Color.clear
        .frame(height: 0)
        .background {
          GeometryReader { proxy in
            Color.clear.preference(
              key: JoiDrawerScrollOffsetKey.self,
              value: proxy.frame(in: .named("JoiDrawerScrollSpace")).minY
            )
          }
        }

      drawerContent
    }
    .coordinateSpace(name: "JoiDrawerScrollSpace")
    .scrollDisabled(!isExpanded)
    .scrollDismissesKeyboard(.interactively)
    .scrollIndicators(.hidden)
    .onPreferenceChange(JoiDrawerScrollOffsetKey.self) { scrollOffset = $0 }
  }

  private func drawerDragGesture(upperDetent: CGFloat, lowerDetent: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 4)
      .onChanged { value in
        guard abs(value.translation.height) > abs(value.translation.width) else {
          dragTranslation = 0
          return
        }

        if isExpanded {
          dragTranslation = scrollOffset >= -1.5
            ? max(0, value.translation.height)
            : 0
        } else {
          dragTranslation = min(0, value.translation.height)
        }
      }
      .onEnded { value in
        guard abs(value.translation.height) > abs(value.translation.width) else {
          dragTranslation = 0
          return
        }

        let travel = lowerDetent - upperDetent
        let velocityThreshold = max(44, travel * 0.16)
        let distanceThreshold = travel * 0.32
        var targetExpanded = isExpanded

        if isExpanded, scrollOffset >= -3 {
          targetExpanded = !(
            value.predictedEndTranslation.height > velocityThreshold
              || dragTranslation > distanceThreshold
          )
        } else if !isExpanded {
          targetExpanded = value.predictedEndTranslation.height < -velocityThreshold
            || dragTranslation < -distanceThreshold
        }

        withAnimation(PanelTheme.disclosure) {
          isExpanded = targetExpanded
          dragTranslation = 0
        }
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
  let selectedDate: Date

  private var days: [Date] {
    let calendar = Calendar.autoupdatingCurrent
    let day = calendar.startOfDay(for: selectedDate)
    let weekday = calendar.component(.weekday, from: day)
    let distanceFromMonday = (weekday + 5) % 7
    let monday = calendar.date(byAdding: .day, value: -distanceFromMonday, to: day) ?? day
    return (0 ..< 7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
  }

  var body: some View {
    HStack(spacing: 4) {
      ForEach(days, id: \.self) { day in
        let selected = Calendar.autoupdatingCurrent.isDate(day, inSameDayAs: selectedDate)
        VStack(spacing: 4) {
          Text(day.formatted(.dateTime.day()))
            .font(.system(size: 15, weight: selected ? .bold : .semibold))
            .foregroundStyle(selected ? PanelTheme.primary : PanelTheme.tertiary)
          Text(day.formatted(.dateTime.weekday(.narrow)).uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(selected ? PanelTheme.coral : PanelTheme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background {
          if selected {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(PanelTheme.strongBorder, lineWidth: 1)
          }
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 20)
    .padding(.bottom, 14)
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
        Text("\(count)")
          .contentTransition(.numericText())
      }
      Spacer()
    }
    .font(.system(size: 10, weight: .bold))
    .foregroundStyle(PanelTheme.tertiary)
    .padding(.horizontal, 24)
    .frame(height: 38)
  }
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
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityText)
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
