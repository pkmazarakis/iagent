import ActivityKit
import SwiftUI
import WidgetKit
import iAgentCore

private struct ProjectionEntry: TimelineEntry {
  let date: Date
  let projection: IAgentWidgetProjection
  let isProjectionAvailable: Bool

  init(
    date: Date,
    projection: IAgentWidgetProjection,
    isProjectionAvailable: Bool = true
  ) {
    self.date = date
    self.projection = projection
    self.isProjectionAvailable = isProjectionAvailable
  }
}

private struct ProjectionProvider: TimelineProvider {
  func placeholder(in context: Context) -> ProjectionEntry {
    ProjectionEntry(date: .now, projection: .preview)
  }

  func getSnapshot(in context: Context, completion: @escaping (ProjectionEntry) -> Void) {
    if context.isPreview {
      completion(ProjectionEntry(date: .now, projection: .preview))
      return
    }
    let loaded = loadProjection()
    completion(ProjectionEntry(
      date: .now,
      projection: loaded.projection,
      isProjectionAvailable: loaded.isAvailable
    ))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<ProjectionEntry>) -> Void) {
    let now = Date()
    let loaded = loadProjection()
    let entry = ProjectionEntry(
      date: now,
      projection: loaded.projection,
      isProjectionAvailable: loaded.isAvailable
    )
    var refresh = Calendar.current.date(byAdding: .minute, value: 15, to: now)
      ?? now.addingTimeInterval(900)
    if let nextMeeting = loaded.projection.nextMeeting {
      let boundaries = [nextMeeting.start, nextMeeting.end]
        .filter { $0 > now }
        .map { $0.addingTimeInterval(1) }
      if let nextBoundary = boundaries.min(), nextBoundary < refresh {
        refresh = nextBoundary
      }
    }
    completion(Timeline(entries: [entry], policy: .after(refresh)))
  }

  private func loadProjection() -> (projection: IAgentWidgetProjection, isAvailable: Bool) {
    guard let store = IAgentWidgetProjectionStore.appGroupStore(),
          let projection = try? store.load()
    else { return (.empty(), false) }
    return (projection, true)
  }
}

private enum WidgetTheme {
  static let contentInset: CGFloat = 16
  static let canvas = Color.black
  static let surface = Color.white.opacity(0.07)
  static let primary = Color.white.opacity(0.96)
  static let secondary = Color.white.opacity(0.52)
  static let tertiary = Color.white.opacity(0.30)
  static let blue = Color(red: 0.16, green: 0.62, blue: 1.0)
  static let violet = Color(red: 0.46, green: 0.39, blue: 1.0)
  static let green = Color(red: 0.2, green: 0.84, blue: 0.5)
  static let amber = Color(red: 0.96, green: 0.72, blue: 0.25)
  static let coral = Color(red: 1.0, green: 0.32, blue: 0.29)
  static let metadataFont = Font.caption2.weight(.bold)
}

private enum LockScreenMetric {
  case codex
  case calendar
  case todos
  case notes

  var title: String {
    switch self {
    case .codex: "Codex"
    case .calendar: "Calendar"
    case .todos: "Todos"
    case .notes: "Notes"
    }
  }

  var symbol: String {
    switch self {
    case .codex: "sparkles"
    case .calendar: "calendar"
    case .todos: "checkmark.square"
    case .notes: "note.text"
    }
  }

  var destination: URL {
    switch self {
    case .codex: IAgentDeepLink.codex.url
    case .calendar: IAgentDeepLink.calendar.url
    case .todos: IAgentDeepLink.todos.url
    case .notes: IAgentDeepLink.notes.url
    }
  }

  func count(in projection: IAgentWidgetProjection) -> Int {
    switch self {
    case .codex: projection.activeCodexCount
    case .calendar: projection.todayCalendarEventCount
    case .todos: projection.openTodoCount
    case .notes: projection.noteCount
    }
  }

  func accessibilityLabel(count: Int, isAvailable: Bool) -> String {
    guard isAvailable else {
      return "\(title) data unavailable. Open iAgent to sync."
    }
    switch self {
    case .codex:
      return "Codex, \(count) active \(count == 1 ? "task" : "tasks"). Opens Codex in iAgent."
    case .calendar:
      return "Calendar, \(count) \(count == 1 ? "event" : "events") today. Opens Calendar in iAgent."
    case .todos:
      return "Todos, \(count) open. Opens Todos in iAgent."
    case .notes:
      return "Notes, \(count) \(count == 1 ? "note" : "notes"). Opens Notes in iAgent."
    }
  }
}

private func compactCount(_ count: Int) -> String {
  count > 99 ? "99+" : "\(max(0, count))"
}

private struct LockScreenOverviewView: View {
  let entry: ProjectionEntry

  private var calendarCount: String {
    entry.isProjectionAvailable ? compactCount(entry.projection.todayCalendarEventCount) : "—"
  }

  private var codexCount: String {
    entry.isProjectionAvailable ? compactCount(entry.projection.activeCodexCount) : "—"
  }

  private var todoCount: String {
    entry.isProjectionAvailable ? compactCount(entry.projection.openTodoCount) : "—"
  }

