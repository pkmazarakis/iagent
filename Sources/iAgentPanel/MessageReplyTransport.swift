import AppKit
import Foundation
import iAgentCore

enum MacMessageReplyService: String, Equatable, Sendable {
  case iMessage = "iMessage"
  case sms = "SMS"

  init(serviceName: String?) {
    let normalized = serviceName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    self = normalized.contains("sms") || normalized.contains("rcs") ? .sms : .iMessage
  }

  var appleScriptValue: String {
    switch self {
    case .iMessage: "imessage"
    case .sms: "sms"
    }
  }
}

enum MacMessageReplyTransportAvailability: Equatable, Sendable {
  case available
  case sendInProgress
  case unavailable(String)
}

struct MacMessageReplySendReceipt: Equatable, Sendable {
  /// A matching, newly inserted outgoing row was observed in Messages' local
  /// database after the AppleScript command returned success. This confirms
  /// that Messages recorded the send, not that the recipient received it.
  let rowID: Int64
  let guid: String?
  let service: MacMessageReplyService
}

enum MacMessageReplySendResult: Equatable, Sendable {
  /// Clear the local draft only for this result.
  case sent(MacMessageReplySendReceipt)

  /// Dispatch may have happened, or Messages accepted the command but its
  /// outgoing row could not be verified. Automatic retry is unsafe.
  case outcomeUncertain(String)

  /// Direct dispatch was proven not to have started because Automation was
  /// denied or the public AppleScript route was unavailable. The caller may
  /// offer a separate, explicit action that opens the AppKit compose fallback.
  case fallbackRequired(String)
}

struct MacMessageReplyFallbackReceipt: Equatable, Sendable {
  enum Disposition: Equatable, Sendable {
    /// AppKit accepted a request to present its compose service. This is not
    /// proof that the window appeared or that its user pressed Send.
    case composeRequested
  }

  let disposition: Disposition
  let recipientCount: Int
}

enum MacMessageReplyTransportError: LocalizedError, Equatable {
  case sendInProgress
  case serviceUnavailable
  case missingRecipient
  case tooManyRecipients
  case emptyBody
  case unsupportedRequest

  var errorDescription: String? {
    switch self {
    case .sendInProgress:
      "A message send is already in progress."
    case .serviceUnavailable:
      "Messages is not available on this Mac."
    case .missingRecipient:
      "Choose one recipient before sending."
    case .tooManyRecipients:
      "Direct replies currently support one recipient."
    case .emptyBody:
      "Write a reply before sending."
    case .unsupportedRequest:
      "Messages cannot open this reply."
    }
  }
}

@MainActor
protocol MacMessageReplyTransport: AnyObject {
  var availability: MacMessageReplyTransportAvailability { get }

  func canSendUserInitiated(
    _ request: MessageReplyRequest,
    service: MacMessageReplyService
  ) -> Bool

  /// Must be called only from an explicit user action. The implementation
  /// never retries after dispatch may have started.
  func sendUserInitiated(
    _ request: MessageReplyRequest,
    service: MacMessageReplyService
  ) async throws -> MacMessageReplySendResult

  /// Opens AppKit's compose UI only after a separate, explicit user choice.
  @discardableResult
  func beginUserConfirmedFallback(
    _ request: MessageReplyRequest
  ) throws -> MacMessageReplyFallbackReceipt
}

/// A public-surface Messages transport based on the basic AppleScript route
/// used by openclaw/imsg. It intentionally does not import IMsgCore, inject
/// code, use private frameworks, or automate Messages' UI.
///
/// Recipient and body are passed in an Apple event descriptor list to a fixed
/// script and are never interpolated into AppleScript source. The Messages
/// event and the outgoing-row verification window are both bounded.
@MainActor
final class DirectMessagesReplyTransport: MacMessageReplyTransport {
  typealias DirectSendOperation = @Sendable (
    MessageReplyRequest,
    MacMessageReplyService
  ) async throws -> MacMessageReplySendResult

  private let directSend: DirectSendOperation
  private let fallback: AppStoreMessagesComposeFallback
  private var isSending = false

