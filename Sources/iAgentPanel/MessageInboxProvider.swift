import Contacts
import CryptoKit
import Darwin
import Foundation
import SQLite3
import iAgentCore

enum MessageProviderAccessState: Equatable, Sendable {
  case loading
  case authorized
  case permissionRequired(String)
  case disabled(String)
  case failed(String)

  var userMessage: String {
    switch self {
    case .loading:
      "Checking local Messages access."
    case .authorized:
      "Local Messages access is ready."
    case .permissionRequired(let message),
      .disabled(let message),
      .failed(let message):
      message
    }
  }

  var canReadMessages: Bool {
    self == .authorized
  }
}

struct MessageProviderBatch: Sendable {
  var conversations: [SyncedMessageConversation]
  var messages: [SyncedMessage]
  var readStates: [SyncedMessageReadState]
  var removedConversationIDs: Set<String>
  var removedMessageIDs: Set<String>
  var isFullSnapshot: Bool

  init(
    conversations: [SyncedMessageConversation] = [],
    messages: [SyncedMessage] = [],
    readStates: [SyncedMessageReadState] = [],
    removedConversationIDs: Set<String> = [],
    removedMessageIDs: Set<String> = [],
    isFullSnapshot: Bool
  ) {
    self.conversations = Self.deduplicate(conversations, updatedAt: \.updatedAt)
      .sorted {
        $0.latestMessageDate > $1.latestMessageDate
      }
    self.messages = Self.deduplicate(messages, updatedAt: \.updatedAt)
      .sorted {
        $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt < $1.sentAt
      }
    self.readStates = Self.deduplicate(readStates, updatedAt: \.updatedAt)
      .sorted { $0.id < $1.id }

    let upsertedConversationIDs = Set(self.conversations.map(\.id))
    let upsertedMessageIDs = Set(self.messages.map(\.id))
    self.removedConversationIDs = removedConversationIDs.subtracting(upsertedConversationIDs)
    self.removedMessageIDs = removedMessageIDs.subtracting(upsertedMessageIDs)
    self.isFullSnapshot = isFullSnapshot
  }

  var isEmptyDelta: Bool {
    !isFullSnapshot
      && conversations.isEmpty
      && messages.isEmpty
      && readStates.isEmpty
      && removedConversationIDs.isEmpty
      && removedMessageIDs.isEmpty
  }

  private static func deduplicate<Value: Identifiable>(
    _ values: [Value],
    updatedAt: KeyPath<Value, Date>
  ) -> [Value] where Value.ID == String {
    var byID: [String: Value] = [:]
    for value in values {
      if let existing = byID[value.id],
        existing[keyPath: updatedAt] > value[keyPath: updatedAt]
      {
        continue
      }
      byID[value.id] = value
    }
    return Array(byID.values)
  }
}

protocol MacMessageProviding: Sendable {
  func authorizationStatus() async -> MessageProviderAccessState
  func backfill(since: Date) async throws -> MessageProviderBatch
  func replyRecipients(
    for conversationID: String,
    since cutoff: Date
  ) async throws -> [MessageReplyRecipient]
  func updates(since: Date) -> AsyncThrowingStream<MessageProviderBatch, Error>
}

extension MacMessageProviding {
  func replyRecipients(
    for conversationID: String,
    since cutoff: Date
  ) async throws -> [MessageReplyRecipient] {
    let snapshot = try await backfill(since: cutoff)
    guard let conversation = snapshot.conversations.first(where: { $0.id == conversationID }),
          !conversation.isGroup
    else { return [] }
    return conversation.participants.compactMap(MessageReplyRecipient.init(participant:))
  }
}

protocol MessageContactNameResolving: Sendable {
  var changeGeneration: UInt64 { get }
  func requestAuthorizationIfNeeded() async
  func displayName(for rawHandle: String) -> String?
}

extension MessageContactNameResolving {
  var changeGeneration: UInt64 { 0 }
}

enum MessageContactIdentifier: Hashable, Sendable {
  case email(String)
  case phone(String)

  private static let URIHandleSchemes = [
    "mailto:",
    "tel:",
    "sms:",
    "imessage:",
    "facetime:",
    "phone:",
    "email:",
  ]
  private static let chatHandlePrefixes = [
    "imessage;-;",
    "sms;-;",
  ]

  static func normalized(_ rawValue: String) -> Self? {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 1_024 else { return nil }
    if let decoded = value.removingPercentEncoding {
      value = decoded
    }

    // Messages handles can be stored either as the bare address or as a public
    // URI/chat identifier. Strip only known wrappers; arbitrary prefixes are
    // deliberately left untouched rather than guessed at.
    for _ in 0..<2 {
      let folded = value.lowercased()
      if let prefix = chatHandlePrefixes.first(where: { folded.hasPrefix($0) }) {
        value.removeFirst(prefix.count)
        continue
      }
      if let scheme = URIHandleSchemes.first(where: { folded.hasPrefix($0) }) {
        value.removeFirst(scheme.count)
        while value.hasPrefix("/") {
          value.removeFirst()
        }
        continue
      }
      break
    }

    if let delimiter = value.firstIndex(where: { $0 == "?" || $0 == "#" || $0 == ";" }) {
      value = String(value[..<delimiter])
    }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("<"), value.hasSuffix(">"), value.count > 2 {
      value.removeFirst()
      value.removeLast()
    }

    if value.contains("@") {
      let normalized = value.precomposedStringWithCanonicalMapping.lowercased()
      let components = normalized.split(separator: "@", omittingEmptySubsequences: false)
      guard components.count == 2,
            !components[0].isEmpty,
            !components[1].isEmpty,
            normalized.utf8.count <= 320,
            !normalized.unicodeScalars.contains(where: {
              CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20
            })
      else { return nil }
      return .email(normalized)
    }

    var digits = value.compactMap(\.wholeNumberValue).map(String.init).joined()
    if digits.hasPrefix("00") {
      digits.removeFirst(2)
    }
    guard digits.count >= 3, digits.count <= 32 else { return nil }
    return .phone(digits)
  }

  func privacySafeDisplayValue(source rawValue: String) -> String {
    switch self {
    case .email(let value):
      return value
    case .phone(let digits):
      var value = (rawValue.removingPercentEncoding ?? rawValue)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      for _ in 0..<2 {
        let folded = value.lowercased()
        if let prefix = Self.chatHandlePrefixes.first(where: { folded.hasPrefix($0) }) {
          value.removeFirst(prefix.count)
          continue
        }
        if let scheme = Self.URIHandleSchemes.first(where: { folded.hasPrefix($0) }) {
          value.removeFirst(scheme.count)
          while value.hasPrefix("/") {
            value.removeFirst()
          }
          continue
        }
        break
      }
      value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      let hadInternationalPrefix = value.hasPrefix("+") || value.hasPrefix("00")
      return hadInternationalPrefix ? "+\(digits)" : digits
    }
  }

}

struct MessageContactNameIndex: Sendable {
  private static let minimumPhoneSuffixDigits = 8
  private static let maximumPhoneSuffixDigits = 15

  private var exactNames: [MessageContactIdentifier: Set<String>] = [:]
  private var phoneSuffixNames: [String: Set<String>] = [:]

  mutating func add(
    displayName: String,
    phoneNumbers: [String],
    emailAddresses: [String]
  ) {
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
          name.utf8.count <= 512,
          !name.unicodeScalars.contains(where: { $0.value < 0x20 })
    else { return }

    for rawValue in phoneNumbers + emailAddresses {
      guard let identifier = MessageContactIdentifier.normalized(rawValue) else {
        continue
      }
      exactNames[identifier, default: []].insert(name)
      guard case .phone(let digits) = identifier,
            digits.count >= Self.minimumPhoneSuffixDigits
      else { continue }
      let maximumLength = min(Self.maximumPhoneSuffixDigits, digits.count)
      for length in Self.minimumPhoneSuffixDigits...maximumLength {
        phoneSuffixNames[String(digits.suffix(length)), default: []].insert(name)
      }
    }
  }

  func displayName(for rawHandle: String) -> String? {
    guard let identifier = MessageContactIdentifier.normalized(rawHandle) else {
      return nil
    }
    return displayName(for: identifier)
  }

  fileprivate func displayName(for identifier: MessageContactIdentifier) -> String? {
    if let exact = exactNames[identifier] {
      return uniqueName(in: exact, disallowing: identifier)
    }
    guard case .phone(let digits) = identifier,
          digits.count >= Self.minimumPhoneSuffixDigits
    else { return nil }

    let maximumLength = min(Self.maximumPhoneSuffixDigits, digits.count)
    for length in stride(
      from: maximumLength,
      through: Self.minimumPhoneSuffixDigits,
      by: -1
    ) {
      guard let names = phoneSuffixNames[String(digits.suffix(length))] else {
        continue
      }
      // A collision at a longer suffix cannot become safer at a shorter one.
      return uniqueName(in: names, disallowing: identifier)
    }
    return nil
  }

