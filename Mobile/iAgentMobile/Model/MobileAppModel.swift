import Foundation
import SwiftUI
import UIKit
import iAgentCore

@MainActor
final class MobileAppModel: ObservableObject {
  enum Tab: Hashable {
    case today
    case codex
    case notes
    case todos
  }

  @Published var selectedTab: Tab = .today
  @Published private(set) var snapshot = IAgentDataSnapshot()
  @Published private(set) var syncStatus = IAgentCloudSyncStatus()
  @Published var isRecorderPresented = false
  @Published var isCalendarPresented = false
  @Published var isNoteEditorPresented = false
  @Published var activeMeetingTitle = "Meeting notes"
  @Published var activeCalendarEventID: String?
  @Published var lastRecordedNote: SyncedNote?

  let calendar = MobileCalendarService()
  let recorder = MobileMeetingRecorder()

  private let localStore: IAgentLocalSyncStore
  private let cloud: IAgentCloudSyncEngine?
  private let fixtureMode: Bool
  private var refreshLoop: Task<Void, Never>?
  private var recordingStartedAt: Date?

  init() {
    let arguments = CommandLine.arguments
    #if DEBUG
    let defaultsToFixtures = !arguments.contains("--live-sync")
    #else
    let defaultsToFixtures = false
    #endif

    fixtureMode = arguments.contains("--ui-testing")
      || ProcessInfo.processInfo.environment["IAGENT_FIXTURES"] == "1"
      || defaultsToFixtures

    if let routeIndex = arguments.firstIndex(of: "--start-tab"),
       arguments.indices.contains(routeIndex + 1) {
      switch arguments[routeIndex + 1] {
      case "codex": selectedTab = .codex
      case "notes": selectedTab = .notes
      case "todos": selectedTab = .todos
      case "recorder": isRecorderPresented = true
      case "calendar":
        selectedTab = .today
        isCalendarPresented = true
      case "note-editor":
        selectedTab = .notes
        isNoteEditorPresented = true
      default: selectedTab = .today
      }
    }

    let storeURL = IAgentLocalSyncStore.defaultFileURL(appIdentifier: "iAgentMobile")
    localStore = IAgentLocalSyncStore(fileURL: storeURL)

    if fixtureMode {
      cloud = nil
    } else {
      cloud = IAgentCloudSyncEngine(
        store: localStore,
        containerIdentifier: "iCloud.com.platon.iagent",
        stateFileURL: storeURL.deletingLastPathComponent().appendingPathComponent("cloud-state.json")
      )
    }
  }

  deinit {
    refreshLoop?.cancel()
  }

  var firstName: String? {
    if fixtureMode { return "Platon" }
    let deviceOwner = UIDevice.current.name
      .replacingOccurrences(of: "’s iPhone", with: "")
      .replacingOccurrences(of: "'s iPhone", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ["iPhone", "This iPhone"].contains(deviceOwner) ? nil : deviceOwner
  }

  var todayEvents: [SyncedCalendarEvent] {
    let source = calendar.events.isEmpty ? snapshot.calendarEvents : calendar.events
    return source.filter { event in
      Calendar.autoupdatingCurrent.isDateInToday(event.startDate)
        || (event.isAllDay && Calendar.autoupdatingCurrent.isDateInToday(event.endDate))
    }
  }

  var activeThreads: [SyncedCodexThread] {
    snapshot.codexThreads.filter { $0.state.isActive && $0.deletedAt == nil }
  }

  var recentThreads: [SyncedCodexThread] {
    snapshot.codexThreads.filter { !$0.state.isActive && $0.deletedAt == nil }
  }

  var openTodos: [SyncedTodo] {
    snapshot.todos.filter { !$0.isCompleted && $0.deletedAt == nil }
  }

  var completedTodos: [SyncedTodo] {
    snapshot.todos.filter { $0.isCompleted && $0.deletedAt == nil }
  }

  var visibleNotes: [SyncedNote] {
    snapshot.notes.filter { $0.deletedAt == nil }
  }

  func start() async {
    if fixtureMode {
      try? await localStore.replaceForTesting(with: MobileFixtureData.payloads())
      syncStatus = IAgentCloudSyncStatus(
        phase: .idle,
        lastSuccessfulSyncAt: Date(),
        message: "Preview data"
      )
    } else {
      async let calendarAccess: Void = calendar.requestAccessAndRefresh()
      async let cloudStart: Void = cloud?.start() ?? ()
      _ = await (calendarAccess, cloudStart)
    }

    await reload()
    startRefreshLoop()
  }

  func refresh() async {
    calendar.refreshToday()
    await cloud?.synchronize()
    await reload()
  }

  func open(_ url: URL) {
    UIApplication.shared.open(url)
  }

  func createTodo(title: String, listName: String? = nil, dueDate: Date? = nil) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let todo = SyncedTodo(title: trimmed, dueDate: dueDate, listName: listName)
    await save(.todo(todo))
  }

