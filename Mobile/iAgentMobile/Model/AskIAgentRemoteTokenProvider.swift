import CryptoKit
import DeviceCheck
import Foundation
import Security

/// Produces a short-lived, request-bound bearer token without creating a user account.
/// App Attest is the primary assurance mechanism. DeviceCheck is used only when App Attest is
/// unavailable on the device, and the server can independently keep that fallback disabled.
protocol AskIAgentRemoteTokenProviding: Sendable {
  func authorizationHeader(for requestBody: Data, relayURL: URL) async throws -> String
}

enum AskIAgentRemoteTokenProviderError: Error, Equatable, Sendable {
  case authenticationFailed
  case rateLimited(retryAfter: TimeInterval?)
  case temporarilyUnavailable
  case malformedResponse
}

protocol AskIAgentAppAttestServicing: Sendable {
  var isSupported: Bool { get }
  func generateKey() async throws -> String
  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

private struct SystemAppAttestService: AskIAgentAppAttestServicing, @unchecked Sendable {
  private let service = DCAppAttestService.shared

  var isSupported: Bool { service.isSupported }

  func generateKey() async throws -> String {
    try await service.generateKey()
  }

  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
    try await service.attestKey(keyID, clientDataHash: clientDataHash)
  }

  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
    try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
  }
}

protocol AskIAgentInstallationKeyStoring: Sendable {
  func installationID() throws -> String
  func appAttestKeyID() throws -> String?
  func setAppAttestKeyID(_ keyID: String?) throws
  /// Starts or resumes this migration generation's one automatic environment recovery.
  ///
  /// The replacement installation identifier is journaled in the same durable record as the
  /// generation before either identity half changes. A later process can therefore finish the
  /// exact same rotation after termination. Returns nil once that replacement was committed so a
  /// repeated relay rejection cannot delete the replacement key and churn identities.
  func resumeOrStartAppAttestEnvironmentRecovery(generation: Int) throws -> String?
  /// Clears only the matching generation after the relay accepts an App Attest exchange.
  func clearAppAttestEnvironmentRecovery(generation: Int) throws
  /// Starts a new anonymous App Attest identity and returns its installation identifier.
  ///
  /// The relay binds every attested key to the installation identifier presented on first use.
  /// Replace and journal the pair as one local identity so a later request cannot present that
  /// key with a different installation identifier.
  func rotateInstallationIdentity() throws -> String
}

/// App Attest identity is process-global even when more than one chat model briefly exists during
/// a presentation handoff. Actor methods are reentrant across network and DeviceCheck awaits, so a
/// provider actor alone cannot prevent two invalid-key recoveries from rotating the same Keychain
/// identity concurrently. This FIFO gate keeps the full App Attest transaction -- identity read,
/// challenge, artifact, exchange, and any one-shot rotation -- in one process-wide critical path.
private actor AskIAgentAppAttestAuthorizationGate {
  static let shared = AskIAgentAppAttestAuthorizationGate()

  private var isOccupied = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    guard isOccupied else {
      isOccupied = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    guard !waiters.isEmpty else {
      isOccupied = false
      return
    }
    waiters.removeFirst().resume()
  }
}