  var body: some View {
    (Text(Image(systemName: "calendar"))
      + Text("  \(calendarCount)     ")
      + Text(Image(systemName: "sparkles"))
      + Text("  \(codexCount)     ")
      + Text(Image(systemName: "checkmark.square"))
      + Text("  \(todoCount)"))
      .font(.caption.weight(.semibold))
      .monospacedDigit()
      .foregroundStyle(.primary)
      .widgetAccentable()
      .lineLimit(1)
      .minimumScaleFactor(0.72)
      .containerBackground(for: .widget) { Color.clear }
      .widgetURL(IAgentDeepLink.calendar.url)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint("Opens iAgent")
  }

  private var accessibilityLabel: String {
    guard entry.isProjectionAvailable else {
      return "iAgent status unavailable. Open iAgent to sync."
    }
    let calendar = entry.projection.todayCalendarEventCount
    let codex = entry.projection.activeCodexCount
    let todos = entry.projection.openTodoCount
    return "Today: \(calendar) calendar \(calendar == 1 ? "event" : "events"), "
      + "\(codex) active Codex \(codex == 1 ? "task" : "tasks"), and "
      + "\(todos) open \(todos == 1 ? "todo" : "todos")."
  }
}

private struct LockScreenNextMeetingView: View {
  let entry: ProjectionEntry
  private let calendar = Calendar.autoupdatingCurrent

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Image(systemName: symbol)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 18, alignment: .center)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text(statusText)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .lineLimit(1)

        Text(titleText)
          .font(.headline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .privacySensitive()

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .widgetAccentable()
    .containerBackground(for: .widget) { AccessoryWidgetBackground() }
    .widgetURL(IAgentDeepLink.calendar.url)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Opens Calendar in iAgent")
  }

  private var visibleMeeting: IAgentWidgetProjection.NextMeeting? {
    guard let meeting = entry.projection.nextMeeting, meeting.end > entry.date else { return nil }
    return meeting
  }

  private var symbol: String {
    if !entry.isProjectionAvailable { return "calendar.badge.exclamationmark" }
    return visibleMeeting == nil ? "calendar.badge.checkmark" : "calendar.badge.clock"
  }

  private var titleText: String {
    guard entry.isProjectionAvailable else { return "Open iAgent to connect Calendar" }
    return visibleMeeting?.title ?? "No upcoming meetings"
  }

  private var statusText: String {
    guard entry.isProjectionAvailable else { return "CALENDAR UNAVAILABLE" }
    guard let meeting = visibleMeeting else { return "YOU’RE CLEAR" }
    if meeting.start <= entry.date {
      return "NOW · ends \(meeting.end.formatted(date: .omitted, time: .shortened))"
    }
    if calendar.isDateInToday(meeting.start) {
      return meeting.start.formatted(date: .omitted, time: .shortened)
    }
    if calendar.isDateInTomorrow(meeting.start) {
      return "TOMORROW · \(meeting.start.formatted(date: .omitted, time: .shortened))"
    }
    return meeting.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
  }

  private var accessibilityLabel: String {
    guard entry.isProjectionAvailable else {
      return "Calendar data unavailable. Open iAgent to connect Calendar."
    }
    guard let meeting = visibleMeeting else {
      return "No upcoming meetings."
    }
    if meeting.start <= entry.date {
      return "Next meeting, \(meeting.title), happening now, ending \(meeting.end.formatted(date: .omitted, time: .shortened))."
    }
    return "Next meeting, \(meeting.title), \(meeting.start.formatted(date: .complete, time: .shortened))."
  }
}

private struct LockScreenCountView: View {
  let entry: ProjectionEntry
  let metric: LockScreenMetric

