import Foundation

private struct PersistedSyncState: Codable, Sendable {
  var records: [String: IAgentSyncPayload] = [:]
  var baseRecords: [String: IAgentSyncPayload] = [:]
  var pendingRecordNames: Set<String> = []
  var cloudSystemFields: [String: Data] = [:]
  var lastSuccessfulSyncAt: Date?
}

public actor IAgentLocalSyncStore {
  public let fileURL: URL
  private var state: PersistedSyncState

  public init(fileURL: URL) {
    self.fileURL = fileURL
    if let data = try? Data(contentsOf: fileURL),
       let decoded = try? JSONDecoder.iAgent.decode(PersistedSyncState.self, from: data)
    {
      state = decoded
    } else {
      state = PersistedSyncState()
    }
  }

  public static func defaultFileURL(appIdentifier: String) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent(appIdentifier, isDirectory: true)
      .appendingPathComponent("sync-store.json")
  }

  public func snapshot() -> IAgentDataSnapshot {
    let payloads = state.records.values.filter { $0.deletedAt == nil }
    return IAgentDataSnapshot(
      notes: payloads.compactMap(\.noteValue).sorted { $0.updatedAt > $1.updatedAt },
      todos: payloads.compactMap(\.todoValue).sorted { $0.createdAt > $1.createdAt },
      todoLists: payloads.compactMap(\.todoListValue).sorted {
        $0.order == $1.order ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.order < $1.order
      },
      meetings: payloads.compactMap(\.meetingValue).sorted { $0.startedAt > $1.startedAt },
      codexThreads: payloads.compactMap(\.codexValue).sorted { $0.updatedAt > $1.updatedAt },
      calendarEvents: payloads.compactMap(\.calendarValue).sorted { $0.startDate < $1.startDate },
      desktopSnapshot: payloads.compactMap(\.desktopValue).max { $0.generatedAt < $1.generatedAt },
      pendingRecordNames: state.pendingRecordNames,
      lastSuccessfulSyncAt: state.lastSuccessfulSyncAt
    )
  }

  @discardableResult
  public func upsertLocal(_ payload: IAgentSyncPayload) throws -> String {
    state.records[payload.recordName] = payload
    state.pendingRecordNames.insert(payload.recordName)
    try persistAndNotify()
    return payload.recordName
  }

  @discardableResult
  public func upsertLocal(_ payloads: [IAgentSyncPayload]) throws -> [String] {
    var names: [String] = []
    for payload in payloads {
      state.records[payload.recordName] = payload
      state.pendingRecordNames.insert(payload.recordName)
      names.append(payload.recordName)
    }
    try persistAndNotify()
    return names
  }

  public func payload(for recordName: String) -> IAgentSyncPayload? {
    state.records[recordName]
  }

  public func allPayloads() -> [IAgentSyncPayload] {
    Array(state.records.values)
  }

  public func pendingRecordNames() -> [String] {
    state.pendingRecordNames.sorted()
  }

  public func cloudSystemFields(for recordName: String) -> Data? {
    state.cloudSystemFields[recordName]
  }

  @discardableResult
  public func mergeRemote(
    _ remote: IAgentSyncPayload,
    cloudSystemFields: Data?
  ) throws -> [String] {
    let name = remote.recordName
    let local = state.records[name]
    let base = state.baseRecords[name]
    var newlyPending: [String] = []

    if state.pendingRecordNames.contains(name), let local {
      let merge = merge(local: local, remote: remote, base: base)
      state.records[name] = merge.primary
      if merge.primary == remote {
        state.pendingRecordNames.remove(name)
      } else {
        state.pendingRecordNames.insert(name)
        newlyPending.append(name)
      }

      if let conflict = merge.conflictCopy {
        state.records[conflict.recordName] = conflict
        state.pendingRecordNames.insert(conflict.recordName)
        newlyPending.append(conflict.recordName)
      }
    } else {
      state.records[name] = remote
      state.pendingRecordNames.remove(name)
    }

    state.baseRecords[name] = remote
    if let cloudSystemFields {
      state.cloudSystemFields[name] = cloudSystemFields
    }
    try persistAndNotify()
    return newlyPending
  }

  public func removeRemote(recordName: String) throws {
    state.records.removeValue(forKey: recordName)
    state.baseRecords.removeValue(forKey: recordName)
    state.pendingRecordNames.remove(recordName)
    state.cloudSystemFields.removeValue(forKey: recordName)
    try persistAndNotify()
  }

  public func markSent(recordName: String, cloudSystemFields: Data?) throws {
    if let payload = state.records[recordName] {
      state.baseRecords[recordName] = payload
    }
    state.pendingRecordNames.remove(recordName)
    if let cloudSystemFields {
      state.cloudSystemFields[recordName] = cloudSystemFields
    }
    state.lastSuccessfulSyncAt = Date()
    try persistAndNotify()
  }

  public func markSyncSuccessful(at date: Date = Date()) throws {
    state.lastSuccessfulSyncAt = date
    try persistAndNotify()
  }

  public func replaceForTesting(with payloads: [IAgentSyncPayload]) throws {
    state = PersistedSyncState(
      records: Dictionary(uniqueKeysWithValues: payloads.map { ($0.recordName, $0) }),
      baseRecords: [:],
      pendingRecordNames: [],
      cloudSystemFields: [:],
      lastSuccessfulSyncAt: Date()
    )
    try persistAndNotify()
  }

  private func persistAndNotify() throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder.iAgent.encode(state)
    try data.write(to: fileURL, options: .atomic)
    NotificationCenter.default.post(name: .iAgentSyncStoreDidChange, object: nil)
  }

  private func merge(
    local: IAgentSyncPayload,
    remote: IAgentSyncPayload,
    base: IAgentSyncPayload?
  ) -> (primary: IAgentSyncPayload, conflictCopy: IAgentSyncPayload?) {
    switch (local, remote, base) {
    case let (.todo(localTodo), .todo(remoteTodo), .some(.todo(baseTodo))):
      return (.todo(mergeTodo(local: localTodo, remote: remoteTodo, base: baseTodo)), nil)

    case let (.note(localNote), .note(remoteNote), .some(.note(baseNote))):
      let localChangedBody = localNote.body != baseNote.body
      let remoteChangedBody = remoteNote.body != baseNote.body
      if localChangedBody, remoteChangedBody, localNote.body != remoteNote.body {
        let stamp = remoteNote.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let conflict = SyncedNote(
          kind: remoteNote.kind,
          title: "\(remoteNote.title) (Conflict \(stamp))",
          body: remoteNote.body,
          createdAt: remoteNote.createdAt,
          updatedAt: Date(),
          sourceDeviceID: remoteNote.sourceDeviceID
        )
        let primary = localNote.updatedAt >= remoteNote.updatedAt ? localNote : remoteNote
        return (.note(primary), .note(conflict))
      }
      return (localNote.updatedAt >= remoteNote.updatedAt ? local : remote, nil)

    default:
      return (local.updatedAt >= remote.updatedAt ? local : remote, nil)
    }
  }

  private func mergeTodo(
    local: SyncedTodo,
    remote: SyncedTodo,
    base: SyncedTodo
  ) -> SyncedTodo {
    SyncedTodo(
      id: local.id,
      title: mergeField(base: base.title, local: local.title, remote: remote.title, preferLocal: local.updatedAt >= remote.updatedAt),
      isCompleted: mergeField(base: base.isCompleted, local: local.isCompleted, remote: remote.isCompleted, preferLocal: local.updatedAt >= remote.updatedAt),
      isStarred: mergeField(base: base.isStarred, local: local.isStarred, remote: remote.isStarred, preferLocal: local.updatedAt >= remote.updatedAt),
      dueDate: mergeField(base: base.dueDate, local: local.dueDate, remote: remote.dueDate, preferLocal: local.updatedAt >= remote.updatedAt),
      listName: mergeField(base: base.listName, local: local.listName, remote: remote.listName, preferLocal: local.updatedAt >= remote.updatedAt),
      completedAt: mergeField(base: base.completedAt, local: local.completedAt, remote: remote.completedAt, preferLocal: local.updatedAt >= remote.updatedAt),
      createdAt: min(local.createdAt, remote.createdAt),
      updatedAt: max(local.updatedAt, remote.updatedAt),
      deletedAt: mergeField(base: base.deletedAt, local: local.deletedAt, remote: remote.deletedAt, preferLocal: local.updatedAt >= remote.updatedAt)
    )
  }

  private func mergeField<Value: Equatable>(
    base: Value,
    local: Value,
    remote: Value,
    preferLocal: Bool
  ) -> Value {
    if local == base { return remote }
    if remote == base { return local }
    if local == remote { return local }
    return preferLocal ? local : remote
  }
}

private extension IAgentSyncPayload {
  var noteValue: SyncedNote? {
    guard case let .note(value) = self else { return nil }
    return value
  }

  var todoValue: SyncedTodo? {
    guard case let .todo(value) = self else { return nil }
    return value
  }

  var todoListValue: SyncedTodoList? {
    guard case let .todoList(value) = self else { return nil }
    return value
  }

  var meetingValue: SyncedMeetingSession? {
    guard case let .meetingSession(value) = self else { return nil }
    return value
  }

  var codexValue: SyncedCodexThread? {
    guard case let .codexThread(value) = self else { return nil }
    return value
  }

  var calendarValue: SyncedCalendarEvent? {
    guard case let .calendarEvent(value) = self else { return nil }
    return value
  }

  var desktopValue: SyncedDesktopSnapshot? {
    guard case let .desktopSnapshot(value) = self else { return nil }
    return value
  }
}

extension JSONEncoder {
  static var iAgent: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  static var iAgent: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
