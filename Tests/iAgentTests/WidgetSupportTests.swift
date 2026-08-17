import Foundation
import XCTest
@testable import iAgentCore

final class WidgetSupportTests: XCTestCase {
  func testDeepLinksRoundTripOnlyKnownRoutes() throws {
    let todoID = UUID()
    let noteID = UUID()
    let routes: [IAgentDeepLink] = [
      .todos, .createTodo, .todo(todoID),
      .notes, .createNote, .note(noteID),
      .calendar,
      .meetingReady,
      .codex, .createCodexRequest, .codexThread("thread-safe_01:child")
    ]

    for route in routes {
      XCTAssertEqual(IAgentDeepLink(url: route.url), route)
    }

    XCTAssertNil(IAgentDeepLink(url: URL(string: "https://todos/create")!))
    XCTAssertNil(IAgentDeepLink(url: URL(string: "iagent://todos/create?title=secret")!))
    XCTAssertNil(IAgentDeepLink(url: URL(string: "iagent://notes/not-a-uuid")!))
    XCTAssertNil(IAgentDeepLink(url: URL(string: "iagent://codex/../../escape")!))
    XCTAssertNil(IAgentDeepLink(url: URL(string: "iagent://calendar/create")!))
    XCTAssertNil(IAgentDeepLink(url: URL(string: "iagent://meetings/start")!))
  }

  func testProjectionIncludesPrivacyBoundedLockScreenCountsAndNextMeeting() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dayStart = calendar.startOfDay(for: now)

    func event(
      id: String,
      title: String,
      start: TimeInterval,
      duration: TimeInterval = 1_800,
      updatedAt: TimeInterval = 0,
      isAllDay: Bool = false
    ) -> SyncedCalendarEvent {
      SyncedCalendarEvent(
        id: id,
        sourceIdentifier: id,
        title: title,
        startDate: dayStart.addingTimeInterval(start),
        endDate: dayStart.addingTimeInterval(start + duration),
        isAllDay: isAllDay,
        calendarTitle: "Private calendar name",
        location: "SECRET LOCATION",
        notes: "SECRET EVENT NOTES",
        linkURLs: [URL(string: "https://private.example.test")!],
        updatedAt: now.addingTimeInterval(updatedAt)
      )
    }

    let nextStart = now.addingTimeInterval(900)
    let secondsFromDayStart = nextStart.timeIntervalSince(dayStart)
    let next = event(
      id: "next",
      title: "  Product\n review  ",
      start: secondsFromDayStart,
      updatedAt: 10
    )
    let duplicate = event(
      id: "next",
      title: "Old title",
      start: secondsFromDayStart,
      updatedAt: -10
    )
    let allDay = event(
      id: "all-day",
      title: "All-day focus",
      start: 0,
      duration: 86_400,
      isAllDay: true
    )
    let earlierToday = event(id: "past", title: "Past meeting", start: 60)
    let tomorrow = event(id: "tomorrow", title: "Tomorrow", start: 86_400 + 60)
    let note = SyncedNote(
      title: "Note",
      body: "PRIVATE BODY",
      sourceDeviceID: "private-device"
    )
    let snapshot = IAgentDataSnapshot(
      notes: [note],
      calendarEvents: [tomorrow, duplicate, earlierToday, allDay]
    )

    let projection = IAgentWidgetProjection.make(
      from: snapshot,
      generatedAt: now,
      calendar: calendar,
      supplementalCalendarEvents: [next]
    )

    XCTAssertEqual(projection.todayCalendarEventCount, 3)
    XCTAssertEqual(projection.noteCount, 1)
    XCTAssertEqual(projection.nextMeeting?.title, "Product review")
    XCTAssertEqual(projection.nextMeeting?.start, nextStart)
    XCTAssertEqual(projection.nextMeeting?.end, next.endDate)
    XCTAssertEqual(projection.nextMeeting?.isAllDay, false)