  private func uniqueName(
    in names: Set<String>,
    disallowing identifier: MessageContactIdentifier
  ) -> String? {
    let sorted = names.sorted()
    guard let first = sorted.first else { return nil }
    let foldedFirst = Self.foldedName(first)
    guard sorted.dropFirst().allSatisfy({ Self.foldedName($0) == foldedFirst }),
          MessageContactIdentifier.normalized(first) != identifier
    else { return nil }
    return first
  }

  private static func foldedName(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }
}

final class ContactsMessageNameResolver: MessageContactNameResolving, @unchecked Sendable {
  private let store: CNContactStore
  private let notificationCenter: NotificationCenter
  private let lock = NSLock()
  private var cachedIndex: MessageContactNameIndex?
  private var cacheGeneration: UInt64 = 0
  private var storeChangeObserver: NSObjectProtocol?

  init(
    store: CNContactStore = CNContactStore(),
    notificationCenter: NotificationCenter = .default
  ) {
    self.store = store
    self.notificationCenter = notificationCenter
    storeChangeObserver = notificationCenter.addObserver(
      forName: Notification.Name.CNContactStoreDidChange,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.invalidateIndex()
    }
  }

  deinit {
    if let storeChangeObserver {
      notificationCenter.removeObserver(storeChangeObserver)
    }
  }

  var changeGeneration: UInt64 {
    lock.withLock { cacheGeneration }
  }

  func requestAuthorizationIfNeeded() async {
    guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else {
      return
    }
    _ = await withCheckedContinuation { continuation in
      store.requestAccess(for: .contacts) { granted, _ in
        continuation.resume(returning: granted)
      }
    }
    invalidateIndex()
  }

  func displayName(for rawHandle: String) -> String? {
    guard Self.contactAccessIsAuthorized(
      CNContactStore.authorizationStatus(for: .contacts)
    ) else {
      // Permission changes post a Contacts-store notification (and the explicit
      // request path invalidates once). A denied lookup must not advance the
      // generation per message or it would force a full provider reload forever.
      lock.withLock {
        cachedIndex = nil
      }
      return nil
    }
    guard let identifier = MessageContactIdentifier.normalized(rawHandle) else {
      return nil
    }

    // ContactStore calls stay outside our lock because its change notification
    // may arrive concurrently. The generation check prevents a just-invalidated
    // index from being reinstalled after a fetch finishes.
    for _ in 0..<2 {
      let (index, generation) = lock.withLock {
        (cachedIndex, cacheGeneration)
      }
      if let index {
        return index.displayName(for: identifier)
      }

      if let targetedName = targetedDisplayName(for: identifier) {
        if lock.withLock({ cacheGeneration == generation }) {
          return targetedName
        }
        continue
      }
      guard let index = buildIndex() else { return nil }
      let installed = lock.withLock {
        guard cacheGeneration == generation else { return false }
        cachedIndex = index
        return true
      }
      if installed {
        return index.displayName(for: identifier)
      }
    }
    return nil
  }

  private func targetedDisplayName(for identifier: MessageContactIdentifier) -> String? {
    let predicate: NSPredicate
    switch identifier {
    case .email(let value):
      predicate = CNContact.predicateForContacts(matchingEmailAddress: value)
    case .phone(let value):
      predicate = CNContact.predicateForContacts(
        matching: CNPhoneNumber(stringValue: value)
      )
    }
    let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
    guard let contacts = try? store.unifiedContacts(
      matching: predicate,
      keysToFetch: keys
    ) else { return nil }

    var index = MessageContactNameIndex()
    for contact in contacts {
      guard let name = Self.displayName(for: contact) else { continue }
      switch identifier {
      case .email(let value):
        index.add(displayName: name, phoneNumbers: [], emailAddresses: [value])
      case .phone(let value):
        index.add(displayName: name, phoneNumbers: [value], emailAddresses: [])
      }
    }
    return index.displayName(for: identifier)
  }

  private func buildIndex() -> MessageContactNameIndex? {
    let keys: [any CNKeyDescriptor] = [
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
      CNContactPhoneNumbersKey as any CNKeyDescriptor,
      CNContactEmailAddressesKey as any CNKeyDescriptor,
    ]
    let request = CNContactFetchRequest(keysToFetch: keys)
    request.unifyResults = true
    var index = MessageContactNameIndex()
    do {
      try store.enumerateContacts(with: request) { contact, _ in
        guard let name = Self.displayName(for: contact) else { return }
        index.add(
          displayName: name,
          phoneNumbers: contact.phoneNumbers.map(\.value.stringValue),
          emailAddresses: contact.emailAddresses.map { $0.value as String }
        )
      }
      return index
    } catch {
      return nil
    }
  }

  private func invalidateIndex() {
    lock.withLock {
      cachedIndex = nil
      cacheGeneration &+= 1
    }
  }

  private static func displayName(for contact: CNContact) -> String? {
    let value = CNContactFormatter.string(from: contact, style: .fullName)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  private static func contactAccessIsAuthorized(_ status: CNAuthorizationStatus) -> Bool {
    // Raw value 4 is the limited-contact authorization introduced on newer OS
    // versions. Referencing `.limited` directly is unavailable in the macOS 14
    // SDK surface even though a newer runtime may return it.
    status == .authorized || status.rawValue == 4
  }
}

enum MessageAttributedBodyDecoder {
  static let maximumArchiveBytes = 1_048_576
  static let maximumTextBytes = 262_144

  static func decode(_ data: Data?) -> String? {
    guard let data, !data.isEmpty, data.count <= maximumArchiveBytes else {
      return nil
    }
    if data.starts(with: Data("bplist".utf8)),
       let attributed = try? NSKeyedUnarchiver.unarchivedObject(
         ofClass: NSAttributedString.self,
         from: data
       ),
       let body = sanitized(attributed.string)
    {
      return body
    }
    guard var reader = TypedStreamReader(data: data),
          let decoded = try? reader.decodeAttributedString()
    else { return nil }
    return sanitized(decoded)
  }

  private struct TypedStreamReader {
    private enum Endianness {
      case little
      case big
    }

    private enum Reference {
      case object
      case classRecord(name: String, version: Int)
    }

    private enum ClassTerminator: Equatable {
      case nilValue
      case reference(Int)
    }

    private struct ClassRecord: Equatable {
      let referenceIndex: Int
      let name: String
      let version: Int
    }

    private enum DecodeError: Error {
      case malformed
    }

    private static let integer16Tag = UInt8(bitPattern: -127)
    private static let integer32Tag = UInt8(bitPattern: -126)
    private static let newTag = UInt8(bitPattern: -124)
    private static let nilTag = UInt8(bitPattern: -123)
    private static let endObjectTag = UInt8(bitPattern: -122)
    private static let maximumTableEntries = 64

    private let bytes: [UInt8]
    private var offset = 0
    private var endianness = Endianness.little
    private var sharedStrings: [String] = []
    private var references: [Reference] = []

    init?(data: Data) {
      guard !data.isEmpty, data.count <= MessageAttributedBodyDecoder.maximumArchiveBytes else {
        return nil
      }
      bytes = [UInt8](data)
    }

    mutating func decodeAttributedString() throws -> String {
      try readHeader()
      guard try readSharedString() == "@" else { throw DecodeError.malformed }
      _ = try readLiteralObject()
      let rootChain = try readClassChain()
      let rootDescriptors = rootChain.classes.map { "\($0.name):\($0.version)" }
      let immutableRoot = [
        "NSAttributedString:0",
        "NSObject:0",
      ]
      let mutableRoot = [
        "NSMutableAttributedString:0",
        "NSAttributedString:0",
        "NSObject:0",
      ]
      guard rootChain.terminator == .nilValue,
            rootDescriptors == immutableRoot || rootDescriptors == mutableRoot,
            let nsObjectReference = rootChain.classes.last?.referenceIndex
      else { throw DecodeError.malformed }

      guard try readSharedString() == "@" else { throw DecodeError.malformed }
      _ = try readLiteralObject()
      let stringChain = try readClassChain()
      let immutableString = stringChain.classes.count == 1
        && stringChain.classes[0].name == "NSString"
        && stringChain.classes[0].version == 1
      let mutableString = stringChain.classes.count == 2
        && stringChain.classes[0].name == "NSMutableString"
        && stringChain.classes[0].version == 1
        && stringChain.classes[1].name == "NSString"
        && stringChain.classes[1].version == 1
      guard immutableString || mutableString,
            stringChain.terminator == .reference(nsObjectReference),
            try readSharedString() == "+"
      else { throw DecodeError.malformed }

      let length = try readInteger(signed: false)
      guard length > 0,
            length <= MessageAttributedBodyDecoder.maximumTextBytes
      else { throw DecodeError.malformed }
      let bodyBytes = try readBytes(count: length)
      guard let body = String(bytes: bodyBytes, encoding: .utf8),
            try readByte() == Self.endObjectTag
      else { throw DecodeError.malformed }
      return body
    }

    private mutating func readHeader() throws {
      guard try readByte() == 4 else { throw DecodeError.malformed }
      let signatureLength = try readInteger(signed: false)
      guard signatureLength == 11,
            let signature = String(
              bytes: try readBytes(count: signatureLength),
              encoding: .ascii
            )
      else { throw DecodeError.malformed }
      switch signature {
      case "streamtyped":
        endianness = .little
      case "typedstream":
        endianness = .big
      default:
        throw DecodeError.malformed
      }
      let systemVersion = try readInteger(signed: false)
      guard systemVersion > 0, systemVersion <= 10_000 else {
        throw DecodeError.malformed
      }
    }