  var body: some View {
    ZStack {
      AccessoryWidgetBackground()

      VStack(spacing: 0) {
        Image(systemName: metric.symbol)
          .font(.caption.weight(.semibold))
          .accessibilityHidden(true)

        Text(entry.isProjectionAvailable ? compactCount(count) : "—")
          .font(.headline.weight(.bold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      .foregroundStyle(.primary)
      .widgetAccentable()
    }
    .containerBackground(for: .widget) { Color.clear }
    .widgetURL(metric.destination)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(metric.accessibilityLabel(
      count: count,
      isAvailable: entry.isProjectionAvailable
    ))
  }

  private var count: Int {
    metric.count(in: entry.projection)
  }
}

private struct WidgetHeader: View {
  let title: String
  let metric: String
  let destination: URL

  var body: some View {
    Link(destination: destination) {
      HStack(spacing: 8) {
        Text(title)
          .font(.headline.weight(.bold))
          .foregroundStyle(WidgetTheme.primary)

        Spacer(minLength: 6)

        Text(metric)
          .font(WidgetTheme.metadataFont)
          .foregroundStyle(WidgetTheme.secondary)
          .monospacedDigit()
      }
      .contentShape(Rectangle())
    }
    .accessibilityLabel("Open \(title), \(metric)")
  }
}

private struct SetupState: View {
  let noun: String
  let destination: URL

  var body: some View {
    Link(destination: destination) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Open iAgent")
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(WidgetTheme.primary)
        Text("Your \(noun) will appear here.")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(WidgetTheme.secondary)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
  }
}

private struct TodosWidgetView: View {
  let entry: ProjectionEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    VStack(alignment: .leading, spacing: family == .systemLarge ? 11 : 8) {
      WidgetHeader(
        title: "Todos",
        metric: "\(entry.projection.openTodoCount) open",
        destination: IAgentDeepLink.todos.url
      )

      if entry.projection.todos.isEmpty {
        Link(destination: IAgentDeepLink.createTodo.url) {
          HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .stroke(WidgetTheme.secondary, lineWidth: 1.2)
              .frame(width: 17, height: 17)
            Text("No open todos")
              .font(.caption.weight(.semibold))
              .foregroundStyle(WidgetTheme.secondary)
            Spacer(minLength: 4)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .accessibilityLabel("No open todos. Open a new todo draft.")
      } else {
        VStack(spacing: 0) {
          ForEach(Array(entry.projection.todos.prefix(itemLimit).enumerated()), id: \.element.id) { index, todo in
            Link(destination: IAgentDeepLink.todo(todo.id).url) {
              HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                  .stroke(WidgetTheme.secondary, lineWidth: 1.2)
                  .frame(width: 17, height: 17)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text(todo.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetTheme.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .privacySensitive()

                  Spacer(minLength: 4)

                  if todo.isStarred {
                    Text(Image(systemName: "star.fill"))
                      .font(WidgetTheme.metadataFont)
                      .foregroundStyle(WidgetTheme.amber)
                      .fixedSize(horizontal: true, vertical: false)
                  } else if let dueDate = todo.dueDate {
                    Text(dueDate, format: .dateTime.month(.abbreviated).day())
                      .font(WidgetTheme.metadataFont)
                      .foregroundStyle(dueDate < entry.date ? WidgetTheme.coral : WidgetTheme.secondary)
                      .fixedSize(horizontal: true, vertical: false)
                      .privacySensitive()
                  }
                }
              }
              .frame(maxWidth: .infinity, minHeight: rowHeight)
              .contentShape(Rectangle())
            }
            .accessibilityLabel("Open todo, \(todo.title)")

            if index < min(itemLimit, entry.projection.todos.count) - 1 {
              Divider().overlay(Color.white.opacity(0.08))
            }
          }
        }
      }

      Link(destination: IAgentDeepLink.createTodo.url) {
        Label("New todo", systemImage: "plus")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(WidgetTheme.secondary)
      }
      .accessibilityLabel("Open new todo draft")
    }
    .widgetSurface()
  }

  private var itemLimit: Int {
    switch family {
    case .systemLarge: 6
    default: 2
    }
  }

  private var rowHeight: CGFloat { family == .systemLarge ? 37 : 29 }
}

private struct NotesWidgetView: View {
  let entry: ProjectionEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    VStack(alignment: .leading, spacing: family == .systemLarge ? 11 : 8) {
      WidgetHeader(
        title: "Notes",
        metric: "\(entry.projection.notes.count) recent",
        destination: IAgentDeepLink.notes.url
      )

      if entry.projection.notes.isEmpty {
        SetupState(noun: "recent notes", destination: IAgentDeepLink.createNote.url)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(entry.projection.notes.prefix(itemLimit).enumerated()), id: \.element.id) { index, note in
            Link(destination: IAgentDeepLink.note(note.id).url) {
              HStack(spacing: 10) {
                Image(systemName: note.isMeeting ? "waveform" : "note.text")
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(note.isMeeting ? WidgetTheme.amber : WidgetTheme.secondary)
                  .frame(width: 17)

                VStack(alignment: .leading, spacing: 2) {
                  Text(note.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WidgetTheme.primary)
                    .lineLimit(1)
                    .privacySensitive()

                  Text(note.updatedAt, style: .relative)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(WidgetTheme.tertiary)
                    .privacySensitive()
                }

                Spacer(minLength: 4)
              }
              .frame(maxWidth: .infinity, minHeight: rowHeight)
              .contentShape(Rectangle())
            }
            .accessibilityLabel("Open note, \(note.title)")

            if index < min(itemLimit, entry.projection.notes.count) - 1 {
              Divider().overlay(Color.white.opacity(0.08))
            }
          }
        }
      }

      Link(destination: IAgentDeepLink.createNote.url) {
        Label("New note", systemImage: "plus")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(WidgetTheme.secondary)
      }
      .accessibilityLabel("Open new note draft")
    }
    .widgetSurface()
  }

  private var itemLimit: Int {
    switch family {
    case .systemLarge: 6
    default: 2
    }
  }

  private var rowHeight: CGFloat { family == .systemLarge ? 37 : 29 }
}

