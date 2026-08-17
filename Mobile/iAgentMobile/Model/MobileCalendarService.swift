import EventKit
import Foundation
import UIKit
import iAgentCore

@MainActor
final class MobileCalendarService: ObservableObject {
  struct AskIAgentSnapshot: Equatable, Sendable {
    let events: [SyncedCalendarEvent]
    let coverage: AskCatalogCoverage?
  }

  static let askIAgentPastDayCount = 366
  static let askIAgentFutureDayCount = 731

  enum AccessState: Equatable {
    case idle
    case granted
    case denied
    case failed(String)
  }

  @Published private(set) var events: [SyncedCalendarEvent] = []
  @Published private(set) var calendarNames: [String] = []
  @Published private(set) var accessState: AccessState = .idle

  private let eventStore = EKEventStore()

  func requestAccessAndRefresh(referenceDate: Date = Date()) async {
    do {
      let granted: Bool
      if #available(iOS 17.0, *) {
        granted = try await eventStore.requestFullAccessToEvents()
      } else {
        granted = false
      }

      guard granted else {
        accessState = .denied
        return
      }
      accessState = .granted
      refreshCalendarNames()
      refresh(referenceDate: referenceDate)
    } catch {
      accessState = .failed(error.localizedDescription)
    }
  }

  func refresh(referenceDate: Date = Date()) {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
    refreshCalendarNames()
    let calendar = Calendar.autoupdatingCurrent
    let start = calendar.startOfDay(for: referenceDate)
    guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
    events = permittedEvents(from: start, to: end)
  }

  /// Returns events from every EventKit calendar the user has authorized. Ask iAgent
  /// uses this read-only range query independently of the Today view's display toggle.
  func permittedEvents(from startDate: Date, to endDate: Date) -> [SyncedCalendarEvent] {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
      startDate < endDate
    else { return [] }
    let predicate = eventStore.predicateForEvents(
      withStart: startDate,
      end: endDate,
      calendars: nil
    )
    return eventStore.events(matching: predicate)
      // Detached recurring-event exceptions are still real, user-visible occurrences. Dropping
      // them would make the fixed Ask iAgent window incomplete while advertising exact coverage.
      .map(Self.syncedEvent)
      .sorted { lhs, rhs in
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        return lhs.startDate < rhs.startDate
      }
  }

  /// Captures one prompt-independent EventKit window for an Ask iAgent turn. The day-aligned
  /// half-open bounds are frozen with the returned value, so submit and retry expose identical
  /// retrieval semantics and an empty authorized result still has exact coverage.
  func askIAgentSnapshot(
    referenceDate: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> AskIAgentSnapshot {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
      let range = Self.askIAgentCoverage(referenceDate: referenceDate, calendar: calendar)
    else {
      return AskIAgentSnapshot(events: [], coverage: nil)
    }
    return AskIAgentSnapshot(
      events: permittedEvents(from: range.start, to: range.end),
      coverage: AskCatalogCoverage(
        start: range.start,
        end: range.end,
        isCompleteWithinRange: true,
        isTruncated: false
      )
    )
  }

  static func askIAgentCoverage(
    referenceDate: Date,
    calendar: Calendar
  ) -> AskDateRange? {
    let day = calendar.startOfDay(for: referenceDate)
    guard
      let start = calendar.date(
        byAdding: .day,
        value: -askIAgentPastDayCount,
        to: day
      ),
      let end = calendar.date(
        byAdding: .day,
        value: askIAgentFutureDayCount,
        to: day
      ),
      start < end
    else { return nil }
    return AskDateRange(start: start, end: end)
  }

  func refreshToday() {
    refresh(referenceDate: Date())
  }

  private func refreshCalendarNames() {
    var seen = Set<String>()
    calendarNames = eventStore.calendars(for: .event)
      .compactMap { calendar in
        let title = calendar.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let key = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard seen.insert(key).inserted else { return nil }
        return title
      }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  private static func links(in event: EKEvent) -> [URL] {
    var values: [URL] = []
    if let url = event.url { values.append(url) }

    let searchable = [event.notes, event.location]
      .compactMap { $0 }
      .joined(separator: "\n")
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      let range = NSRange(searchable.startIndex..., in: searchable)
      for match in detector.matches(in: searchable, range: range) {
        if let url = match.url { values.append(url) }
      }
    }

    var seen = Set<String>()
    return values.filter { seen.insert($0.absoluteString).inserted }
  }

  private static func syncedEvent(_ event: EKEvent) -> SyncedCalendarEvent {
    SyncedCalendarEvent(
      id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
      sourceIdentifier: event.calendarItemExternalIdentifier,
      title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Untitled event",
      startDate: event.startDate,
      endDate: event.endDate,
      isAllDay: event.isAllDay,
      calendarTitle: event.calendar.title,
      location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
      notes: event.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
      calendarColorHex: Self.colorHex(from: event.calendar.cgColor),
      linkURLs: Self.links(in: event),
      updatedAt: event.lastModifiedDate ?? Date()
    )
  }

  private static func colorHex(from cgColor: CGColor?) -> String? {
    guard let cgColor else { return nil }
    let color = UIColor(cgColor: cgColor)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
    return String(
      format: "#%02X%02X%02X",
      Int((red * 255).rounded()),
      Int((green * 255).rounded()),
      Int((blue * 255).rounded())
    )
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
