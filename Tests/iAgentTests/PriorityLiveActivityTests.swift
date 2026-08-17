import Foundation
import XCTest
@testable import iAgentCore

final class PriorityLiveActivityTests: XCTestCase {
  func testSelectsAllSimultaneousTimeBoundItemsInTemporalOrder() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = IAgentDataSnapshot(
      notes: [SyncedNote(
        title: "Excluded note",
        body: "Never eligible",
        sourceDeviceID: "test"
      )],
      todos: [todo(title: "Add bug bash", due: now.addingTimeInterval(-60), now: now),
              todo(title: "Send release brief", due: now.addingTimeInterval(5 * 60), now: now)],
      codexThreads: [thread(
        id: "running",
        title: "Fix calendar refresh",
        state: .running,
        createdAt: now.addingTimeInterval(-25 * 60),
        now: now
      )],
      calendarEvents: [
        meeting(
          id: "in-progress",
          title: "Design sync",
          starts: now.addingTimeInterval(-10 * 60),
          ends: now.addingTimeInterval(20 * 60),
          now: now
        ),
        meeting(
          id: "imminent",
          title: "Release readiness",
          starts: now.addingTimeInterval(8 * 60),
          ends: now.addingTimeInterval(38 * 60),
          now: now
        )
      ],
      desktopSnapshot: desktopHeartbeat(at: now)
    )

    let items = IAgentPriorityPolicy.selectUrgentItems(
      from: snapshot,
      now: now,
      calendar: utcCalendar()
    )

    XCTAssertEqual(
      items.map(\.kind),
      [.todoOverdue, .meetingInProgress, .todoToday, .meetingImmediate, .codexRunning]
    )
    XCTAssertEqual(
      items.map(\.displayTitle),
      ["Add bug bash", "Design sync", "Send release brief", "Release readiness", "Fix calendar refresh"]
    )