    private mutating func readLiteralObject() throws -> Int {
      guard try readByte() == Self.newTag,
            references.count < Self.maximumTableEntries
      else { throw DecodeError.malformed }
      references.append(.object)
      return references.count - 1
    }

    private mutating func readClassChain() throws -> (
      classes: [ClassRecord],
      terminator: ClassTerminator
    ) {
      var classes: [ClassRecord] = []
      while try peekByte() == Self.newTag {
        _ = try readByte()
        guard let name = try readSharedString(),
              references.count < Self.maximumTableEntries
        else { throw DecodeError.malformed }
        let version = try readInteger(signed: true)
        let referenceIndex = references.count
        references.append(.classRecord(name: name, version: version))
        classes.append(
          ClassRecord(referenceIndex: referenceIndex, name: name, version: version)
        )
      }
      guard !classes.isEmpty else { throw DecodeError.malformed }
      if try peekByte() == Self.nilTag {
        _ = try readByte()
        return (classes, .nilValue)
      }
      let referenceIndex = try readReferenceIndex()
      guard referenceIndex < references.count,
            case .classRecord = references[referenceIndex]
      else {
        throw DecodeError.malformed
      }
      return (classes, .reference(referenceIndex))
    }

    private mutating func readSharedString() throws -> String? {
      switch try peekByte() {
      case Self.nilTag:
        _ = try readByte()
        return nil
      case Self.newTag:
        _ = try readByte()
        guard sharedStrings.count < Self.maximumTableEntries else {
          throw DecodeError.malformed
        }
        let value = try readUnsharedString(maximumBytes: 128)
        sharedStrings.append(value)
        return value
      default:
        let referenceIndex = try readReferenceIndex()
        guard referenceIndex < sharedStrings.count else {
          throw DecodeError.malformed
        }
        return sharedStrings[referenceIndex]
      }
    }

    private mutating func readUnsharedString(maximumBytes: Int) throws -> String {
      let length = try readInteger(signed: false)
      guard length >= 0, length <= maximumBytes,
            let value = String(bytes: try readBytes(count: length), encoding: .utf8)
      else { throw DecodeError.malformed }
      return value
    }

    private mutating func readReferenceIndex() throws -> Int {
      let encoded = Int(Int8(bitPattern: try readByte()))
      let index = encoded + 110
      guard encoded >= -110, encoded < 0,
            index >= 0, index < references.count || index < sharedStrings.count
      else { throw DecodeError.malformed }
      return index
    }

    private mutating func readInteger(signed: Bool) throws -> Int {
      let head = try readByte()
      let signedHead = Int(Int8(bitPattern: head))
      if head == Self.integer16Tag {
        let raw = try readUnsignedIntegerBytes(count: 2)
        return signed ? Int(Int16(bitPattern: UInt16(raw))) : Int(raw)
      }
      if head == Self.integer32Tag {
        let raw = try readUnsignedIntegerBytes(count: 4)
        return signed ? Int(Int32(bitPattern: UInt32(raw))) : Int(raw)
      }
      guard !(-128 ... -111).contains(signedHead) else {
        throw DecodeError.malformed
      }
      return signed ? signedHead : Int(head)
    }

    private mutating func readUnsignedIntegerBytes(count: Int) throws -> UInt64 {
      let valueBytes = try readBytes(count: count)
      switch endianness {
      case .little:
        return valueBytes.enumerated().reduce(0) { value, element in
          value | (UInt64(element.element) << (element.offset * 8))
        }
      case .big:
        return valueBytes.reduce(0) { ($0 << 8) | UInt64($1) }
      }
    }

    private mutating func peekByte() throws -> UInt8 {
      guard offset < bytes.count else { throw DecodeError.malformed }
      return bytes[offset]
    }

    private mutating func readByte() throws -> UInt8 {
      let value = try peekByte()
      offset += 1
      return value
    }

    private mutating func readBytes(count: Int) throws -> ArraySlice<UInt8> {
      guard count >= 0, offset <= bytes.count - count else {
        throw DecodeError.malformed
      }
      let result = bytes[offset..<(offset + count)]
      offset += count
      return result
    }
  }

  private static func sanitized(_ value: String) -> String? {
    let trimmed = value.replacingOccurrences(of: "\u{FFFC}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.utf8.count <= maximumTextBytes,
          !trimmed.unicodeScalars.contains(where: { scalar in
            scalar.value < 0x20
              && scalar.value != 0x0A
              && scalar.value != 0x0D
              && scalar.value != 0x09
          })
    else { return nil }
    return trimmed
  }
}

enum MacMessageProviderFactory {
  private static let localAccessOptInKey = "messageInbox.localProviderOptIn.v1"

  static func localAccessIsEnabled(
    preferences: UserDefaults = .standard
  ) -> Bool {
    preferences.bool(forKey: localAccessOptInKey)
  }

  static func setLocalAccessEnabled(
    _ enabled: Bool,
    preferences: UserDefaults = .standard
  ) {
    preferences.set(enabled, forKey: localAccessOptInKey)
  }

  static func accessState(for error: Error) -> MessageProviderAccessState {
    if let providerError = error as? LocalMessagesProviderError {
      return providerError.accessState
    }
    return .failed(error.localizedDescription)
  }

  static func make(
    smokeTest: Bool,
    preferences: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: Set<String> = Set(CommandLine.arguments),
    authorizedDatabaseURL: URL? = nil,
    requiresSecurityScopedDatabaseURL: Bool = false
  ) -> any MacMessageProviding {
    let configuredProvider = environment["IAGENT_MESSAGES_PROVIDER"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    if smokeTest
      || configuredProvider == "mock"
      || arguments.contains("--mock-messages-provider")
    {
      return MockMacMessagesProvider()
    }

    if configuredProvider == "disabled" || arguments.contains("--disable-messages-provider") {
      return DisabledMacMessagesProvider(
        reason: "Messages is disabled for this launch."
      )
    }

    if configuredProvider == "local"
      || arguments.contains("--local-messages-provider")
      || localAccessIsEnabled(preferences: preferences)
    {
      if let authorizedDatabaseURL {
        return LocalMacMessagesProvider(
          databaseURL: authorizedDatabaseURL,
          includesReplyAddresses: MessageReplyPreferences.isEnabled(in: preferences)
        )
      }
      if requiresSecurityScopedDatabaseURL {
        return DisabledMacMessagesProvider(
          reason:
            "Reconnect Messages and choose your Messages folder to restore read-only access."
        )
      }
      return LocalMacMessagesProvider(
        includesReplyAddresses: MessageReplyPreferences.isEnabled(in: preferences)
      )
    }

    // The source path is not even inspected before the user opts in. Once they
    // do, Full Disk Access is the second, OS-enforced permission gate and the
    // local provider still opens the source strictly read-only.
    return DisabledMacMessagesProvider(
      reason:
        "Connect Messages to show the last 14 days. iAgent reads the authorized local source only and never changes Messages."
    )
  }
}

private struct DisabledMacMessagesProvider: MacMessageProviding {
  let reason: String

  func authorizationStatus() async -> MessageProviderAccessState {
    .disabled(reason)
  }

  func backfill(since _: Date) async throws -> MessageProviderBatch {
    MessageProviderBatch(isFullSnapshot: true)
  }

  func updates(since _: Date) -> AsyncThrowingStream<MessageProviderBatch, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

final class MockMacMessagesProvider: MacMessageProviding, @unchecked Sendable {
  private static let sourceDeviceID = "mock-mac-messages"
  private static let selfParticipantID = "mock-participant-self"

  private let referenceDate: Date
  private let liveUpdateDelay: Duration

  init(
    referenceDate: Date = Date(),
    liveUpdateDelay: Duration = .milliseconds(850)
  ) {
    self.referenceDate = referenceDate
    self.liveUpdateDelay = liveUpdateDelay
  }

  func authorizationStatus() async -> MessageProviderAccessState {
    .authorized
  }

  func backfill(since cutoff: Date) async throws -> MessageProviderBatch {
    let effectiveCutoff = max(
      cutoff,
      MessageSyncWindow.cutoff(referenceDate: referenceDate)
    )
    return Self.fixture(referenceDate: referenceDate, cutoff: effectiveCutoff)
  }