private struct CodexWidgetView: View {
  let entry: ProjectionEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    VStack(alignment: .leading, spacing: family == .systemLarge ? 11 : 8) {
      WidgetHeader(
        title: "Codex",
        metric: metric,
        destination: IAgentDeepLink.codex.url
      )

      if entry.projection.codexTasks.isEmpty {
        SetupState(noun: "synced task activity", destination: IAgentDeepLink.codex.url)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(entry.projection.codexTasks.prefix(itemLimit).enumerated()), id: \.element.id) { index, task in
            Link(destination: IAgentDeepLink.codexThread(task.id).url) {
              HStack(spacing: 7) {
                Image(systemName: task.state.symbol)
                  .font(.caption2.weight(.bold))
                  .foregroundStyle(task.state.color)
                  .frame(width: 13)
                  .accessibilityHidden(true)

                Text(task.title)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(WidgetTheme.primary)
                  .lineLimit(1)
                  .truncationMode(.tail)
                  .layoutPriority(2)
                  .privacySensitive()

                if let project = task.projectName {
                  Text(project)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(WidgetTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .privacySensitive()
                }

                Spacer(minLength: 4)

                Text(task.elapsedDescription(at: entry.date))
                  .font(.caption2.weight(.bold))
                  .foregroundStyle(WidgetTheme.secondary)
                  .lineLimit(1)
                  .fixedSize(horizontal: true, vertical: false)
                  .monospacedDigit()
                  .privacySensitive()
              }
              .frame(maxWidth: .infinity, minHeight: rowHeight)
              .contentShape(Rectangle())
            }
            .accessibilityLabel("Open Codex task, \(task.title), \(task.state.label)")

            if index < min(itemLimit, entry.projection.codexTasks.count) - 1 {
              Divider().overlay(Color.white.opacity(0.08))
            }
          }
        }
      }

      HStack {
        Link(destination: IAgentDeepLink.createCodexRequest.url) {
          Label("New request", systemImage: "plus")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(WidgetTheme.secondary)
        }
        .accessibilityLabel("Open new Codex request draft")

        Spacer()

        if entry.date.timeIntervalSince(entry.projection.generatedAt) > 7_200 {
          Text("Open to refresh")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(WidgetTheme.amber)
            .accessibilityLabel("Task activity may be stale. Open iAgent to refresh.")
        }
      }
    }
    .widgetSurface()
  }

  private var metric: String {
    let pending = entry.projection.codexAttentionCount
    let live = max(0, entry.projection.activeCodexCount - pending)
    if pending > 0, live > 0 {
      return "\(live) live · \(pending) pending"
    }
    if pending > 0 { return "\(pending) pending" }
    return "\(live) live"
  }

  private var itemLimit: Int {
    switch family {
    case .systemLarge: 6
    default: 2
    }
  }

  private var rowHeight: CGFloat { family == .systemLarge ? 37 : 29 }
}

private extension View {
  func widgetSurface() -> some View {
    self
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .containerBackground(for: .widget) { WidgetTheme.canvas }
  }
}

private extension IAgentWidgetProjection.CodexState {
  var label: String {
    switch self {
    case .running: "Running"
    case .waitingForInput: "Needs input"
    case .needsApproval: "Approval"
    case .completed: "Complete"
    case .failed: "Failed"
    }
  }

  var color: Color {
    switch self {
    case .running: WidgetTheme.green
    case .waitingForInput: WidgetTheme.blue
    case .needsApproval: WidgetTheme.amber
    case .completed: WidgetTheme.secondary
    case .failed: WidgetTheme.coral
    }
  }

  var symbol: String {
    switch self {
    case .running: "arrow.triangle.2.circlepath"
    case .waitingForInput: "questionmark.bubble.fill"
    case .needsApproval: "exclamationmark.shield.fill"
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
  }
}

private extension IAgentWidgetProjection.CodexTask {
  func elapsedDescription(at referenceDate: Date) -> String {
    guard let startedAt else {
      return updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
    let endDate = state == .running ? referenceDate : updatedAt
    let seconds = max(0, Int(endDate.timeIntervalSince(startedAt)))
    if seconds < 60 { return "<1m" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
  }
}

struct TodosWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: IAgentWidgetConstants.todosKind, provider: ProjectionProvider()) { entry in
      TodosWidgetView(entry: entry)
    }
    .configurationDisplayName("iAgent Todos")
    .description("See your next open todos and continue in iAgent.")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

struct NotesWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: IAgentWidgetConstants.notesKind, provider: ProjectionProvider()) { entry in
      NotesWidgetView(entry: entry)
    }
    .configurationDisplayName("iAgent Notes")
    .description("See recent note titles without exposing note bodies.")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

struct CodexWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: IAgentWidgetConstants.codexKind, provider: ProjectionProvider()) { entry in
      CodexWidgetView(entry: entry)
    }
    .configurationDisplayName("iAgent Codex")
    .description("See read-only Codex task status from your synced devices.")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

private enum CreateWidgetAction: String, CaseIterable {
  case todo
  case note
  case meeting
  case codex

  var title: String {
    switch self {
    case .todo: "New todo"
    case .note: "New note"
    case .meeting: "Meeting"
    case .codex: "Codex request"
    }
  }

  var compactTitle: String {
    switch self {
    case .todo: "Todo"
    case .note: "Note"
    case .meeting: "Meeting"
    case .codex: "Codex"
    }
  }

  var symbol: String {
    switch self {
    case .todo: "checkmark.square"
    case .note: "square.and.pencil"
    case .meeting: "waveform"
    case .codex: "sparkles"
    }
  }

  var color: Color {
    switch self {
    case .todo: WidgetTheme.blue
    case .note: WidgetTheme.violet
    case .meeting: WidgetTheme.coral
    case .codex: WidgetTheme.green
    }
  }

  var destination: URL {
    switch self {
    case .todo: IAgentDeepLink.createTodo.url
    case .note: IAgentDeepLink.createNote.url
    case .meeting: IAgentDeepLink.meetingReady.url
    case .codex: IAgentDeepLink.createCodexRequest.url
    }
  }
}

private struct CreateEntry: TimelineEntry {
  let date: Date
}