actor AskIAgentRemoteTokenProvider: AskIAgentRemoteTokenProviding {
  private enum AppAttestRecoverySignal: Error {
    case identityBindingMismatch
    case environmentMismatch
  }

  // Bump only when a later release intentionally grants one new, bounded migration attempt.
  private static let appAttestEnvironmentRecoveryGeneration = 1

  private enum Assurance: String, Codable {
    case appAttest = "app_attest"
    case deviceCheck = "devicecheck"
  }

  private enum ArtifactType: String, Codable {
    case attestation
    case assertion
    case deviceCheck = "devicecheck"
  }

  private let session: URLSession
  private let keychain: any AskIAgentInstallationKeyStoring
  private let appAttest: any AskIAgentAppAttestServicing

  init(
    session: URLSession = .shared,
    keychain: any AskIAgentInstallationKeyStoring = InstallationKeychain(),
    appAttest: any AskIAgentAppAttestServicing = SystemAppAttestService()
  ) {
    self.session = session
    self.keychain = keychain
    self.appAttest = appAttest
  }

  func authorizationHeader(for requestBody: Data, relayURL: URL) async throws -> String {
    guard relayURL.scheme == "https" else {
      throw AskIAgentRemoteTokenProviderError.temporarilyUnavailable
    }
    do {
      let requestHash = Self.base64URL(Data(SHA256.hash(data: requestBody)))

      if appAttest.isSupported {
        let gate = AskIAgentAppAttestAuthorizationGate.shared
        await gate.acquire()
        do {
          // A cancelled waiter still receives and releases its FIFO slot. Checking cancellation
          // before touching Keychain prevents it from mutating an identity after its turn ended.
          try Task.checkCancellation()
          let installationID = try keychain.installationID()
          let token = try await appAttestToken(
            installationID: installationID,
            requestHash: requestHash,
            relayURL: relayURL
          )
          await gate.release()
          return "Bearer \(token)"
        } catch {
          await gate.release()
          throw error
        }
      }

      // This deliberately does not hide a failed App Attest verification behind the weaker
      // fallback. DeviceCheck is attempted only on devices where App Attest is unsupported.
      let installationID = try keychain.installationID()
      let token = try await deviceCheckToken(
        installationID: installationID,
        requestHash: requestHash,
        relayURL: relayURL
      )
      return "Bearer \(token)"
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AskIAgentRemoteTokenProviderError {
      throw error
    } catch {
      // App Attest invalid-key errors still rotate once inside `appAttestToken`. If the newly
      // generated key is also rejected, surface an authentication failure without weakening to
      // DeviceCheck. Other local/platform failures are transient from the request's perspective.
      if Self.isInvalidAppAttestKey(error) {
        throw AskIAgentRemoteTokenProviderError.authenticationFailed
      }
      throw AskIAgentRemoteTokenProviderError.temporarilyUnavailable
    }
  }

  private func appAttestToken(
    installationID: String,
    requestHash: String,
    relayURL: URL
  ) async throws -> String {
    do {
      return try await appAttestTokenAttempt(
        installationID: installationID,
        requestHash: requestHash,
        relayURL: relayURL
      )
    } catch {
      // A key can become unusable after restore/reinstall, or when Apple certified it but the
      // first exchange never reached our server. The relay binds a key to an installation, so
      // rotate both halves of that anonymous identity exactly once for invalid-key errors.
      // Network/server/authentication failures preserve the identity and are never amplified by
      // an automatic rotation loop.
      let isEnvironmentMismatch = Self.isEnvironmentMismatch(error)
      guard Self.isInvalidAppAttestKey(error)
        || Self.isIdentityBindingMismatch(error)
        || isEnvironmentMismatch
      else {
        throw error
      }
      if isEnvironmentMismatch {
        // Do not persist recovery intent for a request that was already cancelled. Once recovery
        // starts, its Keychain journal makes the synchronous identity mutation crash-resumable.
        try Task.checkCancellation()
        guard let replacementInstallationID = try keychain
          .resumeOrStartAppAttestEnvironmentRecovery(
            generation: Self.appAttestEnvironmentRecoveryGeneration
          )
        else {
          throw AskIAgentRemoteTokenProviderError.authenticationFailed
        }
        do {
          return try await appAttestTokenAttempt(
            installationID: replacementInstallationID,
            requestHash: requestHash,
            relayURL: relayURL
          )
        } catch is AppAttestRecoverySignal {
          // A second environment/binding mismatch cannot trigger another rotation. Fail closed and
          // preserve the journal so a later retry observes the committed replacement as consumed.
          throw AskIAgentRemoteTokenProviderError.authenticationFailed
        }
      }

      try Task.checkCancellation()
      let replacementInstallationID = try keychain.rotateInstallationIdentity()
      do {
        return try await appAttestTokenAttempt(
          installationID: replacementInstallationID,
          requestHash: requestHash,
          relayURL: relayURL
        )
      } catch is AppAttestRecoverySignal {
        // A second binding mismatch cannot trigger another rotation. Fail closed as an
        // authentication error and require an explicit later user retry.
        throw AskIAgentRemoteTokenProviderError.authenticationFailed
      }
    }
  }

  private func appAttestTokenAttempt(
    installationID: String,
    requestHash: String,
    relayURL: URL
  ) async throws -> String {
    var keyID = try keychain.appAttestKeyID()
    if keyID == nil {
      keyID = try await appAttest.generateKey()
      try keychain.setAppAttestKeyID(keyID)
    }
    guard let keyID else { throw AskIAgentRemoteTokenProviderError.temporarilyUnavailable }

    let challenge = try await requestChallenge(
      assurance: .appAttest,
      installationID: installationID,
      keyID: keyID,
      requestHash: requestHash,
      relayURL: relayURL
    )
    guard challenge.protocolVersion == 1,
      challenge.expiresAt > Int64(Date().timeIntervalSince1970 * 1_000)
    else { throw AskIAgentRemoteTokenProviderError.malformedResponse }
    let clientData = try Self.decodeBase64URL(challenge.clientData)
    let clientDataHash = Data(SHA256.hash(data: clientData))

    let artifactType: ArtifactType
    let artifact: Data
    switch challenge.mode {
    case ArtifactType.attestation.rawValue:
      artifactType = .attestation
      artifact = try await appAttest.attestKey(keyID, clientDataHash: clientDataHash)
    case ArtifactType.assertion.rawValue:
      artifactType = .assertion
      artifact = try await appAttest.generateAssertion(keyID, clientDataHash: clientDataHash)
    default:
      throw AskIAgentRemoteTokenProviderError.malformedResponse
    }

    let token = try await exchange(
      challenge: challenge,
      assurance: .appAttest,
      installationID: installationID,
      keyID: keyID,
      artifactType: artifactType,
      artifact: artifact,
      relayURL: relayURL
    )
    // A production-only relay accepted this App Attest artifact, so a previously consumed
    // stale-development-key migration may be armed again. DeviceCheck never reaches this path.
    try keychain.clearAppAttestEnvironmentRecovery(
      generation: Self.appAttestEnvironmentRecoveryGeneration
    )
    return token
  }

  private static func isInvalidAppAttestKey(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == DCErrorDomain && nsError.code == DCError.Code.invalidKey.rawValue
  }

  private static func isIdentityBindingMismatch(_ error: Error) -> Bool {
    guard let signal = error as? AppAttestRecoverySignal else { return false }
    if case .identityBindingMismatch = signal { return true }
    return false
  }

  private static func isEnvironmentMismatch(_ error: Error) -> Bool {
    guard let signal = error as? AppAttestRecoverySignal else { return false }
    if case .environmentMismatch = signal { return true }
    return false
  }

  private func deviceCheckToken(
    installationID: String,
    requestHash: String,
    relayURL: URL
  ) async throws -> String {
    guard DCDevice.current.isSupported else {
      throw AskIAgentRemoteTokenProviderError.temporarilyUnavailable
    }
    let challenge = try await requestChallenge(
      assurance: .deviceCheck,
      installationID: installationID,
      keyID: nil,
      requestHash: requestHash,
      relayURL: relayURL
    )
    guard challenge.protocolVersion == 1,
      challenge.expiresAt > Int64(Date().timeIntervalSince1970 * 1_000),
      challenge.mode == ArtifactType.deviceCheck.rawValue
    else {
      throw AskIAgentRemoteTokenProviderError.malformedResponse
    }
    let deviceToken = try await DCDevice.current.generateToken()
    return try await exchange(
      challenge: challenge,
      assurance: .deviceCheck,
      installationID: installationID,
      keyID: nil,
      artifactType: .deviceCheck,
      artifact: deviceToken,
      relayURL: relayURL
    )
  }

  private func requestChallenge(
    assurance: Assurance,
    installationID: String,
    keyID: String?,
    requestHash: String,
    relayURL: URL
  ) async throws -> ChallengeResponse {
    let body = ChallengeRequest(
      assurance: assurance,
      installationID: installationID,
      keyID: keyID,
      requestHash: requestHash
    )
    return try await post(
      body,
      to: endpoint(named: "challenge", relativeTo: relayURL),
      responseType: ChallengeResponse.self,
      recognizesAppAttestIdentityBindingMismatch: assurance == .appAttest
    )
  }

  private func exchange(
    challenge: ChallengeResponse,
    assurance: Assurance,
    installationID: String,
    keyID: String?,
    artifactType: ArtifactType,
    artifact: Data,
    relayURL: URL
  ) async throws -> String {
    let response = try await post(
      ExchangeRequest(
        challengeID: challenge.challengeID,
        assurance: assurance,
        installationID: installationID,
        keyID: keyID,
        artifactType: artifactType,
        artifact: artifact.base64EncodedString()
      ),
      to: endpoint(named: "exchange", relativeTo: relayURL),
      responseType: ExchangeResponse.self,
      recognizesAppAttestEnvironmentMismatch: assurance == .appAttest
        && artifactType == .attestation
    )
    guard response.protocolVersion == 1,
      response.assurance == assurance,
      response.expiresAt > Int64(Date().timeIntervalSince1970 * 1_000),
      !response.token.isEmpty
    else {
      throw AskIAgentRemoteTokenProviderError.malformedResponse
    }
    return response.token
  }

  private func endpoint(named name: String, relativeTo relayURL: URL) throws -> URL {
    guard relayURL.scheme == "https" else {
      throw AskIAgentRemoteTokenProviderError.temporarilyUnavailable
    }
    return relayURL.deletingLastPathComponent()
      .appendingPathComponent("attestation", isDirectory: true)
      .appendingPathComponent(name, isDirectory: false)
  }

  private func post<Body: Encodable, Response: Decodable>(
    _ body: Body,
    to url: URL,
    responseType: Response.Type,
    recognizesAppAttestIdentityBindingMismatch: Bool = false,
    recognizesAppAttestEnvironmentMismatch: Bool = false
  ) async throws -> Response {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "X-iAgent-Relay-Protocol")
    request.httpBody = try JSONEncoder().encode(body)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AskIAgentRemoteTokenProviderError.temporarilyUnavailable
    }
    guard let http = response as? HTTPURLResponse else {
      throw AskIAgentRemoteTokenProviderError.temporarilyUnavailable
    }
    switch http.statusCode {
    case 200..<300:
      guard data.count <= 72 * 1024 else {
        throw AskIAgentRemoteTokenProviderError.malformedResponse
      }
    case 401:
      if recognizesAppAttestIdentityBindingMismatch,
        Self.isAppAttestIdentityBindingMismatchEnvelope(data)
      {
        throw AppAttestRecoverySignal.identityBindingMismatch
      }
      if recognizesAppAttestEnvironmentMismatch,
        Self.isAppAttestEnvironmentMismatchEnvelope(data)
      {
        throw AppAttestRecoverySignal.environmentMismatch
      }
      throw AskIAgentRemoteTokenProviderError.authenticationFailed
    case 403:
      throw AskIAgentRemoteTokenProviderError.authenticationFailed
    case 429:
      throw AskIAgentRemoteTokenProviderError.rateLimited(
        retryAfter: Self.retryAfter(from: http)
      )
    case 500..<600:
      throw AskIAgentRemoteTokenProviderError.temporarilyUnavailable
    default:
      throw AskIAgentRemoteTokenProviderError.malformedResponse
    }
    do {
      return try JSONDecoder().decode(responseType, from: data)
    } catch {
      throw AskIAgentRemoteTokenProviderError.malformedResponse
    }
  }

  private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
    guard let rawValue = response.value(forHTTPHeaderField: "Retry-After")?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty
    else { return nil }

    if let seconds = TimeInterval(rawValue), seconds.isFinite, seconds >= 0 {
      return min(seconds, 86_400)
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    guard let date = formatter.date(from: rawValue) else { return nil }
    return min(max(0, date.timeIntervalSinceNow), 86_400)
  }

  private static func isAppAttestIdentityBindingMismatchEnvelope(_ data: Data) -> Bool {
    // Match the complete, tiny server envelope. Unknown fields, redirects, proxy pages, generic
    // 401s, and a copy of this code from the exchange endpoint must never mutate local identity.
    guard data.count <= 512,
      let value = try? JSONSerialization.jsonObject(with: data),
      let object = value as? [String: Any],
      Set(object.keys) == Set(["error", "code"]),
      object["error"] as? String == "unauthorized",
      object["code"] as? String == "app_attest_identity_binding_mismatch"
    else { return false }
    return true
  }

  private static func isAppAttestEnvironmentMismatchEnvelope(_ data: Data) -> Bool {
    // This code is accepted only from the App Attest exchange endpoint. Matching the exact
    // two-field envelope prevents proxies, generic 401s, or added fields from rotating identity.
    guard data.count <= 512,
      let value = try? JSONSerialization.jsonObject(with: data),
      let object = value as? [String: Any],
      Set(object.keys) == Set(["error", "code"]),
      object["error"] as? String == "unauthorized",
      object["code"] as? String == "app_attest_environment_mismatch"
    else { return false }
    return true
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decodeBase64URL(_ value: String) throws -> Data {
    guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
      throw AskIAgentRemoteTokenProviderError.malformedResponse
    }
    var encoded = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
    guard let data = Data(base64Encoded: encoded), base64URL(data) == value else {
      throw AskIAgentRemoteTokenProviderError.malformedResponse
    }
    return data
  }

  private struct ChallengeRequest: Encodable {
    let protocolVersion = 1
    let assurance: Assurance
    let installationID: String
    let keyID: String?
    let requestHash: String
  }

  private struct ChallengeResponse: Decodable {
    let protocolVersion: Int
    let challengeID: String
    let mode: String
    let clientData: String
    let expiresAt: Int64
  }

  private struct ExchangeRequest: Encodable {
    let protocolVersion = 1
    let challengeID: String
    let assurance: Assurance
    let installationID: String
    let keyID: String?
    let artifactType: ArtifactType
    let artifact: String
  }

  private struct ExchangeResponse: Decodable {
    let protocolVersion: Int
    let token: String
    let expiresAt: Int64
    let assurance: Assurance
  }
}