  func updates(since cutoff: Date) -> AsyncThrowingStream<MessageProviderBatch, Error> {
    let liveUpdateDelay = liveUpdateDelay
    let streamStartedAt = Date()
    let fixtureReferenceDate = referenceDate

    return AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .utility) {
        do {
          try await Task.sleep(for: liveUpdateDelay)
          try Task.checkCancellation()

          let sentAt = max(fixtureReferenceDate, streamStartedAt)
            .addingTimeInterval(1)
          let rollingCutoff = max(
            cutoff,
            MessageSyncWindow.cutoff(referenceDate: Date())
          )
          guard sentAt >= rollingCutoff else {
            continuation.finish()
            return
          }

          continuation.yield(Self.liveIncomingUpdate(sentAt: sentAt))

          // Remain subscribed until the owner cancels the stream. The mock
          // intentionally produces one stable update rather than ambient noise.
          while !Task.isCancelled {
            try await Task.sleep(for: .seconds(60))
          }
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  private static func fixture(
    referenceDate: Date,
    cutoff: Date
  ) -> MessageProviderBatch {
    let avery = SyncedMessageParticipant(
      id: "mock-participant-avery",
      displayName: "Avery Chen",
      isContactNameResolved: true,
      replyAddress: "+15555550101"
    )
    let maya = SyncedMessageParticipant(
      id: "mock-participant-maya",
      displayName: "Maya Ortiz",
      isContactNameResolved: true,
      replyAddress: "+15555550102"
    )
    let jordan = SyncedMessageParticipant(
      id: "mock-participant-jordan",
      displayName: "Jordan Lee",
      isContactNameResolved: true,
      replyAddress: "+15555550103"
    )
    let sam = SyncedMessageParticipant(
      id: "mock-participant-sam",
      displayName: "Sam Rivera",
      isContactNameResolved: true,
      replyAddress: "+15555550104"
    )

    let averyMessages = [
      mockMessage(
        id: "mock-message-avery-0-expired",
        conversationID: "mock-conversation-avery",
        participant: avery,
        body: "This deliberately expired fixture must never leave the provider.",
        sentAt: referenceDate.addingTimeInterval(-15 * 24 * 60 * 60),
        isFromMe: false,
        isRead: true
      ),
      mockMessage(
        id: "mock-message-avery-1",
        conversationID: "mock-conversation-avery",
        participant: avery,
        body: "Are we still on for coffee tomorrow?",
        sentAt: referenceDate.addingTimeInterval(-23 * 60 * 60),
        isFromMe: false,
        isRead: true
      ),
      mockMessage(
        id: "mock-message-avery-2",
        conversationID: "mock-conversation-avery",
        participant: avery,
        body: "Absolutely — 10 works for me.",
        sentAt: referenceDate.addingTimeInterval(-22 * 60 * 60),
        isFromMe: true,
        isRead: true
      ),
      mockMessage(
        id: "mock-message-avery-3",
        conversationID: "mock-conversation-avery",
        participant: avery,
        body: "Perfect. I’ll pick a place near the station.",
        sentAt: referenceDate.addingTimeInterval(-12 * 60),
        isFromMe: false,
        isRead: true
      ),
      mockMessage(
        id: "mock-message-avery-4",
        conversationID: "mock-conversation-avery",
        participant: avery,
        body: "Found one — I’ll send the address in a minute.",
        sentAt: referenceDate.addingTimeInterval(-5 * 60),
        isFromMe: false,
        isRead: false
      ),
    ]

    let mayaMessages = [
      mockMessage(
        id: "mock-message-maya-1",
        conversationID: "mock-conversation-maya",
        participant: maya,
        body: "The photos came out beautifully.",
        sentAt: referenceDate.addingTimeInterval(-2 * 24 * 60 * 60),
        isFromMe: false,
        isRead: true
      ),
      mockMessage(
        id: "mock-message-maya-2",
        conversationID: "mock-conversation-maya",
        participant: maya,
        body: "They really did. Thanks for sending them!",
        sentAt: referenceDate.addingTimeInterval(-47 * 60 * 60),
        isFromMe: true,
        isRead: true
      ),
      mockMessage(
        id: "mock-message-maya-3",
        conversationID: "mock-conversation-maya",
        participant: maya,
        body: "Of course 😊",
        sentAt: referenceDate.addingTimeInterval(-46 * 60 * 60),
        isFromMe: false,
        isRead: true
      ),
    ]

    let groupMessages = [
      mockMessage(
        id: "mock-message-weekend-1",
        conversationID: "mock-conversation-weekend",
        participant: jordan,
        body: "Should we take the early ferry?",
        sentAt: referenceDate.addingTimeInterval(-3 * 24 * 60 * 60),
        isFromMe: false,
        isRead: true
      ),
      mockMessage(
        id: "mock-message-weekend-2",
        conversationID: "mock-conversation-weekend",
        participant: sam,
        body: "Yes, then we get the whole afternoon there.",
        sentAt: referenceDate.addingTimeInterval(-2 * 24 * 60 * 60 - 2 * 60),
        isFromMe: false,
        isRead: true
      ),
      mockMessage(
        id: "mock-message-weekend-3",
        conversationID: "mock-conversation-weekend",
        participant: jordan,
        body: "Booked for 8:15 — see you at the port.",
        sentAt: referenceDate.addingTimeInterval(-45 * 60),
        isFromMe: false,
        isRead: false
      ),
    ]

    let oldParticipant = SyncedMessageParticipant(
      id: "mock-participant-expired",
      displayName: "Expired Conversation",
      isContactNameResolved: true
    )
    let oldMessage = mockMessage(
      id: "mock-message-expired-only",
      conversationID: "mock-conversation-expired-only",
      participant: oldParticipant,
      body: "This conversation is outside the rolling window.",
      sentAt: referenceDate.addingTimeInterval(-20 * 24 * 60 * 60),
      isFromMe: false,
      isRead: false
    )

    var rawMessages = averyMessages + mayaMessages + groupMessages + [oldMessage]
    // An intentional repeated source row exercises identity-based deduplication.
    rawMessages.append(averyMessages[3])
    let messages = rawMessages.filter { $0.sentAt >= cutoff }
    let includedConversationIDs = Set(messages.map(\.conversationID))

    let conversations = [
      mockConversation(
        id: "mock-conversation-avery",
        displayName: "Avery Chen",
        participants: [avery],
        latest: averyMessages[4],
        awaitingReplyMessageID: averyMessages[4].id
      ),
      mockConversation(
        id: "mock-conversation-maya",
        displayName: "Maya Ortiz",
        participants: [maya],
        latest: mayaMessages[2],
        awaitingReplyMessageID: mayaMessages[2].id
      ),
      mockConversation(
        id: "mock-conversation-weekend",
        displayName: "Weekend Plans",
        participants: [jordan, sam],
        latest: groupMessages[2],
        isGroup: true
      ),
      mockConversation(
        id: "mock-conversation-expired-only",
        displayName: "Expired Conversation",
        participants: [oldParticipant],
        latest: oldMessage
      ),
      // An intentional repeated conversation exercises the same dedup path.
      mockConversation(
        id: "mock-conversation-avery",
        displayName: "Avery Chen",
        participants: [avery],
        latest: averyMessages[4],
        awaitingReplyMessageID: averyMessages[4].id
      ),
    ].filter { includedConversationIDs.contains($0.id) }

    let readStates = [
      SyncedMessageReadState(
        id: "mock-conversation-avery",
        readThroughMessageID: "mock-message-avery-3",
        readThroughDate: averyMessages[3].sentAt,
        latestKnownMessageDate: averyMessages[4].sentAt,
        updatedAt: averyMessages[4].sentAt,
        sourceDeviceID: sourceDeviceID,
        deletedAt: nil
      ),
      SyncedMessageReadState(
        id: "mock-conversation-maya",
        readThroughMessageID: "mock-message-maya-3",
        readThroughDate: mayaMessages[2].sentAt,
        latestKnownMessageDate: mayaMessages[2].sentAt,
        updatedAt: mayaMessages[2].sentAt,
        sourceDeviceID: sourceDeviceID,
        deletedAt: nil
      ),
      SyncedMessageReadState(
        id: "mock-conversation-weekend",
        readThroughMessageID: "mock-message-weekend-2",
        readThroughDate: groupMessages[1].sentAt,
        latestKnownMessageDate: groupMessages[2].sentAt,
        updatedAt: groupMessages[2].sentAt,
        sourceDeviceID: sourceDeviceID,
        deletedAt: nil
      ),
    ].filter { includedConversationIDs.contains($0.id) }

    return MessageProviderBatch(
      conversations: conversations,
      messages: messages,
      readStates: readStates,
      isFullSnapshot: true
    )
  }

  private static func liveIncomingUpdate(sentAt: Date) -> MessageProviderBatch {
    let participant = SyncedMessageParticipant(
      id: "mock-participant-avery",
      displayName: "Avery Chen",
      isContactNameResolved: true,
      replyAddress: "+15555550101"
    )
    let message = mockMessage(
      id: "mock-message-avery-live-1",
      conversationID: "mock-conversation-avery",
      participant: participant,
      body: "One more thing: the café is right beside the east entrance.",
      sentAt: sentAt,
      isFromMe: false,
      isRead: false
    )
    let conversation = mockConversation(
      id: "mock-conversation-avery",
      displayName: "Avery Chen",
      participants: [participant],
      latest: message,
      awaitingReplyMessageID: message.id
    )
    let readState = SyncedMessageReadState(
      id: conversation.id,
      readThroughMessageID: "mock-message-avery-3",
      readThroughDate: sentAt.addingTimeInterval(-7 * 60),
      latestKnownMessageDate: sentAt,
      updatedAt: sentAt,
      sourceDeviceID: sourceDeviceID,
      deletedAt: nil
    )
    return MessageProviderBatch(
      conversations: [conversation],
      messages: [message, message],
      readStates: [readState],
      isFullSnapshot: false
    )
  }

  private static func mockConversation(
    id: String,
    displayName: String,
    participants: [SyncedMessageParticipant],
    latest: SyncedMessage,
    awaitingReplyMessageID: String? = nil,
    isGroup: Bool = false
  ) -> SyncedMessageConversation {
    SyncedMessageConversation(
      id: id,
      displayName: displayName,
      participants: participants,
      isGroup: isGroup,
      serviceName: "iMessage",
      latestMessageID: latest.id,
      latestMessageDate: latest.sentAt,
      latestPreview: preview(latest.body),
      awaitingReplyMessageID: awaitingReplyMessageID,
      updatedAt: latest.updatedAt,
      deletedAt: nil
    )
  }

  private static func mockMessage(
    id: String,
    conversationID: String,
    participant: SyncedMessageParticipant,
    body: String,
    sentAt: Date,
    isFromMe: Bool,
    isRead: Bool
  ) -> SyncedMessage {
    SyncedMessage(
      id: id,
      conversationID: conversationID,
      senderID: isFromMe ? selfParticipantID : participant.id,
      senderDisplayName: isFromMe ? "You" : participant.displayName,
      isFromMe: isFromMe,
      body: body,
      sentAt: sentAt,
      sourceReadAt: isRead ? sentAt : nil,
      updatedAt: sentAt,
      deletedAt: nil
    )
  }
}

final class LocalMacMessagesProvider: MacMessageProviding, @unchecked Sendable {
  private static let sourceDeviceID = "local-mac-messages"
  fileprivate static let permissionMessage =
    "Full Disk Access is a broad macOS permission that includes Messages data. Add iAgent in System Settings > Privacy & Security > Full Disk Access, then relaunch iAgent."

  private let databaseURL: URL
  private let pollingInterval: Duration
  private let snapshotLoadObserver: (@Sendable () -> Void)?
  private let contactNameResolver: any MessageContactNameResolving
  private let includesReplyAddresses: Bool

  var configuredDatabaseURL: URL { databaseURL }

  init(
    databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Messages/chat.db"),
    pollingInterval: Duration = .milliseconds(1_500),
    snapshotLoadObserver: (@Sendable () -> Void)? = nil,
    contactNameResolver: any MessageContactNameResolving = ContactsMessageNameResolver(),
    includesReplyAddresses: Bool = false
  ) {
    self.databaseURL = databaseURL
    self.pollingInterval = pollingInterval
    self.snapshotLoadObserver = snapshotLoadObserver
    self.contactNameResolver = contactNameResolver
    self.includesReplyAddresses = includesReplyAddresses
  }

  func authorizationStatus() async -> MessageProviderAccessState {
    let databaseURL = databaseURL
    return await Task.detached(priority: .utility) {
      Self.inspectAccess(to: databaseURL)
    }.value
  }

  func backfill(since cutoff: Date) async throws -> MessageProviderBatch {
    let databaseURL = databaseURL
    let snapshotLoadObserver = snapshotLoadObserver
    let contactNameResolver = contactNameResolver
    let includesReplyAddresses = includesReplyAddresses
    let effectiveCutoff = max(
      cutoff,
      MessageSyncWindow.cutoff(referenceDate: Date())
    )
    return try await Task.detached(priority: .utility) {
      snapshotLoadObserver?()
      return try Self.loadSnapshot(
        from: databaseURL,
        since: effectiveCutoff,
        contactNameResolver: contactNameResolver,
        includesReplyAddresses: includesReplyAddresses
      )
    }.value
  }

  /// Resolves the routing data for one explicit user action without waiting
  /// for the full inbox snapshot to be persisted and synchronized. The
  /// address remains provider-authored; display names and opaque IDs are never
  /// treated as destinations.
  func replyRecipients(
    for conversationID: String,
    since cutoff: Date
  ) async throws -> [MessageReplyRecipient] {
    let databaseURL = databaseURL
    let contactNameResolver = contactNameResolver
    let effectiveCutoff = max(
      cutoff,
      MessageSyncWindow.cutoff(referenceDate: Date())
    )
    return try await Task.detached(priority: .userInitiated) {
      let snapshot = try Self.loadSnapshot(
        from: databaseURL,
        since: effectiveCutoff,
        contactNameResolver: contactNameResolver,
        includesReplyAddresses: true
      )
      guard let conversation = snapshot.conversations.first(where: { $0.id == conversationID }),
            !conversation.isGroup
      else { return [] }
      return conversation.participants.compactMap(MessageReplyRecipient.init(participant:))
    }.value
  }

  func updates(since cutoff: Date) -> AsyncThrowingStream<MessageProviderBatch, Error> {
    let databaseURL = databaseURL
    let pollingInterval = pollingInterval
    let snapshotLoadObserver = snapshotLoadObserver
    let contactNameResolver = contactNameResolver
    let includesReplyAddresses = includesReplyAddresses

    return AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .utility) {
        await contactNameResolver.requestAuthorizationIfNeeded()
        var previous: MessageProviderBatch?
        var previousSourceSignature: MessagesSourceSignature?
        var previousContactGeneration: UInt64?
        var nextRetentionBoundary: Date?

        while !Task.isCancelled {
          let now = Date()
          let effectiveCutoff = max(
            cutoff,
            MessageSyncWindow.cutoff(referenceDate: now)
          )
          do {
            let signatureBeforeLoad = try Self.sourceSignature(for: databaseURL)
            let contactGenerationBeforeLoad = contactNameResolver.changeGeneration
            let retentionIsDue = nextRetentionBoundary.map { now > $0 } ?? false
            let shouldReload = previous == nil
              || signatureBeforeLoad != previousSourceSignature
              || contactGenerationBeforeLoad != previousContactGeneration
              || retentionIsDue

            if shouldReload {
              snapshotLoadObserver?()
              let snapshot = try Self.loadSnapshot(
                from: databaseURL,
                since: effectiveCutoff,
                contactNameResolver: contactNameResolver,
                includesReplyAddresses: includesReplyAddresses
              )
              let signatureAfterLoad = try Self.sourceSignature(for: databaseURL)
              let contactGenerationAfterLoad = contactNameResolver.changeGeneration
              if let previous {
                let delta = Self.delta(from: previous, to: snapshot)
                if !delta.isEmptyDelta {
                  continuation.yield(delta)
                }
              } else {
                // Re-emitting one authoritative snapshot closes the race between
                // a caller's backfill and its subscription being installed.
                continuation.yield(snapshot)
              }
              previous = snapshot
              nextRetentionBoundary = Self.nextRetentionBoundary(
                after: now,
                messages: snapshot.messages
              )
              // If SQLite changed while the snapshot transaction was in flight,
              // force one more read on the next fast poll rather than accepting a
              // signature that may describe content newer than the snapshot.
              let contentFilesWereStable =
                signatureBeforeLoad.database == signatureAfterLoad.database
                && signatureBeforeLoad.writeAheadLog == signatureAfterLoad.writeAheadLog
              previousSourceSignature = contentFilesWereStable
                ? signatureAfterLoad
                : nil
              previousContactGeneration = contactGenerationBeforeLoad == contactGenerationAfterLoad
                ? contactGenerationAfterLoad
                : nil
            }
          } catch {
            continuation.finish(throwing: error)
            return
          }

          do {
            try await Task.sleep(for: pollingInterval)
          } catch is CancellationError {
            continuation.finish()
            return
          } catch {
            continuation.finish(throwing: error)
            return
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  private struct MessagesSourceSignature: Equatable, Sendable {
    let database: SourceFileSignature
    let writeAheadLog: SourceFileSignature
    let sharedMemory: SourceFileSignature
  }

  private struct SourceFileSignature: Equatable, Sendable {
    let exists: Bool
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    static let missing = SourceFileSignature(
      exists: false,
      device: 0,
      inode: 0,
      size: 0,
      modifiedSeconds: 0,
      modifiedNanoseconds: 0,
      changedSeconds: 0,
      changedNanoseconds: 0
    )
  }

  private static func sourceSignature(
    for databaseURL: URL
  ) throws -> MessagesSourceSignature {
    MessagesSourceSignature(
      database: try sourceFileSignature(at: databaseURL, required: true),
      writeAheadLog: try sourceFileSignature(
        at: URL(fileURLWithPath: databaseURL.path + "-wal"),
        required: false
      ),
      sharedMemory: try sourceFileSignature(
        at: URL(fileURLWithPath: databaseURL.path + "-shm"),
        required: false
      )
    )
  }

  private static func sourceFileSignature(
    at fileURL: URL,
    required: Bool
  ) throws -> SourceFileSignature {
    var metadata = stat()
    let result = fileURL.path.withCString { path in
      Darwin.lstat(path, &metadata)
    }
    guard result == 0 else {
      if !required, errno == ENOENT {
        return .missing
      }
      if errno == EACCES || errno == EPERM {
        throw LocalMessagesProviderError.permissionRequired
      }
      if required, errno == ENOENT {
        throw LocalMessagesProviderError.readFailed
      }
      throw LocalMessagesProviderError.readFailed
    }
    return SourceFileSignature(
      exists: true,
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      size: metadata.st_size,
      modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
      changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
    )
  }

  private static func nextRetentionBoundary(
    after referenceDate: Date,
    messages: [SyncedMessage]
  ) -> Date? {
    messages.lazy
      .map { $0.sentAt.addingTimeInterval(MessageSyncWindow.duration) }
      .filter { $0 >= referenceDate }
      .min()
  }

  private static func inspectAccess(to databaseURL: URL) -> MessageProviderAccessState {
    let fileManager = FileManager.default
    var metadata = stat()
    errno = 0
    let probeResult = databaseURL.path.withCString { path in
      Darwin.lstat(path, &metadata)
    }
    if probeResult != 0 {
      return accessStateForFailedDatabaseProbe(
        errorNumber: errno,
        directoryIsReadable: fileManager.isReadableFile(
          atPath: databaseURL.deletingLastPathComponent().path
        )
      )
    }
    guard fileManager.isReadableFile(atPath: databaseURL.path) else {
      return .permissionRequired(permissionMessage)
    }

    do {
      let database = try openReadOnlyDatabase(at: databaseURL)
      defer { sqlite3_close(database) }
      _ = try schema(in: database)
      return .authorized
    } catch let error as LocalMessagesProviderError {
      return error.accessState
    } catch {
      return .failed("The local Messages source could not be inspected safely.")
    }
  }

  static func accessStateForFailedDatabaseProbe(
    errorNumber: Int32,
    directoryIsReadable: Bool
  ) -> MessageProviderAccessState {
    if errorNumber == EACCES || errorNumber == EPERM {
      return .permissionRequired(permissionMessage)
    }
    if errorNumber == ENOENT {
      if !directoryIsReadable {
        return .permissionRequired(permissionMessage)
      }
      return .failed(
        "The local Messages database was not found. Open Messages on this Mac and try again."
      )
    }
    return .failed("The local Messages source could not be inspected safely.")
  }

  private static func loadSnapshot(
    from databaseURL: URL,
    since cutoff: Date,
    contactNameResolver: any MessageContactNameResolving,
    includesReplyAddresses: Bool
  ) throws -> MessageProviderBatch {
    guard FileManager.default.isReadableFile(atPath: databaseURL.path) else {
      throw LocalMessagesProviderError.permissionRequired
    }

    let database = try openReadOnlyDatabase(at: databaseURL)
    defer { sqlite3_close(database) }
    let schema = try schema(in: database)

    guard sqlite3_exec(database, "BEGIN DEFERRED TRANSACTION", nil, nil, nil) == SQLITE_OK else {
      throw LocalMessagesProviderError.readFailed
    }
    defer {
      // Ending a read transaction with ROLLBACK performs no source mutation.
      _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
    }

    let loaded = try loadMessages(
      from: database,
      schema: schema,
      since: cutoff,
      contactNameResolver: contactNameResolver,
      includesReplyAddresses: includesReplyAddresses
    )
    return MessageProviderBatch(
      conversations: loaded.conversations,
      messages: loaded.messages,
      readStates: loaded.readStates,
      isFullSnapshot: true
    )
  }

  private static func openReadOnlyDatabase(at databaseURL: URL) throws -> OpaquePointer {
    var database: OpaquePointer?
    let flags = Int32(SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
    let result = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
    guard result == SQLITE_OK, let database else {
      if let database {
        sqlite3_close(database)
      }
      if result == SQLITE_CANTOPEN || result == SQLITE_AUTH || result == SQLITE_PERM {
        throw LocalMessagesProviderError.permissionRequired
      }
      throw LocalMessagesProviderError.readFailed
    }

    sqlite3_busy_timeout(database, 1_000)
    guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
      sqlite3_close(database)
      throw LocalMessagesProviderError.readFailed
    }
    return database
  }

  private struct MessagesSchema: Sendable {
    let messageColumns: Set<String>
    let chatColumns: Set<String>
    let handleColumns: Set<String>
    let hasHandleTable: Bool
    let hasChatHandleJoin: Bool
  }

  private static func schema(in database: OpaquePointer) throws -> MessagesSchema {
    let messageColumns = try columns(in: "message", database: database)
    let chatColumns = try columns(in: "chat", database: database)
    let joinColumns = try columns(in: "chat_message_join", database: database)
    let handleColumns = (try? columns(in: "handle", database: database)) ?? []
    let chatHandleJoinColumns = (try? columns(in: "chat_handle_join", database: database)) ?? []

    guard messageColumns.contains("date"),
      messageColumns.contains("is_from_me"),
      chatColumns.contains("guid") || chatColumns.contains("chat_identifier"),
      joinColumns.contains("chat_id"),
      joinColumns.contains("message_id")
    else {
      throw LocalMessagesProviderError.unsupportedSchema
    }

    return MessagesSchema(
      messageColumns: messageColumns,
      chatColumns: chatColumns,
      handleColumns: handleColumns,
      hasHandleTable: !handleColumns.isEmpty,
      hasChatHandleJoin: chatHandleJoinColumns.contains("chat_id")
        && chatHandleJoinColumns.contains("handle_id")
    )
  }

  private static func columns(
    in table: String,
    database: OpaquePointer
  ) throws -> Set<String> {
    // Table names are selected only from the fixed calls above; no source value is
    // interpolated into SQL.
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw LocalMessagesProviderError.unsupportedSchema
    }
    defer { sqlite3_finalize(statement) }

    var result = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
      let name = string(statement, column: 1).lowercased()
      if !name.isEmpty {
        result.insert(name)
      }
    }
    guard !result.isEmpty else {
      throw LocalMessagesProviderError.unsupportedSchema
    }
    return result
  }

  private struct LoadedMessages {
    let conversations: [SyncedMessageConversation]
    let messages: [SyncedMessage]
    let readStates: [SyncedMessageReadState]
  }

  private struct ConversationAccumulator {
    let conversationID: String
    let sourceDisplayName: String
    let sourceServiceName: String
    let sourceParticipantHandle: String
    let style: Int
    var participantsByID: [String: SyncedMessageParticipant] = [:]
    var participantDisplayPrioritiesByID: [String: Int] = [:]
    var messages: [SyncedMessage] = []
    var meaningfulTextEvents: [MeaningfulTextEvent] = []
  }

  private struct MeaningfulTextEvent {
    let messageID: String
    let sentAt: Date
    let sourceRowID: Int64
    let isFromMe: Bool
  }

  private struct ParticipantPresentation {
    let displayName: String
    let priority: Int
    let replyAddress: String?

    var isContactNameResolved: Bool { priority == 0 }
  }

  private struct LoadedParticipant {
    let participant: SyncedMessageParticipant
    let displayPriority: Int
  }

  private static func loadMessages(
    from database: OpaquePointer,
    schema: MessagesSchema,
    since cutoff: Date,
    contactNameResolver: any MessageContactNameResolving,
    includesReplyAddresses: Bool
  ) throws -> LoadedMessages {
    let message = schema.messageColumns
    let chat = schema.chatColumns
    let handle = schema.handleColumns
    let hasHandleJoin = schema.hasHandleTable && message.contains("handle_id")

    func messageExpression(_ column: String, fallback: String) -> String {
      message.contains(column) ? "m.\(column)" : fallback
    }

    func chatExpression(_ column: String, fallback: String) -> String {
      chat.contains(column) ? "c.\(column)" : fallback
    }

    func handleExpression(_ column: String, fallback: String) -> String {
      if column == "ROWID", hasHandleJoin {
        return "h.ROWID"
      }
      return hasHandleJoin && handle.contains(column) ? "h.\(column)" : fallback
    }

    let handleJoin =
      hasHandleJoin
      ? "LEFT JOIN handle h ON h.ROWID = m.handle_id"
      : ""
    let attributedBodyExpression = message.contains("attributedbody")
      ? "CASE WHEN length(m.attributedBody) BETWEEN 1 AND \(MessageAttributedBodyDecoder.maximumArchiveBytes) THEN m.attributedBody ELSE NULL END"
      : "NULL"
    let query = """
      SELECT
        c.ROWID,
        COALESCE(\(chatExpression("guid", fallback: "''")), ''),
        COALESCE(\(chatExpression("chat_identifier", fallback: "''")), ''),
        COALESCE(\(chatExpression("display_name", fallback: "''")), ''),
        COALESCE(\(chatExpression("service_name", fallback: "''")), ''),
        COALESCE(\(chatExpression("style", fallback: "0")), 0),
        m.ROWID,
        COALESCE(\(messageExpression("guid", fallback: "''")), ''),
        COALESCE(\(messageExpression("text", fallback: "''")), ''),
        \(attributedBodyExpression),
        COALESCE(\(messageExpression("cache_has_attachments", fallback: "0")), 0),
        COALESCE(\(messageExpression("is_from_me", fallback: "0")), 0),
        m.date,
        COALESCE(\(messageExpression("date_read", fallback: "0")), 0),
        COALESCE(\(messageExpression("is_read", fallback: "0")), 0),
        COALESCE(\(messageExpression("service", fallback: "''")), ''),
        COALESCE(\(handleExpression("ROWID", fallback: "0")), 0),
        COALESCE(\(handleExpression("id", fallback: "''")), ''),
        COALESCE(\(handleExpression("service", fallback: "''")), ''),
        COALESCE(\(messageExpression("associated_message_guid", fallback: "''")), ''),
        COALESCE(\(messageExpression("associated_message_type", fallback: "0")), 0),
        COALESCE(\(messageExpression("is_system_message", fallback: "0")), 0),
        COALESCE(\(messageExpression("is_service_message", fallback: "0")), 0),
        COALESCE(\(messageExpression("item_type", fallback: "0")), 0),
        COALESCE(\(messageExpression("group_action_type", fallback: "0")), 0),
        COALESCE(\(messageExpression("message_action_type", fallback: "0")), 0),
        COALESCE(\(messageExpression("balloon_bundle_id", fallback: "''")), '')
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      \(handleJoin)
      WHERE m.date >= ?
      ORDER BY m.date ASC, m.ROWID ASC
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw LocalMessagesProviderError.unsupportedSchema
    }
    defer { sqlite3_finalize(statement) }

    let cutoffNanoseconds = Int64(
      (max(0, cutoff.timeIntervalSinceReferenceDate) * 1_000_000_000).rounded(.up)
    )
    sqlite3_bind_int64(statement, 1, cutoffNanoseconds)

    var accumulators: [Int64: ConversationAccumulator] = [:]
    var presentationsByHandle: [String: ParticipantPresentation] = [:]

    func participantPresentation(for rawHandle: String) -> ParticipantPresentation {
      let handle = rawHandle.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !handle.isEmpty else {
        return ParticipantPresentation(displayName: "Contact", priority: 3, replyAddress: nil)
      }
      if let cached = presentationsByHandle[handle] {
        return cached
      }
      let resolved = contactNameResolver.displayName(for: handle).flatMap {
        let safe = safeDisplayName($0, disallowing: [handle])
        return safe.isEmpty ? nil : safe
      }
      let replyAddress = includesReplyAddresses
        ? MessageReplyAddress(rawValue: handle)?.value
        : nil
      let presentation: ParticipantPresentation
      if let resolved {
        presentation = ParticipantPresentation(
          displayName: resolved,
          priority: 0,
          replyAddress: replyAddress
        )
      } else if let identifier = MessageContactIdentifier.normalized(handle) {
        switch identifier {
        case .phone:
          presentation = ParticipantPresentation(
            displayName: identifier.privacySafeDisplayValue(source: handle),
            priority: 1,
            replyAddress: replyAddress
          )
        case .email:
          presentation = ParticipantPresentation(
            displayName: identifier.privacySafeDisplayValue(source: handle),
            priority: 2,
            replyAddress: replyAddress
          )
        }
      } else {
        presentation = ParticipantPresentation(
          displayName: "Contact",
          priority: 3,
          replyAddress: nil
        )
      }
      presentationsByHandle[handle] = presentation
      return presentation
    }

    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw LocalMessagesProviderError.readFailed
      }

      let chatRowID = sqlite3_column_int64(statement, 0)
      let chatGUID = string(statement, column: 1)
      let chatIdentifier = string(statement, column: 2)
      let chatDisplayName = string(statement, column: 3)
      let chatService = string(statement, column: 4)
      let chatStyle = Int(sqlite3_column_int(statement, 5))
      let messageRowID = sqlite3_column_int64(statement, 6)
      let messageGUID = string(statement, column: 7)
      let plainBody = string(statement, column: 8)
      let hasAttachments = sqlite3_column_int(statement, 10) != 0
      let actualBody = firstNonempty(
        plainBody,
        MessageAttributedBodyDecoder.decode(data(statement, column: 9)) ?? ""
      )
      let body = firstNonempty(
        actualBody,
        hasAttachments ? "Attachment" : ""
      )
      let isFromMe = sqlite3_column_int(statement, 11) != 0
      let sentNanoseconds = sqlite3_column_int64(statement, 12)
      let readNanoseconds = sqlite3_column_int64(statement, 13)
      let isRead = sqlite3_column_int(statement, 14) != 0
      let messageService = string(statement, column: 15)
      let handleRowID = sqlite3_column_int64(statement, 16)
      let rawHandle = string(statement, column: 17)
      let handleService = string(statement, column: 18)
      let associatedMessageGUID = string(statement, column: 19)
      let associatedMessageType = sqlite3_column_int64(statement, 20)
      let isSystemMessage = sqlite3_column_int(statement, 21) != 0
      let isServiceMessage = sqlite3_column_int(statement, 22) != 0
      let itemType = sqlite3_column_int64(statement, 23)
      let groupActionType = sqlite3_column_int64(statement, 24)
      let messageActionType = sqlite3_column_int64(statement, 25)
      let balloonBundleID = string(statement, column: 26)
      let isMeaningfulText = !actualBody.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
        && associatedMessageGUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && associatedMessageType == 0
        && !isSystemMessage
        && !isServiceMessage
        && itemType == 0
        && groupActionType == 0
        && messageActionType == 0
        && balloonBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let rawParticipantHandle = rawHandle.isEmpty && chatStyle != 43
        ? chatIdentifier
        : rawHandle

      // SQL already applies the inclusive integer-nanosecond cutoff. Preserve the
      // exact boundary Date instead of letting an Int64 -> Double round trip make
      // an eligible boundary row appear a fraction before the requested instant.
      let sentAt = sentNanoseconds == cutoffNanoseconds
        ? cutoff
        : date(fromAppleNanoseconds: sentNanoseconds)

      let rawChatIdentity = firstNonempty(
        chatGUID,
        chatIdentifier,
        "row:\(chatRowID)"
      )
      let conversationID = namespacedID("conversation", raw: rawChatIdentity)
      let rawMessageIdentity = firstNonempty(messageGUID, "row:\(messageRowID)")
      let messageID = namespacedID("message", raw: rawMessageIdentity)
      let senderID: String
      let senderDisplayName: String
      let senderDisplayPriority: Int
      if isFromMe {
        senderID = namespacedID("participant", raw: "self")
        senderDisplayName = "You"
        senderDisplayPriority = 0
      } else {
        let rawSenderIdentity = firstNonempty(rawParticipantHandle, "row:\(handleRowID)")
        senderID = namespacedID("participant", raw: rawSenderIdentity)
        let presentation = participantPresentation(for: rawParticipantHandle)
        senderDisplayName = presentation.displayName
        senderDisplayPriority = presentation.priority
      }

      let sourceReadAt: Date?
      if readNanoseconds > 0 {
        sourceReadAt = date(fromAppleNanoseconds: readNanoseconds)
      } else if !isFromMe, isRead {
        sourceReadAt = sentAt
      } else {
        sourceReadAt = nil
      }
      let updatedAt = max(sentAt, sourceReadAt ?? sentAt)
      let syncedMessage = SyncedMessage(
        id: messageID,
        conversationID: conversationID,
        senderID: senderID,
        senderDisplayName: senderDisplayName,
        isFromMe: isFromMe,
        body: body,
        sentAt: sentAt,
        sourceReadAt: sourceReadAt,
        updatedAt: updatedAt,
        deletedAt: nil
      )

      var accumulator =
        accumulators[chatRowID]
        ?? ConversationAccumulator(
          conversationID: conversationID,
          sourceDisplayName: safeDisplayName(
            chatDisplayName,
            disallowing: [chatIdentifier, rawHandle]
          ),
          sourceServiceName: firstNonempty(chatService, messageService, handleService, "iMessage"),
          sourceParticipantHandle: rawParticipantHandle,
          style: chatStyle
        )
      accumulator.messages.append(syncedMessage)
      if isMeaningfulText {
        accumulator.meaningfulTextEvents.append(
          MeaningfulTextEvent(
            messageID: messageID,
            sentAt: sentAt,
            sourceRowID: messageRowID,
            isFromMe: isFromMe
          )
        )
      }
      if !isFromMe {
        accumulator.participantsByID[senderID] = SyncedMessageParticipant(
          id: senderID,
          displayName: senderDisplayName,
          isContactNameResolved: senderDisplayPriority == 0,
          replyAddress: participantPresentation(for: rawParticipantHandle).replyAddress
        )
        accumulator.participantDisplayPrioritiesByID[senderID] = senderDisplayPriority
      }
      accumulators[chatRowID] = accumulator
    }

    if schema.hasChatHandleJoin, schema.hasHandleTable {
      for chatRowID in accumulators.keys.sorted() {
        let participants = try loadParticipants(
          for: chatRowID,
          from: database,
          participantPresentation: participantPresentation
        )
        for loadedParticipant in participants {
          let participant = loadedParticipant.participant
          accumulators[chatRowID]?.participantsByID[participant.id] = participant
          accumulators[chatRowID]?.participantDisplayPrioritiesByID[participant.id] =
            loadedParticipant.displayPriority
        }
      }
    }

    var conversations: [SyncedMessageConversation] = []
    var messages: [SyncedMessage] = []
    var readStates: [SyncedMessageReadState] = []
    for accumulator in accumulators.values {
      let deduplicatedMessages = MessageProviderBatch(
        messages: accumulator.messages,
        isFullSnapshot: false
      ).messages
      guard
        let latest = deduplicatedMessages.max(by: {
          $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt < $1.sentAt
        })
      else {
        continue
      }

      var participants = Array(accumulator.participantsByID.values)
        .sorted {
          let leftPriority = accumulator.participantDisplayPrioritiesByID[$0.id] ?? 3
          let rightPriority = accumulator.participantDisplayPrioritiesByID[$1.id] ?? 3
          if leftPriority != rightPriority {
            return leftPriority < rightPriority
          }
          let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
          return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
      if participants.isEmpty {
        let presentation = participantPresentation(for: accumulator.sourceParticipantHandle)
        let fallbackID = namespacedID(
          "participant",
          raw: firstNonempty(
            accumulator.sourceParticipantHandle,
            "conversation:\(accumulator.conversationID)"
          )
        )
        participants = [
          SyncedMessageParticipant(
            id: fallbackID,
            displayName: presentation.displayName,
            isContactNameResolved: presentation.isContactNameResolved,
            replyAddress: presentation.replyAddress
          )
        ]
      }

      let isGroup = accumulator.style == 43
        || (accumulator.style != 45 && participants.count > 1)
      let displayName = conversationDisplayName(
        sourceDisplayName: accumulator.sourceDisplayName,
        participants: participants,
        isGroup: isGroup
      )
      let latestMeaningfulTextEvent = accumulator.meaningfulTextEvents.max { left, right in
        if left.sentAt == right.sentAt {
          return left.sourceRowID < right.sourceRowID
        }
        return left.sentAt < right.sentAt
      }
      let awaitingReplyMessageID = isGroup ? nil : latestMeaningfulTextEvent.flatMap { event in
        event.isFromMe ? nil : event.messageID
      }
      conversations.append(
        SyncedMessageConversation(
          id: accumulator.conversationID,
          displayName: displayName,
          participants: participants,
          isGroup: isGroup,
          serviceName: accumulator.sourceServiceName,
          latestMessageID: latest.id,
          latestMessageDate: latest.sentAt,
          latestPreview: preview(latest.body),
          awaitingReplyMessageID: awaitingReplyMessageID,
          updatedAt: latest.updatedAt,
          deletedAt: nil
        )
      )
      messages.append(contentsOf: deduplicatedMessages)

      let latestReadIncoming =
        deduplicatedMessages
        .filter { !$0.isFromMe && $0.sourceReadAt != nil }
        .max {
          $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt < $1.sentAt
        }
      readStates.append(
        SyncedMessageReadState(
          id: accumulator.conversationID,
          readThroughMessageID: latestReadIncoming?.id,
          readThroughDate: latestReadIncoming?.sentAt,
          latestKnownMessageDate: latest.sentAt,
          updatedAt: max(latest.updatedAt, latestReadIncoming?.sourceReadAt ?? .distantPast),
          sourceDeviceID: sourceDeviceID,
          deletedAt: nil
        )
      )
    }

    return LoadedMessages(
      conversations: conversations,
      messages: messages,
      readStates: readStates
    )
  }

  private static func loadParticipants(
    for chatRowID: Int64,
    from database: OpaquePointer,
    participantPresentation: (String) -> ParticipantPresentation
  ) throws -> [LoadedParticipant] {
    let query = """
      SELECT h.ROWID, COALESCE(h.id, '')
      FROM chat_handle_join chj
      JOIN handle h ON h.ROWID = chj.handle_id
      WHERE chj.chat_id = ?
      ORDER BY h.ROWID ASC
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw LocalMessagesProviderError.unsupportedSchema
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, chatRowID)

    var participants: [LoadedParticipant] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw LocalMessagesProviderError.readFailed
      }
      let rowID = sqlite3_column_int64(statement, 0)
      let rawHandle = string(statement, column: 1)
      let rawIdentity = firstNonempty(rawHandle, "row:\(rowID)")
      let presentation = participantPresentation(rawHandle)
      participants.append(
        LoadedParticipant(
          participant: SyncedMessageParticipant(
            id: namespacedID("participant", raw: rawIdentity),
            displayName: presentation.displayName,
            isContactNameResolved: presentation.isContactNameResolved,
            replyAddress: presentation.replyAddress
          ),
          displayPriority: presentation.priority
        )
      )
    }
    return participants
  }

