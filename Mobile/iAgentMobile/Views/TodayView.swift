import SwiftUI
import iAgentCore

struct TodayView: View {
  @ObservedObject var model: MobileAppModel
  let onNavigateToTab: (MobileAppModel.Tab) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dayFlowDirection: CGFloat = 1

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.55) {
        hero
      } drawer: {
        VStack(spacing: 0) {
          JoiWeekStrip(selectedDate: $model.selectedCalendarDate) {
            model.selectCalendarDate($0)
          }
          JoiDottedDivider(inset: 20)
          timeline
        }
        .padding(.bottom, 96)
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .navigationDestination(isPresented: $model.isCalendarPresented) {
      CalendarMobileView(model: model)
    }
    .navigationDestination(isPresented: $model.isMessagesPresented) {
      MessagesMobileView(model: model)
    }
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 0) {
      JoiDayMasthead(date: model.selectedCalendarDate) {
        showCalendar()
      }

      briefing
        .padding(.top, 42)

      HStack(spacing: 8) {
        HStack(spacing: 18) {
          Button {
            showCalendar()
          } label: {
            JoiHeroMetric(
              symbol: "calendar",
              value: "\(model.selectedCalendarEvents.count) scheduled",
              color: PanelTheme.coral,
              direction: dayFlowDirection
            )
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(calendarMetricAccessibilityLabel)
          .accessibilityHint("Opens Calendar")
          .accessibilityIdentifier("today-calendar-metric")

          Button {
            onNavigateToTab(.codex)
          } label: {
            JoiHeroMetric(
              assetName: "CodexBlossom",
              value: "\(model.activeThreads.count) live",
              color: PanelTheme.green,
              direction: dayFlowDirection
            )
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(codexMetricAccessibilityLabel)
          .accessibilityHint("Switches to the Codex tab")
          .accessibilityIdentifier("today-codex-metric")

          Button {
            onNavigateToTab(.todos)
          } label: {
            JoiHeroMetric(
              symbol: "checkmark.square",
              value: "\(model.openTodos.count) open",
              color: PanelTheme.blue,
              direction: dayFlowDirection
            )
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(todoMetricAccessibilityLabel)
          .accessibilityHint("Switches to the To-dos tab")
          .accessibilityIdentifier("today-todos-metric")
        }
        .layoutPriority(1)

        Spacer(minLength: 0)

        SettingsButton(showsAttentionBadge: settingsNeedsAttention) {
          model.isSettingsPresented = true
        }
        .fixedSize()
      }
      .padding(.top, 28)

      Spacer(minLength: 26)
    }
    .padding(.horizontal, PanelTheme.horizontalPadding)
    .padding(.top, 10)
    .onChange(of: model.selectedCalendarDate) { previous, next in
      dayFlowDirection = next >= previous ? 1 : -1
    }
  }

  private var settingsNeedsAttention: Bool {
    model.syncPendingCount > 0
      || model.syncStatus.phase == .failed
      || model.syncStatus.phase == .accountUnavailable
  }

  private var briefing: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("\(greeting)\(briefingName).")
        .foregroundStyle(PanelTheme.secondary)

      TodayInlineFlowLayout(horizontalSpacing: 5, verticalSpacing: 2) {
        Text("You have")
          .foregroundStyle(PanelTheme.secondary)

        briefingLink(
          symbol: "calendar",
          text: "\(model.selectedCalendarEvents.count) \(model.selectedCalendarEvents.count == 1 ? "event" : "events"),",
          accessibilityLabel: calendarBriefingAccessibilityLabel,
          accessibilityHint: "Opens Calendar"
        ) {
          showCalendar()
        }

        briefingLink(
          symbol: "sparkles",
          text: "\(model.activeThreads.count) Codex \(model.activeThreads.count == 1 ? "task" : "tasks")",
          accessibilityLabel: codexBriefingAccessibilityLabel,
          accessibilityHint: "Switches to the Codex tab"
        ) {
          onNavigateToTab(.codex)
        }

        Text("and")
          .foregroundStyle(PanelTheme.secondary)

        briefingLink(
          symbol: "checkmark.square",
          text: "\(model.openTodos.count) \(model.openTodos.count == 1 ? "todo" : "todos").",
          accessibilityLabel: todoBriefingAccessibilityLabel,
          accessibilityHint: "Switches to the To-dos tab"
        ) {
          onNavigateToTab(.todos)
        }
      }

      Text(scheduleOutlook)
        .foregroundStyle(PanelTheme.secondary)
    }
      .font(.system(size: 23, weight: .semibold))
      .lineSpacing(3)
      .fixedSize(horizontal: false, vertical: true)
      .contentTransition(.numericText(countsDown: dayFlowDirection < 0))
      .animation(PanelTheme.disclosure, value: model.selectedCalendarDate)
      .accessibilityElement(children: .contain)
  }

  private var briefingName: String {
    model.firstName.map { ", \($0)" } ?? ""
  }

  private func briefingLink(
    symbol: String,
    text: String,
    accessibilityLabel: String,
    accessibilityHint: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: symbol)
        Text(text)
      }
      .foregroundStyle(PanelTheme.primary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(accessibilityHint)
  }

  @ViewBuilder
  private var timeline: some View {
    let events = model.selectedCalendarEvents
    let threads = Array(model.activeThreads.prefix(2))
    let todos = Array(model.openTodos.prefix(2))
    let messageSummary = model.homeUnreadMessageSummary()
    let messageItems = messageSummary.contactItems
    let remainingUnreadMessageCount = messageSummary.remainingUnreadMessageCount
    let hasMessageRows = !messageItems.isEmpty || remainingUnreadMessageCount > 0

    if !hasMessageRows && events.isEmpty && threads.isEmpty && todos.isEmpty {
      EmptyPanelState(
        symbol: "sun.max",
        title: "A quiet day",
        detail: "Nothing is asking for your attention right now."
      )
    } else {
      ForEach(Array(messageItems.enumerated()), id: \.element.id) { index, item in
        JoiDrawerButton {
          model.presentMessages(conversationID: item.conversationID)
        } label: {
          JoiHomeUnreadMessageRow(item: item)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unread message from \(item.contactName)")
        .accessibilityValue(
          "\(item.previewText). \(item.latestUnreadMessage.sentAt.compactRelative())"
        )
        .accessibilityHint("Opens recent message history")

        if index < messageItems.count - 1
          || remainingUnreadMessageCount > 0
          || !events.isEmpty
          || !threads.isEmpty
          || !todos.isEmpty
        {
          JoiDottedDivider()
        }
      }

      if remainingUnreadMessageCount > 0 {
        JoiDrawerButton {
          model.presentMessages()
        } label: {
          JoiUnreadMessagesOverflowRow(count: remainingUnreadMessageCount)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "\(remainingUnreadMessageCount) more unread "
            + (remainingUnreadMessageCount == 1 ? "message" : "messages")
        )
        .accessibilityHint("Opens the Messages page")

        if !events.isEmpty || !threads.isEmpty || !todos.isEmpty {
          JoiDottedDivider()
        }
      }

      ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
        JoiDrawerNavigationLink {
          CalendarEventDetailView(model: model, event: event)
        } label: {
          JoiCalendarRow(event: event)
        }
        .buttonStyle(.plain)
        if index < events.count - 1 || !threads.isEmpty || !todos.isEmpty {
          JoiDottedDivider()
        }
      }

      ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
        JoiDrawerButton {
          onNavigateToTab(.codex)
        } label: {
          JoiCodexRow(thread: thread)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Codex task \(thread.title)")
        .accessibilityHint("Switches to the Codex tab")
        if index < threads.count - 1 || !todos.isEmpty {
          JoiDottedDivider()
        }
      }

      ForEach(Array(todos.enumerated()), id: \.element.id) { index, todo in
        JoiTodoSummaryRow(model: model, todo: todo)
        if index < todos.count - 1 { JoiDottedDivider() }
      }
    }
  }

  private var greeting: String {
    switch Calendar.autoupdatingCurrent.component(.hour, from: Date()) {
    case 0 ..< 12: "Good morning"
    case 12 ..< 17: "Good afternoon"
    default: "Good evening"
    }
  }

  private var scheduleOutlook: String {
    let events = model.selectedCalendarEvents
    let calendar = Calendar.autoupdatingCurrent
    let now = Date()
    if calendar.isDateInToday(model.selectedCalendarDate),
       let current = events.first(where: { $0.isHappening(at: now) }) {
      return "You're in \(current.title) until \(current.endDate.formatted(date: .omitted, time: .shortened))."
    }
    if calendar.isDateInToday(model.selectedCalendarDate),
       let next = events.first(where: { $0.isAllDay || $0.startDate > now }) {
      return next.isAllDay
        ? "\(next.title) is on the calendar all day."
        : "Next is \(next.title) at \(next.startDate.formatted(date: .omitted, time: .shortened))."
    }
    if let first = events.first {
      return first.isAllDay
        ? "\(first.title) is scheduled all day."
        : "\(first.title) starts at \(first.startDate.formatted(date: .omitted, time: .shortened))."
    }
    return calendar.isDateInToday(model.selectedCalendarDate)
      ? "You're mostly free for the rest of today."
      : "Nothing is scheduled for this day."
  }

  private var calendarBriefingAccessibilityLabel: String {
    let count = model.selectedCalendarEvents.count
    return "Calendar, \(count) \(count == 1 ? "event" : "events")"
  }

  private var calendarMetricAccessibilityLabel: String {
    let count = model.selectedCalendarEvents.count
    return "Calendar, \(count) scheduled \(count == 1 ? "event" : "events")"
  }

  private var codexBriefingAccessibilityLabel: String {
    let count = model.activeThreads.count
    return "Codex, \(count) \(count == 1 ? "task" : "tasks")"
  }

  private var todoBriefingAccessibilityLabel: String {
    let count = model.openTodos.count
    return "To-dos, \(count) \(count == 1 ? "todo" : "todos")"
  }

  private var codexMetricAccessibilityLabel: String {
    let count = model.activeThreads.count
    return "Codex, \(count) live \(count == 1 ? "task" : "tasks")"
  }

  private var todoMetricAccessibilityLabel: String {
    let count = model.openTodos.count
    return "Todos, \(count) open \(count == 1 ? "todo" : "todos")"
  }

  private func showCalendar() {
    if reduceMotion {
      model.isCalendarPresented = true
    } else {
      withAnimation(PanelTheme.disclosure) {
        model.isCalendarPresented = true
      }
    }
  }
}

