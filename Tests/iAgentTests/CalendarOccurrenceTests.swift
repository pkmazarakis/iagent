import XCTest
@testable import iAgentCore

final class CalendarOccurrenceTests: XCTestCase {
  func testRecurringOccurrencesWithSharedSourceIdentifierRemainDistinct() {
    let first = event(
      id: "standup-first",
      sourceIdentifier: "recurring-standup",
      start: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let following = event(
      id: "standup-following",
      sourceIdentifier: "recurring-standup",
      start: first.startDate.addingTimeInterval(86_400)
    )

    XCTAssertFalse(first.isSameOccurrence(as: following))
  }

  func testSameOccurrenceWithSharedSourceIdentifierCollapses() {
    let desktop = event(
      id: "desktop-id",
      sourceIdentifier: "shared-event-id",
      start: Date(timeIntervalSince1970: 1_800_000_000)
    )
    var phone = event(
      id: "phone-id",
      sourceIdentifier: " SHARED-EVENT-ID ",
      start: desktop.startDate.addingTimeInterval(0.4)
    )
    phone.endDate = desktop.endDate.addingTimeInterval(0.4)

    XCTAssertTrue(desktop.isSameOccurrence(as: phone))
  }

  func testSameOccurrenceCanMatchAcrossDifferentDeviceIdentifiers() {
    let desktop = event(
      id: "desktop-id",
      sourceIdentifier: "desktop-external-id",
      start: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let phone = event(
      id: "phone-id",
      sourceIdentifier: "phone-external-id",
      start: desktop.startDate
    )

    XCTAssertTrue(desktop.isSameOccurrence(as: phone))
  }

  func testAllDayAndTimedEventsDoNotCollapse() {
    let timed = event(
      id: "timed",
      sourceIdentifier: "same-source",
      start: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let allDay = SyncedCalendarEvent(
      id: "all-day",
      sourceIdentifier: timed.sourceIdentifier,
      title: timed.title,
      startDate: timed.startDate,
      endDate: timed.endDate,
      isAllDay: true,
      calendarTitle: timed.calendarTitle,
      location: nil,
      linkURLs: [],
      updatedAt: timed.updatedAt
    )

    XCTAssertFalse(timed.isSameOccurrence(as: allDay))
  }

  private func event(
    id: String,
    sourceIdentifier: String?,
    start: Date
  ) -> SyncedCalendarEvent {
    SyncedCalendarEvent(
      id: id,
      sourceIdentifier: sourceIdentifier,
      title: "Daily Standup",
      startDate: start,
      endDate: start.addingTimeInterval(1_800),
      isAllDay: false,
      calendarTitle: "Work",
      location: nil,
      linkURLs: [],
      updatedAt: start
    )
  }
}
