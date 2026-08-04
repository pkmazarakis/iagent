import Foundation
import iAgentCore

struct DesktopSyncInput: Sendable {
  let threads: [AgentThread]?
  let calendarEvents: [CalendarEventItem]?
  let todos: [LocalTodo]
  let todoListNames: [String]
  let projectOrder: [String]
}

struct DesktopWritableSyncState: Sendable {
  let todos: [LocalTodo]
  let todoListNames: [String]
  let status: IAgentCloudSyncStatus
}

actor DesktopSyncCoordinator {
  private struct NoteIndex: Codable, Sendable {
    struct Entry: Codable, Sendable {
      let id: UUID
      var kind: SyncedNoteKind
      let sourceDeviceID: String
      let createdAt: Date
    }

    var entries: [String: Entry] = [:]
  }

  private struct PublishIndex: Codable, Sendable {
    var todoRecordNames: Set<String> = []
    var todoListRecordNames: Set<String> = []
  }

  private let store: IAgentLocalSyncStore
  private let cloud: IAgentCloudSyncEngine?
  private let documentStore: LocalDocumentStore
  private let noteIndexURL: URL
  private let publishIndexURL: URL
  private let deviceID: String
  private let deviceName: String
  private var noteIndex: NoteIndex
  private var publishIndex: PublishIndex

  init(documentStore: LocalDocumentStore, smokeTest: Bool) {
    self.documentStore = documentStore
    let syncDirectory = documentStore.rootURL.appendingPathComponent(".sync", isDirectory: true)
    noteIndexURL = syncDirectory.appendingPathComponent("note-index.json")
    publishIndexURL = syncDirectory.appendingPathComponent("publish-index.json")
    deviceID = Self.loadDeviceID(from: syncDirectory.appendingPathComponent("device-id.txt"))
    deviceName = Host.current().localizedName ?? "Mac"
    noteIndex = Self.loadNoteIndex(from: noteIndexURL)
    publishIndex = Self.loadPublishIndex(from: publishIndexURL)

    let storeURL: URL
    if smokeTest {
      storeURL = documentStore.rootURL
        .appendingPathComponent(".sync", isDirectory: true)
        .appendingPathComponent("sync-store.json")
    } else {
      storeURL = IAgentLocalSyncStore.defaultFileURL(appIdentifier: "iAgentPanel")
    }
    let store = IAgentLocalSyncStore(fileURL: storeURL)
    self.store = store

    let cloudDisabled = smokeTest
      || ProcessInfo.processInfo.environment["IAGENT_DISABLE_CLOUD_SYNC"] == "1"
    if cloudDisabled {
      cloud = nil
    } else {
      cloud = IAgentCloudSyncEngine(
        store: store,
        containerIdentifier: "iCloud.com.platon.iagent",
        stateFileURL: storeURL.deletingLastPathComponent().appendingPathComponent("cloud-state.json")
      )
    }
  }

  func synchronize(
    input: DesktopSyncInput,
    fetchRemote: Bool
  ) async -> DesktopWritableSyncState {
    do {
      var changed = false
      changed = try await stageReadOnlyData(input) || changed
      changed = try await stageTodos(input.todos) || changed
      changed = try await stageTodoLists(input.todoListNames) || changed
      changed = try await stageLocalNotes() || changed

      if fetchRemote {
        await cloud?.synchronize()
      } else if changed {
        await cloud?.pushLocalChanges()
      }

      let materialized = try await materializeRemoteNotes()
      if materialized {
        let noteChanges = try await stageLocalNotes()
        if noteChanges {
          await cloud?.pushLocalChanges()
        }
      }

      return await writableState()
    } catch {
      let snapshot = await store.snapshot()
      return DesktopWritableSyncState(
        todos: snapshot.todos.map(LocalTodo.init),
        todoListNames: snapshot.todoLists.map(\.name),
        status: IAgentCloudSyncStatus(phase: .failed, message: error.localizedDescription)
      )
    }
  }

  func publishMeeting(
    document: LocalDocument,
    event: CalendarEventItem?,
    startedAt: Date,
    endedAt: Date
  ) async {
    do {
      let note = try indexedNote(for: document, kind: .meeting)
      let meeting = SyncedMeetingSession(
        noteID: note.id,
        title: note.title,
        calendarEventID: event?.id,
        sourceDeviceID: deviceID,
        state: .completed,
        startedAt: startedAt,
        endedAt: endedAt,
        updatedAt: endedAt
      )
      let changed = try await stageChanged([.note(note), .meetingSession(meeting)])
      try persistNoteIndex()
      if changed {
        await cloud?.pushLocalChanges()
      }
    } catch {
      // The Markdown note remains canonical even when cloud sync is unavailable.
    }
  }

  func stop() async {
    await cloud?.stop()
  }

  func mergeRemoteForTesting(_ payloads: [IAgentSyncPayload]) async throws {
    for payload in payloads {
      _ = try await store.mergeRemote(payload, cloudSystemFields: nil)
    }
  }

  private func stageReadOnlyData(_ input: DesktopSyncInput) async throws -> Bool {
    let threadPayloads = input.threads?.map { thread in
      IAgentSyncPayload.codexThread(
        SyncedCodexThread(
          id: thread.id,
          projectName: thread.projectName,
          title: thread.title,
          activity: thread.activity,
          state: thread.state.syncedState,
          modes: thread.modes.compactMap(\.syncedMode),
          createdAt: thread.createdAt,
          updatedAt: thread.updatedAt
        )
      )
    }

    let calendarPayloads = input.calendarEvents?.map { event in
      IAgentSyncPayload.calendarEvent(
        SyncedCalendarEvent(
          id: event.id,
          title: event.title,
          startDate: event.startDate,
          endDate: event.endDate,
          isAllDay: event.isAllDay,
          calendarTitle: event.calendarTitle,
          location: event.location,
          linkURLs: event.linkURLs,
          updatedAt: event.updatedAt
        )
      )
    }

    let existingDesktop = await store.allPayloads().compactMap { payload -> SyncedDesktopSnapshot? in
      guard case let .desktopSnapshot(value) = payload,
            value.id == deviceID,
            value.deletedAt == nil
      else { return nil }
      return value
    }.first
    let activeCodexCount = input.threads?.filter(\.state.isActive).count
      ?? existingDesktop?.activeCodexCount
      ?? 0
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "0.1"
    let generatedAt: Date
    if let existingDesktop,
       existingDesktop.activeCodexCount == activeCodexCount,
       existingDesktop.openTodoCount == input.todos.filter({ !$0.isCompleted }).count,
       existingDesktop.projectOrder == input.projectOrder,
       existingDesktop.deviceName == deviceName,
       existingDesktop.appVersion == appVersion {
      generatedAt = existingDesktop.generatedAt
    } else {
      generatedAt = Date()
    }
    let desktop = IAgentSyncPayload.desktopSnapshot(
      SyncedDesktopSnapshot(
        id: deviceID,
        deviceName: deviceName,
        activeCodexCount: activeCodexCount,
        openTodoCount: input.todos.filter { !$0.isCompleted }.count,
        projectOrder: input.projectOrder,
        generatedAt: generatedAt,
        appVersion: appVersion
      )
    )

    var changed = false
    if let threadPayloads {
      changed = try await stageAuthoritative(threadPayloads, kind: .codexThread)
    }
    if let calendarPayloads {
      changed = try await stageAuthoritative(calendarPayloads, kind: .calendarEvent) || changed
    }
    changed = try await stageChanged([desktop]) || changed
    return changed
  }

  private func stageTodos(_ todos: [LocalTodo]) async throws -> Bool {
    let payloads = todos.map { todo in
      IAgentSyncPayload.todo(
        SyncedTodo(
          id: todo.id,
          title: todo.title,
          isCompleted: todo.isCompleted,
          isStarred: todo.isStarred,
          dueDate: todo.dueDate,
          listName: todo.listName,
          completedAt: todo.completedAt,
          createdAt: todo.createdAt,
          updatedAt: todo.updatedAt
        )
      )
    }
    let changed = try await stageTrackedAuthoritative(
      payloads,
      previouslyPublished: publishIndex.todoRecordNames
    )
    publishIndex.todoRecordNames = Set(payloads.map(\.recordName))
    try persistPublishIndex()
    return changed
  }

  private func stageTodoLists(_ names: [String]) async throws -> Bool {
    let existing = await store.allPayloads().compactMap { payload -> SyncedTodoList? in
      guard case let .todoList(value) = payload, value.deletedAt == nil else { return nil }
      return value
    }
    let now = Date()
    let payloads = names.enumerated().map { index, name -> IAgentSyncPayload in
      if var value = existing.first(where: {
        $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
      }) {
        if value.name != name || value.order != index {
          value.name = name
          value.order = index
          value.updatedAt = now
        }
        return .todoList(value)
      }
      return .todoList(SyncedTodoList(name: name, order: index, createdAt: now, updatedAt: now))
    }
    let changed = try await stageTrackedAuthoritative(
      payloads,
      previouslyPublished: publishIndex.todoListRecordNames
    )
    publishIndex.todoListRecordNames = Set(payloads.map(\.recordName))
    try persistPublishIndex()
    return changed
  }

  private func stageLocalNotes() async throws -> Bool {
    let notesDirectory = documentStore.folderURL(for: .note)
    let fileManager = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
    let files = (fileManager.enumerator(
      at: notesDirectory,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles]
    )?.allObjects as? [URL] ?? []).filter { url in
      url.pathExtension.lowercased() == "md"
        && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    var payloads: [IAgentSyncPayload] = []
    var livePaths = Set<String>()
    for fileURL in files {
      let relativePath = try relativePath(for: fileURL)
      livePaths.insert(relativePath)
      let source = try String(contentsOf: fileURL, encoding: .utf8)
      let parsed = Self.parseMarkdown(source, fallbackTitle: fileURL.deletingPathExtension().lastPathComponent)
      let values = try fileURL.resourceValues(forKeys: Set(keys))
      let createdAt = values.creationDate ?? values.contentModificationDate ?? Date()
      let updatedAt = values.contentModificationDate ?? createdAt
      var entry = noteIndex.entries[relativePath] ?? NoteIndex.Entry(
        id: UUID(),
        kind: source.contains("## Transcript") ? .meeting : .note,
        sourceDeviceID: deviceID,
        createdAt: createdAt
      )
      if source.contains("## Transcript") {
        entry.kind = .meeting
      }
      noteIndex.entries[relativePath] = entry
      payloads.append(
        .note(
          SyncedNote(
            id: entry.id,
            kind: entry.kind,
            title: parsed.title,
            body: parsed.body,
            createdAt: entry.createdAt,
            updatedAt: updatedAt,
            sourceDeviceID: entry.sourceDeviceID,
            relativeFilePath: relativePath
          )
        )
      )
    }

    let existingByID = Dictionary(uniqueKeysWithValues: await store.allPayloads().compactMap {
      payload -> (UUID, IAgentSyncPayload)? in
      guard case let .note(note) = payload else { return nil }
      return (note.id, payload)
    })
    for (path, entry) in Array(noteIndex.entries) where !livePaths.contains(path) {
      if let existing = existingByID[entry.id], existing.deletedAt == nil {
        payloads.append(existing.deleting())
      }
      noteIndex.entries.removeValue(forKey: path)
    }

    try persistNoteIndex()
    return try await stageChanged(payloads)
  }

  private func materializeRemoteNotes() async throws -> Bool {
    let payloads = await store.allPayloads()
    var changed = false

    for payload in payloads {
      guard case var .note(note) = payload else { continue }
      let indexed = noteIndex.entries.first(where: { $0.value.id == note.id })

      if note.deletedAt != nil {
        if let indexed {
          let fileURL = documentStore.rootURL.appendingPathComponent(indexed.key)
          if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
          }
          noteIndex.entries.removeValue(forKey: indexed.key)
          changed = true
        }
        continue
      }

      let relativePath: String
      if let indexed {
        relativePath = indexed.key
      } else if let supplied = note.relativeFilePath, Self.isSafeNotePath(supplied) {
        relativePath = supplied
      } else {
        relativePath = generatedNotePath(for: note)
      }

      if indexed == nil {
        noteIndex.entries[relativePath] = NoteIndex.Entry(
          id: note.id,
          kind: note.kind,
          sourceDeviceID: note.sourceDeviceID,
          createdAt: note.createdAt
        )
        changed = true
      }

      let fileURL = documentStore.rootURL.appendingPathComponent(relativePath)
      let localModified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      if localModified == nil || localModified! <= note.updatedAt.addingTimeInterval(0.5) {
        try FileManager.default.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Self.markdown(title: note.title, body: note.body)
          .write(to: fileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
          [.modificationDate: note.updatedAt],
          ofItemAtPath: fileURL.path
        )
        changed = true
      }

      if note.relativeFilePath != relativePath {
        note.relativeFilePath = relativePath
        _ = try await stageChanged([.note(note)])
        changed = true
      }
    }

    try persistNoteIndex()
    return changed
  }

  private func indexedNote(
    for document: LocalDocument,
    kind: SyncedNoteKind
  ) throws -> SyncedNote {
    let relativePath = try relativePath(for: document.fileURL)
    let values = try document.fileURL.resourceValues(
      forKeys: [.creationDateKey, .contentModificationDateKey]
    )
    let createdAt = values.creationDate ?? document.createdAt
    let updatedAt = values.contentModificationDate ?? Date()
    var entry = noteIndex.entries[relativePath] ?? NoteIndex.Entry(
      id: UUID(),
      kind: kind,
      sourceDeviceID: deviceID,
      createdAt: createdAt
    )
    entry.kind = kind
    noteIndex.entries[relativePath] = entry
    return SyncedNote(
      id: entry.id,
      kind: kind,
      title: document.title,
      body: document.body,
      createdAt: entry.createdAt,
      updatedAt: updatedAt,
      sourceDeviceID: entry.sourceDeviceID,
      relativeFilePath: relativePath
    )
  }

  private func writableState() async -> DesktopWritableSyncState {
    let snapshot = await store.snapshot()
    let status = await cloud?.status() ?? IAgentCloudSyncStatus(
      phase: .idle,
      lastSuccessfulSyncAt: snapshot.lastSuccessfulSyncAt,
      message: "Local sync store"
    )
    return DesktopWritableSyncState(
      todos: snapshot.todos.map(LocalTodo.init),
      todoListNames: snapshot.todoLists.map(\.name),
      status: status
    )
  }

  private func stageAuthoritative(
    _ payloads: [IAgentSyncPayload],
    kind: IAgentEntityKind
  ) async throws -> Bool {
    var candidates = payloads
    let currentNames = Set(payloads.map(\.recordName))
    for existing in await store.allPayloads()
    where existing.kind == kind && existing.deletedAt == nil && !currentNames.contains(existing.recordName) {
      candidates.append(existing.deleting())
    }
    return try await stageChanged(candidates)
  }

  private func stageTrackedAuthoritative(
    _ payloads: [IAgentSyncPayload],
    previouslyPublished: Set<String>
  ) async throws -> Bool {
    var candidates = payloads
    let currentNames = Set(payloads.map(\.recordName))
    let removedNames = previouslyPublished.subtracting(currentNames)
    for recordName in removedNames {
      if let existing = await store.payload(for: recordName), existing.deletedAt == nil {
        candidates.append(existing.deleting())
      }
    }
    return try await stageChanged(candidates)
  }

  private func stageChanged(_ payloads: [IAgentSyncPayload]) async throws -> Bool {
    var changed: [IAgentSyncPayload] = []
    for payload in payloads {
      let existing = await store.payload(for: payload.recordName)
      if let existing, existing.updatedAt > payload.updatedAt {
        continue
      }
      if existing != payload {
        changed.append(payload)
      }
    }
    guard !changed.isEmpty else { return false }
    _ = try await store.upsertLocal(changed)
    return true
  }

  private func relativePath(for fileURL: URL) throws -> String {
    let rootPath = documentStore.rootURL.standardizedFileURL.path + "/"
    let path = fileURL.standardizedFileURL.path
    guard path.hasPrefix(rootPath) else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    return String(path.dropFirst(rootPath.count))
  }

  private func generatedNotePath(for note: SyncedNote) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let stamp = formatter.string(from: note.createdAt)
    let slug = Self.slug(note.title)
    return "Notes/\(stamp)-\(slug)-\(note.id.uuidString.prefix(6).lowercased()).md"
  }

  private func persistNoteIndex() throws {
    try FileManager.default.createDirectory(
      at: noteIndexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(noteIndex).write(to: noteIndexURL, options: .atomic)
  }

  private func persistPublishIndex() throws {
    try FileManager.default.createDirectory(
      at: publishIndexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(publishIndex).write(to: publishIndexURL, options: .atomic)
  }

  private static func loadNoteIndex(from fileURL: URL) -> NoteIndex {
    guard let data = try? Data(contentsOf: fileURL) else { return NoteIndex() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(NoteIndex.self, from: data)) ?? NoteIndex()
  }

  private static func loadPublishIndex(from fileURL: URL) -> PublishIndex {
    guard let data = try? Data(contentsOf: fileURL) else { return PublishIndex() }
    return (try? JSONDecoder().decode(PublishIndex.self, from: data)) ?? PublishIndex()
  }

  private static func loadDeviceID(from fileURL: URL) -> String {
    if let value = try? String(contentsOf: fileURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
       !value.isEmpty {
      return value
    }
    let value = UUID().uuidString.lowercased()
    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? value.write(to: fileURL, atomically: true, encoding: .utf8)
    return value
  }

  private static func parseMarkdown(
    _ source: String,
    fallbackTitle: String
  ) -> (title: String, body: String) {
    var lines = source.components(separatedBy: .newlines)
    guard let first = lines.first,
          first.hasPrefix("# ")
    else {
      return (fallbackTitle, source)
    }
    let title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    lines.removeFirst()
    if lines.first?.isEmpty == true { lines.removeFirst() }
    return (title.isEmpty ? fallbackTitle : title, lines.joined(separator: "\n"))
  }

  private static func markdown(title: String, body: String) -> String {
    let trimmedBody: String
    let lines = body.components(separatedBy: .newlines)
    if let first = lines.first,
       first.trimmingCharacters(in: .whitespacesAndNewlines) == "# \(title)" {
      trimmedBody = lines.dropFirst().drop(while: { $0.isEmpty }).joined(separator: "\n")
    } else {
      trimmedBody = body
    }
    guard !trimmedBody.isEmpty else { return "# \(title)\n" }
    return "# \(title)\n\n\(trimmedBody)\(trimmedBody.hasSuffix("\n") ? "" : "\n")"
  }

  private static func isSafeNotePath(_ path: String) -> Bool {
    !path.hasPrefix("/")
      && !path.components(separatedBy: "/").contains("..")
      && path.hasPrefix("Notes/")
      && (path as NSString).pathExtension.lowercased() == "md"
  }

  private static func slug(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let characters = value.lowercased().unicodeScalars.map { scalar -> Character in
      allowed.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let result = String(characters)
      .split(separator: "-", omittingEmptySubsequences: true)
      .prefix(8)
      .joined(separator: "-")
    return result.isEmpty ? "untitled" : result
  }
}

private extension LocalTodo {
  init(_ synced: SyncedTodo) {
    self.init(
      id: synced.id,
      title: synced.title,
      isCompleted: synced.isCompleted,
      isStarred: synced.isStarred,
      dueDate: synced.dueDate,
      listName: synced.listName,
      completedAt: synced.completedAt,
      createdAt: synced.createdAt,
      updatedAt: synced.updatedAt
    )
  }
}

private extension AgentState {
  var syncedState: SyncedCodexState {
    switch self {
    case .running: .running
    case .waitingForInput: .waitingForInput
    case .needsApproval: .needsApproval
    case .completed: .completed
    case .failed: .failed
    }
  }
}

private extension ThreadMode {
  var syncedMode: SyncedThreadMode? {
    switch self {
    case .plan: .plan
    case .goal: .goal
    case .voice: .voice
    }
  }
}