private struct CreateProvider: TimelineProvider {
  func placeholder(in context: Context) -> CreateEntry {
    CreateEntry(date: .now)
  }

  func getSnapshot(in context: Context, completion: @escaping (CreateEntry) -> Void) {
    completion(CreateEntry(date: .now))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<CreateEntry>) -> Void) {
    completion(Timeline(entries: [CreateEntry(date: .now)], policy: .never))
  }
}

private struct CreateWidgetView: View {
  let entry: CreateEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Create")
          .font(.headline.weight(.bold))
          .foregroundStyle(WidgetTheme.primary)
        Spacer()
        Text("Opens iAgent")
          .font(.caption2.weight(.bold))
          .foregroundStyle(WidgetTheme.tertiary)
      }

      HStack(spacing: 6) {
        ForEach(CreateWidgetAction.allCases, id: \.self) { action in
          actionLink(action)
        }
      }
      .frame(maxHeight: .infinity)
    }
    .padding(WidgetTheme.contentInset)
    .widgetSurface()
  }

  private func actionLink(_ action: CreateWidgetAction) -> some View {
    Link(destination: action.destination) {
      VStack(spacing: 7) {
        Image(systemName: action.symbol)
          .font(.headline.weight(.semibold))
          .foregroundStyle(action.color)

        Text(action.compactTitle)
          .font(.caption.weight(.bold))
          .foregroundStyle(WidgetTheme.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.78)
      }
      .padding(.horizontal, 5)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .background(WidgetTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .contentShape(Rectangle())
    }
    .accessibilityLabel("Open \(action.title) in iAgent")
    .accessibilityHint(action == .meeting
      ? "Recording starts only after you tap Start in the app."
      : "Nothing is created until you confirm in the app.")
  }
}

struct CreateWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: IAgentWidgetConstants.createKind,
      provider: CreateProvider()
    ) { entry in
      CreateWidgetView(entry: entry)
    }
    .configurationDisplayName("iAgent Create")
    .description("Open a focused draft or ready screen. Nothing starts or saves automatically.")
    .supportedFamilies([.systemMedium])
    .contentMarginsDisabled()
  }
}

private enum PriorityActivityTheme {
  /// Matches the raised bottom-sheet surface in the iAgent mobile UI.
  static let sheet = Color(red: 0.105, green: 0.105, blue: 0.11)
  static let primary = Color.white.opacity(0.96)
  static let secondary = Color.white.opacity(0.48)
  static let tertiary = Color.white.opacity(0.25)
  static let divider = Color.white.opacity(0.15)
  /// Matches `JoiTimelineRow(minHeight: 62)` in the Home bottom sheet.
  static let itemRowHeight: CGFloat = 62
  /// Header + two item rows + two dividers = ActivityKit's 160-point cap.
  static let headerHeight: CGFloat = 34
}

private struct PriorityActivityDivider: View {
  var leadingInset: CGFloat
  var trailingInset: CGFloat

  var body: some View {
    Canvas { context, size in
      var path = Path()
      path.move(to: CGPoint(x: 0, y: 0.5))
      path.addLine(to: CGPoint(x: size.width, y: 0.5))
      context.stroke(
        path,
        with: .color(PriorityActivityTheme.divider),
        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 6])
      )
    }
    .frame(height: 1)
    .padding(.leading, leadingInset)
    .padding(.trailing, trailingInset)
    .accessibilityHidden(true)
  }
}

private struct PriorityActivityListRow: View {
  let item: IAgentPriorityContentItem
  let isStale: Bool
  let updatedAt: Date
  var horizontalPadding: CGFloat = 24

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: isStale ? "arrow.clockwise.circle" : item.kind.symbolName)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(PriorityActivityTheme.primary)
        .frame(width: 24, height: 30)
        .accessibilityHidden(true)

      Text(item.title)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(PriorityActivityTheme.primary)
        .lineLimit(1)
        .layoutPriority(1)

      Spacer(minLength: 6)

      HStack(spacing: 7) {
        Text(statusText)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(PriorityActivityTheme.secondary)
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.8)

        if item.kind.destination != nil {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(PriorityActivityTheme.tertiary)
            .accessibilityHidden(true)
        }
      }
    }
    .privacySensitive()
    .padding(.horizontal, horizontalPadding)
    .frame(height: PriorityActivityTheme.itemRowHeight)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Opens the relevant iAgent list")
  }

  private var statusText: String {
    guard !isStale else { return "stale" }

    switch item.kind {
    case .codexRunning:
      return "running · \(compactInterval(from: item.timeAnchor, to: updatedAt))"
    case .meetingInProgress:
      return "live · \(compactInterval(from: item.timeAnchor, to: updatedAt))"
    case .meetingImmediate, .meetingSoon:
      return "starts · \(compactInterval(from: updatedAt, to: item.timeAnchor))"
    case .todoOverdue:
      return "overdue · \(compactInterval(from: item.timeAnchor, to: updatedAt))"
    case .todoToday:
      return "due · \(item.timeAnchor.formatted(date: .omitted, time: .shortened))"
    case .todoSoon:
      return "due · \(item.timeAnchor.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    case .none:
      return "clear"
    }
  }

  private func compactInterval(from start: Date, to end: Date) -> String {
    let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
    guard minutes > 0 else { return "<1m" }
    guard minutes >= 60 else { return "\(minutes)m" }

    let hours = minutes / 60
    let remainderMinutes = minutes % 60
    guard hours >= 24 else {
      return remainderMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainderMinutes)m"
    }

    let days = hours / 24
    let remainderHours = hours % 24
    return remainderHours == 0 ? "\(days)d" : "\(days)d \(remainderHours)h"
  }

  private var accessibilityLabel: String {
    isStale ? "\(item.title), out of date." : "Urgent item: \(item.title)."
  }
}

