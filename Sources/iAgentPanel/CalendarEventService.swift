import AppKit
import EventKit
import SwiftUI

enum CalendarAccessState: Equatable, Sendable {
  case idle
  case requesting
  case granted
  case denied
  case restricted
  case failed(String)

  var canReadEvents: Bool {
    self == .granted
  }
}

struct CalendarEventTint: Equatable, Sendable {
  let red: Double
  let green: Double
  let blue: Double

  var color: Color {
    Color(red: red, green: green, blue: blue)
  }

  static let fallback = CalendarEventTint(red: 0.416, green: 0.718, blue: 1)
}

struct CalendarEventItem: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let startDate: Date
  let endDate: Date
  let isAllDay: Bool
  let calendarTitle: String
  let location: String?
  let tint: CalendarEventTint

  func isHappening(at date: Date) -> Bool {
    !isAllDay && startDate <= date && endDate > date
  }

  func hasEnded(at date: Date) -> Bool {
    !isAllDay && endDate <= date
  }

  func timeText(locale: Locale = .current) -> String {
    guard !isAllDay else { return "All day" }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeStyle = .short
    return formatter.string(from: startDate)
  }
}

@MainActor
final class CalendarEventService: ObservableObject {
  @Published private(set) var events: [CalendarEventItem] = []
  @Published private(set) var accessState: CalendarAccessState = .idle
  @Published private(set) var referenceNow = Date()

  var onChange: (() -> Void)?

  private let eventStore = EKEventStore()
  private let smokeTest: Bool
  private var eventStoreObserver: NSObjectProtocol?
  private var refreshTimer: Timer?
  private var hasStarted = false

  init(smokeTest: Bool) {
    self.smokeTest = smokeTest
  }

  func start() {
    guard !hasStarted else {
      refresh()
      return
    }
    hasStarted = true

    if smokeTest {
      accessState = .granted
      events = Self.sampleEvents(referenceDate: Date())
      onChange?()
      return
    }

    eventStoreObserver = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged,
      object: eventStore,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.refresh()
      }
    }

    refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refresh()
      }
    }
    refreshTimer?.tolerance = 2
    resolveAccess()
  }

  func stop() {
    if let eventStoreObserver {
      NotificationCenter.default.removeObserver(eventStoreObserver)
    }
    eventStoreObserver = nil
    refreshTimer?.invalidate()
    refreshTimer = nil
  }

  func requestAccess() {
    guard !smokeTest else {
      accessState = .granted
      refresh()
      return
    }

    accessState = .requesting
    Task { [weak self] in
      guard let self else { return }
      do {
        let granted = try await self.eventStore.requestFullAccessToEvents()
        self.accessState = granted ? .granted : .denied
        if granted {
          self.refresh()
        } else {
          self.events = []
          self.onChange?()
        }
      } catch {
        self.accessState = .failed(error.localizedDescription)
        self.events = []
        self.onChange?()
      }
    }
  }

  func refresh() {
    referenceNow = Date()
    guard accessState.canReadEvents else { return }

    if smokeTest {
      events = Self.sampleEvents(referenceDate: referenceNow)
      onChange?()
      return
    }

    let calendar = Calendar.autoupdatingCurrent
    let start = calendar.startOfDay(for: referenceNow)
    guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
    let predicate = eventStore.predicateForEvents(
      withStart: start,
      end: end,
      calendars: nil
    )
    events = eventStore.events(matching: predicate)
      .filter { $0.status != .canceled }
      .map(Self.item(from:))
      .sorted {
        if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
        return $0.startDate < $1.startDate
      }
    onChange?()
  }

  func prepareMeetingPreview(referenceDate: Date = Date()) {
    guard smokeTest else { return }
    referenceNow = referenceDate
    let calendar = Calendar.autoupdatingCurrent

    func offset(minutes: Int) -> Date {
      calendar.date(byAdding: .minute, value: minutes, to: referenceDate) ?? referenceDate
    }

    events = [
      CalendarEventItem(
        id: "smoke-roadmap-sync",
        title: "Roadmap sync",
        startDate: offset(minutes: -5),
        endDate: offset(minutes: 50),
        isAllDay: false,
        calendarTitle: "Work",
        location: "Studio",
        tint: CalendarEventTint(red: 0.94, green: 0.38, blue: 0.34)
      ),
      CalendarEventItem(
        id: "smoke-design-later",
        title: "Design review",
        startDate: offset(minutes: 90),
        endDate: offset(minutes: 150),
        isAllDay: false,
        calendarTitle: "Work",
        location: nil,
        tint: CalendarEventTint(red: 0.36, green: 0.89, blue: 0.62)
      ),
      CalendarEventItem(
        id: "smoke-dinner-later",
        title: "Dinner with Maya",
        startDate: offset(minutes: 240),
        endDate: offset(minutes: 330),
        isAllDay: false,
        calendarTitle: "Personal",
        location: "Bar Iris",
        tint: CalendarEventTint(red: 0.94, green: 0.78, blue: 0.4)
      ),
    ]
    onChange?()
  }

  func openCalendar() {
    guard !smokeTest else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(
      at: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
      configuration: configuration
    )
  }

  func openCalendarPrivacySettings() {
    guard !smokeTest,
          let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
          )
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func resolveAccess() {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess, .authorized:
      accessState = .granted
      refresh()
    case .notDetermined:
      requestAccess()
    case .restricted:
      accessState = .restricted
      events = []
      onChange?()
    case .denied, .writeOnly:
      accessState = .denied
      events = []
      onChange?()
    @unknown default:
      accessState = .failed("Calendar access is unavailable")
      events = []
      onChange?()
    }
  }

  private static func item(from event: EKEvent) -> CalendarEventItem {
    CalendarEventItem(
      id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
      title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? "Untitled event",
      startDate: event.startDate,
      endDate: event.endDate,
      isAllDay: event.isAllDay,
      calendarTitle: event.calendar.title,
      location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      tint: tint(from: event.calendar.cgColor)
    )
  }

  private static func tint(from cgColor: CGColor?) -> CalendarEventTint {
    guard let cgColor,
          let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB)
    else {
      return .fallback
    }
    return CalendarEventTint(
      red: Double(color.redComponent),
      green: Double(color.greenComponent),
      blue: Double(color.blueComponent)
    )
  }

  private static func sampleEvents(referenceDate: Date) -> [CalendarEventItem] {
    let calendar = Calendar.autoupdatingCurrent
    let start = calendar.startOfDay(for: referenceDate)

    func date(hour: Int, minute: Int = 0) -> Date {
      calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start) ?? start
    }

    return [
      CalendarEventItem(
        id: "smoke-planning",
        title: "Product planning",
        startDate: date(hour: 9, minute: 30),
        endDate: date(hour: 10, minute: 15),
        isAllDay: false,
        calendarTitle: "Work",
        location: "Studio",
        tint: CalendarEventTint(red: 0.42, green: 0.72, blue: 1)
      ),
      CalendarEventItem(
        id: "smoke-design",
        title: "Design review",
        startDate: date(hour: 14),
        endDate: date(hour: 15),
        isAllDay: false,
        calendarTitle: "Work",
        location: nil,
        tint: CalendarEventTint(red: 0.36, green: 0.89, blue: 0.62)
      ),
      CalendarEventItem(
        id: "smoke-dinner",
        title: "Dinner with Maya",
        startDate: date(hour: 18, minute: 30),
        endDate: date(hour: 20),
        isAllDay: false,
        calendarTitle: "Personal",
        location: "Bar Iris",
        tint: CalendarEventTint(red: 0.94, green: 0.78, blue: 0.4)
      ),
    ]
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
