import Carbon
import Foundation
import SQLite3
import iAgentCore

enum MessagesDirectDispatchDisposition: Equatable, Sendable {
  case accepted
  case notStarted(errorNumber: Int, detail: String)
  case outcomeUncertain(String)
  case unavailable(String)
}

private struct MessagesAppleScriptCommand: Equatable, Sendable {
  let source: String
  let arguments: [String]
}

/// Runs a fixed AppleScript inside the entitled app process. User-controlled
/// text exists only in an Apple event argument list; it is never code and is
/// never written to the script.
///
/// A sandboxed `Process` child inherits the parent's sandbox profile, but the
/// system `/usr/bin/osascript` executable is separately signed and cannot use
/// this app's Messages Apple Events exception. Running that executable from a
/// TestFlight build therefore fails with `errAEPrivilegeError` (-10004). An
/// in-process `NSAppleScript` sends as iAgent's own audit identity and can use
/// the entitlements and user consent attached to the signed app.
struct MessagesAppleScriptExecutor: Sendable {
  /// AppleScript applies this timeout to the Messages Apple event itself. If
  /// the timeout starts after dispatch, the structured phase marker keeps the
  /// result uncertain and prevents an automatic duplicate send.
  static let timeout: TimeInterval = 60

  static var isAvailable: Bool { true }

  static let scriptSource = """
    on iagent_send(theRecipient, theMessage, theService, targetChatID)
        set dispatchPhase to "pre_dispatch"
        try
            with timeout of \(Int(timeout)) seconds
                tell application id "com.apple.MobileSMS"
                    if targetChatID is not "" then
                        set targetChat to chat id targetChatID
                        set dispatchPhase to "dispatch_started"
                        send theMessage to targetChat
                    else
                        if theService is "sms" then
                            set targetService to first service whose service type is SMS
                        else
                            set targetService to first service whose service type is iMessage
                        end if
                        set targetBuddy to buddy theRecipient of targetService
                        set dispatchPhase to "dispatch_started"
                        send theMessage to targetBuddy
                    end if
                end tell
            end timeout
            return "IAGENT_RESULT" & tab & "ok" & tab & "completed" & tab & "0"
        on error errorMessage number errorNumber
            if dispatchPhase is "pre_dispatch" then
                return "IAGENT_RESULT" & tab & "failure" & tab & "not_started" & tab & errorNumber
            end if
            return "IAGENT_RESULT" & tab & "failure" & tab & "may_have_completed" & tab & errorNumber
        end try
    end iagent_send
    """

  static func command(
    recipient: String,
    body: String,
    service: MacMessageReplyService,
    chatGUID: String?
  ) -> (source: String, arguments: [String]) {
    (
      scriptSource,
      [recipient, body, service.appleScriptValue, chatGUID ?? ""]
    )
  }

  @MainActor
  fileprivate func send(
    recipient: String,
    body: String,
    service: MacMessageReplyService,
    chatGUID: String?
  ) -> MessagesDirectDispatchDisposition {
    guard Self.isAvailable else {
      return .unavailable("The in-process AppleScript runner is unavailable.")
    }
    let specification = Self.command(
      recipient: recipient,
      body: body,
      service: service,
      chatGUID: chatGUID
    )
    let command = MessagesAppleScriptCommand(
      source: specification.source,
      arguments: specification.arguments
    )
    return Self.run(command)
  }

  @MainActor
  private static func run(
    _ command: MessagesAppleScriptCommand
  ) -> MessagesDirectDispatchDisposition {
    guard let script = NSAppleScript(source: command.source) else {
      return .unavailable("The in-process AppleScript runner could not be created.")
    }
    var compileError: NSDictionary?
    guard script.compileAndReturnError(&compileError) else {
      return .unavailable("The in-process AppleScript runner could not be compiled.")
    }

    let event = invocationEvent(arguments: command.arguments)

    var executionError: NSDictionary?
    let result = script.executeAppleEvent(event, error: &executionError)
    guard executionError == nil else {
      // A handler-level error is caught by the fixed script and includes its
      // dispatch phase. Reaching this path means the runner itself could not
      // return a trustworthy result; never invite an automatic retry.
      return .outcomeUncertain(
        "Messages automation returned no trustworthy dispatch result. Do not retry automatically."
      )
    }
    return interpret(result.stringValue ?? "")
  }