private struct PriorityActivityEmptyRow: View {
  let isStale: Bool
  var horizontalPadding: CGFloat = 24

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: isStale ? "arrow.clockwise.circle" : "checkmark.circle")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(PriorityActivityTheme.primary)
        .frame(width: 24, height: 30)
        .accessibilityHidden(true)

      Text(isStale ? "Open iAgent to refresh" : "Nothing needs attention")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(PriorityActivityTheme.primary)
        .lineLimit(1)

      Spacer(minLength: 8)
      Text(isStale ? "stale" : "clear")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(PriorityActivityTheme.secondary)
    }
    .padding(.horizontal, horizontalPadding)
    .frame(height: PriorityActivityTheme.itemRowHeight)
    .privacySensitive()
  }
}

private struct PriorityActivityRows: View {
  let state: IAgentPriorityContentState
  let isStale: Bool
  var horizontalPadding: CGFloat = 24
  var dividerTrailingPadding: CGFloat = 20

  /// Two exact Home-style items fit below the compact header without ActivityKit
  /// compression. The header owns the remaining-item count.
  private var displayedItems: [IAgentPriorityContentItem] {
    Array(state.items.prefix(2))
  }

  var body: some View {
    if displayedItems.isEmpty {
      PriorityActivityEmptyRow(
        isStale: isStale,
        horizontalPadding: horizontalPadding
      )
    } else {
      ForEach(Array(displayedItems.enumerated()), id: \.offset) { index, item in
        PriorityActivityListRow(
          item: item,
          isStale: isStale,
          updatedAt: state.updatedAt,
          horizontalPadding: horizontalPadding
        )
        if index < displayedItems.count - 1 {
          PriorityActivityDivider(
            leadingInset: horizontalPadding,
            trailingInset: dividerTrailingPadding
          )
        }
      }

    }
  }
}

private struct PriorityActivityHeader: View {
  let state: IAgentPriorityContentState
  let isStale: Bool
  var horizontalPadding: CGFloat = 24

  var body: some View {
    HStack(spacing: 8) {
      Text("iAgent")
        .font(.caption.weight(.bold))
        .foregroundStyle(PriorityActivityTheme.primary)

      if isStale {
        Text("out of date")
      } else {
        Text("updated ") + Text(state.updatedAt, style: .relative)
      }

      Spacer(minLength: 8)

      if additionalItemCount > 0 {
        Text("\(additionalItemCount) more")
      }
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(PriorityActivityTheme.secondary)
    .monospacedDigit()
    .padding(.horizontal, horizontalPadding)
    .frame(height: PriorityActivityTheme.headerHeight)
    .privacySensitive()
  }

  private var additionalItemCount: Int {
    max(0, state.totalItemCount - 2)
  }
}

private struct PriorityLockScreenView: View {
  let state: IAgentPriorityContentState
  let systemIsStale: Bool

  private var isStale: Bool {
    systemIsStale || state.presentation == .stale
  }

  var body: some View {
    VStack(spacing: 0) {
      PriorityActivityHeader(state: state, isStale: isStale)
      PriorityActivityDivider(leadingInset: 24, trailingInset: 20)
      PriorityActivityRows(state: state, isStale: isStale)
    }
    .activityBackgroundTint(PriorityActivityTheme.sheet)
    .activitySystemActionForegroundColor(PriorityActivityTheme.primary)
    .widgetURL(state.primaryDestination?.url)
  }
}

struct PriorityLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: IAgentPriorityActivityAttributes.self) { context in
      PriorityLockScreenView(
        state: context.state,
        systemIsStale: context.isStale
      )
    } dynamicIsland: { context in
      let isStale = context.isStale || context.state.presentation == .stale

      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 8) {
            Text("iAgent")
              .font(.caption.weight(.bold))
              .foregroundStyle(PriorityActivityTheme.primary)
            if isStale {
              Text("out of date")
            } else {
              Text("updated ") + Text(context.state.updatedAt, style: .relative)
            }
          }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(PriorityActivityTheme.secondary)
            .monospacedDigit()
            .padding(.leading, 4)
        }

        DynamicIslandExpandedRegion(.trailing) {
          let additionalItemCount = max(0, context.state.totalItemCount - 2)
          if additionalItemCount > 0 {
            Text("\(additionalItemCount) more")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(PriorityActivityTheme.secondary)
              .monospacedDigit()
              .padding(.trailing, 3)
          }
        }

        DynamicIslandExpandedRegion(.bottom) {
          VStack(spacing: 0) {
            PriorityActivityDivider(leadingInset: 4, trailingInset: 4)
            PriorityActivityRows(
              state: context.state,
              isStale: isStale,
              horizontalPadding: 4,
              dividerTrailingPadding: 4
            )
          }
        }
      } compactLeading: {
        Image(systemName: isStale ? "arrow.clockwise" : context.state.primaryKind.symbolName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(PriorityActivityTheme.primary)
          .accessibilityHidden(true)
      } compactTrailing: {
        Text(compactStatus(for: context.state, isStale: isStale))
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(PriorityActivityTheme.primary)
          .privacySensitive()
      } minimal: {
        Image(systemName: isStale ? "arrow.clockwise" : context.state.primaryKind.symbolName)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(PriorityActivityTheme.primary)
          .privacySensitive()
      }
      .widgetURL(context.state.primaryDestination?.url)
      .keylineTint(PriorityActivityTheme.primary)
    }
  }

  private func compactStatus(
    for state: IAgentPriorityContentState,
    isStale: Bool
  ) -> String {
    if isStale { return "STALE" }
    return state.totalItemCount == 0 ? "CLEAR" : "\(state.totalItemCount)"
  }
}