  func toggleTodo(_ todo: SyncedTodo) async {
    var updated = todo
    updated.isCompleted.toggle()
    updated.completedAt = updated.isCompleted ? Date() : nil
    updated.updatedAt = Date()
    await save(.todo(updated))
  }

  func toggleStar(_ todo: SyncedTodo) async {
    var updated = todo
    updated.isStarred.toggle()
    updated.updatedAt = Date()
    await save(.todo(updated))
  }

  func deleteTodo(_ todo: SyncedTodo) async {
    var updated = todo
    updated.deletedAt = Date()
    updated.updatedAt = Date()
    await save(.todo(updated))
  }

  func createTodoList(named name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !snapshot.todoLists.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
    else { return }
    let list = SyncedTodoList(name: trimmed, order: snapshot.todoLists.count)
    await save(.todoList(list))
  }

  @discardableResult
  func saveNote(
    id: UUID? = nil,
    title: String,
    body: String,
    kind: SyncedNoteKind = .note
  ) async -> SyncedNote {
    let existing = id.flatMap { noteID in snapshot.notes.first(where: { $0.id == noteID }) }
    let now = Date()
    let note = SyncedNote(
      id: existing?.id ?? UUID(),
      kind: kind,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Untitled note",
      body: body,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      sourceDeviceID: existing?.sourceDeviceID ?? UIDevice.current.identifierForVendor?.uuidString ?? "iphone",
      relativeFilePath: existing?.relativeFilePath
    )
    await save(.note(note))
    return note
  }

  func deleteNote(_ note: SyncedNote) async {
    var updated = note
    updated.deletedAt = Date()
    updated.updatedAt = Date()
    await save(.note(updated))
  }

  func presentRecorder(title: String = "Meeting notes", calendarEventID: String? = nil) {
    activeMeetingTitle = title
    activeCalendarEventID = calendarEventID
    lastRecordedNote = nil
    isRecorderPresented = true
  }

  func startRecording() async {
    guard await recorder.start() else { return }
    recordingStartedAt = Date()
  }

  func finishRecording() async {
    let transcript = recorder.stop()
    let startedAt = recordingStartedAt ?? Date().addingTimeInterval(-recorder.elapsed)
    let now = Date()
    let formattedTranscript = transcript.nonEmpty ?? "_No speech was recognized._"
    let body = """
    **Date:** \(startedAt.formatted(date: .long, time: .omitted))  
    **Started:** \(startedAt.formatted(date: .omitted, time: .shortened))

    ## Transcript

    \(formattedTranscript)
    """
    let note = SyncedNote(
      kind: .meeting,
      title: activeMeetingTitle,
      body: body,
      createdAt: startedAt,
      updatedAt: now,
      sourceDeviceID: UIDevice.current.identifierForVendor?.uuidString ?? "iphone"
    )
    let meeting = SyncedMeetingSession(
      noteID: note.id,
      title: activeMeetingTitle,
      calendarEventID: activeCalendarEventID,
      sourceDeviceID: note.sourceDeviceID,
      state: .completed,
      startedAt: startedAt,
      endedAt: now,
      updatedAt: now
    )

    do {
      try await localStore.upsertLocal([.note(note), .meetingSession(meeting)])
      await reload()
      await cloud?.pushLocalChanges()
      lastRecordedNote = note
      recordingStartedAt = nil
    } catch {
      syncStatus = IAgentCloudSyncStatus(phase: .failed, message: error.localizedDescription)
    }
  }

  func dismissRecorder() {
    _ = recorder.stop()
    recorder.reset()
    recordingStartedAt = nil
    isRecorderPresented = false
  }

  private func save(_ payload: IAgentSyncPayload) async {
    do {
      try await localStore.upsertLocal(payload)
      await reload()
      await cloud?.pushLocalChanges()
      await reloadStatus()
    } catch {
      syncStatus = IAgentCloudSyncStatus(phase: .failed, message: error.localizedDescription)
    }
  }

  private func reload() async {
    snapshot = await localStore.snapshot()
    await reloadStatus()
  }

  private func reloadStatus() async {
    if let cloud {
      syncStatus = await cloud.status()
    }
  }

  private func startRefreshLoop() {
    refreshLoop?.cancel()
    refreshLoop = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard let self else { return }
        await reload()
      }
    }
  }
}