  @MainActor
  static func invocationEvent(arguments: [String]) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kASAppleScriptSuite),
      eventID: AEEventID(kASSubroutineEvent),
      targetDescriptor: nil,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    event.setParam(
      NSAppleEventDescriptor(string: "iagent_send"),
      forKeyword: AEKeyword(keyASSubroutineName)
    )
    let argumentList = NSAppleEventDescriptor.list()
    for (index, argument) in arguments.enumerated() {
      argumentList.insert(
        NSAppleEventDescriptor(string: argument),
        at: index + 1
      )
    }
    event.setParam(argumentList, forKeyword: AEKeyword(keyDirectObject))
    return event
  }

  static func interpret(_ output: String) -> MessagesDirectDispatchDisposition {
    let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "\t", omittingEmptySubsequences: false)
      .map(String.init)
    guard fields.count == 4, fields[0] == "IAGENT_RESULT" else {
      return .outcomeUncertain(
        "Messages automation returned no trustworthy dispatch result. Do not retry automatically."
      )
    }
    if fields[1] == "ok", fields[2] == "completed" {
      return .accepted
    }
    let errorNumber = Int(fields[3]) ?? 0
    if fields[2] == "not_started" {
      return .notStarted(
        errorNumber: errorNumber,
        detail: "Messages automation did not start the send (AppleScript error \(errorNumber))."
      )
    }
    return .outcomeUncertain(
      "Messages automation failed after dispatch may have started (AppleScript error \(errorNumber)). Do not retry automatically."
    )
  }
}

struct MessagesOutgoingVerificationContext: Sendable {
  let databaseURL: URL
  let recipient: String
  let service: MacMessageReplyService
  let baselineRowID: Int64
  let chatRowID: Int64?
  let chatGUID: String?
}

struct MessagesOutgoingRow: Sendable {
  let rowID: Int64
  let guid: String?
}

struct MessagesOutgoingVerifier: Sendable {
  static let defaultTimeout: TimeInterval = 8
  let databaseURL: URL?
  let verificationTimeout: TimeInterval

  init(
    databaseURL: URL?,
    verificationTimeout: TimeInterval = Self.defaultTimeout
  ) {
    self.databaseURL = databaseURL
    self.verificationTimeout = max(0, verificationTimeout)
  }

  func prepare(
    recipient: String,
    service: MacMessageReplyService
  ) -> MessagesOutgoingVerificationContext? {
    guard let databaseURL,
          let database = try? Self.openReadOnlyDatabase(at: databaseURL)
    else { return nil }
    defer { sqlite3_close(database) }

    guard let baselineRowID = try? Self.maximumMessageRowID(in: database) else {
      return nil
    }
    let chat = try? Self.resolveDirectChat(
      recipient: recipient,
      service: service,
      in: database
    )
    return MessagesOutgoingVerificationContext(
      databaseURL: databaseURL,
      recipient: recipient,
      service: service,
      baselineRowID: baselineRowID,
      chatRowID: chat?.rowID,
      chatGUID: chat?.guid
    )
  }

