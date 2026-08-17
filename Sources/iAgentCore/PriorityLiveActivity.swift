import Foundation

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

/// The time-bound item types eligible for the priority Live Activity.
/// Notes are intentionally absent from this model.
public enum IAgentPriorityKind: String, Codable, Hashable, Sendable {
  case codexRunning
  case meetingInProgress
  case meetingImmediate
  case meetingSoon
  case todoOverdue
  case todoToday
  case todoSoon
  case none

  public var destination: IAgentDeepLink? {
    switch self {
    case .codexRunning:
      .codex
    case .meetingInProgress, .meetingImmediate, .meetingSoon:
      .calendar
    case .todoOverdue, .todoToday, .todoSoon:
      .todos
    case .none:
      nil
    }
  }

  public var fallbackTitle: String {
    switch self {
    case .codexRunning: "Active Codex task"
    case .meetingInProgress: "Meeting in progress"
    case .meetingImmediate, .meetingSoon: "Upcoming meeting"
    case .todoOverdue: "Overdue todo"
    case .todoToday: "Todo due today"
    case .todoSoon: "Todo due soon"
    case .none: "Nothing needs attention"
    }
  }

  public var symbolName: String {
    switch self {
    case .codexRunning: "sparkles"
    case .meetingInProgress: "calendar.badge.clock"
    case .meetingImmediate, .meetingSoon: "calendar"
    case .todoOverdue: "exclamationmark.circle"
    case .todoToday, .todoSoon: "checkmark.square"
    case .none: "checkmark.circle"
    }
  }

  fileprivate var temporalPhase: Int {
    switch self {
    case .todoOverdue: 0
    case .meetingInProgress: 1
    case .meetingImmediate, .meetingSoon, .todoToday, .todoSoon: 2
    case .codexRunning: 3
    case .none: 4
    }
  }
}

public enum IAgentPriorityPresentation: String, Codable, Hashable, Sendable {
  case focus
  case empty
  /// The system's `isStale` value remains authoritative while an activity runs.
  case stale
}

/// One privacy-controlled row in ActivityKit's dynamic payload.
///
/// Titles are intentionally display-only, single-line, length-bounded strings.
/// Source identifiers, notes, locations, prompts, activities, and paths never enter
/// this type.
public struct IAgentPriorityContentItem: Codable, Hashable, Sendable {
  public let kind: IAgentPriorityKind
  public let title: String
  /// Due time, meeting start, or Codex creation time depending on `kind`.
  public let timeAnchor: Date
  /// Present only for an in-progress meeting.
  public let endDate: Date?

  public init(
    kind: IAgentPriorityKind,
    title: String,
    timeAnchor: Date,
    endDate: Date? = nil
  ) {
    self.kind = kind
    self.title = title
    self.timeAnchor = timeAnchor
    self.endDate = endDate
  }
}

/// ActivityKit's bounded dynamic payload. Up to five compact item rows are
/// retained so the UI can use its final band for either an item or overflow.
public struct IAgentPriorityContentState: Codable, Hashable, Sendable {
  public let presentation: IAgentPriorityPresentation
  public let items: [IAgentPriorityContentItem]
  public let additionalItemCount: Int
  public let updatedAt: Date

  public init(
    presentation: IAgentPriorityPresentation,
    items: [IAgentPriorityContentItem],
    additionalItemCount: Int,
    updatedAt: Date
  ) {
    self.presentation = presentation
    self.items = items
    self.additionalItemCount = max(0, additionalItemCount)
    self.updatedAt = updatedAt
  }

  public var totalItemCount: Int {
    items.count + additionalItemCount
  }

  public var primaryKind: IAgentPriorityKind {
    items.first?.kind ?? .none
  }

  public var primaryDestination: IAgentDeepLink? {
    items.first?.kind.destination
  }
}

#if os(iOS) && canImport(ActivityKit)
@available(iOS 16.1, *)
public struct IAgentPriorityActivityAttributes: ActivityAttributes {
  public typealias ContentState = IAgentPriorityContentState