struct LockScreenOverviewWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: IAgentWidgetConstants.lockScreenOverviewKind,
      provider: ProjectionProvider()
    ) { entry in
      LockScreenOverviewView(entry: entry)
    }
    .configurationDisplayName("iAgent at a Glance")
    .description("See today’s calendar, active Codex, and open todo counts.")
    .supportedFamilies([.accessoryInline, .accessoryRectangular])
  }
}

struct LockScreenNextMeetingWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: IAgentWidgetConstants.lockScreenNextMeetingKind,
      provider: ProjectionProvider()
    ) { entry in
      LockScreenNextMeetingView(entry: entry)
    }
    .configurationDisplayName("iAgent Next Meeting")
    .description("See the time and title of your next meeting.")
    .supportedFamilies([.accessoryRectangular])
  }
}

struct LockScreenCodexWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: IAgentWidgetConstants.lockScreenCodexKind,
      provider: ProjectionProvider()
    ) { entry in
      LockScreenCountView(entry: entry, metric: .codex)
    }
    .configurationDisplayName("iAgent Codex Count")
    .description("See how many Codex tasks are active.")
    .supportedFamilies([.accessoryCircular])
  }
}

struct LockScreenCalendarWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: IAgentWidgetConstants.lockScreenCalendarKind,
      provider: ProjectionProvider()
    ) { entry in
      LockScreenCountView(entry: entry, metric: .calendar)
    }
    .configurationDisplayName("iAgent Calendar Count")
    .description("See how many calendar events you have today.")
    .supportedFamilies([.accessoryCircular])
  }
}

struct LockScreenTodosWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: IAgentWidgetConstants.lockScreenTodosKind,
      provider: ProjectionProvider()
    ) { entry in
      LockScreenCountView(entry: entry, metric: .todos)
    }
    .configurationDisplayName("iAgent Todo Count")
    .description("See how many todos remain open.")
    .supportedFamilies([.accessoryCircular])
  }
}

struct LockScreenNotesWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: IAgentWidgetConstants.lockScreenNotesKind,
      provider: ProjectionProvider()
    ) { entry in
      LockScreenCountView(entry: entry, metric: .notes)
    }
    .configurationDisplayName("iAgent Note Count")
    .description("See how many notes are available in iAgent.")
    .supportedFamilies([.accessoryCircular])
  }
}

@main
struct IAgentWidgetsBundle: WidgetBundle {
  var body: some Widget {
    PriorityLiveActivityWidget()
    CreateWidget()
    LockScreenOverviewWidget()
    LockScreenNextMeetingWidget()
    LockScreenCodexWidget()
    LockScreenCalendarWidget()
    LockScreenTodosWidget()
    LockScreenNotesWidget()
    TodosWidget()
    NotesWidget()
    CodexWidget()
  }
}

private extension IAgentWidgetProjection {
  static var preview: IAgentWidgetProjection {
    let now = Date()
    return IAgentWidgetProjection(
      generatedAt: now.addingTimeInterval(-180),
      lastSuccessfulSyncAt: now.addingTimeInterval(-180),
      openTodoCount: 4,
      activeCodexCount: 2,
      codexAttentionCount: 1,
      todayCalendarEventCount: 4,
      noteCount: 12,
      nextMeeting: NextMeeting(
        title: "Design sync",
        start: now.addingTimeInterval(3_600),
        end: now.addingTimeInterval(6_300),
        isAllDay: false
      ),
      todos: [
        Todo(id: UUID(), title: "Send the mobile sync brief", isStarred: true, dueDate: now.addingTimeInterval(7_200), listName: "work"),
        Todo(id: UUID(), title: "Review meeting notes", isStarred: false, dueDate: now.addingTimeInterval(12_000), listName: "work"),
        Todo(id: UUID(), title: "Book the flight", isStarred: false, dueDate: nil, listName: "personal")
      ],
      notes: [
        Note(id: UUID(), title: "Mobile companion principles", isMeeting: false, updatedAt: now.addingTimeInterval(-900)),
        Note(id: UUID(), title: "Design sync", isMeeting: true, updatedAt: now.addingTimeInterval(-3_600)),
        Note(id: UUID(), title: "Widget rollout", isMeeting: false, updatedAt: now.addingTimeInterval(-7_200))
      ],
      codexTasks: [
        CodexTask(id: "preview-1", title: "Build Home Screen widgets", projectName: "iagent", state: .running, startedAt: now.addingTimeInterval(-1_320), updatedAt: now.addingTimeInterval(-120)),
        CodexTask(id: "preview-2", title: "Refine task sync", projectName: "iagent", state: .needsApproval, startedAt: now.addingTimeInterval(-2_700), updatedAt: now.addingTimeInterval(-480)),
        CodexTask(id: "preview-3", title: "Document release flow", projectName: "timeline", state: .completed, startedAt: now.addingTimeInterval(-5_400), updatedAt: now.addingTimeInterval(-3_600))
      ]
    )
  }
}

