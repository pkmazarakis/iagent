import Foundation

struct CodexSubmission: Sendable, Equatable {
  let threadID: String
  let turnID: String
}

enum CodexAppServerEvent: Sendable {
  case turnCompleted(threadID: String, status: String)
  case attentionRequired(threadID: String, message: String)
  case processStopped(message: String)
}

struct CodexAppServerError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

private final class CodexProcessIOBridge: @unchecked Sendable {
  private weak var client: CodexAppServerClient?

  init(client: CodexAppServerClient) {
    self.client = client
  }

  func makeTerminationHandler() -> @Sendable (Process) -> Void {
    { [weak self] process in
      self?.receiveTermination(status: process.terminationStatus)
    }
  }

  func makeOutputHandler() -> @Sendable (FileHandle) -> Void {
    { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.receiveOutput(data)
    }
  }

  func makeErrorHandler() -> @Sendable (FileHandle) -> Void {
    { handle in
      let data = handle.availableData
      guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
      fputs("[app-server] \(message)", stderr)
    }
  }

  private func receiveTermination(status: Int32) {
    Task { @MainActor [weak client] in
      client?.handleTermination(status: status)
    }
  }

  private func receiveOutput(_ data: Data) {
    Task { @MainActor [weak client] in
      client?.consume(data)
    }
  }
}

@MainActor
final class CodexAppServerClient {
  var onEvent: ((CodexAppServerEvent) -> Void)?

  private var process: Process?
  private var inputHandle: FileHandle?
  private var outputHandle: FileHandle?
  private var errorHandle: FileHandle?
  private var processIOBridge: CodexProcessIOBridge?
  private var readBuffer = Data()
  private var nextRequestID = 1
  private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
  private var initialized = false
  private var startupTask: Task<Void, Error>?

  func startThread(
    prompt text: String,
    cwd: String
  ) async throws -> CodexSubmission {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      throw CodexAppServerError(message: "Enter a prompt for the new Codex task.")
    }