  /// A schema marker only. Static attributes contain no personal data.
  public let surfaceVersion: Int

  public init(surfaceVersion: Int = 2) {
    self.surfaceVersion = surfaceVersion
  }
}
#endif

/// An in-process eligible item. `sourceID` exists only for stable ordering and is
/// never copied into ActivityKit content.
public struct IAgentUrgentItem: Equatable, Sendable {
  public let kind: IAgentPriorityKind
  public let displayTitle: String
  public let sourceID: String
  public let timeAnchor: Date
  public let endDate: Date?

  fileprivate init(
    kind: IAgentPriorityKind,
    displayTitle: String,
    sourceID: String,
    timeAnchor: Date,
    endDate: Date? = nil
  ) {
    self.kind = kind
    self.displayTitle = displayTitle
    self.sourceID = sourceID
    self.timeAnchor = timeAnchor
    self.endDate = endDate
  }
}

public enum IAgentPriorityPolicy {
  public static let immediateMeetingMinutes = 10
  public static let meetingWindowMinutes = 30
  public static let maximumVisibleItems = 5
  public static let maximumTitleCharacters = 72
  public static let staleInterval: TimeInterval = 15 * 60
  public static let minimumHeartbeatInterval: TimeInterval = 5 * 60
  public static let endedStateDismissalInterval: TimeInterval = 15 * 60