    let state = IAgentPriorityPolicy.contentState(for: items, updatedAt: now)
    XCTAssertEqual(state.items.count, 5)
    XCTAssertEqual(state.additionalItemCount, 0)
  }

  func testContentStateKeepsFiveItemsAndExactOverflowCount() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = IAgentDataSnapshot(
      todos: [
        todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "First", due: now.addingTimeInterval(-60), now: now),
        todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, title: "Fifth", due: now.addingTimeInterval(-60), now: now),
        todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "Third", due: now.addingTimeInterval(-60), now: now),
        todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Second", due: now.addingTimeInterval(-60), now: now),
        todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, title: "Fourth", due: now.addingTimeInterval(-60), now: now),
        todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, title: "Sixth", due: now.addingTimeInterval(-60), now: now),
        todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!, title: "Eighth", due: now.addingTimeInterval(-60), now: now),
        todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, title: "Seventh", due: now.addingTimeInterval(-60), now: now)
      ]
    )

    let items = IAgentPriorityPolicy.selectUrgentItems(from: snapshot, now: now)
    XCTAssertEqual(
      items.map(\.displayTitle),
      ["First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth"]
    )

    let state = IAgentPriorityPolicy.contentState(for: items, updatedAt: now)
    XCTAssertEqual(state.items.map(\.title), ["First", "Second", "Third", "Fourth", "Fifth"])
    XCTAssertEqual(state.additionalItemCount, 3)
    XCTAssertEqual(state.totalItemCount, 8)

    let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    XCTAssertFalse(encoded.contains("00000000-0000-0000-0000-000000000001"))
  }

  func testMeetingEligibilityIncludesInProgressAndThirtyMinuteBoundary() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let events = [
      meeting(id: "ended", title: "Ended", starts: now.addingTimeInterval(-20 * 60), ends: now, now: now),
      meeting(id: "active", title: "Active", starts: now.addingTimeInterval(-10 * 60), ends: now.addingTimeInterval(10 * 60), now: now),
      meeting(id: "ten", title: "At ten", starts: now.addingTimeInterval(10 * 60), ends: now.addingTimeInterval(40 * 60), now: now),
      meeting(id: "ten-plus", title: "After ten", starts: now.addingTimeInterval(10 * 60 + 1), ends: now.addingTimeInterval(40 * 60), now: now),
      meeting(id: "thirty", title: "At thirty", starts: now.addingTimeInterval(30 * 60), ends: now.addingTimeInterval(60 * 60), now: now),
      meeting(id: "outside", title: "Outside", starts: now.addingTimeInterval(30 * 60 + 1), ends: now.addingTimeInterval(61 * 60), now: now),
      meeting(id: "all-day", title: "All day", starts: now.addingTimeInterval(-60), ends: now.addingTimeInterval(60), now: now, isAllDay: true)
    ]

    let items = IAgentPriorityPolicy.selectUrgentItems(
      from: IAgentDataSnapshot(calendarEvents: events),
      now: now,
      calendar: utcCalendar()
    )

    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: items.map { ($0.displayTitle, $0.kind) }),
      [
        "Active": .meetingInProgress,
        "At ten": .meetingImmediate,
        "After ten": .meetingSoon,
        "At thirty": .meetingSoon
      ]
    )
  }

  func testTodoNearDueWindowUsesCalendarArithmeticAcrossDST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let now = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026,
      month: 3,
      day: 8,
      hour: 1,
      minute: 30
    )))
    let inside = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026,
      month: 3,
      day: 9,
      hour: 1,
      minute: 29
    )))
    let outside = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026,
      month: 3,
      day: 9,
      hour: 1,
      minute: 31
    )))

    let items = IAgentPriorityPolicy.selectUrgentItems(
      from: IAgentDataSnapshot(todos: [
        todo(title: "Inside wall-clock day", due: inside, now: now),
        todo(title: "Outside wall-clock day", due: outside, now: now)
      ]),
      now: now,
      calendar: calendar
    )

    XCTAssertEqual(items.map(\.displayTitle), ["Inside wall-clock day"])
    XCTAssertEqual(items.first?.kind, .todoSoon)
  }

  func testStaleBoundaryAndEmptyStateAreExplicit() {
    let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let before = updatedAt.addingTimeInterval(IAgentPriorityPolicy.staleInterval - 0.001)
    let boundary = updatedAt.addingTimeInterval(IAgentPriorityPolicy.staleInterval)

    XCTAssertFalse(IAgentPriorityPolicy.isStale(updatedAt: updatedAt, now: before))
    XCTAssertTrue(IAgentPriorityPolicy.isStale(updatedAt: updatedAt, now: boundary))
    XCTAssertEqual(IAgentPriorityPolicy.staleDate(after: updatedAt), boundary)

    let state = IAgentPriorityPolicy.contentState(for: [], updatedAt: updatedAt)
    XCTAssertEqual(state.presentation, .empty)
    XCTAssertTrue(state.items.isEmpty)
    XCTAssertEqual(state.additionalItemCount, 0)
  }

  func testStaleDesktopHeartbeatExcludesCodexAndNotesAreNeverEligible() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let staleHeartbeat = desktopHeartbeat(
      at: now.addingTimeInterval(-SyncedDesktopSnapshot.freshnessTimeout)
    )
    let snapshot = IAgentDataSnapshot(
      notes: [SyncedNote(
        title: "Do not leak this title",
        body: "Do not leak this body",
        sourceDeviceID: "private-device",
        relativeFilePath: "/private/path.md"
      )],
      codexThreads: [thread(
        id: "running",
        title: "Apparently running",
        state: .running,
        createdAt: now.addingTimeInterval(-600),
        now: now
      )],
      desktopSnapshot: staleHeartbeat
    )

    XCTAssertTrue(IAgentPriorityPolicy.selectUrgentItems(from: snapshot, now: now).isEmpty)
  }

  func testPayloadShowsTitlesButExcludesPrivateMetadataAndCodexPaths() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let codex = SyncedCodexThread(
      id: "private-thread-identifier",
      projectName: "/Users/person/private-project",
      title: "Fix calendar refresh",
      activity: "Raw Codex prompt must stay private",
      state: .running,
      modes: [.plan],
      createdAt: now.addingTimeInterval(-600),
      updatedAt: now
    )
    let snapshot = IAgentDataSnapshot(
      codexThreads: [codex],
      desktopSnapshot: desktopHeartbeat(at: now)
    )
    let state = IAgentPriorityPolicy.contentState(
      for: IAgentPriorityPolicy.selectUrgentItems(from: snapshot, now: now),
      updatedAt: now
    )
    let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)

    XCTAssertEqual(state.items.first?.title, "Fix calendar refresh")
    XCTAssertTrue(encoded.contains("Fix calendar refresh"))
    XCTAssertFalse(encoded.contains("/Users/person/private-project"))
    XCTAssertFalse(encoded.contains("private-thread-identifier"))
    XCTAssertFalse(encoded.contains("Raw Codex prompt"))

    XCTAssertEqual(
      IAgentPriorityPolicy.safeDisplayTitle(
        "Run /Users/person/private-project/tests",
        fallback: "Active Codex task",
        screensFilesystemPaths: true
      ),
      "Active Codex task"
    )
  }

  func testOnlyRunningCodexUsesCreatedAtAsElapsedAnchor() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let startedAt = now.addingTimeInterval(-45 * 60)
    let snapshot = IAgentDataSnapshot(
      codexThreads: [
        thread(id: "running", title: "Running", state: .running, createdAt: startedAt, now: now),
        thread(id: "waiting", title: "Waiting", state: .waitingForInput, createdAt: startedAt, now: now),
        thread(id: "approval", title: "Approval", state: .needsApproval, createdAt: startedAt, now: now)
      ],
      desktopSnapshot: desktopHeartbeat(at: now)
    )

    let items = IAgentPriorityPolicy.selectUrgentItems(from: snapshot, now: now)
    XCTAssertEqual(items.map(\.displayTitle), ["Running"])
    XCTAssertEqual(items.first?.timeAnchor, startedAt)
  }

  private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func desktopHeartbeat(at date: Date) -> SyncedDesktopSnapshot {
    SyncedDesktopSnapshot(
      id: "desktop",
      deviceName: "Mac",
      activeCodexCount: 1,
      openTodoCount: 0,
      projectOrder: [],
      generatedAt: date,
      lastSeenAt: date,
      appVersion: "test"
    )
  }

  private func thread(
    id: String,
    title: String,
    state: SyncedCodexState,
    createdAt: Date,
    now: Date
  ) -> SyncedCodexThread {
    SyncedCodexThread(
      id: id,
      projectName: "project",
      title: title,
      activity: "Private task activity",
      state: state,
      modes: [.plan],
      createdAt: createdAt,
      updatedAt: now
    )
  }

  private func meeting(
    id: String,
    title: String,
    starts: Date,
    ends: Date,
    now: Date,
    isAllDay: Bool = false
  ) -> SyncedCalendarEvent {
    SyncedCalendarEvent(
      id: id,
      sourceIdentifier: id,
      title: title,
      startDate: starts,
      endDate: ends,
      isAllDay: isAllDay,
      calendarTitle: "Private calendar",
      location: "Private location",
      notes: "Private meeting notes",
      linkURLs: [],
      updatedAt: now
    )
  }

  private func todo(
    id: UUID = UUID(),
    title: String,
    due: Date,
    now: Date
  ) -> SyncedTodo {
    SyncedTodo(
      id: id,
      title: title,
      notes: "Private todo notes",
      dueDate: due,
      createdAt: now.addingTimeInterval(-600),
      updatedAt: now
    )
  }
}
