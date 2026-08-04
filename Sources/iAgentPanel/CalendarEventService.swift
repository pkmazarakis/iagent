import AppKit
import EventKit
import SwiftUI

private struct CalendarScriptEventDetails: Sendable {
  let uid: String
  let title: String
  let startDate: Date
  let calendarTitle: String
  let linkURLs: [URL]
}

private enum CalendarScriptLoadResult: Sendable {
  case success([CalendarScriptEventDetails])
  case failure(String)
}

private struct CalendarScriptLoadError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private enum CalendarInviteURLExtractor {
  static func urls(explicitURLs: [URL] = [], textCandidates: [String]) -> [URL] {
    var urls: [URL] = []
    var seen: Set<String> = []

    func append(_ url: URL) {
      guard isOpenable(url) else { return }
      let key = url.absoluteString.lowercased()
      guard seen.insert(key).inserted else { return }
      urls.append(url)
    }

    explicitURLs.forEach(append)
    let detector = try? NSDataDetector(
      types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    let invisibleScalars = CharacterSet(charactersIn: "\u{200B}\u{2060}\u{FEFF}")
    for rawText in textCandidates {
      let text = rawText.components(separatedBy: invisibleScalars).joined()
      let range = NSRange(text.startIndex ..< text.endIndex, in: text)
      detector?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
        if let url = match?.url {
          append(url)
        }
      }
    }
    return urls
  }

  private static func isOpenable(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return ["http", "https", "zoommtg", "msteams", "webex"].contains(scheme)
  }
}

private enum CalendarScriptEventLoader {
  private static let source = """
  tell application "Calendar"
    set dayStart to current date
    set time of dayStart to 0
    set dayEnd to dayStart + (24 * hours)
    set rows to {}
    repeat with cal in calendars
      set dayEvents to (every event of cal whose start date is greater than or equal to dayStart and start date is less than dayEnd)
      repeat with ev in dayEvents
        set eventURL to ""
        try
          set rawURL to url of ev
          if rawURL is not missing value then set eventURL to rawURL as text
        end try
        set eventLocation to ""
        try
          set rawLocation to location of ev
          if rawLocation is not missing value then set eventLocation to rawLocation as text
        end try
        set eventNotes to ""
        try
          set rawNotes to description of ev
          if rawNotes is not missing value then set eventNotes to rawNotes as text
        end try
        set end of rows to {(uid of ev as text), (summary of ev as text), (start date of ev), (name of cal as text), eventURL, eventLocation, eventNotes}
      end repeat
    end repeat
    return rows
  end tell
  """

  static func loadToday() throws -> [CalendarScriptEventDetails] {
    guard let script = NSAppleScript(source: source) else {
      throw CalendarScriptLoadError(message: "Could not create the Calendar link script.")
    }
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
      let message = errorInfo[NSAppleScript.errorMessage] as? String
        ?? String(describing: errorInfo)
      throw CalendarScriptLoadError(message: message)
    }

