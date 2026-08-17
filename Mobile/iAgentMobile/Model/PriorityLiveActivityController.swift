@preconcurrency import ActivityKit
import Foundation
import iAgentCore

enum PriorityLiveActivityRefreshResult: Equatable {
  case unavailable
  case noFocus
  case started
  case updated
  case unchanged
  case ended
}

@MainActor
final class PriorityLiveActivityController {
  var activitiesAreEnabled: Bool {
    ActivityAuthorizationInfo().areActivitiesEnabled
  }

  func refresh(
    snapshot: IAgentDataSnapshot,
    supplementalCalendarEvents: [SyncedCalendarEvent],
    userHasOptedIn: Bool,
    allowStart: Bool,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) async -> (items: [IAgentUrgentItem], result: PriorityLiveActivityRefreshResult) {
    guard userHasOptedIn else {
      let ended = await endAll(at: now, immediately: true)
      return ([], ended ? .ended : .noFocus)
    }

    let urgentItems = IAgentPriorityPolicy.selectUrgentItems(
      from: snapshot,
      supplementalCalendarEvents: supplementalCalendarEvents,
      now: now,
      calendar: calendar
    )
    let activities = activeActivities

    guard !urgentItems.isEmpty else {
      guard !activities.isEmpty else { return ([], .noFocus) }
      let emptyState = IAgentPriorityPolicy.contentState(for: [], updatedAt: now)
      let content = ActivityContent(
        state: emptyState,
        staleDate: IAgentPriorityPolicy.staleDate(after: now),
        relevanceScore: 0
      )
      for activity in activities {
        await activity.end(
          content,
          dismissalPolicy: .after(
            now.addingTimeInterval(IAgentPriorityPolicy.endedStateDismissalInterval)
          )
        )
      }
      return ([], .ended)
    }

    let nextState = IAgentPriorityPolicy.contentState(for: urgentItems, updatedAt: now)
    let content = ActivityContent(
      state: nextState,
      staleDate: IAgentPriorityPolicy.staleDate(after: now),
      relevanceScore: 0
    )

    if let primary = activities.first {
      for duplicate in activities.dropFirst() {
        await duplicate.end(nil, dismissalPolicy: .immediate)
      }

      let currentState = primary.content.state
      let semanticContentChanged = currentState.presentation != nextState.presentation
        || currentState.items != nextState.items
        || currentState.additionalItemCount != nextState.additionalItemCount
      let heartbeatIsDue = now.timeIntervalSince(currentState.updatedAt)
        >= IAgentPriorityPolicy.minimumHeartbeatInterval

      guard semanticContentChanged || heartbeatIsDue || primary.activityState == .stale else {
        return (urgentItems, .unchanged)
      }

      await primary.update(content)
      return (urgentItems, .updated)
    }

    guard allowStart, activitiesAreEnabled else {
      return (urgentItems, activitiesAreEnabled ? .unchanged : .unavailable)
    }

    do {
      _ = try Activity.request(
        attributes: IAgentPriorityActivityAttributes(),
        content: content,
        pushType: nil
      )
      return (urgentItems, .started)
    } catch {
      return (urgentItems, .unavailable)
    }
  }

  @discardableResult
  func endAll(at now: Date = Date(), immediately: Bool) async -> Bool {
    let activities = activeActivities
    guard !activities.isEmpty else { return false }

    if immediately {
      for activity in activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
    } else {
      let state = IAgentPriorityContentState(
        presentation: .stale,
        items: [],
        additionalItemCount: 0,
        updatedAt: now
      )
      let content = ActivityContent(
        state: state,
        staleDate: now,
        relevanceScore: 0
      )
      for activity in activities {
        await activity.end(
          content,
          dismissalPolicy: .after(
            now.addingTimeInterval(IAgentPriorityPolicy.endedStateDismissalInterval)
          )
        )
      }
    }
    return true
  }

  private var activeActivities: [Activity<IAgentPriorityActivityAttributes>] {
    Activity<IAgentPriorityActivityAttributes>.activities.sorted { $0.id < $1.id }
  }
}
