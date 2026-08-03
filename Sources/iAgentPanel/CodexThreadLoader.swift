import Foundation
import SQLite3

struct CodexThreadLoadResult: Sendable {
  let threads: [AgentThread]
  let databasePath: String
  let watchPaths: [String]
  let hasMore: Bool
}

struct CodexThreadLoaderError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

enum CodexThreadLoader {
  private static let rolloutTailBytes: UInt64 = 2_000_000
  private static let rolloutCache = RolloutSnapshotCache()

  private struct StoredThread {
    let id: String
    let rolloutPath: String
    let createdAt: Date
    let updatedAt: Date
    let title: String
    let name: String
    let preview: String
    let cwd: String
    let source: String
    let threadSource: String
    let agentNickname: String
    let agentRole: String
  }

  private struct PendingCall: Sendable {
    let id: String
    let name: String
    let input: String
  }

  private struct RolloutSnapshot: Sendable {
    var activity: String?
    var activityDate: Date?
    var state: AgentState = .completed
    var activeStart: Date?
    var lastDuration: TimeInterval?
    var isPlan = false
  }

  private struct RolloutParserState: Sendable {
    var snapshot = RolloutSnapshot()
    var pendingCalls: [PendingCall] = []
    var completedCallIDs = Set<String>()
    var currentStart: Date?
    var remainder = ""
  }

  private struct LifecycleEvent: Sendable {
    let type: String
    let timestamp: Date?
    let duration: TimeInterval?
  }

  private struct CachedSnapshot: Sendable {
    let byteCount: UInt64
    let modifiedAt: Date
    let parserState: RolloutParserState
  }

