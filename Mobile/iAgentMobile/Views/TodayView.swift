import SwiftUI
import iAgentCore

struct TodayView: View {
  @ObservedObject var model: MobileAppModel

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.55) {
        hero
      } drawer: {
        VStack(spacing: 0) {
          JoiWeekStrip(selectedDate: Date())
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
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 0) {
      JoiDayMasthead(date: Date()) {
        model.isCalendarPresented = true
      }

      briefing
        .padding(.top, 42)

      HStack(spacing: 18) {
        JoiHeroMetric(
          symbol: "calendar",
          value: "\(model.todayEvents.count) today",
          color: PanelTheme.coral
        )
        JoiHeroMetric(
          symbol: "sparkles",
          value: "\(model.activeThreads.count) live",
          color: PanelTheme.green
        )
        JoiHeroMetric(
          symbol: "checkmark.square",
          value: "\(model.openTodos.count) open",
          color: PanelTheme.blue
        )
      }
      .padding(.top, 28)

      Spacer(minLength: 26)
    }
    .padding(.horizontal, PanelTheme.horizontalPadding)
    .padding(.top, 10)
  }

  private var briefing: some View {
    briefingText
      .font(.system(size: 23, weight: .semibold))
      .lineSpacing(3)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityLabel(briefingAccessibilityText)
  }

  private var briefingText: Text {
    let eventCount = model.todayEvents.count
    let threadCount = model.activeThreads.count
    let todoCount = model.openTodos.count
    let name = model.firstName.map { ", \($0)" } ?? ""

    return Text("\(greeting)\(name).\n")
      .foregroundStyle(PanelTheme.secondary)
      + Text("You have ")
      .foregroundStyle(PanelTheme.secondary)
      + Text(Image(systemName: "calendar"))
      .foregroundStyle(PanelTheme.primary)
      + Text(" \(eventCount) \(eventCount == 1 ? "event" : "events"),\n")
      .foregroundStyle(PanelTheme.primary)
      + Text(Image(systemName: "sparkles"))
      .foregroundStyle(PanelTheme.primary)
      + Text(" \(threadCount) Codex \(threadCount == 1 ? "task" : "tasks") ")
      .foregroundStyle(PanelTheme.primary)
      + Text("and ")
      .foregroundStyle(PanelTheme.secondary)
      + Text(Image(systemName: "checkmark.square"))
      .foregroundStyle(PanelTheme.primary)
      + Text(" \(todoCount) \(todoCount == 1 ? "todo" : "todos").\n")
      .foregroundStyle(PanelTheme.primary)
      + Text(scheduleOutlook)
      .foregroundStyle(PanelTheme.secondary)
  }

  @ViewBuilder
  private var timeline: some View {
    let events = Array(model.todayEvents.prefix(3))
    let threads = Array(model.activeThreads.prefix(2))
    let todos = Array(model.openTodos.prefix(2))

    if events.isEmpty && threads.isEmpty && todos.isEmpty {
      EmptyPanelState(
        symbol: "sun.max",
        title: "A quiet day",
        detail: "Nothing is asking for your attention right now."
      )
    } else {
      ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
        JoiCalendarRow(model: model, event: event)
        if index < events.count - 1 || !threads.isEmpty || !todos.isEmpty {
          JoiDottedDivider()
        }
      }

      ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
        JoiCodexRow(thread: thread)
          .onTapGesture { model.selectedTab = .codex }
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
    let now = Date()
    if let current = model.todayEvents.first(where: { $0.isHappening(at: now) }) {
      return "You're in \(current.title) until \(current.endDate.formatted(date: .omitted, time: .shortened))."
    }
    if let next = model.todayEvents.first(where: { $0.isAllDay || $0.startDate > now }) {
      return "Next is \(next.title) at \(next.startDate.formatted(date: .omitted, time: .shortened))."
    }
    return "You're mostly free for the rest of today."
  }

  private var briefingAccessibilityText: String {
    "\(greeting). You have \(model.todayEvents.count) events, \(model.activeThreads.count) live Codex tasks, and \(model.openTodos.count) todos. \(scheduleOutlook)"
  }
}

struct JoiCalendarRow: View {
  @ObservedObject var model: MobileAppModel
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
          Button {
            model.presentRecorder(title: event.title, calendarEventID: event.id)
          } label: {
            Circle()
              .fill(PanelTheme.coral)
              .frame(width: 9, height: 9)
              .frame(width: 26, height: 30)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Record \(event.title)")
        }

        if let link = event.linkURLs.first {
          Button { model.open(link) } label: {
            Image(systemName: "arrow.up.right")
              .font(.system(size: 12, weight: .bold))
              .foregroundStyle(PanelTheme.blue)
              .frame(width: 26, height: 30)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Open meeting link")
        }

        Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(PanelTheme.secondary)
          .monospacedDigit()
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
    let hour = Calendar.autoupdatingCurrent.component(.hour, from: event.startDate)
    if hour < 11 { return PanelTheme.sun }
    if hour >= 18 { return PanelTheme.violet }
    return PanelTheme.secondary
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

struct JoiTodoSummaryRow: View {
  @ObservedObject var model: MobileAppModel
  let todo: SyncedTodo

  var body: some View {
    JoiTimelineRow(minHeight: 62) {
      Button {
        Task { await model.toggleTodo(todo) }
      } label: {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(PanelTheme.secondary, lineWidth: 1.4)
          .frame(width: 22, height: 22)
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Complete \(todo.title)")
    } content: {
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
    } trailing: {
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
}

struct CalendarMobileView: View {
  @ObservedObject var model: MobileAppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    PanelScreen {
      ScrollView {
        VStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 16) {
            JoiBackButton { dismiss() }
            JoiDayMasthead(date: Date())
          }
          .padding(.horizontal, PanelTheme.horizontalPadding)
          .padding(.top, 8)
          .padding(.bottom, 24)

          JoiTimelineSheet {
            VStack(spacing: 0) {
              JoiWeekStrip(selectedDate: Date())
              JoiDottedDivider(inset: 20)

              if model.todayEvents.isEmpty {
                EmptyPanelState(
                  symbol: "sun.max",
                  title: "A clear day",
                  detail: "There are no events on today's calendar."
                )
              } else {
                ForEach(Array(model.todayEvents.enumerated()), id: \.element.id) { index, event in
                  JoiCalendarRow(model: model, event: event)
                  if index < model.todayEvents.count - 1 { JoiDottedDivider() }
                }
              }
            }
            .padding(.bottom, 96)
          }
        }
      }
      .scrollIndicators(.hidden)
      .refreshable { await model.refresh() }
    }
    .toolbar(.hidden, for: .navigationBar)
  }
}

extension SyncedCalendarEvent {
  func isHappening(at date: Date) -> Bool {
    !isAllDay && startDate <= date && endDate > date
  }
}
