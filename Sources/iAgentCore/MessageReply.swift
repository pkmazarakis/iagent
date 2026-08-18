import Foundation

/// Persists the user's explicit choice to enable a Messages handoff transport
/// for eligible one-to-one conversations. Reading an inbox never changes this
/// preference, and a missing value is off.
public enum MessageReplyPreferences {
  public static let optInKey = "messageReply.sendTransportOptIn.v1"

  public static func isEnabled(in preferences: UserDefaults = .standard) -> Bool {
    preferences.bool(forKey: optInKey)
  }

  public static func setEnabled(
    _ isEnabled: Bool,
    in preferences: UserDefaults = .standard
  ) {
    preferences.set(isEnabled, forKey: optInKey)
  }
}

/// A canonical phone number or email address that can be handed to an
/// OS-provided message composer. Arbitrary names and opaque participant IDs
/// are intentionally not accepted as routing addresses.
public struct MessageReplyAddress: Hashable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable {
    case phone
    case email
  }

  public let kind: Kind
  public let value: String

  public init?(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  public init?(rawValue: String) {
    guard let unwrapped = Self.unwrapped(rawValue) else { return nil }
    if unwrapped.contains("@") {
      guard let email = Self.canonicalEmail(unwrapped) else { return nil }
      kind = .email
      value = email
    } else {
      guard let phone = Self.canonicalPhone(unwrapped) else { return nil }
      kind = .phone
      value = phone
    }
  }

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

  private static func unwrapped(_ rawValue: String) -> String? {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 1_024 else { return nil }
    if let decoded = value.removingPercentEncoding {
      value = decoded
    }

    // Messages stores both public URI forms and chat identifiers. Only known
    // wrappers are removed; unknown schemes fail later instead of being guessed.
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
      value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value.isEmpty ? nil : value
  }

  private static func canonicalEmail(_ value: String) -> String? {
    let normalized = value.precomposedStringWithCanonicalMapping
    guard normalized.utf8.count <= 320,
          !normalized.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
              || CharacterSet.controlCharacters.contains($0)
          })
    else { return nil }

    let components = normalized.split(separator: "@", omittingEmptySubsequences: false)
    guard components.count == 2 else { return nil }
    let local = String(components[0])
    let domain = String(components[1]).lowercased()
    let localPunctuation = "!#$%&'*+-/=?^_`{|}~."
    guard !local.isEmpty,
          !domain.isEmpty,
          local.allSatisfy({
            $0.isLetter || $0.isNumber || localPunctuation.contains($0)
          }),
          domain.allSatisfy({
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "."
          }),
          !local.hasPrefix("."),
          !local.hasSuffix("."),
          !local.contains(".."),
          !domain.hasPrefix("."),
          !domain.hasSuffix("."),
          !domain.contains(".."),
          !domain.split(separator: ".", omittingEmptySubsequences: false).contains(where: {
            $0.hasPrefix("-") || $0.hasSuffix("-")
          })
    else { return nil }
    // Domain names are case-insensitive. Preserve the local part because an
    // email provider is allowed to treat its case as significant.
    return "\(local)@\(domain)"
  }

  private static func canonicalPhone(_ value: String) -> String? {
    var digits = ""
    var hasInternationalPlus = false
    var hasSeenDigit = false

    for character in value {
      if let digit = character.wholeNumberValue {
        digits.append(String(digit))
        hasSeenDigit = true
      } else if character == "+" {
        guard !hasInternationalPlus, !hasSeenDigit else { return nil }
        hasInternationalPlus = true
      } else if character.isWhitespace || "()-.".contains(character) {
        continue
      } else {
        return nil
      }
    }

    if hasInternationalPlus {
      guard !digits.hasPrefix("00"), (3...32).contains(digits.count) else { return nil }
      return "+\(digits)"
    }
    if digits.hasPrefix("00") {
      digits.removeFirst(2)
      guard (3...32).contains(digits.count) else { return nil }
      return "+\(digits)"
    }
    guard (3...32).contains(digits.count) else { return nil }
    return digits
  }
}

/// A recipient whose routing address came from the provider-authored explicit
/// reply field. Display names and opaque IDs remain presentation metadata only.
public struct MessageReplyRecipient: Identifiable, Hashable, Sendable {
  public let participantID: String
  public let displayName: String
  public let address: MessageReplyAddress

  public var id: String { participantID }

  public init?(participant: SyncedMessageParticipant) {
    guard let rawAddress = participant.replyAddress,
          let address = MessageReplyAddress(rawAddress)
    else { return nil }
    participantID = participant.id
    displayName = participant.displayName
    self.address = address
  }
}

public struct MessageReplyRequest: Equatable, Sendable {
  /// Phase 1 deliberately supports only one-to-one replies.
  public static let maximumRecipientCount = 1
  public static let maximumBodyCharacterCount = 4_000

  public enum ValidationError: LocalizedError, Equatable, Sendable {
    case noRecipients
    case tooManyRecipients
    case blankBody
    case bodyTooLong

    public var errorDescription: String? {
      switch self {
      case .noRecipients:
        "Choose at least one valid Messages recipient."
      case .tooManyRecipients:
        "Choose only one recipient for this reply."
      case .blankBody:
        "Enter a reply before opening Messages."
      case .bodyTooLong:
        "A reply can include at most \(MessageReplyRequest.maximumBodyCharacterCount) characters."
      }
    }
  }

  public let recipients: [MessageReplyRecipient]
  public let body: String

  public init(recipients: [MessageReplyRecipient], body: String) throws {
    var seenAddresses = Set<MessageReplyAddress>()
    let uniqueRecipients = recipients.filter { recipient in
      seenAddresses.insert(recipient.address).inserted
    }
    guard !uniqueRecipients.isEmpty else { throw ValidationError.noRecipients }
    guard uniqueRecipients.count <= Self.maximumRecipientCount else {
      throw ValidationError.tooManyRecipients
    }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.blankBody
    }
    guard body.count <= Self.maximumBodyCharacterCount else {
      throw ValidationError.bodyTooLong
    }
    self.recipients = uniqueRecipients
    self.body = body
  }
}

/// Describes what happened to the OS-owned composer without claiming that a
/// message was delivered. `.sendRequested` means the user tapped Send there.
public enum MessageReplyCompletion: Equatable, Sendable {
  case cancelled
  case sendRequested
  case failed(String)
}