  private static func delta(
    from old: MessageProviderBatch,
    to new: MessageProviderBatch
  ) -> MessageProviderBatch {
    let oldConversations = Dictionary(uniqueKeysWithValues: old.conversations.map { ($0.id, $0) })
    let newConversations = Dictionary(uniqueKeysWithValues: new.conversations.map { ($0.id, $0) })
    let oldMessages = Dictionary(uniqueKeysWithValues: old.messages.map { ($0.id, $0) })
    let newMessages = Dictionary(uniqueKeysWithValues: new.messages.map { ($0.id, $0) })
    let oldReadStates = Dictionary(uniqueKeysWithValues: old.readStates.map { ($0.id, $0) })

    let conversations = new.conversations.filter { oldConversations[$0.id] != $0 }
    let messages = new.messages.filter { oldMessages[$0.id] != $0 }
    let readStates = new.readStates.filter { oldReadStates[$0.id] != $0 }
    return MessageProviderBatch(
      conversations: conversations,
      messages: messages,
      readStates: readStates,
      removedConversationIDs: Set(oldConversations.keys).subtracting(newConversations.keys),
      removedMessageIDs: Set(oldMessages.keys).subtracting(newMessages.keys),
      isFullSnapshot: false
    )
  }

  private static func date(fromAppleNanoseconds value: Int64) -> Date {
    Date(timeIntervalSinceReferenceDate: Double(value) / 1_000_000_000)
  }