  init(
    databaseURL: URL? = nil,
    directSend: DirectSendOperation? = nil,
    fallback: AppStoreMessagesComposeFallback = AppStoreMessagesComposeFallback()
  ) {
    self.directSend = directSend ?? { request, service in
      // Resolve the security-scoped Messages URL for each explicit send. The
      // view can be created before the user connects their Messages folder.
      let resolvedDatabaseURL: URL?
      if let databaseURL {
        resolvedDatabaseURL = databaseURL
      } else {
        resolvedDatabaseURL = await MainActor.run {
          SandboxAccessManager.shared.authorizedMessagesDatabaseURL
            ?? LocalMacMessagesProvider.accountMessagesDatabaseURL()
        }
      }
      return try await MessagesDirectSendPipeline(databaseURL: resolvedDatabaseURL).send(
        request,
        service: service
      )
    }
    self.fallback = fallback
  }

  var availability: MacMessageReplyTransportAvailability {
    guard !isSending else { return .sendInProgress }
    guard MessagesAppleScriptExecutor.isAvailable else {
      return .unavailable("Direct Messages automation is unavailable on this Mac.")
    }
    return .available
  }

  func canSendUserInitiated(
    _ request: MessageReplyRequest,
    service _: MacMessageReplyService
  ) -> Bool {
    !isSending && (try? Self.payload(for: request)) != nil
  }

  func sendUserInitiated(
    _ request: MessageReplyRequest,
    service: MacMessageReplyService
  ) async throws -> MacMessageReplySendResult {
    guard !isSending else { throw MacMessageReplyTransportError.sendInProgress }
    _ = try Self.payload(for: request)
    guard MessagesAppleScriptExecutor.isAvailable else {
      return .fallbackRequired(
        "Direct Messages automation is unavailable. You can open this draft in Messages instead."
      )
    }

    isSending = true
    defer { isSending = false }
    return try await directSend(request, service)
  }

  @discardableResult
  func beginUserConfirmedFallback(
    _ request: MessageReplyRequest
  ) throws -> MacMessageReplyFallbackReceipt {
    try fallback.beginUserConfirmedFallback(request)
  }

  nonisolated static func payload(
    for request: MessageReplyRequest
  ) throws -> (recipient: String, body: String) {
    guard request.recipients.count == 1,
          let recipient = request.recipients.first?.address.value,
          !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      if request.recipients.count > 1 {
        throw MacMessageReplyTransportError.tooManyRecipients
      }
      throw MacMessageReplyTransportError.missingRecipient
    }
    guard !request.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MacMessageReplyTransportError.emptyBody
    }
    return (recipient, request.body)
  }
}

/// AppKit compose fallback retained for denied/unavailable direct automation.
/// It is never invoked implicitly by `sendUserInitiated`.
@MainActor
final class AppStoreMessagesComposeFallback: NSObject {
  typealias ServiceFactory = @MainActor () -> NSSharingService?

  private let serviceFactory: ServiceFactory
  private var activeService: NSSharingService?

  init(
    serviceFactory: @escaping ServiceFactory = {
      NSSharingService(named: .composeMessage)
    }
  ) {
    self.serviceFactory = serviceFactory
    super.init()
  }

  @discardableResult
  func beginUserConfirmedFallback(
    _ request: MessageReplyRequest
  ) throws -> MacMessageReplyFallbackReceipt {
    guard activeService == nil else {
      throw MacMessageReplyTransportError.sendInProgress
    }
    let payload = try DirectMessagesReplyTransport.payload(for: request)
    guard let service = serviceFactory() else {
      throw MacMessageReplyTransportError.serviceUnavailable
    }

    let items: [Any] = [payload.body as NSString]
    service.recipients = [payload.recipient]
    guard service.canPerform(withItems: items) else {
      throw MacMessageReplyTransportError.unsupportedRequest
    }

    // NSSharingService.delegate is not an ownership edge. Retain the service
    // until AppKit reports that its user-controlled UI has finished.
    service.delegate = self
    activeService = service
    service.perform(withItems: items)

    return MacMessageReplyFallbackReceipt(
      disposition: .composeRequested,
      recipientCount: 1
    )
  }
}

extension AppStoreMessagesComposeFallback: NSSharingServiceDelegate {
  func sharingService(
    _ sharingService: NSSharingService,
    didShareItems _: [Any]
  ) {
    releaseIfActive(sharingService)
  }

  func sharingService(
    _ sharingService: NSSharingService,
    didFailToShareItems _: [Any],
    error _: any Error
  ) {
    releaseIfActive(sharingService)
  }

  private func releaseIfActive(_ sharingService: NSSharingService) {
    guard activeService === sharingService else { return }
    activeService = nil
  }
}