private enum MobileFixtureData {
  static func payloads(referenceDate: Date = Date()) -> [IAgentSyncPayload] {
    let calendar = Calendar.autoupdatingCurrent
    let startOfDay = calendar.startOfDay(for: referenceDate)
    func today(_ hour: Int, _ minute: Int = 0) -> Date {
      calendar.date(byAdding: .minute, value: hour * 60 + minute, to: startOfDay) ?? referenceDate
    }

    let events = [
      SyncedCalendarEvent(
        id: "fixture-design-sync",
        title: "Design sync",
        startDate: today(10),
        endDate: today(10, 45),
        isAllDay: false,
        calendarTitle: "Work",
        location: "Studio",
        linkURLs: [URL(string: "https://meet.google.com/abc-defg-hij")!],
        updatedAt: referenceDate
      ),
      SyncedCalendarEvent(
        id: "fixture-product-review",
        title: "Product review",
        startDate: today(13, 30),
        endDate: today(14, 15),
        isAllDay: false,
        calendarTitle: "Work",
        location: nil,
        linkURLs: [],
        updatedAt: referenceDate
      ),
      SyncedCalendarEvent(
        id: "fixture-dinner",
        title: "Dinner with Maya",
        startDate: today(18, 30),
        endDate: today(20),
        isAllDay: false,
        calendarTitle: "Home",
        location: "Bar Iris",
        linkURLs: [],
        updatedAt: referenceDate
      )
    ]

    let threads = [
      SyncedCodexThread(
        id: "fixture-thread-1",
        projectName: "iagent",
        title: "Build mobile companion",
        activity: "Wiring the private CloudKit sync layer",
        state: .running,
        modes: [.plan],
        createdAt: referenceDate.addingTimeInterval(-2_400),
        updatedAt: referenceDate.addingTimeInterval(-120)
      ),
      SyncedCodexThread(
        id: "fixture-thread-2",
        projectName: "pagi",
        title: "Refine ingestion pipeline",
        activity: "Waiting for approval on the migration",
        state: .needsApproval,
        modes: [.goal],
        createdAt: referenceDate.addingTimeInterval(-7_200),
        updatedAt: referenceDate.addingTimeInterval(-480)
      ),
      SyncedCodexThread(
        id: "fixture-thread-3",
        projectName: "timeline",
        title: "Document release flow",
        activity: "The release guide is ready",
        state: .completed,
        modes: [],
        createdAt: referenceDate.addingTimeInterval(-86_400),
        updatedAt: referenceDate.addingTimeInterval(-3_600)
      )
    ]

    let todos = [
      SyncedTodo(
        title: "Send the mobile sync brief",
        isStarred: true,
        dueDate: today(17),
        listName: "work",
        createdAt: referenceDate.addingTimeInterval(-5_400)
      ),
      SyncedTodo(
        title: "Book the flight",
        listName: "personal",
        createdAt: referenceDate.addingTimeInterval(-3_600)
      ),
      SyncedTodo(
        title: "Review meeting notes",
        dueDate: today(20),
        listName: "work",
        createdAt: referenceDate.addingTimeInterval(-1_800)
      )
    ]

    let notes = [
      SyncedNote(
        title: "Mobile companion principles",
        body: "# Mobile companion principles\n\nLocal first. Calm hierarchy. Always make sync state legible.",
        createdAt: referenceDate.addingTimeInterval(-86_400),
        updatedAt: referenceDate.addingTimeInterval(-900),
        sourceDeviceID: "fixture-mac"
      ),
      SyncedNote(
        kind: .meeting,
        title: "Design sync",
        body: "# Design sync\n\n## Transcript\n\nKeep the mobile surface compact and preserve the panel rhythm.",
        createdAt: referenceDate.addingTimeInterval(-172_800),
        updatedAt: referenceDate.addingTimeInterval(-86_000),
        sourceDeviceID: "fixture-mac"
      )
    ]

    let lists = [
      SyncedTodoList(name: "work", order: 0),
      SyncedTodoList(name: "personal", order: 1)
    ]
    let desktop = SyncedDesktopSnapshot(
      id: "fixture-desktop",
      deviceName: "Platon's MacBook Pro",
      activeCodexCount: threads.filter(\.state.isActive).count,
      openTodoCount: todos.count,
      projectOrder: ["iagent", "pagi", "timeline"],
      generatedAt: referenceDate,
      appVersion: "0.1"
    )

    return events.map(IAgentSyncPayload.calendarEvent)
      + threads.map(IAgentSyncPayload.codexThread)
      + todos.map(IAgentSyncPayload.todo)
      + notes.map(IAgentSyncPayload.note)
      + lists.map(IAgentSyncPayload.todoList)
      + [.desktopSnapshot(desktop)]
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