private struct TodayInlineFlowLayout: Layout {
  let horizontalSpacing: CGFloat
  let verticalSpacing: CGFloat

  private struct Placement {
    var origin: CGPoint
    let size: CGSize
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    measure(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    let placements = measure(maxWidth: bounds.width, subviews: subviews).placements
    for (index, placement) in placements.enumerated() {
      subviews[index].place(
        at: CGPoint(
          x: bounds.minX + placement.origin.x,
          y: bounds.minY + placement.origin.y
        ),
        proposal: ProposedViewSize(
          width: placement.size.width,
          height: placement.size.height
        )
      )
    }
  }

  private func measure(
    maxWidth: CGFloat,
    subviews: Subviews
  ) -> (size: CGSize, placements: [Placement]) {
    var placements: [Placement] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var lineStart = 0
    var measuredWidth: CGFloat = 0

    func centerCurrentLine() {
      guard lineStart < placements.count else { return }
      for index in lineStart ..< placements.count {
        placements[index].origin.y += (lineHeight - placements[index].size.height) / 2
      }
    }

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let proposedX = x == 0 ? 0 : x + horizontalSpacing
      if proposedX > 0, proposedX + size.width > maxWidth {
        centerCurrentLine()
        measuredWidth = max(measuredWidth, x)
        y += lineHeight + verticalSpacing
        x = 0
        lineHeight = 0
        lineStart = placements.count
      }

      let itemX = x == 0 ? 0 : x + horizontalSpacing
      placements.append(Placement(origin: CGPoint(x: itemX, y: y), size: size))
      x = itemX + size.width
      lineHeight = max(lineHeight, size.height)
    }

