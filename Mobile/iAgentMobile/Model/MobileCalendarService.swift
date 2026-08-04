import EventKit
import Foundation
import iAgentCore

@MainActor
final class MobileCalendarService: ObservableObject {
  enum AccessState: Equatable {
    case idle
    case granted
    case denied
    case failed(String)
  }

  @Published private(set) var events: [SyncedCalendarEvent] = []
  @Published private(set) var accessState: AccessState = .idle

  private let eventStore = EKEventStore()

  func requestAccessAndRefresh() async {
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
      refreshToday()
    } catch {
      accessState = .failed(error.localizedDescription)
    }
  }

  func refreshToday(referenceDate: Date = Date()) {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
    let calendar = Calendar.autoupdatingCurrent
    let start = calendar.startOfDay(for: referenceDate)
    guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
    let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)

    events = eventStore.events(matching: predicate)
      .filter { !$0.isDetached }
      .map { event in
        SyncedCalendarEvent(
          id: event.eventIdentifier ?? UUID().uuidString,
          title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Untitled event",
          startDate: event.startDate,
          endDate: event.endDate,
          isAllDay: event.isAllDay,
          calendarTitle: event.calendar.title,
          location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
          linkURLs: Self.links(in: event),
          updatedAt: event.lastModifiedDate ?? Date()
        )
      }
      .sorted { lhs, rhs in
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        return lhs.startDate < rhs.startDate
      }
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
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
