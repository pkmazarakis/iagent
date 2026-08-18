import Foundation
import Darwin
import iAgentCore

struct DesktopSyncInput: Sendable {
  let threads: [AgentThread]?
  let calendarEvents: [CalendarEventItem]?
  let todos: [LocalTodo]
  let todoListNames: [String]
  let projectOrder: [String]
  let todosAreAuthoritative: Bool
  let todoListNamesAreAuthoritative: Bool

  init(
    threads: [AgentThread]?,
    calendarEvents: [CalendarEventItem]?,
    todos: [LocalTodo],
    todoListNames: [String],
    projectOrder: [String],
    todosAreAuthoritative: Bool = true,
    todoListNamesAreAuthoritative: Bool = true
  ) {
    self.threads = threads
    self.calendarEvents = calendarEvents
    self.todos = todos
    self.todoListNames = todoListNames
    self.projectOrder = projectOrder
    self.todosAreAuthoritative = todosAreAuthoritative
    self.todoListNamesAreAuthoritative = todoListNamesAreAuthoritative
  }
}

struct DesktopWritableSyncState: Sendable {
  let todos: [LocalTodo]
  let todoListNames: [String]
  let noteCount: Int
  let messageConversations: [SyncedMessageConversation]
  let messages: [SyncedMessage]
  let messageReadStates: [SyncedMessageReadState]
  let messageRelayStates: [SyncedMessageRelayState]
  let calendarEvents: [SyncedCalendarEvent]
  let artifactMentions: [ArtifactMention]
  let status: IAgentCloudSyncStatus
  let pendingRecordCount: Int
}

enum DesktopTodoReconciler {
  static func merge(
    remote: [LocalTodo],
    captured: [LocalTodo],
    current: [LocalTodo]
  ) -> [LocalTodo] {
    let capturedByID = Dictionary(uniqueKeysWithValues: captured.map { ($0.id, $0) })
    let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    let locallyDeletedIDs = Set(capturedByID.keys).subtracting(currentByID.keys)
    var mergedByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })

    for id in locallyDeletedIDs {
      mergedByID.removeValue(forKey: id)
    }
    for todo in current {
      if let remoteTodo = mergedByID[todo.id] {
        if todo.updatedAt > remoteTodo.updatedAt {
          mergedByID[todo.id] = todo
        }
      } else if let capturedTodo = capturedByID[todo.id] {
        if todo.updatedAt > capturedTodo.updatedAt {
          mergedByID[todo.id] = todo
        }
      } else {
        mergedByID[todo.id] = todo
      }
    }

    return mergedByID.values.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }
}

