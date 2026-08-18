import AppKit
import Foundation
import iAgentCore

enum MacMessageReplyTransportAvailability: Equatable, Sendable {
  case available
  case handoffInProgress
  case unavailable(String)
}

struct MacMessageReplyHandoffReceipt: Equatable, Sendable {
  enum Disposition: Equatable, Sendable {
    /// The request was submitted to AppKit's public compose sharing service.
    /// This does not prove that a compose window opened or that a message was
    /// sent or delivered.
    case handoffRequested
  }

  let disposition: Disposition
  let recipientCount: Int
}

enum MacMessageReplyTransportError: LocalizedError, Equatable {
  case serviceUnavailable
  case handoffInProgress
  case missingRecipient
  case emptyBody
  case unsupportedRequest

  var errorDescription: String? {
    switch self {
    case .serviceUnavailable:
      "Messages handoff is not available on this Mac."
    case .handoffInProgress:
      "A Messages handoff is already in progress."
    case .missingRecipient:
      "Choose at least one recipient before opening Messages."
    case .emptyBody:
      "Write a reply before opening Messages."
    case .unsupportedRequest:
      "Messages cannot open this reply."
    }
  }
}

@MainActor
protocol MacMessageReplyTransport: AnyObject {
  var availability: MacMessageReplyTransportAvailability { get }

  func canBeginUserConfirmedHandoff(_ request: MessageReplyRequest) -> Bool

  @discardableResult
  func beginUserConfirmedHandoff(
    _ request: MessageReplyRequest
  ) throws -> MacMessageReplyHandoffReceipt
}

/// Requests AppKit's public Messages compose sharing service. AppKit owns any
/// resulting UI; this transport never sends a message itself and never treats
/// a completed share callback as proof that a compose window opened or that a
/// message was delivered.
@MainActor
final class AppStoreMessagesHandoffTransport: NSObject, MacMessageReplyTransport {
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

  var availability: MacMessageReplyTransportAvailability {
    guard activeService == nil else { return .handoffInProgress }
    guard serviceFactory() != nil else {
      return .unavailable(
        MacMessageReplyTransportError.serviceUnavailable.localizedDescription
      )
    }
    return .available
  }

  func canBeginUserConfirmedHandoff(_ request: MessageReplyRequest) -> Bool {
    guard activeService == nil,
          let payload = try? Self.payload(for: request),
          let service = serviceFactory()
    else { return false }

    service.recipients = payload.recipients
    return service.canPerform(withItems: payload.items)
  }

  @discardableResult
  func beginUserConfirmedHandoff(
    _ request: MessageReplyRequest
  ) throws -> MacMessageReplyHandoffReceipt {
    guard activeService == nil else {
      throw MacMessageReplyTransportError.handoffInProgress
    }

    let payload = try Self.payload(for: request)
    guard let service = serviceFactory() else {
      throw MacMessageReplyTransportError.serviceUnavailable
    }

    service.recipients = payload.recipients
    guard service.canPerform(withItems: payload.items) else {
      throw MacMessageReplyTransportError.unsupportedRequest
    }

    // NSSharingService.delegate is not an ownership edge. Retain the service
    // until AppKit reports that its user-controlled sharing UI has finished.
    service.delegate = self
    activeService = service
    service.perform(withItems: payload.items)

    return MacMessageReplyHandoffReceipt(
      disposition: .handoffRequested,
      recipientCount: payload.recipients.count
    )
  }

  private static func payload(
    for request: MessageReplyRequest
  ) throws -> (recipients: [String], items: [Any]) {
    let recipients = request.recipients.map(\.address.value)
    guard !recipients.isEmpty,
          recipients.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          })
    else {
      throw MacMessageReplyTransportError.missingRecipient
    }

    guard !request.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MacMessageReplyTransportError.emptyBody
    }

    return (recipients, [request.body as NSString])
  }
}

extension AppStoreMessagesHandoffTransport: NSSharingServiceDelegate {
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
    // Cancellation and service errors both end this handoff. Neither outcome
    // is a statement about message delivery, so this layer only releases the
    // service and lets the next explicit user action start another handoff.
    releaseIfActive(sharingService)
  }

  private func releaseIfActive(_ sharingService: NSSharingService) {
    guard activeService === sharingService else { return }
    activeService = nil
  }
}