    centerCurrentLine()
    measuredWidth = max(measuredWidth, x)
    return (
      CGSize(width: measuredWidth, height: y + lineHeight),
      placements
    )
  }
}

struct JoiCalendarRow: View {
  let event: SyncedCalendarEvent

  var body: some View {
    JoiTimelineRow(minHeight: 62) {
      Image(systemName: eventSymbol)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(eventColor)
    } content: {
      HStack(spacing: 8) {
        Text(event.title)
          .font(.system(size: 16, weight: isCurrent ? .bold : .semibold))
          .foregroundStyle(PanelTheme.primary)
          .lineLimit(1)

        if isCurrent {
          Text("NOW")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(PanelTheme.coral)
        }
      }
    } trailing: {
      HStack(spacing: 9) {
        if isCurrent || startsSoon {
          Circle()
            .fill(PanelTheme.coral)
            .frame(width: 9, height: 9)
        }

        if !event.linkURLs.isEmpty {
          Image(systemName: "arrow.up.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(PanelTheme.blue)
        }

        Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(PanelTheme.secondary)
          .monospacedDigit()
          .contentTransition(.numericText())
          .animation(PanelTheme.disclosure, value: event.startDate)

        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(PanelTheme.tertiary)
      }
    }
  }

  private var eventSymbol: String {
    if event.isAllDay { return "asterisk" }
    let hour = Calendar.autoupdatingCurrent.component(.hour, from: event.startDate)
    if hour < 11 { return "sun.max.fill" }
    if hour >= 18 { return "moon.fill" }
    return "calendar"
  }

  private var eventColor: Color {
    if isCurrent { return PanelTheme.coral }
    return event.panelAccent
  }

  private var isCurrent: Bool { event.isHappening(at: Date()) }
  private var startsSoon: Bool {
    let interval = event.startDate.timeIntervalSinceNow
    return interval > 0 && interval <= 600
  }
}

struct JoiCodexRow: View {
  let thread: SyncedCodexThread