    try await ensureStarted()
    let startResponse = try await request(
      method: "thread/start",
      params: [
        "cwd": cwd,
        "serviceName": "iagent_panel",
      ]
    )
    let threadID = try stringValue(in: startResponse, path: ["result", "thread", "id"])
    let turnResponse = try await request(
      method: "turn/start",
      params: [
        "threadId": threadID,
        "input": [["type": "text", "text": prompt]],
      ]
    )
    let turnID = try stringValue(in: turnResponse, path: ["result", "turn", "id"])
    return CodexSubmission(threadID: threadID, turnID: turnID)
  }

  func stop() {
    outputHandle?.readabilityHandler = nil
    errorHandle?.readabilityHandler = nil
    if process?.isRunning == true {
      process?.terminate()
    }
    process = nil
    inputHandle = nil
    outputHandle = nil
    errorHandle = nil
    processIOBridge = nil
    initialized = false
    startupTask?.cancel()
    startupTask = nil
    failPending(message: "Codex app-server stopped.")
  }

  private func ensureStarted() async throws {
    if initialized, process?.isRunning == true {
      return
    }
    if let startupTask {
      return try await startupTask.value
    }

    let task = Task { @MainActor [weak self] in
      guard let self else {
        throw CodexAppServerError(message: "The Codex client is unavailable.")
      }
      try await self.launchAndInitialize()
    }
    startupTask = task
    do {
      try await task.value
      startupTask = nil
    } catch {
      startupTask = nil
      stop()
      throw error
    }
  }

  private func launchAndInitialize() async throws {
    let executableURL = try Self.resolveExecutableURL()
    let process = Process()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()

    process.executableURL = executableURL
    process.arguments = ["app-server", "--listen", "stdio://"]
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    let processIOBridge = CodexProcessIOBridge(client: self)
    self.processIOBridge = processIOBridge
    process.terminationHandler = processIOBridge.makeTerminationHandler()
    outputPipe.fileHandleForReading.readabilityHandler = processIOBridge.makeOutputHandler()
    errorPipe.fileHandleForReading.readabilityHandler = processIOBridge.makeErrorHandler()

    self.process = process
    inputHandle = inputPipe.fileHandleForWriting
    outputHandle = outputPipe.fileHandleForReading
    errorHandle = errorPipe.fileHandleForReading

    do {
      try process.run()
    } catch {
      throw CodexAppServerError(
        message: "Could not launch Codex app-server: \(error.localizedDescription)"
      )
    }

    _ = try await request(
      method: "initialize",
      params: [
        "clientInfo": [
          "name": "iagent_panel",
          "title": "iAgent Panel",
          "version": "0.2.0",
        ],
      ]
    )
    try sendNotification(method: "initialized", params: [:])
    initialized = true
  }

  private func request(
    method: String,
    params: [String: Any]
  ) async throws -> Data {
    guard let inputHandle else {
      throw CodexAppServerError(message: "Codex app-server is not connected.")
    }

    let requestID = nextRequestID
    nextRequestID += 1
    let payload: [String: Any] = [
      "method": method,
      "id": requestID,
      "params": params,
    ]
    let data = try encodedLine(payload)

    return try await withCheckedThrowingContinuation { continuation in
      pending[requestID] = continuation
      do {
        try inputHandle.write(contentsOf: data)
      } catch {
        pending.removeValue(forKey: requestID)
        continuation.resume(
          throwing: CodexAppServerError(
            message: "Could not send \(method) to Codex: \(error.localizedDescription)"
          )
        )
      }
    }
  }

  private func sendNotification(
    method: String,
    params: [String: Any]
  ) throws {
    guard let inputHandle else {
      throw CodexAppServerError(message: "Codex app-server is not connected.")
    }
    try inputHandle.write(
      contentsOf: encodedLine(["method": method, "params": params])
    )
  }

  private func encodedLine(_ object: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw CodexAppServerError(message: "Could not encode a Codex app-server request.")
    }
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    return data
  }

  fileprivate func consume(_ data: Data) {
    readBuffer.append(data)
    while let newline = readBuffer.firstIndex(of: 0x0A) {
      let line = readBuffer[..<newline]
      readBuffer.removeSubrange(...newline)
      guard !line.isEmpty else { continue }
      handleLine(Data(line))
    }
  }

  private func handleLine(_ data: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return
    }

    if let method = object["method"] as? String {
      if let requestID = number(object["id"]) {
        handleServerRequest(id: requestID, method: method, params: object["params"])
      } else {
        handleNotification(method: method, params: object["params"])
      }
      return
    }

    guard let requestID = number(object["id"]),
          let continuation = pending.removeValue(forKey: requestID)
    else {
      return
    }

    if let error = object["error"] as? [String: Any] {
      let message = error["message"] as? String ?? "Codex app-server returned an error."
      continuation.resume(throwing: CodexAppServerError(message: message))
    } else {
      continuation.resume(returning: data)
    }
  }

  private func handleNotification(method: String, params value: Any?) {
    let params = value as? [String: Any] ?? [:]
    let threadID = params["threadId"] as? String ?? ""

    if method == "turn/completed" {
      let turn = params["turn"] as? [String: Any]
      let status = turn?["status"] as? String ?? "completed"
      onEvent?(.turnCompleted(threadID: threadID, status: status))
    }
  }

  private func handleServerRequest(id: Int, method: String, params value: Any?) {
    let params = value as? [String: Any] ?? [:]
    let threadID = params["threadId"] as? String ?? ""

    switch method {
    case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
      onEvent?(
        .attentionRequired(
          threadID: threadID,
          message: "An approval was declined in iAgent. Open the task in Codex to run it with broader access."
        )
      )
      try? sendServerResponse(id: id, result: ["decision": "decline"])

    case "item/permissions/requestApproval":
      onEvent?(
        .attentionRequired(
          threadID: threadID,
          message: "Additional permissions were not granted from iAgent."
        )
      )
      try? sendServerResponse(id: id, result: ["permissions": [:], "scope": "turn"])

    default:
      try? sendServerError(id: id, message: "This interaction needs the full Codex app.")
    }
  }

  private func sendServerResponse(id: Int, result: [String: Any]) throws {
    guard let inputHandle else { return }
    try inputHandle.write(contentsOf: encodedLine(["id": id, "result": result]))
  }

  private func sendServerError(id: Int, message: String) throws {
    guard let inputHandle else { return }
    try inputHandle.write(
      contentsOf: encodedLine([
        "id": id,
        "error": ["code": -32_001, "message": message],
      ])
    )
  }

  private func stringValue(in data: Data, path: [String]) throws -> String {
    guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CodexAppServerError(message: "Codex returned an unreadable response.")
    }

    for component in path.dropLast() {
      guard let next = value[component] as? [String: Any] else {
        throw CodexAppServerError(message: "Codex returned an incomplete response.")
      }
      value = next
    }

    guard let key = path.last, let string = value[key] as? String, !string.isEmpty else {
      throw CodexAppServerError(message: "Codex did not return a task identifier.")
    }
    return string
  }

  private func number(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
      return number.intValue
    }
    return value as? Int
  }

  fileprivate func handleTermination(status: Int32) {
    guard process != nil else { return }
    outputHandle?.readabilityHandler = nil
    errorHandle?.readabilityHandler = nil
    process = nil
    inputHandle = nil
    outputHandle = nil
    errorHandle = nil
    processIOBridge = nil
    initialized = false
    startupTask = nil
    let message = "Codex app-server exited with status \(status)."
    failPending(message: message)
    onEvent?(.processStopped(message: message))
  }

  private func failPending(message: String) {
    let continuations = pending.values
    pending.removeAll()
    for continuation in continuations {
      continuation.resume(throwing: CodexAppServerError(message: message))
    }
  }

  private static func resolveExecutableURL() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    let candidates = [
      environment["CODEX_EXECUTABLE"],
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
    ].compactMap { $0 }

    if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      return URL(fileURLWithPath: path)
    }

    throw CodexAppServerError(
      message: "Codex could not be found. Install the ChatGPT app or set CODEX_EXECUTABLE."
    )
  }
}