  private static func namespacedID(_ namespace: String, raw: String) -> String {
    let digest = SHA256.hash(data: Data("iagent-messages|\(namespace)|\(raw)".utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "macmsg-\(namespace)-\(hex)"
  }

  private static func safeDisplayName(
    _ candidate: String,
    disallowing rawIdentifiers: [String]
  ) -> String {
    let displayName = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !displayName.isEmpty else { return "" }
    let normalized = displayName.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: .current
    )
    let normalizedIdentifier = MessageContactIdentifier.normalized(displayName)
    let isRawIdentifier = rawIdentifiers.contains { value in
      let rawValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if let normalizedIdentifier,
         MessageContactIdentifier.normalized(rawValue) == normalizedIdentifier
      {
        return true
      }
      return rawValue.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      ) == normalized
    }
    return isRawIdentifier ? "" : displayName
  }

  private static func conversationDisplayName(
    sourceDisplayName: String,
    participants: [SyncedMessageParticipant],
    isGroup: Bool
  ) -> String {
    if !sourceDisplayName.isEmpty {
      return sourceDisplayName
    }
    let resolvedNames = participants.map(\.displayName).filter { $0 != "Contact" }
      .reduce(into: [String]()) { names, name in
        if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
          names.append(name)
        }
      }
    if isGroup {
      guard !resolvedNames.isEmpty else { return "Group" }
      let visible = resolvedNames.prefix(3).joined(separator: ", ")
      let remaining = resolvedNames.count - min(3, resolvedNames.count)
      return remaining > 0 ? "\(visible) +\(remaining)" : visible
    }
    return resolvedNames.first ?? participants.first?.displayName ?? "Contact"
  }

