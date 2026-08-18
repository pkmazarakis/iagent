import Foundation
import MessageUI
import SwiftUI
import UIKit
import iAgentCore

enum MobileMessageReplyTransportError: LocalizedError {
  case textMessagingUnavailable
  case missingRecipients
  case unsupportedRecipient

  var errorDescription: String? {
    switch self {
    case .textMessagingUnavailable:
      "Apple's message composer is not available on this iPhone."
    case .missingRecipients:
      "This conversation does not have a supported Messages recipient."
    case .unsupportedRecipient:
      "Apple's iPhone message composer requires phone-number recipients."
    }
  }
}

/// The injectable boundary between iAgent's reply UI and Apple's user-confirmed composer.
/// Implementations prepare a composer only; they never send a message themselves.
@MainActor
protocol MobileMessageReplyTransport {
  func canSendText() -> Bool
  func makeComposer(for request: MessageReplyRequest) throws -> MFMessageComposeViewController
}

@MainActor
struct SystemMobileMessageReplyTransport: MobileMessageReplyTransport {
  func canSendText() -> Bool {
    MFMessageComposeViewController.canSendText()
  }

  func makeComposer(for request: MessageReplyRequest) throws -> MFMessageComposeViewController {
    guard canSendText() else {
      throw MobileMessageReplyTransportError.textMessagingUnavailable
    }

    guard request.recipients.allSatisfy({ $0.address.kind == .phone }) else {
      throw MobileMessageReplyTransportError.unsupportedRecipient
    }
    let recipients = request.recipients.map(\.address.value)
    guard !recipients.isEmpty, recipients.allSatisfy({ !$0.isEmpty }) else {
      throw MobileMessageReplyTransportError.missingRecipients
    }

    let controller = MFMessageComposeViewController()
    // MessageUI requires initial values to be set before the system UI is presented.
    controller.recipients = recipients
    controller.body = request.body
    return controller
  }
}

/// Hosts Apple's standard Messages composer. The person can edit, cancel, or explicitly
/// request sending from the system UI; a `.sendRequested` result is not a delivery receipt.
@MainActor
struct MobileMessageReplyComposer: UIViewControllerRepresentable {
  typealias UIViewControllerType = UIViewController

  let request: MessageReplyRequest
  let transport: any MobileMessageReplyTransport
  let onCompletion: @MainActor (MessageReplyCompletion) -> Void

  init(
    request: MessageReplyRequest,
    transport: (any MobileMessageReplyTransport)? = nil,
    onCompletion: @MainActor @escaping (MessageReplyCompletion) -> Void
  ) {
    self.request = request
    self.transport = transport ?? SystemMobileMessageReplyTransport()
    self.onCompletion = onCompletion
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onCompletion: onCompletion)
  }

  func makeUIViewController(context: Context) -> UIViewController {
    do {
      let controller = try transport.makeComposer(for: request)
      context.coordinator.attach(to: controller)
      return controller
    } catch {
      let message = (error as? LocalizedError)?.errorDescription
        ?? "Apple's message composer could not be opened."
      let coordinator = context.coordinator
      return UIHostingController(
        rootView: MobileMessageReplyUnavailableView(message: message) {
          coordinator.finish(.failed(message))
        }
      )
    }
  }

  func updateUIViewController(
    _ uiViewController: UIViewController,
    context: Context
  ) {
    // MessageUI does not support changing recipients or body after presentation.
  }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency MFMessageComposeViewControllerDelegate {
    private let onCompletion: @MainActor (MessageReplyCompletion) -> Void
    private var retainedComposer: MFMessageComposeViewController?
    private var hasFinished = false

    init(onCompletion: @MainActor @escaping (MessageReplyCompletion) -> Void) {
      self.onCompletion = onCompletion
    }

    func attach(to controller: MFMessageComposeViewController) {
      retainedComposer = controller
      controller.messageComposeDelegate = self
    }

    func messageComposeViewController(
      _ controller: MFMessageComposeViewController,
      didFinishWith result: MessageComposeResult
    ) {
      let completion: MessageReplyCompletion
      switch result {
      case .cancelled:
        completion = .cancelled
      case .sent:
        // This reports the person's request to send, not carrier or recipient delivery.
        completion = .sendRequested
      case .failed:
        completion = .failed("Messages could not accept the send request.")
      @unknown default:
        completion = .failed("Messages returned an unknown compose result.")
      }

      guard beginFinishing() else { return }
      retainedComposer = nil
      controller.dismiss(animated: true) { [onCompletion] in
        onCompletion(completion)
      }
    }

    func finish(_ completion: MessageReplyCompletion) {
      guard beginFinishing() else { return }
      retainedComposer = nil
      onCompletion(completion)
    }

    private func beginFinishing() -> Bool {
      guard !hasFinished else { return false }
      hasFinished = true
      return true
    }
  }
}

private struct MobileMessageReplyUnavailableView: View {
  let message: String
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      ContentUnavailableView(
        "Messages unavailable",
        systemImage: "message.badge.exclamationmark",
        description: Text(message)
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", action: onClose)
        }
      }
    }
  }
}