#Preview("Todos — medium", as: .systemMedium) {
  TodosWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("Todos — large", as: .systemLarge) {
  TodosWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("Notes — medium", as: .systemMedium) {
  NotesWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("Notes — large", as: .systemLarge) {
  NotesWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("Codex — medium", as: .systemMedium) {
  CodexWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("Codex — large", as: .systemLarge) {
  CodexWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("Create — medium", as: .systemMedium) {
  CreateWidget()
} timeline: {
  CreateEntry(date: .now)
}

#Preview("At a Glance — inline", as: .accessoryInline) {
  LockScreenOverviewWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("At a Glance — rectangular", as: .accessoryRectangular) {
  LockScreenOverviewWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("Next Meeting", as: .accessoryRectangular) {
  LockScreenNextMeetingWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("Codex Count", as: .accessoryCircular) {
  LockScreenCodexWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("Calendar Count", as: .accessoryCircular) {
  LockScreenCalendarWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("Todo Count", as: .accessoryCircular) {
  LockScreenTodosWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

#Preview("Note Count", as: .accessoryCircular) {
  LockScreenNotesWidget()
} timeline: {
  ProjectionEntry(date: .now, projection: .preview)
}

private extension IAgentPriorityContentState {
  static let previewMultiple = IAgentPriorityContentState(
    presentation: .focus,
    items: [
      IAgentPriorityContentItem(
        kind: .todoOverdue,
        title: "Add bug bash",
        timeAnchor: Date().addingTimeInterval(-42 * 60)
      ),
      IAgentPriorityContentItem(
        kind: .meetingInProgress,
        title: "Design sync",
        timeAnchor: Date().addingTimeInterval(-12 * 60),
        endDate: Date().addingTimeInterval(18 * 60)
      ),
      IAgentPriorityContentItem(
        kind: .todoToday,
        title: "Send release brief",
        timeAnchor: Date().addingTimeInterval(75 * 60)
      ),
      IAgentPriorityContentItem(
        kind: .codexRunning,
        title: "Fix calendar refresh",
        timeAnchor: Date().addingTimeInterval(-27 * 60)
      )
    ],
    additionalItemCount: 2,
    updatedAt: Date().addingTimeInterval(-45)
  )

  static let previewUpcoming = IAgentPriorityContentState(
    presentation: .focus,
    items: [
      IAgentPriorityContentItem(
        kind: .meetingImmediate,
        title: "Release readiness",
        timeAnchor: Date().addingTimeInterval(8 * 60)
      ),
      IAgentPriorityContentItem(
        kind: .codexRunning,
        title: "Fix calendar refresh",
        timeAnchor: Date().addingTimeInterval(-27 * 60)
      )
    ],
    additionalItemCount: 0,
    updatedAt: Date().addingTimeInterval(-90)
  )

  static let previewEmpty = IAgentPriorityContentState(
    presentation: .empty,
    items: [],
    additionalItemCount: 0,
    updatedAt: Date().addingTimeInterval(-60)
  )

  static let previewStale = IAgentPriorityContentState(
    presentation: .stale,
    items: previewMultiple.items,
    additionalItemCount: previewMultiple.additionalItemCount,
    updatedAt: Date().addingTimeInterval(-25 * 60)
  )
}

#Preview("Priority — Lock Screen", as: .content, using: IAgentPriorityActivityAttributes()) {
  PriorityLiveActivityWidget()
} contentStates: {
  IAgentPriorityContentState.previewMultiple
  IAgentPriorityContentState.previewUpcoming
  IAgentPriorityContentState.previewEmpty
  IAgentPriorityContentState.previewStale
}

#Preview(
  "Priority — Dynamic Island Compact",
  as: .dynamicIsland(.compact),
  using: IAgentPriorityActivityAttributes()
) {
  PriorityLiveActivityWidget()
} contentStates: {
  IAgentPriorityContentState.previewMultiple
  IAgentPriorityContentState.previewStale
}

#Preview(
  "Priority — Dynamic Island Expanded",
  as: .dynamicIsland(.expanded),
  using: IAgentPriorityActivityAttributes()
) {
  PriorityLiveActivityWidget()
} contentStates: {
  IAgentPriorityContentState.previewMultiple
  IAgentPriorityContentState.previewUpcoming
  IAgentPriorityContentState.previewEmpty
  IAgentPriorityContentState.previewStale
}

#Preview(
  "Priority — Dynamic Island Minimal",
  as: .dynamicIsland(.minimal),
  using: IAgentPriorityActivityAttributes()
) {
  PriorityLiveActivityWidget()
} contentStates: {
  IAgentPriorityContentState.previewMultiple
  IAgentPriorityContentState.previewStale
}