/// Installation identifiers and App Attest key identifiers are device-local and do not sync.
/// This avoids turning the anonymous protection mechanism into a cross-device identity.
struct InstallationKeychain: AskIAgentInstallationKeyStoring, Sendable {
  private struct EnvironmentRecoveryJournal: Codable {
    let generation: Int
    let replacementInstallationID: String
  }

  private enum StoredEnvironmentRecovery {
    case legacyGeneration(Int)
    case journal(EnvironmentRecoveryJournal)

    var generation: Int {
      switch self {
      case .legacyGeneration(let generation): return generation
      case .journal(let journal): return journal.generation
      }
    }
  }

  private let service = "com.platon.iagent.mobile.ask-iagent-attestation"
  private let installationAccount = "anonymous-installation-id"
  private let appAttestAccount = "app-attest-key-id"
  private let pendingInstallationAccount = "pending-anonymous-installation-id"
  private let environmentRecoveryAccount = "app-attest-environment-recovery-generation"

  func installationID() throws -> String {
    try finishPendingIdentityRotation()
    try finishPendingEnvironmentRecovery()
    return try currentOrCreateInstallationID()
  }

  func appAttestKeyID() throws -> String? {
    try finishPendingIdentityRotation()
    try finishPendingEnvironmentRecovery()
    guard let data = try read(account: appAttestAccount) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func setAppAttestKeyID(_ keyID: String?) throws {
    if let keyID {
      try finishPendingIdentityRotation()
      try finishPendingEnvironmentRecovery()
      try write(Data(keyID.utf8), account: appAttestAccount)
    } else {
      let status = SecItemDelete(query(account: appAttestAccount) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainError.failure(status)
      }
    }
  }

  func resumeOrStartAppAttestEnvironmentRecovery(generation: Int) throws -> String? {
    guard generation > 0 else { throw KeychainError.invalidRecoveryGeneration }
    try finishPendingIdentityRotation()
    let currentInstallationID = try currentOrCreateInstallationID()

    let journal: EnvironmentRecoveryJournal
    if let stored = try storedEnvironmentRecovery() {
      if stored.generation > generation { return nil }
      switch stored {
      case .journal(let storedJournal) where storedJournal.generation == generation:
        // The installation write is the commit point. Once it matches the journal, retrying the
        // same relay rejection must not delete the new key or create another anonymous identity.
        guard currentInstallationID != storedJournal.replacementInstallationID else { return nil }
        journal = storedJournal
      default:
        // Build 28 stored only the generation before rotating. If that request was cancelled or the
        // process terminated, it left no replacement to resume and permanently suppressed retry.
        // Upgrade that incomplete marker to the crash-safe journal before touching either identity.
        journal = try makeEnvironmentRecoveryJournal(
          generation: generation,
          excluding: currentInstallationID
        )
        try writeRecoveryJournal(journal)
      }
    } else {
      journal = try makeEnvironmentRecoveryJournal(
        generation: generation,
        excluding: currentInstallationID
      )
      // This single item atomically records both the bounded budget and the replacement before
      // deleting the key or changing the installation. A failed write leaves both halves intact,
      // so a later user retry remains eligible to create the journal.
      try writeRecoveryJournal(journal)
    }

    try finishEnvironmentRecovery(journal, currentInstallationID: currentInstallationID)
    return journal.replacementInstallationID
  }

  func clearAppAttestEnvironmentRecovery(generation: Int) throws {
    guard generation > 0 else { throw KeychainError.invalidRecoveryGeneration }
    guard try storedEnvironmentRecovery()?.generation == generation else { return }
    try delete(account: environmentRecoveryAccount)
  }

  private func currentOrCreateInstallationID() throws -> String {
    if let existing = try read(account: installationAccount),
      let value = String(data: existing, encoding: .utf8),
      value.range(of: "^[A-Za-z0-9_-]{32,128}$", options: .regularExpression) != nil
    {
      return value
    }
    let value = try makeInstallationID()
    try write(Data(value.utf8), account: installationAccount)
    return value
  }

  private func storedEnvironmentRecovery() throws -> StoredEnvironmentRecovery? {
    guard let data = try read(account: environmentRecoveryAccount) else { return nil }
    if let journal = try? JSONDecoder().decode(EnvironmentRecoveryJournal.self, from: data),
      journal.generation > 0,
      journal.replacementInstallationID.range(
        of: "^[A-Za-z0-9_-]{32,128}$",
        options: .regularExpression
      ) != nil
    {
      return .journal(journal)
    }
    if let value = String(data: data, encoding: .utf8),
      let generation = Int(value),
      generation > 0
    {
      return .legacyGeneration(generation)
    }
    throw KeychainError.invalidRecoveryJournal
  }

  private func finishPendingEnvironmentRecovery() throws {
    guard let stored = try storedEnvironmentRecovery(),
      case .journal(let journal) = stored
    else { return }
    try finishEnvironmentRecovery(
      journal,
      currentInstallationID: currentOrCreateInstallationID()
    )
  }

  private func finishEnvironmentRecovery(
    _ journal: EnvironmentRecoveryJournal,
    currentInstallationID: String
  ) throws {
    guard currentInstallationID != journal.replacementInstallationID else { return }
    // Deleting the old key before committing the replacement installation ensures no later request
    // can pair that key with the replacement. Both operations are idempotent on journal replay.
    try delete(account: appAttestAccount)
    try write(Data(journal.replacementInstallationID.utf8), account: installationAccount)
  }

  private func makeEnvironmentRecoveryJournal(
    generation: Int,
    excluding currentInstallationID: String
  ) throws -> EnvironmentRecoveryJournal {
    var replacement = try makeInstallationID()
    while replacement == currentInstallationID {
      replacement = try makeInstallationID()
    }
    return EnvironmentRecoveryJournal(
      generation: generation,
      replacementInstallationID: replacement
    )
  }

  private func writeRecoveryJournal(_ journal: EnvironmentRecoveryJournal) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try write(try encoder.encode(journal), account: environmentRecoveryAccount)
  }