actor DesktopSyncCoordinator {
  private struct QuarantinedNoteMetadata: Codable, Sendable {
    let originalRelativePath: String
    let reason: String
    let quarantinedAt: Date
  }

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
  private let cloudPreflight: DesktopCloudSyncPreflight
  private let storageMigrationWarning: String?
  private let documentStore: LocalDocumentStore
  private let noteIndexURL: URL
  private let publishIndexURL: URL
  private let deviceID: String
  private let deviceName: String
  private let noteRequiresDownload: @Sendable (URL) -> Bool
  private var noteIndex: NoteIndex
  private var publishIndex: PublishIndex
  private var noteSourceWarning: String?

  init(
    documentStore: LocalDocumentStore,
    smokeTest: Bool,
    noteRequiresDownload: (@Sendable (URL) -> Bool)? = nil
  ) {
    self.documentStore = documentStore
    self.noteRequiresDownload = noteRequiresDownload ?? Self.isDatalessFile
    let storagePaths = DesktopSyncStoragePaths.prepare(
      documentRootURL: documentStore.rootURL,
      smokeTest: smokeTest
    )
    let syncDirectory = storagePaths.metadataDirectoryURL
    storageMigrationWarning = storagePaths.migrationWarning
    noteIndexURL = syncDirectory.appendingPathComponent("note-index.json")
    publishIndexURL = syncDirectory.appendingPathComponent("publish-index.json")
    deviceID = Self.loadDeviceID(from: syncDirectory.appendingPathComponent("device-id.txt"))
    deviceName = Host.current().localizedName ?? "Mac"
    noteIndex = Self.loadNoteIndex(from: noteIndexURL)
    publishIndex = Self.loadPublishIndex(from: publishIndexURL)

    let storeURL = storagePaths.storeURL
    let store = IAgentLocalSyncStore(
      fileURL: storeURL,
      messageProjectionRole: .localAuthority
    )
    self.store = store

    let cloudPreflight = DesktopCloudSyncPreflight.current(smokeTest: smokeTest)
    self.cloudPreflight = cloudPreflight
    if !cloudPreflight.isAvailable {
      cloud = nil
    } else {
      cloud = IAgentCloudSyncEngine(
        store: store,
        containerIdentifier: DesktopCloudSyncPreflight.expectedContainerIdentifier,
        stateFileURL: storeURL.deletingLastPathComponent().appendingPathComponent("cloud-state.json")
      )
    }
  }

  func synchronize(
    input: DesktopSyncInput,
    fetchRemote: Bool,
    referenceDate: Date = Date()
  ) async -> DesktopWritableSyncState {
    do {
      let retentionDeletions = try await store.enforceMessageRetention(
        referenceDate: referenceDate
      )
      var changed = !retentionDeletions.isEmpty
      changed = try await stageReadOnlyData(input, referenceDate: referenceDate) || changed
      if input.todosAreAuthoritative {
        changed = try await stageTodos(input.todos) || changed
      }
      if input.todoListNamesAreAuthoritative {
        changed = try await stageTodoLists(input.todoListNames) || changed
      }
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
        noteCount: snapshot.notes.count,
        messageConversations: snapshot.messageConversations,
        messages: snapshot.messages,
        messageReadStates: snapshot.messageReadStates,
        messageRelayStates: snapshot.messageRelayStates,
        calendarEvents: snapshot.calendarEvents,
        artifactMentions: ArtifactMentionCatalog.make(snapshot: snapshot),
        status: IAgentCloudSyncStatus(phase: .failed, message: error.localizedDescription),
        pendingRecordCount: snapshot.pendingRecordNames
          .union(snapshot.pendingDeletionRecordNames).count
      )
    }
  }

  /// Reconciles the read-only local Messages projection into the same private
  /// sync store used by the desktop panel. Message bodies never leave this
  /// bridge through a write-back to Messages; only the private CloudKit mirror
  /// is updated.
  func ingestMessageBatch(
    _ batch: MessageProviderBatch,
    referenceDate: Date = Date()
  ) async -> DesktopWritableSyncState {
    do {
      let cutoff = MessageSyncWindow.cutoff(referenceDate: referenceDate)
      let messages = deduplicatedMessages(batch.messages).filter {
        $0.deletedAt == nil && $0.sentAt >= cutoff
      }
      let messagesByConversation = Dictionary(grouping: messages, by: \.conversationID)
      let retainedConversationIDs = Set(messagesByConversation.keys)

      var conversations: [SyncedMessageConversation] = []
      for source in batch.conversations where retainedConversationIDs.contains(source.id) {
        guard let latest = messagesByConversation[source.id]?.max(by: {
          ($0.sentAt, $0.id) < ($1.sentAt, $1.id)
        }) else { continue }
        var conversation = source
        conversation.latestMessageID = latest.id
        conversation.latestMessageDate = latest.sentAt
        conversation.latestPreview = latest.body
        conversation.updatedAt = max(conversation.updatedAt, latest.updatedAt)
        conversations.append(conversation)
      }
      conversations = deduplicatedConversations(conversations)

      var changed = false
      if batch.isFullSnapshot {
        let liveMessageNames = Set(messages.map { IAgentSyncPayload.message($0).recordName })
        let liveConversationNames = Set(conversations.map {
          IAgentSyncPayload.messageConversation($0).recordName
        })
        for existing in await store.allPayloads() {
          let shouldRemove: Bool
          switch existing {
          case .message:
            shouldRemove = !liveMessageNames.contains(existing.recordName)
          case .messageConversation:
            shouldRemove = !liveConversationNames.contains(existing.recordName)
          default:
            shouldRemove = false
          }
          if shouldRemove {
            try await store.deleteLocal(recordName: existing.recordName)
            changed = true
          }
        }
      }

      for messageID in batch.removedMessageIDs {
        let recordName = "\(IAgentEntityKind.message.rawValue)_\(messageID)"
        if await store.payload(for: recordName) != nil {
          try await store.deleteLocal(recordName: recordName)
          changed = true
        }
      }
      for conversationID in batch.removedConversationIDs {
        let recordName = "\(IAgentEntityKind.messageConversation.rawValue)_\(conversationID)"
        if await store.payload(for: recordName) != nil {
          try await store.deleteLocal(recordName: recordName)
          changed = true
        }
        for existing in await store.allPayloads() {
          guard case let .message(message) = existing,
                message.conversationID == conversationID
          else { continue }
          try await store.deleteLocal(recordName: existing.recordName)
          changed = true
        }
      }

      var payloads = conversations.map(IAgentSyncPayload.messageConversation)
        + messages.map(IAgentSyncPayload.message)
      for source in batch.readStates where retainedConversationIDs.contains(source.id) {
        payloads.append(.messageReadState(await reconciledReadState(source)))
      }
      changed = try await stageChanged(payloads) || changed
      let retentionDeletions = try await store.enforceMessageRetention(
        referenceDate: referenceDate
      )
      changed = !retentionDeletions.isEmpty || changed

      let localState = await writableState()
      if changed, let cloud {
        // The inbox is local-first: a first visible snapshot must not wait for
        // what can be a large initial CloudKit upload.
        Task(priority: .utility) {
          await cloud.pushLocalChanges()
        }
      }
      return localState
    } catch {
      return await writableState(failure: error)
    }
  }

  func removeDevelopmentMessageFixtures() async -> DesktopWritableSyncState {
    do {
      var changed = false
      for payload in await store.allPayloads() {
        guard payload.id.hasPrefix("mock-") else { continue }
        switch payload.kind {
        case .messageConversation, .message, .messageReadState:
          try await store.deleteLocal(recordName: payload.recordName)
          changed = true
        default:
          continue
        }
      }
      if changed {
        await cloud?.pushLocalChanges()
      }
      return await writableState()
    } catch {
      return await writableState(failure: error)
    }
  }

  func markMessageConversationRead(
    conversationID: String,
    through message: SyncedMessage
  ) async -> DesktopWritableSyncState {
    do {
      let candidate = SyncedMessageReadState(
        id: conversationID,
        readThroughMessageID: message.id,
        readThroughDate: message.sentAt,
        latestKnownMessageDate: message.sentAt,
        updatedAt: Date(),
        sourceDeviceID: deviceID
      )
      let changed = try await stageChanged([
        .messageReadState(await reconciledReadState(candidate))
      ])
      if changed {
        await cloud?.pushLocalChanges()
      }
      return await writableState()
    } catch {
      return await writableState(failure: error)
    }
  }

  /// Removes opt-in routing data from every cached conversation without
  /// requiring fresh access to Messages. This makes revocation durable even
  /// when the source database is temporarily unavailable, while preserving the
  /// otherwise read-only conversation projection.
  func scrubMessageReplyAddresses() async -> DesktopWritableSyncState {
    do {
      let changed = try await store.scrubMessageReplyAddresses()
      let localState = await writableState()
      if changed, let cloud {
        Task(priority: .utility) {
          await cloud.pushLocalChanges()
        }
      }
      return localState
    } catch {
      return await writableState(failure: error)
    }
  }

  func publishMessageRelayState(
    _ access: MessageProviderAccessState
  ) async -> DesktopWritableSyncState {
    let relay = SyncedMessageRelayState(
      id: deviceID,
      phase: access.syncedPhase,
      detail: access.userFacingDetail,
      updatedAt: Date()
    )
    do {
      let changed = try await stageChanged([.messageRelayState(relay)])
      if changed {
        await cloud?.pushLocalChanges()
      }
      return await writableState()
    } catch {
      return await writableState(failure: error)
    }
  }

  func publishMeeting(
    document: LocalDocument,
    event: CalendarEventItem?,
    startedAt: Date,
    endedAt: Date,
    transcriptSegments: [MeetingTranscriptSegment] = []
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
        updatedAt: endedAt,
        transcriptSegments: transcriptSegments.map { segment in
          SyncedTranscriptSegment(
            id: segment.id,
            source: segment.source == .microphone ? .microphone : .meetingAudio,
            text: segment.text,
            startOffset: segment.startedAt
          )
        }
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

  /// Persists a user edit to one todo without treating the currently visible
  /// list as authoritative. This keeps checkbox edits safe when the canonical
  /// iCloud JSON file is present but has not materialized on this Mac yet.
  func publishTodoMutation(_ todo: LocalTodo) async -> DesktopWritableSyncState {
    do {
      let changed = try await stageChanged([Self.payload(for: todo)])
      if changed {
        await cloud?.pushLocalChanges()
      }
      return await writableState()
    } catch {
      let snapshot = await store.snapshot()
      return DesktopWritableSyncState(
        todos: snapshot.todos.map(LocalTodo.init),
        todoListNames: snapshot.todoLists.map(\.name),
        noteCount: snapshot.notes.count,
        messageConversations: snapshot.messageConversations,
        messages: snapshot.messages,
        messageReadStates: snapshot.messageReadStates,
        messageRelayStates: snapshot.messageRelayStates,
        calendarEvents: snapshot.calendarEvents,
        artifactMentions: ArtifactMentionCatalog.make(snapshot: snapshot),
        status: IAgentCloudSyncStatus(phase: .failed, message: error.localizedDescription),
        pendingRecordCount: snapshot.pendingRecordNames
          .union(snapshot.pendingDeletionRecordNames).count
      )
    }
  }

  func currentCloudSyncStatus() async -> IAgentCloudSyncStatus {
    var status: IAgentCloudSyncStatus
    if let cloud {
      status = await cloud.status()
    } else {
      let snapshot = await store.snapshot()
      status = IAgentCloudSyncStatus(
        phase: cloudPreflight.phase,
        lastSuccessfulSyncAt: snapshot.lastSuccessfulSyncAt,
        message: cloudPreflight.message
      )
    }
    status.message = statusMessage(
      cloudMessage: status.message,
      includeNoteSourceWarning: true
    )
    return status
  }

  func stop() async {
    await cloud?.stop()
  }

  /// Resolves legacy UUID note links to the same portable library document
  /// used by path-based links. New authored mentions use notePath directly,
  /// but existing links remain useful after the routing upgrade.
  func localDocument(noteID: UUID) -> LocalDocument? {
    guard let relativePath = noteIndex.entries.first(where: { $0.value.id == noteID })?.key
    else { return nil }
    return documentStore.load(relativePath: relativePath)
  }

  func mergeRemoteForTesting(_ payloads: [IAgentSyncPayload]) async throws {
    _ = try await store.applyRemoteChanges(
      payloads.map { IAgentFetchedRecord(payload: $0, cloudSystemFields: nil) },
      deletedRecordNames: []
    )
  }

  func pendingRecordNamesForTesting() async -> [String] {
    await store.pendingRecordNames()
  }

  private func stageReadOnlyData(
    _ input: DesktopSyncInput,
    referenceDate: Date
  ) async throws -> Bool {
    let threadPayloads = input.threads?.map { thread in
      let visibleOutputs = thread.visibleOutputs.sorted { $0.occurredAt < $1.occurredAt }
      return IAgentSyncPayload.codexThread(
        SyncedCodexThread(
          id: thread.id,
          projectName: thread.projectName,
          title: thread.title,
          // `thread.activity` is a desktop presentation field and may contain
          // agent reasoning. Sync only text the user could see as an answer.
          activity: visibleOutputs.last?.text ?? "",
          // Only user-visible assistant messages are synced for Ask iAgent grounding.
          // Desktop-only reasoning activity remains local to the Codex UI.
          activityHistory: visibleOutputs.map {
            SyncedCodexActivity(id: $0.id, text: $0.text, occurredAt: $0.occurredAt)
          },
          visibleOutputs: visibleOutputs.map {
            SyncedCodexOutputExcerpt(id: $0.id, text: $0.text, occurredAt: $0.occurredAt)
          },
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
          sourceIdentifier: event.sourceIdentifier,
          title: event.title,
          startDate: event.startDate,
          endDate: event.endDate,
          isAllDay: event.isAllDay,
          calendarTitle: event.calendarTitle,
          location: event.location,
          notes: event.notes,
          calendarColorHex: event.tint.hexString,
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
    let openTodoCount = input.todosAreAuthoritative
      ? input.todos.filter({ !$0.isCompleted }).count
      : existingDesktop?.openTodoCount
    let contentIsUnchanged = existingDesktop.map {
      $0.activeCodexCount == activeCodexCount
        && $0.openTodoCount == openTodoCount
        && $0.hasAuthoritativeTodoCount == input.todosAreAuthoritative
        && $0.projectOrder == input.projectOrder
        && $0.deviceName == deviceName
        && $0.appVersion == appVersion
    } ?? false
    let monotonicNow = max(
      referenceDate,
      existingDesktop?.freshnessDate.addingTimeInterval(0.001) ?? referenceDate
    )
    let generatedAt = contentIsUnchanged
      ? existingDesktop?.generatedAt ?? referenceDate
      : monotonicNow
    let lastSeenAt: Date?
    if !contentIsUnchanged || existingDesktop?.lastSeenAt == nil {
      lastSeenAt = monotonicNow
    } else if let existingDesktop,
              referenceDate.timeIntervalSince(existingDesktop.freshnessDate)
                >= SyncedDesktopSnapshot.heartbeatInterval {
      lastSeenAt = monotonicNow
    } else {
      lastSeenAt = existingDesktop?.lastSeenAt
    }
    let desktop = IAgentSyncPayload.desktopSnapshot(
      SyncedDesktopSnapshot(
        id: deviceID,
        deviceName: deviceName,
        activeCodexCount: activeCodexCount,
        openTodoCount: openTodoCount,
        todoCountIsAuthoritative: input.todosAreAuthoritative,
        projectOrder: input.projectOrder,
        generatedAt: generatedAt,
        lastSeenAt: lastSeenAt,
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
    let payloads = todos.map(Self.payload(for:))
    let changed = try await stageTrackedAuthoritative(
      payloads,
      previouslyPublished: publishIndex.todoRecordNames
    )
    publishIndex.todoRecordNames = Set(payloads.map(\.recordName))
    try persistPublishIndex()
    return changed
  }

  private static func payload(for todo: LocalTodo) -> IAgentSyncPayload {
    .todo(
      SyncedTodo(
        id: todo.id,
        title: todo.title,
        notes: todo.notes,
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
    )?.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "md" }

    var payloads: [IAgentSyncPayload] = []
    var livePaths = Set<String>()
    var unavailablePaths: [String] = []
    for fileURL in files {
      let relativePath = try relativePath(for: fileURL)
      livePaths.insert(relativePath)
      if noteRequiresDownload(fileURL) {
        if fileManager.isUbiquitousItem(at: fileURL) {
          try? fileManager.startDownloadingUbiquitousItem(at: fileURL)
        }
        unavailablePaths.append(relativePath)
        continue
      }

      let source: String
      let values: URLResourceValues
      do {
        values = try fileURL.resourceValues(forKeys: Set(keys))
        guard values.isRegularFile == true else {
          unavailablePaths.append(relativePath)
          continue
        }
        source = try String(contentsOf: fileURL, encoding: .utf8)
      } catch {
        // A temporarily unavailable iCloud item must not block unrelated sync or become a deletion.
        unavailablePaths.append(relativePath)
        if fileManager.isUbiquitousItem(at: fileURL) {
          try? fileManager.startDownloadingUbiquitousItem(at: fileURL)
        }
        continue
      }

      let parsed = Self.parseMarkdown(source, fallbackTitle: fileURL.deletingPathExtension().lastPathComponent)
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
    let meetingsByNoteID = Dictionary(grouping: await store.allPayloads().compactMap {
      payload -> SyncedMeetingSession? in
      guard case let .meetingSession(meeting) = payload else { return nil }
      return meeting
    }, by: \.noteID)
    for (path, entry) in Array(noteIndex.entries) where !livePaths.contains(path) {
      let deletedAt = Date()
      if let existing = existingByID[entry.id] {
        if existing.deletedAt == nil {
          payloads.append(existing.deleting(at: deletedAt))
        }
        for meeting in meetingsByNoteID[entry.id] ?? [] where meeting.deletedAt == nil {
          payloads.append(IAgentSyncPayload.meetingSession(meeting).deleting(at: deletedAt))
        }
      }
      noteIndex.entries.removeValue(forKey: path)
    }

    noteSourceWarning = unavailablePaths.isEmpty
      ? nil
      : "\(unavailablePaths.count) Markdown \(unavailablePaths.count == 1 ? "note is" : "notes are") unavailable; their synced records were preserved and iAgent will retry."
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
        changed = try await tombstoneMeetings(
          linkedTo: note.id,
          at: note.deletedAt ?? note.updatedAt
        ) || changed
        if let indexed {
          let fileURL = documentStore.rootURL.appendingPathComponent(indexed.key)
          if FileManager.default.fileExists(atPath: fileURL.path) {
            if noteRequiresDownload(fileURL) {
              preserveUnavailableNote(at: fileURL)
              continue
            }
            guard let source = try? String(contentsOf: fileURL, encoding: .utf8),
                  let localModified = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey]
                  ).contentModificationDate
            else {
              preserveUnavailableNote(at: fileURL)
              continue
            }
            let parsed = Self.parseMarkdown(
              source,
              fallbackTitle: fileURL.deletingPathExtension().lastPathComponent
            )
            let canonicalSource = Self.markdown(title: parsed.title, body: parsed.body)
            let deletedSource = Self.markdown(title: note.title, body: note.body)
            let deletionVersion = note.deletedAt ?? note.updatedAt
            let hasLocalWork = canonicalSource != deletedSource
              || localModified > deletionVersion.addingTimeInterval(0.5)

            if hasLocalWork {
              // Preserve concurrent/local work as a new record instead of letting a remote tombstone
              // silently erase the canonical Markdown file.
              noteIndex.entries[indexed.key] = NoteIndex.Entry(
                id: UUID(),
                kind: indexed.value.kind,
                sourceDeviceID: deviceID,
                createdAt: indexed.value.createdAt
              )
              changed = true
              continue
            }

            try quarantineNoteFile(
              at: fileURL,
              relativePath: indexed.key,
              reason: "remote-deletion",
              moveOriginal: true
            )
          }
          noteIndex.entries.removeValue(forKey: indexed.key)
          changed = true
        }
        continue
      }

      let relativePath: String
      if let indexed {
        relativePath = indexed.key
      } else {
        relativePath = availableRemoteNotePath(for: note)
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
      if FileManager.default.fileExists(atPath: fileURL.path), noteRequiresDownload(fileURL) {
        preserveUnavailableNote(at: fileURL)
        continue
      }
      let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
      let existingSource: String?
      let localModified: Date?
      if fileExists {
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8),
              let modified = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey]
              ).contentModificationDate
        else {
          preserveUnavailableNote(at: fileURL)
          continue
        }
        existingSource = source
        localModified = modified
      } else {
        existingSource = nil
        localModified = nil
      }
      if localModified == nil || localModified! <= note.updatedAt.addingTimeInterval(0.5) {
        let rendered = Self.markdown(title: note.title, body: note.body)
        if let existingSource, existingSource != rendered {
          try quarantineNoteFile(
            at: fileURL,
            relativePath: relativePath,
            reason: "before-remote-update",
            moveOriginal: false
          )
        }
        try FileManager.default.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try rendered.write(to: fileURL, atomically: true, encoding: .utf8)
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

  private func tombstoneMeetings(linkedTo noteID: UUID, at date: Date) async throws -> Bool {
    let tombstones = await store.allPayloads().compactMap { payload -> IAgentSyncPayload? in
      guard case let .meetingSession(meeting) = payload,
            meeting.noteID == noteID,
            meeting.deletedAt == nil
      else { return nil }
      return payload.deleting(at: date)
    }
    return try await stageChanged(tombstones)
  }

  private func availableRemoteNotePath(for note: SyncedNote) -> String {
    if let supplied = note.relativeFilePath,
       Self.isSafeNotePath(supplied),
       notePathIsAvailable(supplied) {
      return supplied
    }

    let generated = generatedNotePath(for: note)
    guard !notePathIsAvailable(generated) else { return generated }
    let extensionless = (generated as NSString).deletingPathExtension
    let pathExtension = (generated as NSString).pathExtension
    var suffix = 2
    while true {
      let candidate = "\(extensionless)-\(suffix).\(pathExtension)"
      if notePathIsAvailable(candidate) { return candidate }
      suffix += 1
    }
  }

  private func notePathIsAvailable(_ relativePath: String) -> Bool {
    noteIndex.entries[relativePath] == nil
      && !FileManager.default.fileExists(
        atPath: documentStore.rootURL.appendingPathComponent(relativePath).path
      )
  }

  private func preserveUnavailableNote(at fileURL: URL) {
    if FileManager.default.isUbiquitousItem(at: fileURL) {
      try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
    }
    if noteSourceWarning == nil {
      noteSourceWarning = "A Markdown note is unavailable; its synced record was preserved and iAgent will retry."
    }
  }

  private func quarantineNoteFile(
    at fileURL: URL,
    relativePath: String,
    reason: String,
    moveOriginal: Bool
  ) throws {
    let quarantineRoot = noteIndexURL.deletingLastPathComponent()
      .appendingPathComponent("NoteQuarantine", isDirectory: true)
    let itemDirectory = quarantineRoot
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)

    let fileName = fileURL.lastPathComponent.isEmpty ? "Recovered-note.md" : fileURL.lastPathComponent
    let destination = itemDirectory.appendingPathComponent(fileName)
    if moveOriginal {
      try FileManager.default.moveItem(at: fileURL, to: destination)
    } else {
      try FileManager.default.copyItem(at: fileURL, to: destination)
    }

    let metadata = QuarantinedNoteMetadata(
      originalRelativePath: relativePath,
      reason: reason,
      quarantinedAt: Date()
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(metadata).write(
      to: itemDirectory.appendingPathComponent("metadata.json"),
      options: .atomic
    )
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

  private func writableState(
    failure: Error? = nil
  ) async -> DesktopWritableSyncState {
    let snapshot = await store.snapshot()
    var status: IAgentCloudSyncStatus
    if let failure {
      status = IAgentCloudSyncStatus(
        phase: .failed,
        lastSuccessfulSyncAt: snapshot.lastSuccessfulSyncAt,
        message: failure.localizedDescription
      )
    } else {
      status = await cloud?.status() ?? IAgentCloudSyncStatus(
        phase: cloudPreflight.phase,
        lastSuccessfulSyncAt: snapshot.lastSuccessfulSyncAt,
        message: cloudPreflight.message
      )
    }
    status.message = statusMessage(
      cloudMessage: status.message,
      includeNoteSourceWarning: true
    )
    return DesktopWritableSyncState(
      todos: snapshot.todos.map(LocalTodo.init),
      todoListNames: snapshot.todoLists.map(\.name),
      noteCount: snapshot.notes.count,
      messageConversations: snapshot.messageConversations,
      messages: snapshot.messages,
      messageReadStates: snapshot.messageReadStates,
      messageRelayStates: snapshot.messageRelayStates,
      calendarEvents: snapshot.calendarEvents,
      artifactMentions: ArtifactMentionCatalog.make(snapshot: snapshot),
      status: status,
      pendingRecordCount: snapshot.pendingRecordNames
        .union(snapshot.pendingDeletionRecordNames).count
    )
  }

  private func statusMessage(
    cloudMessage: String?,
    includeNoteSourceWarning: Bool
  ) -> String? {
    let warnings = [
      cloudMessage,
      storageMigrationWarning,
      includeNoteSourceWarning ? noteSourceWarning : nil,
    ]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !warnings.isEmpty else { return nil }
    return Array(NSOrderedSet(array: warnings)).compactMap { $0 as? String }
      .joined(separator: " ")
  }

  private func reconciledReadState(
    _ candidate: SyncedMessageReadState
  ) async -> SyncedMessageReadState {
    guard case let .messageReadState(existing)? = await store.payload(
      for: IAgentSyncPayload.messageReadState(candidate).recordName
    ) else {
      return candidate
    }

    let existingCursor = (
      existing.readThroughDate ?? .distantPast,
      existing.readThroughMessageID ?? ""
    )
    let candidateCursor = (
      candidate.readThroughDate ?? .distantPast,
      candidate.readThroughMessageID ?? ""
    )
    let winner = candidateCursor >= existingCursor ? candidate : existing
    return SyncedMessageReadState(
      id: candidate.id,
      readThroughMessageID: winner.readThroughMessageID,
      readThroughDate: winner.readThroughDate,
      latestKnownMessageDate: max(
        existing.latestKnownMessageDate,
        candidate.latestKnownMessageDate
      ),
      updatedAt: max(existing.updatedAt, candidate.updatedAt),
      sourceDeviceID: winner.sourceDeviceID,
      deletedAt: nil
    )
  }

  private func deduplicatedMessages(_ values: [SyncedMessage]) -> [SyncedMessage] {
    var byID: [String: SyncedMessage] = [:]
    for value in values {
      if let existing = byID[value.id], existing.updatedAt > value.updatedAt {
        continue
      }
      byID[value.id] = value
    }
    return Array(byID.values)
  }

  private func deduplicatedConversations(
    _ values: [SyncedMessageConversation]
  ) -> [SyncedMessageConversation] {
    var byID: [String: SyncedMessageConversation] = [:]
    for value in values {
      if let existing = byID[value.id], existing.updatedAt > value.updatedAt {
        continue
      }
      byID[value.id] = value
    }
    return Array(byID.values)
  }

  private func stageAuthoritative(
    _ payloads: [IAgentSyncPayload],
    kind: IAgentEntityKind
  ) async throws -> Bool {
    let existingPayloads = Dictionary(
      uniqueKeysWithValues: (await store.allPayloads()).map { ($0.recordName, $0) }
    )
    var candidates = payloads.map { payload in
      guard let existing = existingPayloads[payload.recordName] else { return payload }
      return Self.revivingAuthoritativePayload(payload, over: existing)
    }
    let currentNames = Set(payloads.map(\.recordName))
    for existing in existingPayloads.values
    where existing.kind == kind && existing.deletedAt == nil && !currentNames.contains(existing.recordName) {
      candidates.append(existing.deleting())
    }
    return try await stageChanged(candidates)
  }

  private static func revivingAuthoritativePayload(
    _ payload: IAgentSyncPayload,
    over existing: IAgentSyncPayload
  ) -> IAgentSyncPayload {
    guard payload.deletedAt == nil,
          existing.deletedAt != nil,
          existing.updatedAt >= payload.updatedAt
    else { return payload }

    let restoredAt = max(Date(), existing.updatedAt.addingTimeInterval(0.001))
    switch payload {
    case .note(var value):
      value.deletedAt = nil
      value.updatedAt = restoredAt
      return .note(value)
    case .todo(var value):
      value.deletedAt = nil
      value.updatedAt = restoredAt
      return .todo(value)
    case .todoList(var value):
      value.deletedAt = nil
      value.updatedAt = restoredAt
      return .todoList(value)
    case .meetingSession(var value):
      value.deletedAt = nil
      value.updatedAt = restoredAt
      return .meetingSession(value)
    case .codexThread(var value):
      value.deletedAt = nil
      value.updatedAt = restoredAt
      return .codexThread(value)
    case .calendarEvent(var value):
      value.deletedAt = nil
      value.updatedAt = restoredAt
      return .calendarEvent(value)
    case .desktopSnapshot(var value):
      value.deletedAt = nil
      value.generatedAt = restoredAt
      value.lastSeenAt = restoredAt
      return .desktopSnapshot(value)
    case .messageConversation(var value):
      value.deletedAt = nil
      value.updatedAt = restoredAt
      return .messageConversation(value)
    case .message(var value):
      value.deletedAt = nil
      value.updatedAt = restoredAt
      return .message(value)
    case .messageReadState(var value):
      value.deletedAt = nil
      value.updatedAt = restoredAt
      return .messageReadState(value)
    case .messageRelayState(var value):
      value.deletedAt = nil
      value.updatedAt = restoredAt
      return .messageRelayState(value)
    }
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
      let isAuthoritativeMessageProjection = payload.kind == .messageConversation
        || payload.kind == .message
      if let existing,
         !isAuthoritativeMessageProjection,
         existing.updatedAt > payload.updatedAt {
        continue
      }
      let candidate: IAgentSyncPayload
      if let existing, isAuthoritativeMessageProjection {
        candidate = messageProjection(
          payload,
          preservingTimestampFrom: existing
        )
      } else {
        candidate = payload
      }
      if existing != candidate {
        changed.append(candidate)
      }
    }
    guard !changed.isEmpty else { return false }
    return try await store.stageLocalChanges(changed)
  }

  private func messageProjection(
    _ payload: IAgentSyncPayload,
    preservingTimestampFrom existing: IAgentSyncPayload
  ) -> IAgentSyncPayload {
    let timestamp = max(payload.updatedAt, existing.updatedAt)
    switch payload {
    case .messageConversation(var conversation):
      conversation.updatedAt = timestamp
      return .messageConversation(conversation)
    case .message(var message):
      message.updatedAt = timestamp
      return .message(message)
    default:
      return payload
    }
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

  private static func isDatalessFile(_ fileURL: URL) -> Bool {
    var fileStatus = stat()
    guard Darwin.lstat(fileURL.path, &fileStatus) == 0 else { return false }
    let userDatalessFlag = UInt32(0x4000_0000)
    return fileStatus.st_flags & userDatalessFlag != 0
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

private extension MessageProviderAccessState {
  var syncedPhase: SyncedMessageRelayPhase {
    switch self {
    case .loading: .loading
    case .authorized: .available
    case .permissionRequired: .permissionRequired
    case .disabled: .disabled
    case .failed: .failed
    }
  }

  var userFacingDetail: String? {
    switch self {
    case .loading, .authorized:
      nil
    case let .permissionRequired(detail),
         let .disabled(detail),
         let .failed(detail):
      detail
    }
  }
}

private extension LocalTodo {
  init(_ synced: SyncedTodo) {
    self.init(
      id: synced.id,
      title: synced.title,
      notes: synced.notes,
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