  var body: some View {
    JoiTimelineRow(minHeight: 62) {
      StatusMark(state: thread.state)
    } content: {
      HStack(spacing: 10) {
        Text(thread.title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(PanelTheme.primary)
          .lineLimit(1)
          .layoutPriority(1)

        if let project = thread.projectName {
          Text(project)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PanelTheme.tertiary)
            .lineLimit(1)
        }
      }
    } trailing: {
      Text(thread.updatedAt.compactRelative())
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
        .monospacedDigit()
    }
  }
}

private struct JoiHomeUnreadMessageRow: View {
  let item: MobileHomeUnreadMessageItem

  var body: some View {
    JoiTimelineRow(minHeight: 62) {
      JoiMessageAvatar(
        displayName: item.contactName,
        identity: item.conversationID,
        size: 24
      )
    } content: {
      HStack(spacing: 0) {
        Text(item.contactName)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(PanelTheme.primary)
          .lineLimit(1)
          .layoutPriority(2)

        Text(item.previewText)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(PanelTheme.tertiary)
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(.leading, 8)

        Spacer(minLength: 20)

        Circle()
          .fill(PanelTheme.coral)
          .frame(width: 7, height: 7)

        Text(item.latestUnreadMessage.sentAt.compactRelative())
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(PanelTheme.secondary)
          .monospacedDigit()
          .padding(.leading, 8)

        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(PanelTheme.tertiary)
          .padding(.leading, 8)
      }
    } trailing: {
      EmptyView()
    }
  }
}

private struct JoiUnreadMessagesOverflowRow: View {
  let count: Int

  var body: some View {
    JoiTimelineRow(minHeight: 62) {
      Image(systemName: "message")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
    } content: {
      Text("\(count) more unread \(count == 1 ? "message" : "messages")")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
        .lineLimit(1)
    } trailing: {
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(PanelTheme.tertiary)
    }
  }
}

struct JoiTodoSummaryRow: View {
  @ObservedObject var model: MobileAppModel
  let todo: SyncedTodo