  func rotateInstallationIdentity() throws -> String {
    let replacement = try makeInstallationID()
    // Persist the replacement as a tiny recovery journal before either half changes. If the app
    // is terminated between the two keychain mutations, the next read idempotently finishes the
    // rotation instead of pairing a replacement installation with the stale key (or vice versa).
    try write(Data(replacement.utf8), account: pendingInstallationAccount)
    try finishPendingIdentityRotation()
    return replacement
  }

  private func finishPendingIdentityRotation() throws {
    guard let pending = try read(account: pendingInstallationAccount) else { return }
    guard let replacement = String(data: pending, encoding: .utf8),
      replacement.range(of: "^[A-Za-z0-9_-]{32,128}$", options: .regularExpression) != nil
    else {
      throw KeychainError.invalidRotationJournal
    }
    try delete(account: appAttestAccount)
    try write(Data(replacement.utf8), account: installationAccount)
    try delete(account: pendingInstallationAccount)
  }

  private func makeInstallationID() throws -> String {
    var random = Data(count: 32)
    let status = random.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
    }
    guard status == errSecSuccess else { throw KeychainError.failure(status) }
    return random.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func delete(account: String) throws {
    let status = SecItemDelete(query(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.failure(status)
    }
  }

  private func read(account: String) throws -> Data? {
    var request = query(account: account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw KeychainError.failure(status)
    }
    return data
  }

  private func write(_ data: Data, account: String) throws {
    let base = query(account: account)
    let status = SecItemUpdate(
      base as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw KeychainError.failure(status) }
    var item = base
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw KeychainError.failure(addStatus) }
  }

  private func query(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
  }

  private enum KeychainError: Error {
    case failure(OSStatus)
    case invalidRotationJournal
    case invalidRecoveryJournal
    case invalidRecoveryGeneration
  }
}