    var details: [CalendarScriptEventDetails] = []
    guard result.numberOfItems > 0 else { return details }
    for index in 1 ... result.numberOfItems {
      guard let row = result.atIndex(index),
            row.numberOfItems >= 7,
            let uid = row.atIndex(1)?.stringValue,
            let title = row.atIndex(2)?.stringValue,
            let startDate = row.atIndex(3)?.dateValue,
            let calendarTitle = row.atIndex(4)?.stringValue
      else { continue }

      let eventURL = row.atIndex(5)?.stringValue ?? ""
      let location = row.atIndex(6)?.stringValue ?? ""
      let notes = row.atIndex(7)?.stringValue ?? ""
      details.append(
        CalendarScriptEventDetails(
          uid: uid,
          title: title,
          startDate: startDate,
          calendarTitle: calendarTitle,
          linkURLs: CalendarInviteURLExtractor.urls(
            textCandidates: [eventURL, location, notes]
          )
        )
      )
    }
    return details
  }
}

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
  let sourceIdentifier: String?
  let title: String
  let startDate: Date
  let endDate: Date
  let isAllDay: Bool
  let calendarTitle: String
  let location: String?
  let linkURLs: [URL]
  let tint: CalendarEventTint
  let updatedAt: Date

  init(
    id: String,
    sourceIdentifier: String? = nil,
    title: String,
    startDate: Date,
    endDate: Date,
    isAllDay: Bool,
    calendarTitle: String,
    location: String?,
    linkURLs: [URL] = [],
    tint: CalendarEventTint,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.sourceIdentifier = sourceIdentifier
    self.title = title
    self.startDate = startDate
    self.endDate = endDate
    self.isAllDay = isAllDay
    self.calendarTitle = calendarTitle
    self.location = location
    self.linkURLs = linkURLs
    self.tint = tint
    self.updatedAt = updatedAt
  }

  func replacingLinkURLs(_ linkURLs: [URL]) -> CalendarEventItem {
    CalendarEventItem(
      id: id,
      sourceIdentifier: sourceIdentifier,
      title: title,
      startDate: startDate,
      endDate: endDate,
      isAllDay: isAllDay,
      calendarTitle: calendarTitle,
      location: location,
      linkURLs: linkURLs,
      tint: tint,
      updatedAt: updatedAt
    )
  }

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
  private(set) var liveDiagnosticLines: [String] = []
  private(set) var supplementalRefreshInFlight = false
  private(set) var supplementalRefreshError: String?

  var onChange: (() -> Void)?

  private let eventStore = EKEventStore()
  private let smokeTest: Bool
  private var eventStoreObserver: NSObjectProtocol?
  private var refreshTimer: Timer?
  private var externalRefreshTask: Task<Void, Never>?
  private var supplementalRefreshTask: Task<Void, Never>?
  private var supplementalLinkCache: [String: [URL]]
  private var hasStarted = false

  private static let supplementalCacheDefaultsKey = "calendarSupplementalLinkCache.v1"

  init(smokeTest: Bool) {
    self.smokeTest = smokeTest
    supplementalLinkCache = smokeTest ? [:] : Self.loadSupplementalLinkCache()
  }

  func start() {
    guard !hasStarted else {
      refresh(forceReload: true)
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
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.scheduleExternalRefresh()
      }
    }

    let refreshTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refresh()
      }
    }
    refreshTimer.tolerance = 2
    RunLoop.main.add(refreshTimer, forMode: .common)
    self.refreshTimer = refreshTimer
    resolveAccess()
  }

  func stop() {
    if let eventStoreObserver {
      NotificationCenter.default.removeObserver(eventStoreObserver)
    }
    eventStoreObserver = nil
    externalRefreshTask?.cancel()
    externalRefreshTask = nil
    supplementalRefreshTask?.cancel()
    supplementalRefreshTask = nil
    supplementalRefreshInFlight = false
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
          self.refresh(forceReload: true)
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

  func refresh(forceReload: Bool = false) {
    referenceNow = Date()
    guard accessState.canReadEvents else { return }

    if smokeTest {
      events = Self.sampleEvents(referenceDate: referenceNow)
      onChange?()
      return
    }

    if forceReload {
      eventStore.reset()
    } else {
      eventStore.refreshSourcesIfNecessary()
    }

    let calendar = Calendar.autoupdatingCurrent
    let start = calendar.startOfDay(for: referenceNow)
    guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
    let predicate = eventStore.predicateForEvents(
      withStart: start,
      end: end,
      calendars: nil
    )
    let fetchedEvents = eventStore.events(matching: predicate)
    if CommandLine.arguments.contains("--calendar-live-test") {
      liveDiagnosticLines = fetchedEvents.map { event in
        let notes = String(reflecting: event.notes)
        let location = String(reflecting: event.location)
        let structuredLocation = String(reflecting: event.structuredLocation?.title)
        let url = String(reflecting: event.url?.absoluteString)
        return "[calendar-live:raw] title=\(event.title ?? "Untitled") "
            + "hasNotes=\(event.hasNotes) url=\(url) location=\(location) "
            + "structuredLocation=\(structuredLocation) notes=\(notes)"
      }
      liveDiagnosticLines.forEach { print($0) }
    }
    let mappedEvents = fetchedEvents
      .filter { $0.status != .canceled }
      .map(Self.item(from:))
      .sorted {
        if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
        return $0.startDate < $1.startDate
      }
    events = mappedEvents.map(applyingSupplementalLinks)
    onChange?()
    if forceReload {
      scheduleSupplementalLinkRefresh()
    }
  }

  private func scheduleSupplementalLinkRefresh() {
    supplementalRefreshTask?.cancel()
    supplementalRefreshInFlight = true
    supplementalRefreshError = nil
    supplementalRefreshTask = Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        do {
          return CalendarScriptLoadResult.success(try CalendarScriptEventLoader.loadToday())
        } catch {
          return CalendarScriptLoadResult.failure(error.localizedDescription)
        }
      }.value

      guard !Task.isCancelled, let self else { return }
      self.supplementalRefreshInFlight = false
      self.supplementalRefreshTask = nil
      switch result {
      case let .success(details):
        self.supplementalRefreshError = nil
        for detail in details {
          for key in Self.cacheKeys(for: detail) {
            if detail.linkURLs.isEmpty {
              self.supplementalLinkCache.removeValue(forKey: key)
            } else {
              self.supplementalLinkCache[key] = detail.linkURLs
            }
          }
        }
        self.persistSupplementalLinkCache()
        self.events = self.events.map(self.applyingSupplementalLinks)
        self.onChange?()
      case let .failure(message):
        self.supplementalRefreshError = message
      }
    }
  }

  private func applyingSupplementalLinks(to event: CalendarEventItem) -> CalendarEventItem {
    var merged = event.linkURLs
    var seen = Set(merged.map { $0.absoluteString.lowercased() })
    for key in Self.cacheKeys(for: event) {
      for url in supplementalLinkCache[key] ?? [] {
        guard seen.insert(url.absoluteString.lowercased()).inserted else { continue }
        merged.append(url)
      }
    }
    return event.replacingLinkURLs(merged)
  }

  private static func cacheKeys(for event: CalendarEventItem) -> [String] {
    cacheKeys(
      uid: event.sourceIdentifier,
      title: event.title,
      startDate: event.startDate,
      calendarTitle: event.calendarTitle
    )
  }

  private static func cacheKeys(for detail: CalendarScriptEventDetails) -> [String] {
    cacheKeys(
      uid: detail.uid,
      title: detail.title,
      startDate: detail.startDate,
      calendarTitle: detail.calendarTitle
    )
  }

  private static func cacheKeys(
    uid: String?,
    title: String,
    startDate: Date,
    calendarTitle: String
  ) -> [String] {
    var keys: [String] = []
    if let uid = uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty {
      keys.append("uid|\(uid.lowercased())")
    }
    let timestamp = Int(startDate.timeIntervalSince1970.rounded())
    keys.append(
      "event|\(calendarTitle.lowercased())|\(title.lowercased())|\(timestamp)"
    )
    return keys
  }

  private static func loadSupplementalLinkCache() -> [String: [URL]] {
    guard let raw = UserDefaults.standard.dictionary(forKey: supplementalCacheDefaultsKey)
      as? [String: [String]]
    else { return [:] }
    return raw.reduce(into: [:]) { result, entry in
      let urls = entry.value.compactMap(URL.init(string:))
      if !urls.isEmpty {
        result[entry.key] = urls
      }
    }
  }

  private func persistSupplementalLinkCache() {
    let raw = supplementalLinkCache.mapValues { urls in
      urls.map(\.absoluteString)
    }
    UserDefaults.standard.set(raw, forKey: Self.supplementalCacheDefaultsKey)
  }

  private func scheduleExternalRefresh() {
    externalRefreshTask?.cancel()
    externalRefreshTask = Task { [weak self] in
      // Calendar can notify before all edited fields have reached EventKit.
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, let self else { return }
      self.refresh(forceReload: true)
      self.externalRefreshTask = nil
    }
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
        linkURLs: [URL(string: "https://meet.example.com/roadmap-sync")!],
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

  func openEventLink(_ url: URL) {
    guard !smokeTest else { return }
    NSWorkspace.shared.open(url)
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
      refresh(forceReload: true)
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
      sourceIdentifier: event.calendarItemExternalIdentifier,
      title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? "Untitled event",
      startDate: event.startDate,
      endDate: event.endDate,
      isAllDay: event.isAllDay,
      calendarTitle: event.calendar.title,
      location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      linkURLs: inviteURLs(from: event),
      tint: tint(from: event.calendar.cgColor),
      updatedAt: event.lastModifiedDate ?? event.startDate
    )
  }

  private static func inviteURLs(from event: EKEvent) -> [URL] {
    CalendarInviteURLExtractor.urls(
      explicitURLs: [event.url].compactMap { $0 },
      textCandidates: [
        event.location,
        event.structuredLocation?.title,
        event.notes,
      ].compactMap { $0 }
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
        linkURLs: [URL(string: "https://meet.example.com/product-planning")!],
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