  private static func string(_ statement: OpaquePointer, column: Int32) -> String {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
      let bytes = sqlite3_column_text(statement, column)
    else {
      return ""
    }
    return String(cString: bytes)
  }

  private static func data(_ statement: OpaquePointer, column: Int32) -> Data? {
    guard sqlite3_column_type(statement, column) == SQLITE_BLOB else { return nil }
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0,
          count <= MessageAttributedBodyDecoder.maximumArchiveBytes,
          let bytes = sqlite3_column_blob(statement, column)
    else { return nil }
    return Data(bytes: bytes, count: count)
  }
}

private enum LocalMessagesProviderError: LocalizedError, Sendable {
  case permissionRequired
  case unsupportedSchema
  case readFailed

  var errorDescription: String? {
    switch self {
    case .permissionRequired:
      LocalMacMessagesProvider.permissionMessage
    case .unsupportedSchema:
      "This macOS Messages database layout is not supported by this version of iAgent."
    case .readFailed:
      "iAgent could not safely read the local Messages source."
    }
  }

  var accessState: MessageProviderAccessState {
    switch self {
    case .permissionRequired:
      .permissionRequired(errorDescription ?? "Full Disk Access is required.")
    case .unsupportedSchema, .readFailed:
      .failed(errorDescription ?? "Local Messages is unavailable.")
    }
  }
}

private func firstNonempty(_ values: String...) -> String {
  values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
}

private func preview(_ body: String) -> String {
  let compact =
    body
    .split(whereSeparator: { $0.isWhitespace })
    .joined(separator: " ")
  guard !compact.isEmpty else { return "Attachment" }
  return String(compact.prefix(160))
}