  func verify(
    body: String,
    context: MessagesOutgoingVerificationContext
  ) -> MessagesOutgoingRow? {
    guard let database = try? Self.openReadOnlyDatabase(at: context.databaseURL) else {
      return nil
    }
    defer { sqlite3_close(database) }

    let deadline = Date().addingTimeInterval(verificationTimeout)
    repeat {
      var resolvedChatRowID = context.chatRowID
      if resolvedChatRowID == nil,
         let refreshedChat = try? Self.resolveDirectChat(
           recipient: context.recipient,
           service: context.service,
           in: database
         )
      {
        resolvedChatRowID = refreshedChat.rowID
      }
      if let chatRowID = resolvedChatRowID {
        do {
          if let row = try Self.matchingOutgoingRow(
            body: body,
            chatRowID: chatRowID,
            afterRowID: context.baselineRowID,
            in: database
          ) {
            return row
          }
        } catch {
          return nil
        }
      }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return nil
  }

  /// Detects the macOS 26 Messages failure mode where AppleScript returns
  /// success but Messages writes an empty outgoing row that is not joined to
  /// the intended chat. This is diagnostic only: it never enables a retry.
  func unjoinedEmptyOutgoingRow(
    context: MessagesOutgoingVerificationContext
  ) -> Int64? {
    guard let database = try? Self.openReadOnlyDatabase(at: context.databaseURL)
    else { return nil }
    defer { sqlite3_close(database) }
    return try? Self.unjoinedEmptyOutgoingRow(
      context: context,
      in: database
    )
  }

  private static func openReadOnlyDatabase(at url: URL) throws -> OpaquePointer {
    var database: OpaquePointer?
    let flags = Int32(SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
    let result = sqlite3_open_v2(url.path, &database, flags, nil)
    guard result == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      throw MacMessageReplyTransportError.serviceUnavailable
    }
    sqlite3_busy_timeout(database, 500)
    guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
      sqlite3_close(database)
      throw MacMessageReplyTransportError.serviceUnavailable
    }
    return database
  }