  /// Returns every eligible time-bound item without consulting notes. Ordering is
  /// temporal, not score-based: overdue, in-progress, upcoming by time, then
  /// running Codex by start time. A fresh desktop heartbeat is required for Codex.
  public static func selectUrgentItems(
    from snapshot: IAgentDataSnapshot,
    supplementalCalendarEvents: [SyncedCalendarEvent] = [],
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> [IAgentUrgentItem] {
    var candidates: [IAgentUrgentItem] = []

    if snapshot.desktopSnapshot?.isFresh(at: now) == true {
      candidates.append(contentsOf: snapshot.codexThreads.compactMap { thread in
        guard thread.deletedAt == nil,
              thread.state == .running,
              thread.createdAt <= now
        else { return nil }

        return IAgentUrgentItem(
          kind: .codexRunning,
          displayTitle: safeDisplayTitle(
            thread.title,
            fallback: IAgentPriorityKind.codexRunning.fallbackTitle,
            screensFilesystemPaths: true
          ),
          sourceID: thread.id,
          timeAnchor: thread.createdAt
        )
      })
    }

    let immediateBoundary = calendar.date(
      byAdding: .minute,
      value: immediateMeetingMinutes,
      to: now
    ) ?? now.addingTimeInterval(TimeInterval(immediateMeetingMinutes * 60))
    let meetingBoundary = calendar.date(
      byAdding: .minute,
      value: meetingWindowMinutes,
      to: now
    ) ?? now.addingTimeInterval(TimeInterval(meetingWindowMinutes * 60))

    let meetings = coalescedCalendarEvents(
      snapshot.calendarEvents + supplementalCalendarEvents
    )
    candidates.append(contentsOf: meetings.compactMap { event in
      guard event.deletedAt == nil, !event.isAllDay else { return nil }

      let kind: IAgentPriorityKind
      if event.startDate <= now, event.endDate > now {
        kind = .meetingInProgress
      } else if event.startDate > now, event.startDate <= meetingBoundary {
        kind = event.startDate <= immediateBoundary ? .meetingImmediate : .meetingSoon
      } else {
        return nil
      }

      return IAgentUrgentItem(
        kind: kind,
        displayTitle: safeDisplayTitle(event.title, fallback: kind.fallbackTitle),
        sourceID: event.id,
        timeAnchor: event.startDate,
        endDate: kind == .meetingInProgress ? event.endDate : nil
      )
    })

    let todayEnd = calendar.date(
      byAdding: .day,
      value: 1,
      to: calendar.startOfDay(for: now)
    ) ?? now
    let nearDueBoundary = calendar.date(byAdding: .day, value: 1, to: now)
      ?? now.addingTimeInterval(24 * 60 * 60)

    candidates.append(contentsOf: snapshot.todos.compactMap { todo in
      guard todo.deletedAt == nil,
            !todo.isCompleted,
            let dueDate = todo.dueDate,
            dueDate <= nearDueBoundary
      else { return nil }

      let kind: IAgentPriorityKind
      if dueDate < now {
        kind = .todoOverdue
      } else if dueDate < todayEnd {
        kind = .todoToday
      } else {
        kind = .todoSoon
      }

      return IAgentUrgentItem(
        kind: kind,
        displayTitle: safeDisplayTitle(todo.title, fallback: kind.fallbackTitle),
        sourceID: todo.id.uuidString.lowercased(),
        timeAnchor: dueDate
      )
    })

    return candidates.sorted(by: comesBefore)
  }

  public static func contentState(
    for urgentItems: [IAgentUrgentItem],
    updatedAt: Date = Date(),
    presentation: IAgentPriorityPresentation? = nil
  ) -> IAgentPriorityContentState {
    let visible = Array(urgentItems.prefix(maximumVisibleItems))
    return IAgentPriorityContentState(
      presentation: presentation ?? (visible.isEmpty ? .empty : .focus),
      items: visible.map {
        IAgentPriorityContentItem(
          kind: $0.kind,
          title: $0.displayTitle,
          timeAnchor: $0.timeAnchor,
          endDate: $0.endDate
        )
      },
      additionalItemCount: max(0, urgentItems.count - visible.count),
      updatedAt: updatedAt
    )
  }

  public static func staleDate(after updateDate: Date) -> Date {
    updateDate.addingTimeInterval(staleInterval)
  }

  public static func isStale(updatedAt: Date, now: Date = Date()) -> Bool {
    now >= staleDate(after: updatedAt)
  }

  /// Produces a single-line, bounded title. Codex titles receive an additional
  /// filesystem-path screen because task names can be derived from local prompts.
  public static func safeDisplayTitle(
    _ rawTitle: String,
    fallback: String,
    screensFilesystemPaths: Bool = false
  ) -> String {
    let components = rawTitle
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
    let normalized = components.joined(separator: " ")
    guard !normalized.isEmpty else { return fallback }

    if screensFilesystemPaths {
      let pathMarkers = ["/Users/", "file://", "~/", "\\Users\\"]
      if pathMarkers.contains(where: normalized.localizedCaseInsensitiveContains) {
        return fallback
      }
    }

    guard normalized.count > maximumTitleCharacters else { return normalized }
    return String(normalized.prefix(maximumTitleCharacters - 1)) + "…"
  }

  private static func comesBefore(
    _ lhs: IAgentUrgentItem,
    _ rhs: IAgentUrgentItem
  ) -> Bool {
    if lhs.kind.temporalPhase != rhs.kind.temporalPhase {
      return lhs.kind.temporalPhase < rhs.kind.temporalPhase
    }

    let leftTime = comparisonTime(for: lhs)
    let rightTime = comparisonTime(for: rhs)
    if leftTime != rightTime { return leftTime < rightTime }
    return lhs.sourceID < rhs.sourceID
  }

  private static func comparisonTime(for item: IAgentUrgentItem) -> Date {
    if item.kind == .meetingInProgress {
      return item.endDate ?? item.timeAnchor
    }
    return item.timeAnchor
  }

  private static func coalescedCalendarEvents(
    _ events: [SyncedCalendarEvent]
  ) -> [SyncedCalendarEvent] {
    var result: [SyncedCalendarEvent] = []
    for event in events where event.deletedAt == nil {
      guard let existingIndex = result.firstIndex(where: { $0.isSameOccurrence(as: event) }) else {
        result.append(event)
        continue
      }
      if event.updatedAt > result[existingIndex].updatedAt {
        result[existingIndex] = event
      }
    }
    return result
  }
}