  private final class RolloutSnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CachedSnapshot] = [:]

    func value(for path: String) -> CachedSnapshot? {
      lock.lock()
      defer { lock.unlock() }
      return values[path]
    }

    func store(
      _ parserState: RolloutParserState,
      for path: String,
      byteCount: UInt64,
      modifiedAt: Date
    ) {
      lock.lock()
      values[path] = CachedSnapshot(
        byteCount: byteCount,
        modifiedAt: modifiedAt,
        parserState: parserState
      )
      lock.unlock()
    }
  }

  static func loadRecent(limit: Int = 24) throws -> CodexThreadLoadResult {
    let paths = try resolvePaths()
    let storedResult = try readThreads(from: paths.stateDatabase, limit: limit)
    let storedThreads = storedResult.threads
    let goals = readGoalThreadIDs(from: paths.codexHome)
    let now = Date()

    let threads = storedThreads.map { stored in
      let snapshot = inspectRollout(at: stored.rolloutPath)
      let projectName = projectName(for: stored.cwd)
      let title = displayTitle(for: stored, projectName: projectName)
      let activity = displayActivity(from: snapshot, state: snapshot.state, projectName: projectName)
      let elapsed = elapsedText(
        state: snapshot.state,
        activeStart: snapshot.activeStart,
        lastDuration: snapshot.lastDuration,
        createdAt: stored.createdAt,
        updatedAt: stored.updatedAt,
        now: now
      )

      var modes: [ThreadMode] = []
      if snapshot.isPlan {
        modes.append(.plan)
      }
      if goals.threadIDs.contains(stored.id) {
        modes.append(.goal)
      }
      if stored.threadSource.lowercased().contains("voice") || stored.source.lowercased().contains("voice") {
        modes.append(.voice)
      }

      return AgentThread(
        id: stored.id,
        projectName: projectName,
        workspacePath: stored.cwd.isEmpty ? nil : stored.cwd,
        title: title,
        activity: activity,
        state: snapshot.state,
        modes: modes,
        elapsed: elapsed,
        createdAt: stored.createdAt,
        updatedAt: stored.updatedAt
      )
    }

    var watchPaths = Set(storedThreads.map(\.rolloutPath).filter { !$0.isEmpty })
    watchPaths.insert(paths.codexHome.path)
    watchPaths.insert(paths.stateDatabase.path)
    watchPaths.insert(paths.stateDatabase.path + "-wal")
    if let goalDatabasePath = goals.databasePath {
      watchPaths.insert(goalDatabasePath)
      watchPaths.insert(goalDatabasePath + "-wal")
    }

    return CodexThreadLoadResult(
      threads: threads,
      databasePath: paths.stateDatabase.path,
      watchPaths: watchPaths.sorted(),
      hasMore: storedResult.hasMore
    )
  }

  private static func resolvePaths() throws -> (stateDatabase: URL, codexHome: URL) {
    let environment = ProcessInfo.processInfo.environment
    let defaultCodexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? defaultCodexHome

    var sqliteDirectories: [URL] = []
    if let configured = environment["CODEX_SQLITE_HOME"], !configured.isEmpty {
      sqliteDirectories.append(URL(fileURLWithPath: configured))
    }
    sqliteDirectories.append(codexHome)

    for directory in sqliteDirectories {
      if let database = newestDatabase(in: directory, prefix: "state_", suffix: ".sqlite") {
        return (database, codexHome)
      }
    }

    throw CodexThreadLoaderError(message: "No Codex state database was found under \(codexHome.path).")
  }

  private static func newestDatabase(in directory: URL, prefix: String, suffix: String) -> URL? {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return nil
    }

    return files
      .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(suffix) }
      .sorted { left, right in
        let leftVersion = databaseVersion(left.lastPathComponent, prefix: prefix, suffix: suffix)
        let rightVersion = databaseVersion(right.lastPathComponent, prefix: prefix, suffix: suffix)
        if leftVersion != rightVersion {
          return leftVersion > rightVersion
        }

        let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return leftDate > rightDate
      }
      .first
  }

  private static func databaseVersion(_ filename: String, prefix: String, suffix: String) -> Int {
    let version = filename.dropFirst(prefix.count).dropLast(suffix.count)
    return Int(version) ?? 0
  }

  private static func readThreads(
    from databaseURL: URL,
    limit: Int
  ) throws -> (threads: [StoredThread], hasMore: Bool) {
    try withReadOnlyDatabase(databaseURL) { database in
      let boundedLimit = max(1, min(limit, 200))
      let query = """
        SELECT
          id,
          rollout_path,
          COALESCE(created_at_ms, created_at * 1000),
          COALESCE(NULLIF(recency_at_ms, 0), updated_at_ms, updated_at * 1000),
          title,
          COALESCE(name, ''),
          preview,
          cwd,
          source,
          COALESCE(thread_source, ''),
          COALESCE(agent_nickname, ''),
          COALESCE(agent_role, '')
        FROM threads
        WHERE archived = 0
          AND preview <> ''
          AND LOWER(COALESCE(thread_source, '')) NOT LIKE '%subagent%'
          AND LOWER(COALESCE(source, '')) NOT LIKE '%"subagent"%'
          AND title NOT LIKE '<codex_delegation>%'
        ORDER BY COALESCE(NULLIF(recency_at_ms, 0), updated_at_ms, updated_at * 1000) DESC, id DESC
        LIMIT \(boundedLimit + 1)
        """

      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw databaseError(database, prefix: "Could not prepare the recent threads query")
      }
      defer { sqlite3_finalize(statement) }

      var rows: [StoredThread] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 2)) / 1000)
        let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)
        rows.append(
          StoredThread(
            id: string(statement, column: 0),
            rolloutPath: string(statement, column: 1),
            createdAt: createdAt,
            updatedAt: updatedAt,
            title: string(statement, column: 4),
            name: string(statement, column: 5),
            preview: string(statement, column: 6),
            cwd: string(statement, column: 7),
            source: string(statement, column: 8),
            threadSource: string(statement, column: 9),
            agentNickname: string(statement, column: 10),
            agentRole: string(statement, column: 11)
          )
        )
      }
      let hasMore = rows.count > boundedLimit
      return (Array(rows.prefix(boundedLimit)), hasMore)
    }
  }

  private static func readGoalThreadIDs(
    from codexHome: URL
  ) -> (threadIDs: Set<String>, databasePath: String?) {
    guard let goalDatabase = newestDatabase(in: codexHome, prefix: "goals_", suffix: ".sqlite") else {
      return ([], nil)
    }

    let threadIDs: Set<String> = (try? withReadOnlyDatabase(goalDatabase) { database in
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, "SELECT thread_id FROM thread_goals", -1, &statement, nil) == SQLITE_OK,
            let statement
      else {
        return Set<String>()
      }
      defer { sqlite3_finalize(statement) }

      var ids = Set<String>()
      while sqlite3_step(statement) == SQLITE_ROW {
        ids.insert(string(statement, column: 0))
      }
      return ids
    }) ?? Set()
    return (threadIDs, goalDatabase.path)
  }

  private static func withReadOnlyDatabase<T>(_ url: URL, body: (OpaquePointer) throws -> T) throws -> T {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
      if let database {
        sqlite3_close(database)
      }
      throw CodexThreadLoaderError(message: "Could not open Codex database at \(url.path).")
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 800)
    return try body(database)
  }

  private static func databaseError(_ database: OpaquePointer, prefix: String) -> CodexThreadLoaderError {
    let detail = sqlite3_errmsg(database).map(String.init(cString:)) ?? "Unknown SQLite error"
    return CodexThreadLoaderError(message: "\(prefix): \(detail)")
  }

  private static func string(_ statement: OpaquePointer, column: Int32) -> String {
    guard let value = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: value)
  }

  private static func inspectRollout(at path: String) -> RolloutSnapshot {
    guard !path.isEmpty else {
      return RolloutSnapshot()
    }

    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let byteCount = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    let modifiedAt = (attributes?[.modificationDate] as? Date) ?? .distantPast
    let url = URL(fileURLWithPath: path)

    if let cached = rolloutCache.value(for: path) {
      if cached.byteCount == byteCount, cached.modifiedAt == modifiedAt {
        return cached.parserState.snapshot
      }

      if byteCount > cached.byteCount,
         let appended = readRange(
           of: url,
           from: cached.byteCount,
           length: byteCount - cached.byteCount
         )
      {
        var parserState = cached.parserState
        consume(appended, into: &parserState, droppingLeadingPartialLine: false)
        finalize(&parserState)
        rolloutCache.store(
          parserState,
          for: path,
          byteCount: byteCount,
          modifiedAt: modifiedAt
        )
        return parserState.snapshot
      }
    }

    guard byteCount > 0 else {
      return RolloutSnapshot()
    }

    var parserState = lifecycleSeed(at: url, byteCount: byteCount)
    let tailLength = min(byteCount, rolloutTailBytes)
    if let data = readRange(of: url, from: byteCount - tailLength, length: tailLength) {
      consume(
        data,
        into: &parserState,
        droppingLeadingPartialLine: tailLength < byteCount
      )
    }
    finalize(&parserState)
    rolloutCache.store(
      parserState,
      for: path,
      byteCount: byteCount,
      modifiedAt: modifiedAt
    )
    return parserState.snapshot
  }

  private static func lifecycleSeed(at url: URL, byteCount: UInt64) -> RolloutParserState {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let chunkSize: UInt64 = 512_000
    let overlap: UInt64 = 1_024
    var cursor = byteCount

    while cursor > 0 {
      let offset = cursor > chunkSize ? cursor - chunkSize : 0
      guard var data = readRange(of: url, from: offset, length: cursor - offset) else {
        break
      }
      if offset > 0, let newline = data.firstIndex(of: 0x0A) {
        data.removeSubrange(data.startIndex...newline)
      }

      let events = containsLifecycleMarker(in: data)
        ? lifecycleEvents(in: data, formatter: formatter)
        : []
      if let latest = events.last {
        var parserState = RolloutParserState()
        if latest.type == "task_started" {
          let startedAt = latest.timestamp ?? Date()
          parserState.currentStart = startedAt
          parserState.snapshot.activeStart = startedAt
          parserState.snapshot.state = .running
          return parserState
        }

        parserState.snapshot.state = latest.type == "task_complete" ? .completed : .failed
        if let duration = latest.duration {
          parserState.snapshot.lastDuration = duration
        }
        return parserState
      }

      guard offset > 0 else { break }
      cursor = min(byteCount, offset + overlap)
    }

    return RolloutParserState()
  }

  private static func containsLifecycleMarker(in data: Data) -> Bool {
    let markers = [
      Data("\"type\":\"task_started\"".utf8),
      Data("\"type\":\"task_complete\"".utf8),
      Data("\"type\":\"turn_aborted\"".utf8),
      Data("\"type\":\"stream_error\"".utf8),
    ]
    return markers.contains { data.range(of: $0) != nil }
  }

  private static func lifecycleEvents(
    in data: Data,
    formatter: ISO8601DateFormatter
  ) -> [LifecycleEvent] {
    let text = String(decoding: data, as: UTF8.self)
    var events: [LifecycleEvent] = []

    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      guard line.contains("task_started")
              || line.contains("task_complete")
              || line.contains("turn_aborted")
              || line.contains("stream_error"),
            let lineData = String(line).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
            object["type"] as? String == "event_msg",
            let payload = object["payload"] as? [String: Any],
            let payloadType = payload["type"] as? String,
            payloadType == "task_started"
              || payloadType == "task_complete"
              || payloadType == "turn_aborted"
              || payloadType == "stream_error"
      else {
        continue
      }

      let timestamp = (object["timestamp"] as? String).flatMap(formatter.date(from:))
      let duration = (payload["duration_ms"] as? NSNumber).map {
        max(0, $0.doubleValue / 1000)
      }
      events.append(LifecycleEvent(type: payloadType, timestamp: timestamp, duration: duration))
    }
    return events
  }

  private static func consume(
    _ data: Data,
    into parserState: inout RolloutParserState,
    droppingLeadingPartialLine: Bool
  ) {
    var bytes = data
    if droppingLeadingPartialLine, let newline = bytes.firstIndex(of: 0x0A) {
      bytes.removeSubrange(bytes.startIndex...newline)
    }

    let text = parserState.remainder + String(decoding: bytes, as: UTF8.self)
    let endsOnLineBoundary = text.last == "\n"
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if endsOnLineBoundary {
      parserState.remainder = ""
    } else {
      parserState.remainder = lines.popLast().map(String.init) ?? text
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    for line in lines where !line.isEmpty {
      guard let lineData = String(line).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
            let recordType = object["type"] as? String
      else {
        continue
      }

      let timestamp = (object["timestamp"] as? String).flatMap(formatter.date(from:))

      if recordType == "turn_context",
         let payload = object["payload"] as? [String: Any],
         let collaboration = payload["collaboration_mode"] as? [String: Any],
         let mode = collaboration["mode"] as? String
      {
        parserState.snapshot.isPlan = mode.caseInsensitiveCompare("plan") == .orderedSame
        continue
      }

      guard let payload = object["payload"] as? [String: Any],
            let payloadType = payload["type"] as? String
      else {
        continue
      }

      if recordType == "event_msg" {
        switch payloadType {
        case "task_started":
          parserState.currentStart = timestamp ?? Date()
          parserState.snapshot.activeStart = parserState.currentStart
          parserState.snapshot.state = .running
          parserState.pendingCalls.removeAll(keepingCapacity: true)
          parserState.completedCallIDs.removeAll(keepingCapacity: true)

        case "task_complete":
          if let duration = (payload["duration_ms"] as? NSNumber)?.doubleValue {
            parserState.snapshot.lastDuration = max(0, duration / 1000)
          } else if let start = parserState.currentStart, let end = timestamp {
            parserState.snapshot.lastDuration = max(0, end.timeIntervalSince(start))
          }
          parserState.currentStart = nil
          parserState.snapshot.activeStart = nil
          parserState.snapshot.state = .completed
          parserState.pendingCalls.removeAll(keepingCapacity: true)
          parserState.completedCallIDs.removeAll(keepingCapacity: true)

        case "turn_aborted", "stream_error":
          if let start = parserState.currentStart, let end = timestamp {
            parserState.snapshot.lastDuration = max(0, end.timeIntervalSince(start))
          }
          parserState.currentStart = nil
          parserState.snapshot.activeStart = nil
          parserState.snapshot.state = .failed
          parserState.pendingCalls.removeAll(keepingCapacity: true)
          parserState.completedCallIDs.removeAll(keepingCapacity: true)

        case "agent_reasoning":
          if let value = payload["text"] as? String, let activity = cleanActivity(value) {
            parserState.snapshot.activity = activity
            parserState.snapshot.activityDate = timestamp
          }

        case "agent_message":
          if let value = payload["message"] as? String, let activity = cleanActivity(value) {
            parserState.snapshot.activity = activity
            parserState.snapshot.activityDate = timestamp
          }

        default:
          break
        }
      } else if recordType == "response_item" {
        if payloadType == "custom_tool_call" || payloadType == "function_call" {
          let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? UUID().uuidString
          let name = (payload["name"] as? String) ?? ""
          let input = stringify(payload["input"] ?? payload["arguments"] ?? "")
          parserState.pendingCalls.append(PendingCall(id: callID, name: name, input: input))
        } else if payloadType == "custom_tool_call_output" || payloadType == "function_call_output" {
          if let callID = payload["call_id"] as? String {
            parserState.completedCallIDs.insert(callID)
          }
        }
      }
    }
  }

  private static func finalize(_ parserState: inout RolloutParserState) {
    if let activeStart = parserState.currentStart {
      parserState.snapshot.activeStart = activeStart
      parserState.snapshot.state = .running

      if let pending = parserState.pendingCalls.reversed().first(where: {
        !parserState.completedCallIDs.contains($0.id)
      }) {
        let name = pending.name.lowercased()
        let input = pending.input.lowercased()
        if name.contains("request_user_input") || name.contains("requestuserinput") {
          parserState.snapshot.state = .waitingForInput
        } else if name.contains("approval") || name.contains("request_permissions") || input.contains("require_escalated") {
          parserState.snapshot.state = .needsApproval
        }
      }

      if let activityDate = parserState.snapshot.activityDate,
         activityDate < activeStart
      {
        parserState.snapshot.activity = nil
      }
    } else {
      parserState.snapshot.activeStart = nil
    }
  }

  private static func readRange(of url: URL, from offset: UInt64, length: UInt64) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    do {
      try handle.seek(toOffset: offset)
      return try handle.read(upToCount: Int(length))
    } catch {
      return nil
    }
  }

  private static func projectName(for cwd: String) -> String? {
    let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    guard standardized.path != home.path, standardized.path != "/" else { return nil }

    let name = standardized.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }

  private static func displayTitle(for stored: StoredThread, projectName: String?) -> String {
    let source = stored.threadSource.lowercased()
    if source.contains("voice") {
      return "Voice session · \(projectName ?? "Codex")"
    }

    if source.contains("subagent") || stored.title.contains("<codex_delegation>") {
      if !stored.agentNickname.isEmpty {
        return "\(stored.agentNickname) · \(projectName ?? "Agent")"
      }
      if !stored.agentRole.isEmpty {
        return concise(stored.agentRole, limit: 58)
      }
      return "Agent work · \(projectName ?? "Codex")"
    }

    for candidate in [stored.name, stored.title, stored.preview] {
      var cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      if cleaned.hasPrefix("/goal ") {
        cleaned.removeFirst("/goal ".count)
      }
      guard !cleaned.isEmpty, !cleaned.hasPrefix("<") else { continue }
      return concise(cleaned, limit: 62)
    }

    return projectName.map { "Thread in \($0)" } ?? "Codex thread"
  }

  private static func displayActivity(
    from snapshot: RolloutSnapshot,
    state: AgentState,
    projectName: String?
  ) -> String {
    if let activity = snapshot.activity {
      return activity
    }

    switch state {
    case .running:
      return "Starting work in \(projectName ?? "the current project")"
    case .waitingForInput:
      return "Waiting for your response"
    case .needsApproval:
      return "Waiting for approval"
    case .completed:
      return "Most recent work is complete"
    case .failed:
      return "The most recent run stopped before completion"
    }
  }

  private static func elapsedText(
    state: AgentState,
    activeStart: Date?,
    lastDuration: TimeInterval?,
    createdAt: Date,
    updatedAt: Date,
    now: Date
  ) -> String {
    let interval: TimeInterval
    if state.isActive, let activeStart {
      interval = now.timeIntervalSince(activeStart)
    } else if let lastDuration {
      interval = lastDuration
    } else {
      interval = max(0, updatedAt.timeIntervalSince(createdAt))
    }

    let seconds = max(0, Int(interval))
    if seconds < 60 {
      return "<1m"
    }
    let minutes = seconds / 60
    if minutes < 60 {
      return "\(minutes)m"
    }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
  }

  private static func cleanActivity(_ value: String) -> String? {
    let collapsed = value
      .replacingOccurrences(of: "`", with: "")
      .replacingOccurrences(of: "**", with: "")
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !collapsed.isEmpty else { return nil }
    return concise(collapsed, limit: 150)
  }

  private static func concise(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    let end = value.index(value.startIndex, offsetBy: limit)
    let prefix = String(value[..<end])
    if let space = prefix.lastIndex(of: " ") {
      return String(prefix[..<space]) + "…"
    }
    return prefix + "…"
  }

  private static func stringify(_ value: Any) -> String {
    if let string = value as? String {
      return string
    }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value),
       let string = String(data: data, encoding: .utf8)
    {
      return string
    }
    return String(describing: value)
  }
}