  private static func maximumMessageRowID(in database: OpaquePointer) throws -> Int64 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "SELECT COALESCE(MAX(ROWID), 0) FROM message",
      -1,
      &statement,
      nil
    ) == SQLITE_OK,
      let statement
    else { throw MacMessageReplyTransportError.serviceUnavailable }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw MacMessageReplyTransportError.serviceUnavailable
    }
    return sqlite3_column_int64(statement, 0)
  }

  private static func resolveDirectChat(
    recipient: String,
    service: MacMessageReplyService,
    in database: OpaquePointer
  ) throws -> (rowID: Int64, guid: String?)? {
    guard let expectedAddress = MessageReplyAddress(recipient) else { return nil }
    let sql = """
      SELECT
        c.ROWID,
        COALESCE(c.guid, ''),
        COALESCE(h.id, ''),
        COALESCE(c.chat_identifier, ''),
        COUNT(DISTINCT chj.handle_id)
      FROM chat c
      LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
      LEFT JOIN handle h ON h.ROWID = chj.handle_id
      LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      LEFT JOIN message latest ON latest.ROWID = cmj.message_id
      WHERE COALESCE(c.style, 0) != 43
      GROUP BY c.ROWID
      ORDER BY
        CASE WHEN lower(COALESCE(c.service_name, '')) = lower(?1) THEN 0 ELSE 1 END,
        MAX(COALESCE(latest.date, 0)) DESC,
        c.ROWID DESC
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
    else { throw MacMessageReplyTransportError.serviceUnavailable }
    defer { sqlite3_finalize(statement) }
    bind(service.rawValue, at: 1, in: statement)

    while sqlite3_step(statement) == SQLITE_ROW {
      let memberCount = sqlite3_column_int64(statement, 4)
      guard memberCount <= 1 else { continue }
      let handle = string(at: 2, in: statement) ?? ""
      let chatIdentifier = string(at: 3, in: statement) ?? ""
      guard [handle, chatIdentifier].contains(where: {
        routingAddress($0, matches: expectedAddress)
      }) else { continue }

      let guid = string(at: 1, in: statement)
      return (
        sqlite3_column_int64(statement, 0),
        guid?.isEmpty == false ? guid : nil
      )
    }
    return nil
  }

  private static func routingAddress(
    _ rawValue: String,
    matches expected: MessageReplyAddress
  ) -> Bool {
    guard let candidate = MessageReplyAddress(rawValue) else { return false }
    guard candidate.kind == expected.kind else { return false }
    switch candidate.kind {
    case .phone:
      return candidate.value == expected.value
    case .email:
      return candidate.value.caseInsensitiveCompare(expected.value) == .orderedSame
    }
  }

  private static func matchingOutgoingRow(
    body: String,
    chatRowID: Int64,
    afterRowID: Int64,
    in database: OpaquePointer
  ) throws -> MessagesOutgoingRow? {
    let messageColumns = try columns(in: "message", database: database)
    let plainTextExpression = messageColumns.contains("text") ? "m.text" : "NULL"
    let attributedBodyExpression = messageColumns.contains("attributedBody")
      ? "m.attributedBody"
      : "NULL"
    guard plainTextExpression != "NULL" || attributedBodyExpression != "NULL" else {
      return nil
    }
    let sql = """
      SELECT
        m.ROWID,
        COALESCE(m.guid, ''),
        \(plainTextExpression),
        \(attributedBodyExpression)
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      WHERE cmj.chat_id = ?1
        AND m.ROWID > ?2
        AND COALESCE(m.is_from_me, 0) = 1
      ORDER BY m.ROWID ASC
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
    else { throw MacMessageReplyTransportError.serviceUnavailable }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, chatRowID)
    sqlite3_bind_int64(statement, 2, afterRowID)

    while sqlite3_step(statement) == SQLITE_ROW {
      let plainText = string(at: 2, in: statement)
      let attributedText = MessageAttributedBodyDecoder.decode(
        data(at: 3, in: statement)
      )
      guard [plainText, attributedText].compactMap({ $0 }).contains(body) else {
        continue
      }
      let guid = string(at: 1, in: statement)
      return MessagesOutgoingRow(
        rowID: sqlite3_column_int64(statement, 0),
        guid: guid?.isEmpty == false ? guid : nil
      )
    }
    return nil
  }

  private static func unjoinedEmptyOutgoingRow(
    context: MessagesOutgoingVerificationContext,
    in database: OpaquePointer
  ) throws -> Int64? {
    guard let expectedAddress = MessageReplyAddress(context.recipient) else {
      return nil
    }
    let messageColumns = try columns(in: "message", database: database)
    guard messageColumns.contains("handle_id"),
          messageColumns.contains("is_from_me")
    else { return nil }

    let emptyPlainText = messageColumns.contains("text")
      ? "LENGTH(COALESCE(m.text, '')) = 0"
      : "1"
    let emptyAttributedBody = messageColumns.contains("attributedBody")
      ? "LENGTH(COALESCE(m.attributedBody, X'')) = 0"
      : "1"
    let hasNoAttachments = messageColumns.contains("cache_has_attachments")
      ? "COALESCE(m.cache_has_attachments, 0) = 0"
      : "1"
    let sql = """
      SELECT m.ROWID, COALESCE(h.id, '')
      FROM message m
      LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE m.ROWID > ?1
        AND COALESCE(m.is_from_me, 0) = 1
        AND cmj.message_id IS NULL
        AND \(emptyPlainText)
        AND \(emptyAttributedBody)
        AND \(hasNoAttachments)
      ORDER BY m.ROWID ASC
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
    else { throw MacMessageReplyTransportError.serviceUnavailable }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, context.baselineRowID)

    while sqlite3_step(statement) == SQLITE_ROW {
      let rawHandle = string(at: 1, in: statement) ?? ""
      guard ghostHandle(
        rawHandle,
        matches: expectedAddress,
        chatGUID: context.chatGUID
      ) else { continue }
      return sqlite3_column_int64(statement, 0)
    }
    return nil
  }

  private static func ghostHandle(
    _ rawValue: String,
    matches expected: MessageReplyAddress,
    chatGUID: String?
  ) -> Bool {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if let chatGUID,
       trimmed.caseInsensitiveCompare(chatGUID) == .orderedSame
    {
      return true
    }
    if routingAddress(trimmed, matches: expected) {
      return true
    }

    let folded = trimmed.lowercased()
    for prefix in ["any;+;", "any;-;"] where folded.hasPrefix(prefix) {
      let bareHandle = String(trimmed.dropFirst(prefix.count))
      if routingAddress(bareHandle, matches: expected) {
        return true
      }
    }
    return false
  }

  private static func columns(
    in table: String,
    database: OpaquePointer
  ) throws -> Set<String> {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "PRAGMA table_info(\(table))",
      -1,
      &statement,
      nil
    ) == SQLITE_OK,
      let statement
    else { throw MacMessageReplyTransportError.serviceUnavailable }
    defer { sqlite3_finalize(statement) }

    var result = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
      if let name = string(at: 1, in: statement) {
        result.insert(name)
      }
    }
    return result
  }

  private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private static func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
    _ = value.withCString { pointer in
      sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
    }
  }

  private static func string(at index: Int32, in statement: OpaquePointer) -> String? {
    guard let text = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: text)
  }

  private static func data(at index: Int32, in statement: OpaquePointer) -> Data? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let bytes = sqlite3_column_blob(statement, index)
    else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count > 0 else { return nil }
    return Data(bytes: bytes, count: count)
  }
}

struct MessagesDirectSendPipeline: Sendable {
  private static let automationDeniedError = -1743
  private static let unavailableErrors: Set<Int> = [-600, -609, -10814]

  let databaseURL: URL?

  func send(
    _ request: MessageReplyRequest,
    service: MacMessageReplyService
  ) async throws -> MacMessageReplySendResult {
    let payload = try DirectMessagesReplyTransport.payload(for: request)
    let verifier = MessagesOutgoingVerifier(databaseURL: databaseURL)
    let verification = await Task.detached(priority: .userInitiated) {
      verifier.prepare(
        recipient: payload.recipient,
        service: service
      )
    }.value
    let dispatch = await MessagesAppleScriptExecutor().send(
      recipient: payload.recipient,
      body: payload.body,
      service: service,
      chatGUID: verification?.chatGUID
    )

    switch dispatch {
    case .accepted:
      guard let verification else {
        return .outcomeUncertain(
          "Messages accepted the send, but its outgoing database was unavailable for verification. The message may have sent; do not retry automatically."
        )
      }
      let verificationResult: (row: MessagesOutgoingRow?, ghostRowID: Int64?) =
        await Task.detached(priority: .userInitiated) {
          if let row = verifier.verify(body: payload.body, context: verification) {
            return (row: row, ghostRowID: nil)
          }
          return (
            row: nil,
            ghostRowID: verifier.unjoinedEmptyOutgoingRow(context: verification)
          )
        }.value
      let row = verificationResult.row
      let ghostRowID = verificationResult.ghostRowID
      guard let row else {
        return Self.missingVerificationResult(
          ghostRowID: ghostRowID
        )
      }
      return .sent(
        MacMessageReplySendReceipt(
          rowID: row.rowID,
          guid: row.guid,
          service: service
        )
      )

    case .notStarted(let errorNumber, let detail):
      return Self.notStartedResult(errorNumber: errorNumber, detail: detail)

    case .outcomeUncertain(let message):
      return .outcomeUncertain(message)

    case .unavailable(let message):
      return .fallbackRequired(
        "\(message) You can open this draft in Messages instead."
      )
    }
  }

  static func notStartedResult(
    errorNumber: Int,
    detail: String
  ) -> MacMessageReplySendResult {
    if errorNumber == Self.automationDeniedError {
      return .fallbackRequired(
        "Automation access to Messages was denied. Allow iAgent in System Settings > Privacy & Security > Automation, or open this draft in Messages instead."
      )
    }
    if Self.unavailableErrors.contains(errorNumber) {
      return .fallbackRequired(
        "Messages automation is unavailable right now. You can open this draft in Messages instead."
      )
    }
    return .fallbackRequired(
      "\(detail) The direct send did not start, so you can open this draft in Messages instead."
    )
  }

  static func missingVerificationResult(
    ghostRowID: Int64?
  ) -> MacMessageReplySendResult {
    if let ghostRowID {
      return .outcomeUncertain(
        "Messages created an unjoined empty outgoing row (\(ghostRowID)) for this route, so delivery was not confirmed. Do not retry automatically."
      )
    }
    return .outcomeUncertain(
      "Messages accepted the send, but no matching outgoing row appeared within \(Int(MessagesOutgoingVerifier.defaultTimeout)) seconds. The message may have sent; do not retry automatically."
    )
  }
}