    let encoded = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
    XCTAssertFalse(encoded.contains("SECRET EVENT NOTES"))
    XCTAssertFalse(encoded.contains("SECRET LOCATION"))
    XCTAssertFalse(encoded.contains("Private calendar name"))
    XCTAssertFalse(encoded.contains("private.example.test"))
    XCTAssertFalse(encoded.contains("PRIVATE BODY"))
  }

  func testProjectionDecodesPreLockScreenV1Snapshot() throws {
    let date = Date(timeIntervalSince1970: 42)
    let legacyProjection = IAgentWidgetProjection(
      generatedAt: date,
      lastSuccessfulSyncAt: date,
      openTodoCount: 2,
      activeCodexCount: 1,
      codexAttentionCount: 0,
      todos: [],
      notes: [
        .init(id: UUID(), title: "Legacy note", isMeeting: false, updatedAt: date)
      ],
      codexTasks: []
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoder.encode(legacyProjection)) as? [String: Any]
    )
    object.removeValue(forKey: "todayCalendarEventCount")
    object.removeValue(forKey: "noteCount")
    object.removeValue(forKey: "nextMeeting")

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(
      IAgentWidgetProjection.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertEqual(decoded.version, IAgentWidgetProjection.schemaVersion)
    XCTAssertEqual(decoded.todayCalendarEventCount, 0)
    XCTAssertEqual(decoded.noteCount, 1)
    XCTAssertNil(decoded.nextMeeting)
  }

  func testNextMeetingPrefersAnOngoingTimedEventAndSkipsPastAndAllDayEvents() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let past = SyncedCalendarEvent(
      id: "past",
      title: "Past review",
      startDate: now.addingTimeInterval(-7_200),
      endDate: now.addingTimeInterval(-3_600),
      isAllDay: false,
      calendarTitle: "Work",
      location: nil,
      linkURLs: [],
      updatedAt: now
    )
    let allDay = SyncedCalendarEvent(
      id: "all-day",
      title: "Company holiday",
      startDate: now.addingTimeInterval(-3_600),
      endDate: now.addingTimeInterval(82_800),
      isAllDay: true,
      calendarTitle: "Work",
      location: nil,
      linkURLs: [],
      updatedAt: now
    )
    let ongoing = SyncedCalendarEvent(
      id: "ongoing",
      title: "Design sync",
      startDate: now.addingTimeInterval(-600),
      endDate: now.addingTimeInterval(1_200),
      isAllDay: false,
      calendarTitle: "Work",
      location: nil,
      linkURLs: [],
      updatedAt: now
    )
    let upcoming = SyncedCalendarEvent(
      id: "upcoming",
      title: "Product review",
      startDate: now.addingTimeInterval(3_600),
      endDate: now.addingTimeInterval(5_400),
      isAllDay: false,
      calendarTitle: "Work",
      location: nil,
      linkURLs: [],
      updatedAt: now
    )
    let snapshot = IAgentDataSnapshot(calendarEvents: [past, allDay, upcoming, ongoing])

    let projection = IAgentWidgetProjection.make(from: snapshot, generatedAt: now)

    XCTAssertEqual(projection.nextMeeting?.title, "Design sync")
    XCTAssertEqual(projection.nextMeeting?.start, ongoing.startDate)
    XCTAssertEqual(projection.nextMeeting?.end, ongoing.endDate)
  }

  func testProjectionIsBoundedSortedAndExcludesSensitiveBodiesAndActivity() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var todos: [SyncedTodo] = []
    for index in 0..<12 {
      let title = index == 0 ? "  Private\n\ttodo   title  " : "Todo \(index)"
      let todo = SyncedTodo(
        title: title,
        isStarred: index == 11,
        dueDate: now.addingTimeInterval(Double(index) * 60),
        createdAt: now.addingTimeInterval(Double(-index))
      )
      todos.append(todo)
    }
    let note = SyncedNote(
      title: "Roadmap",
      body: "SECRET NOTE BODY",
      sourceDeviceID: "private-device"
    )
    let task = SyncedCodexThread(
      id: "task-1",
      projectName: "/Users/private/workspace",
      title: "Build widgets",
      activity: "SECRET CODEX PROMPT AND PROGRESS",
      state: .needsApproval,
      modes: [.plan],
      createdAt: now,
      updatedAt: now
    )
    let unsafeTask = SyncedCodexThread(
      id: "../../private/thread",
      projectName: "/Users/private/another-workspace",
      title: "Unsafe identifier",
      activity: "SHOULD NEVER BE PROJECTED",
      state: .running,
      modes: [],
      createdAt: now,
      updatedAt: now
    )
    let snapshot = IAgentDataSnapshot(
      notes: [note],
      todos: todos,
      codexThreads: [task, unsafeTask],
      lastSuccessfulSyncAt: now
    )

    let projection = IAgentWidgetProjection.make(from: snapshot, generatedAt: now)

    XCTAssertEqual(projection.todos.count, IAgentWidgetProjection.maximumItemsPerSection)
    XCTAssertEqual(projection.todos.first?.title, "Todo 11")
    XCTAssertEqual(projection.codexAttentionCount, 1)
    XCTAssertEqual(projection.codexTasks.first?.state, .needsApproval)
    XCTAssertEqual(projection.codexTasks.first?.projectName, "workspace")
    XCTAssertEqual(projection.codexTasks.first?.startedAt, now)
    XCTAssertEqual(projection.codexTasks.count, 1)

    let encoder = JSONEncoder()
    let json = String(decoding: try encoder.encode(projection), as: UTF8.self)
    XCTAssertFalse(json.contains("SECRET NOTE BODY"))
    XCTAssertFalse(json.contains("SECRET CODEX PROMPT AND PROGRESS"))
    XCTAssertFalse(json.contains("private-device"))
    XCTAssertFalse(json.contains("/Users/private"))
    XCTAssertFalse(json.contains("../../private/thread"))
    XCTAssertFalse(json.contains("SHOULD NEVER BE PROJECTED"))
  }

  func testProjectionStoreRoundTripsAtomically() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-widget-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IAgentWidgetProjectionStore(fileURL: root.appendingPathComponent("projection.json"))
    let projection = IAgentWidgetProjection.empty(at: Date(timeIntervalSince1970: 42))

    try store.save(projection)

    XCTAssertEqual(try store.load(), projection)
  }
}