  var body: some View {
    HStack(spacing: 14) {
      JoiDrawerButton {
        Task { await model.toggleTodo(id: todo.id) }
      } label: {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(PanelTheme.secondary, lineWidth: 1.4)
          .frame(width: 24, height: 24)
          .frame(width: 36, height: 36)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Complete \(todo.title)")

      JoiDrawerNavigationLink {
        TodoDetailView(model: model, todoID: todo.id)
      } label: {
        HStack(spacing: 10) {
          HStack(spacing: 10) {
            Text(todo.title)
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(PanelTheme.primary)
              .lineLimit(1)
              .layoutPriority(1)

            if let listName = todo.listName {
              Text(listName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PanelTheme.tertiary)
                .lineLimit(1)
            }
          }

          Spacer(minLength: 8)
          todoTrailingMetadata
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Open \(todo.title)")
      .accessibilityHint("Shows todo details")
    }
    .padding(.horizontal, 24)
    .frame(minHeight: 62)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var todoTrailingMetadata: some View {
    if todo.isStarred {
      Image(systemName: "star.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(PanelTheme.amber)
    } else if let dueDate = todo.dueDate {
      Text(dueDate.formatted(date: .omitted, time: .shortened))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
    }
  }
}

struct CalendarMobileView: View {
  @ObservedObject var model: MobileAppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.34) {
        calendarHero
      } drawer: {
        LazyVStack(spacing: 0) {
          JoiWeekStrip(selectedDate: $model.selectedCalendarDate) {
            model.selectCalendarDate($0)
          }
          JoiDottedDivider(inset: 20)
          calendarSourceControl
          JoiDottedDivider(inset: 20)

          JoiSectionHeader(
            title: "Synced from Mac",
            count: model.selectedCalendarEvents.count
          )

          if model.selectedCalendarEvents.isEmpty {
            EmptyPanelState(
              symbol: model.hasDesktopSnapshot ? "sun.max" : "desktopcomputer",
              title: model.hasDesktopSnapshot ? "A clear day" : "Waiting for your Mac",
              detail: model.hasDesktopSnapshot
                ? "The Mac calendar has no events on this day."
                : "No synced desktop calendar snapshot has reached this iPhone."
            )
          } else {
            ForEach(Array(model.selectedCalendarEvents.enumerated()), id: \.element.id) { index, event in
              JoiDrawerNavigationLink {
                CalendarEventDetailView(model: model, event: event)
              } label: {
                JoiCalendarRow(event: event)
              }
              .buttonStyle(.plain)
              if index < model.selectedCalendarEvents.count - 1 { JoiDottedDivider() }
            }
          }

          if model.showsPhoneCalendarEvents {
            JoiSectionHeader(
              title: "On this iPhone",
              count: model.selectedPhoneCalendarEvents.count
            )

            if model.selectedPhoneCalendarEvents.isEmpty {
              Text("No additional phone-only events on this day.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PanelTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
            } else {
              ForEach(
                Array(model.selectedPhoneCalendarEvents.enumerated()),
                id: \.element.id
              ) { index, event in
                JoiDrawerNavigationLink {
                  CalendarEventDetailView(model: model, event: event)
                } label: {
                  JoiCalendarRow(event: event)
                }
                .buttonStyle(.plain)
                if index < model.selectedPhoneCalendarEvents.count - 1 {
                  JoiDottedDivider()
                }
              }
            }
          }
        }
        .padding(.bottom, 96)
      }
    }
    .toolbar(.hidden, for: .navigationBar)
  }

  private var calendarHero: some View {
    VStack(alignment: .leading, spacing: 16) {
      JoiBackButton { dismiss() }
      JoiDayMasthead(date: model.selectedCalendarDate)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, PanelTheme.horizontalPadding)
    .padding(.top, 8)
  }

  private var calendarSourceControl: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("CALENDAR SOURCE")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(PanelTheme.tertiary)
        Text("Mac events drive the dashboard count")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(PanelTheme.secondary)
      }

      Spacer(minLength: 8)

      JoiDrawerButton {
        withAnimation(PanelTheme.quick) {
          model.setShowsPhoneCalendarEvents(!model.showsPhoneCalendarEvents)
        }
      } label: {
        Label(
          model.showsPhoneCalendarEvents ? "Hide iPhone" : "Show iPhone",
          systemImage: model.showsPhoneCalendarEvents ? "iphone.slash" : "iphone"
        )
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(PanelTheme.primary)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(PanelTheme.surface, in: Capsule())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 16)
  }
}

private struct CalendarEventDetailView: View {
  @ObservedObject var model: MobileAppModel
  let event: SyncedCalendarEvent
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    PanelScreen {
      ScrollView {
        VStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 22) {
            JoiBackButton { dismiss() }

            Text(event.title)
              .font(.system(size: 36, weight: .bold))
              .foregroundStyle(PanelTheme.primary)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
              Circle()
                .fill(event.panelAccent)
                .frame(width: 9, height: 9)
              Text(event.calendarTitle)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(event.panelAccent)

              if event.isHappening(at: Date()) {
                Text("·")
                  .foregroundStyle(PanelTheme.tertiary)
                Text("Happening now")
                  .font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(PanelTheme.coral)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, PanelTheme.horizontalPadding)
          .padding(.top, 8)
          .padding(.bottom, 28)

          JoiTimelineSheet {
            VStack(alignment: .leading, spacing: 0) {
              Text("EVENT DETAILS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(PanelTheme.tertiary)
                .padding(.bottom, 22)

              metadataRow(symbol: "calendar", title: "Date", value: dateSummary)
              detailDivider
              metadataRow(symbol: "clock", title: "Time", value: timeSummary)

              if let location = event.location?.nonEmpty {
                detailDivider
                metadataRow(symbol: "location", title: "Location", value: location)
              }

              detailDivider
              metadataRow(symbol: "rectangle.stack", title: "Calendar", value: event.calendarTitle)
              detailDivider
              metadataRow(
                symbol: model.isPhoneOnlyCalendarEvent(event) ? "iphone" : "desktopcomputer",
                title: "Source",
                value: model.isPhoneOnlyCalendarEvent(event)
                  ? "On this iPhone · excluded from synced count"
                  : "Synced from Mac · included in dashboard count"
              )

              if let notes = event.notes?.nonEmpty {
                detailDivider
                metadataRow(symbol: "note.text", title: "Notes", value: notes)
              }

              if !event.linkURLs.isEmpty {
                detailDivider
                VStack(alignment: .leading, spacing: 12) {
                  Label("LINKS", systemImage: "link")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(PanelTheme.tertiary)

                  ForEach(event.linkURLs, id: \.absoluteString) { link in
                    Button { model.open(link) } label: {
                      HStack(spacing: 10) {
                        Text(link.host ?? link.absoluteString)
                          .font(.system(size: 15, weight: .semibold))
                          .foregroundStyle(PanelTheme.primary)
                          .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                          .font(.system(size: 12, weight: .bold))
                          .foregroundStyle(PanelTheme.blue)
                      }
                      .padding(.horizontal, 14)
                      .frame(height: 46)
                      .background(PanelTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                  }
                }
              }

              if !event.isAllDay, event.endDate > Date() {
                detailDivider
                Button {
                  model.presentRecorder(title: event.title, calendarEventID: event.id)
                } label: {
                  Label("Record this meeting", systemImage: "waveform")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(PanelTheme.primary, in: Capsule())
                }
                .buttonStyle(.plain)
              }

              Text("Updated \(event.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PanelTheme.tertiary)
                .padding(.top, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 100)
          }
        }
      }
      .scrollIndicators(.hidden)
    }
    .toolbar(.hidden, for: .navigationBar)
  }

  @ViewBuilder
  private func metadataRow(symbol: String, title: String, value: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(event.panelAccent)
        .frame(width: 20, alignment: .center)

      VStack(alignment: .leading, spacing: 5) {
        Text(title.uppercased())
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(PanelTheme.tertiary)
        Text(value)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(PanelTheme.primary)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var detailDivider: some View {
    JoiDottedDivider(inset: 0)
      .padding(.vertical, 18)
  }

  private var dateSummary: String {
    let start = event.startDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    let inclusiveEnd = event.isAllDay ? event.endDate.addingTimeInterval(-1) : event.endDate
    guard !Calendar.autoupdatingCurrent.isDate(event.startDate, inSameDayAs: inclusiveEnd) else {
      return start
    }
    return "\(start) – \(inclusiveEnd.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))"
  }

  private var timeSummary: String {
    if event.isAllDay { return "All day" }
    if Calendar.autoupdatingCurrent.isDate(event.startDate, inSameDayAs: event.endDate) {
      return "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
    }
    return "\(event.startDate.formatted(date: .abbreviated, time: .shortened)) – \(event.endDate.formatted(date: .abbreviated, time: .shortened))"
  }
}

extension SyncedCalendarEvent {
  func isHappening(at date: Date) -> Bool {
    !isAllDay && startDate <= date && endDate > date
  }

  fileprivate var panelAccent: Color {
    guard let calendarColorHex else { return PanelTheme.secondary }
    let hex = calendarColorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return PanelTheme.secondary }
    return Color(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }
}

private extension String {
  var nonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
