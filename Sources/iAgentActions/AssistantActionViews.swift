#if os(iOS)
import EventKit
import EventKitUI
import SwiftUI
import UIKit
import iAgentActionContracts
import iAgentCore

public struct AssistantActionConfirmationResult: Equatable, Sendable {
  public let intent: AssistantActionIntent
  public let receipt: AssistantActionReceipt

  public init(intent: AssistantActionIntent, receipt: AssistantActionReceipt) {
    self.intent = intent
    self.receipt = receipt
  }
}

@MainActor
public final class AssistantActionCardModel: ObservableObject {
  @Published public private(set) var intent: AssistantActionIntent?
  @Published public private(set) var receipt: AssistantActionReceipt?
  @Published public private(set) var isWorking = false
  @Published public private(set) var errorMessage: String?

  public let broker: AssistantActionBroker
  public let pendingStore: AssistantActionPendingStore?
  private var presentationGeneration: UInt64 = 0

  public init(
    broker: AssistantActionBroker,
    pendingStore: AssistantActionPendingStore? = nil
  ) {
    self.broker = broker
    self.pendingStore = pendingStore
  }

  public func present(_ intent: AssistantActionIntent) async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    isWorking = true
    defer {
      if presentationGeneration == generation { isWorking = false }
    }
    do {
      _ = try await broker.stage(intent)
      try await pendingStore?.save(intent)
      guard presentationGeneration == generation else { return }
      self.intent = intent
      receipt = nil
      errorMessage = nil
    } catch {
      if presentationGeneration == generation {
        errorMessage = error.localizedDescription
      }
    }
  }

  public func restoreMostRecentPendingReview() async {
    guard let pendingStore else { return }
    presentationGeneration &+= 1
    let generation = presentationGeneration
    isWorking = true
    defer {
      if presentationGeneration == generation { isWorking = false }
    }
    do {
      guard let restored = try await pendingStore.mostRecentRestorableIntent() else { return }
      let restoreResult = try await broker.restorePendingReview(restored)
      switch restoreResult {
      case .terminal, .cancelled:
        do {
          try await pendingStore.remove(intentID: restored.id)
          if presentationGeneration == generation {
            intent = nil
            receipt = nil
            errorMessage = nil
          }
        } catch {
          // The action is already terminal and therefore must never be presented for another
          // confirmation. Keep the cleanup failure visible and retry cleanup on the next restore.
          if presentationGeneration == generation {
            intent = nil
            receipt = nil
            errorMessage = error.localizedDescription
          }
        }
        return
      case .awaitingReview:
        guard presentationGeneration == generation else { return }
        intent = restored
        receipt = nil
        errorMessage = nil
        return
      case .nativeHandoff(let durableReceipt):
        // A system handoff can have produced an external side effect before its callback was
        // durably finalized (for example, EventKit saved the event and the app then terminated).
        // Reopening a fresh editor could duplicate that side effect, so restore this as an
        // explicitly uncertain, non-confirmable state. A new proposal requires a new user turn.
        guard presentationGeneration == generation else { return }
        intent = restored
        receipt = durableReceipt
        errorMessage =
          "This handoff may already have completed. Check the destination before preparing it again."
        return
      }
    } catch AssistantActionBrokerError.intentExpired {
      // Expiry removes only a true awaiting-review proposal. Receipt-first broker restoration has
      // already preserved any durable native/terminal state regardless of age.
      do {
        if let restored = try await pendingStore.mostRecentRestorableIntent() {
          try await pendingStore.remove(intentID: restored.id)
        }
        if presentationGeneration == generation {
          intent = nil
          receipt = nil
          errorMessage = nil
        }
      } catch {
        if presentationGeneration == generation {
          intent = nil
          receipt = nil
          errorMessage = error.localizedDescription
        }
      }
    } catch {
      if presentationGeneration == generation {
        errorMessage = error.localizedDescription
      }
    }
  }

  @discardableResult
  public func confirmFromCurrentUserGesture() async -> AssistantActionConfirmationResult? {
    guard let capturedIntent = intent else { return nil }
    let generation = presentationGeneration
    isWorking = true
    defer {
      if isCurrent(capturedIntent, generation: generation) { isWorking = false }
    }
    do {
      let confirmation = try await broker.confirm(
        intentID: capturedIntent.id,
        userGestureID: UUID()
      )
      let result = try await broker.commit(confirmation)
      var cleanupError: Error?
      if result.disposition != .nativeHandoffRequired {
        do {
          try await pendingStore?.remove(intentID: capturedIntent.id)
        } catch {
          // The durable receipt is authoritative. A stale pending file is safe to clean on restore
          // and must not turn a successful single-use action into a reported commit failure.
          cleanupError = error
        }
      }
      if isCurrent(capturedIntent, generation: generation) {
        receipt = result
        errorMessage = cleanupError?.localizedDescription
      }
      return AssistantActionConfirmationResult(intent: capturedIntent, receipt: result)
    } catch {
      if isCurrent(capturedIntent, generation: generation) {
        errorMessage = error.localizedDescription
      }
      return nil
    }
  }

  public func cancel() async {
    guard let capturedIntent = intent else { return }
    let generation = presentationGeneration
    if receipt?.disposition == .nativeHandoffRequired {
      do {
        try await pendingStore?.remove(intentID: capturedIntent.id)
        if isCurrent(capturedIntent, generation: generation) {
          intent = nil
          receipt = nil
          errorMessage = nil
        }
      } catch {
        if isCurrent(capturedIntent, generation: generation) {
          errorMessage = error.localizedDescription
        }
      }
      return
    }
    do {
      try await broker.cancel(intentID: capturedIntent.id)
      var cleanupError: Error?
      do {
        try await pendingStore?.remove(intentID: capturedIntent.id)
      } catch {
        cleanupError = error
      }
      if isCurrent(capturedIntent, generation: generation) {
        self.intent = nil
        receipt = nil
        errorMessage = cleanupError?.localizedDescription
      }
    } catch {
      if isCurrent(capturedIntent, generation: generation) {
        errorMessage = error.localizedDescription
      }
    }
  }

  @discardableResult
  public func finishCalendarHandoff(
    intentID: String,
    proposalDigest: String,
    outcome: AssistantCalendarEventEditor.Outcome
  ) async -> Bool {
    let shouldShowProgress = isCurrent(intentID: intentID, proposalDigest: proposalDigest)
    if shouldShowProgress { isWorking = true }
    defer {
      if isCurrent(intentID: intentID, proposalDigest: proposalDigest) { isWorking = false }
    }
    if case .failed(let detail) = outcome {
      if isCurrent(intentID: intentID, proposalDigest: proposalDigest) {
        errorMessage = detail
      }
      return true
    }
    do {
      let result: AssistantActionReceipt
      switch outcome {
      case let .saved(identifier, revision):
        result = try await broker.finalizeNativeHandoff(
          intentID: intentID,
          proposalDigest: proposalDigest,
          outcome: .completed(
            entityIdentifier: identifier,
            revision: revision,
            summary: "Saved the event through Apple’s Calendar editor."
          )
        )
      case .cancelled:
        result = try await broker.finalizeNativeHandoff(
          intentID: intentID,
          proposalDigest: proposalDigest,
          outcome: .cancelled(
            summary: "Calendar editor was cancelled; no event was saved."
          )
        )
      case .failed:
        preconditionFailure("Calendar failures return before native handoff finalization.")
      }
      var cleanupError: Error?
      do {
        try await pendingStore?.remove(intentID: intentID)
      } catch {
        cleanupError = error
      }
      if isCurrent(intentID: intentID, proposalDigest: proposalDigest) {
        receipt = result
        errorMessage = cleanupError?.localizedDescription
      }
      return true
    } catch {
      if isCurrent(intentID: intentID, proposalDigest: proposalDigest) {
        errorMessage = error.localizedDescription
      }
      return false
    }
  }

  @discardableResult
  public func finishCodexHandoff(
    intentID: String,
    proposalDigest: String,
    outcome: AssistantCodexRequestHandoffView.Outcome
  ) async -> Bool {
    let shouldShowProgress = isCurrent(intentID: intentID, proposalDigest: proposalDigest)
    if shouldShowProgress { isWorking = true }
    defer {
      if isCurrent(intentID: intentID, proposalDigest: proposalDigest) { isWorking = false }
    }
    do {
      let result: AssistantActionReceipt
      switch outcome {
      case .completed:
        result = try await broker.finalizeNativeHandoff(
          intentID: intentID,
          proposalDigest: proposalDigest,
          outcome: .completed(
            entityIdentifier: nil,
            revision: nil,
            summary:
              "Shared the request through the user-selected handoff. iAgent did not create or run a Codex task."
          )
        )
      case .cancelled:
        result = try await broker.finalizeNativeHandoff(
          intentID: intentID,
          proposalDigest: proposalDigest,
          outcome: .cancelled(
            summary: "Codex handoff was cancelled; no task was created or run."
          )
        )
      }
      var cleanupError: Error?
      do {
        try await pendingStore?.remove(intentID: intentID)
      } catch {
        cleanupError = error
      }
      if isCurrent(intentID: intentID, proposalDigest: proposalDigest) {
        receipt = result
        errorMessage = cleanupError?.localizedDescription
      }
      return true
    } catch {
      if isCurrent(intentID: intentID, proposalDigest: proposalDigest) {
        errorMessage = error.localizedDescription
      }
      return false
    }
  }

  private func isCurrent(_ intent: AssistantActionIntent, generation: UInt64) -> Bool {
    presentationGeneration == generation
      && isCurrent(intentID: intent.id, proposalDigest: intent.proposalDigest)
  }

  private func isCurrent(intentID: String, proposalDigest: String) -> Bool {
    intent?.id == intentID && intent?.proposalDigest == proposalDigest
  }
}

@MainActor
public final class AssistantActionRuntime {
  public let capabilityStore: AssistantActionCapabilityStore
  public let journal: AssistantActionJournal
  public let pendingStore: AssistantActionPendingStore
  public let calendarHandoff: AssistantCalendarDraftHandoff
  public let broker: AssistantActionBroker
  public let cards: AssistantActionCardModel
  public let settings: AssistantActionCapabilitySettingsModel

  public init(
    localStore: IAgentLocalSyncStore,
    sourceDeviceID: String,
    persistenceDirectory: URL,
    isAppForeground: @escaping @Sendable () -> Bool,
    foregroundAuthority: AssistantActionForegroundAuthority? = nil
  ) {
    let capabilityStore = AssistantActionCapabilityStore(
      fileURL: persistenceDirectory.appendingPathComponent("assistant-action-capabilities.json")
    )
    let journal = AssistantActionJournal(
      fileURL: persistenceDirectory.appendingPathComponent("assistant-action-journal.json")
    )
    let pendingStore = AssistantActionPendingStore(
      fileURL: persistenceDirectory.appendingPathComponent("assistant-action-pending.json")
    )
    let calendarHandoff = AssistantCalendarDraftHandoff()
    let executor = LocalFirstAssistantActionExecutor(
      store: localStore,
      sourceDeviceID: sourceDeviceID
    )
    let broker = AssistantActionBroker(
      capabilities: capabilityStore,
      permissions: calendarHandoff,
      executor: executor,
      journal: journal,
      isAppForeground: isAppForeground,
      foregroundAuthority: foregroundAuthority
    )
    self.capabilityStore = capabilityStore
    self.journal = journal
    self.pendingStore = pendingStore
    self.calendarHandoff = calendarHandoff
    self.broker = broker
    cards = AssistantActionCardModel(broker: broker, pendingStore: pendingStore)
    settings = AssistantActionCapabilitySettingsModel(store: capabilityStore)
  }
}

public struct AssistantActionReviewView: View {
  public let intent: AssistantActionIntent
  public let receipt: AssistantActionReceipt?
  public let isWorking: Bool
  public let errorMessage: String?
  public let onConfirm: () -> Void
  public let onCancel: () -> Void

  @State private var isBodyExpanded = false

  public init(
    intent: AssistantActionIntent,
    receipt: AssistantActionReceipt? = nil,
    isWorking: Bool = false,
    errorMessage: String? = nil,
    onConfirm: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.intent = intent
    self.receipt = receipt
    self.isWorking = isWorking
    self.errorMessage = errorMessage
    self.onConfirm = onConfirm
    self.onCancel = onCancel
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 9) {
        Image(systemName: receipt.map(receiptSymbol) ?? symbolName)
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 22, height: 22)
          .accessibilityHidden(true)

        Text(receipt?.summary ?? presentation.title)
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .combine)

      proposalBody

      if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .accessibilityLabel("Action error: \(errorMessage)")
      }

      if receipt == nil {
        actionButtons
          .frame(maxWidth: .infinity, alignment: .trailing)
      } else if receipt?.disposition == .nativeHandoffRequired {
        Button(role: .cancel, action: onCancel) {
          Image(systemName: "xmark")
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 44, height: 44)
            .background(Color.primary.opacity(0.08), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel("Dismiss uncertain handoff")
        .accessibilityHint(
          "Dismisses this status without repeating or cancelling the external handoff."
        )
      }
    }
    .padding(16)
    .background(
      Color.primary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
    }
    .onChange(of: intent.id) { _ in
      isBodyExpanded = false
    }
  }

  private var proposalBody: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(reviewBody)
        .font(.body)
        .foregroundStyle(.primary)
        .lineSpacing(3)
        .lineLimit(isCollapsibleNote && !isBodyExpanded ? 5 : nil)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(proposalBodyAccessibilityLabel)

      if isCollapsibleNote {
        Button(isBodyExpanded ? "Show less" : "Show more") {
          isBodyExpanded.toggle()
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityHint(
          isBodyExpanded
            ? "Collapses the proposed note to a short preview."
            : "Expands the complete proposed note for review."
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var actionButtons: some View {
    HStack(spacing: 8) {
      Button(role: .cancel, action: onCancel) {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .semibold))
          .frame(width: 44, height: 44)
          .background(Color.primary.opacity(0.08), in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .disabled(isWorking)
      .accessibilityLabel(intent.review.cancelVerb)
      .accessibilityHint("Dismisses this proposal without making changes.")

      Button(action: onConfirm) {
        Group {
          if isWorking {
            ProgressView()
              .controlSize(.small)
              .tint(Color(.systemBackground))
          } else {
            Image(systemName: "checkmark")
              .font(.system(size: 15, weight: .bold))
          }
        }
        .frame(width: 44, height: 44)
        .foregroundStyle(Color(.systemBackground))
        .background(Color.primary, in: Circle())
        .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .disabled(isWorking)
      .accessibilityLabel(intent.review.primaryVerb)
      .accessibilityHint("Confirms this proposal once. No change happens before confirmation.")
    }
    .fixedSize()
  }

  private var reviewBody: String {
    presentation.body
  }

  private var isCollapsibleNote: Bool {
    guard case .createNote = intent.payload else { return false }
    let lineBreakCount = reviewBody.reduce(into: 0) { count, character in
      if character == "\n" { count += 1 }
    }
    return reviewBody.count > 220 || lineBreakCount >= 4
  }

  private var proposalBodyAccessibilityLabel: String {
    guard isCollapsibleNote, !isBodyExpanded else {
      return "Proposed content: \(reviewBody)"
    }
    let preview = String(reviewBody.prefix(220))
    return "Proposed note preview: \(preview)"
  }

  private var presentation: AssistantActionReviewPresentation {
    AssistantActionReviewPresentation(intent: intent)
  }

  private var symbolName: String {
    switch intent.capability {
    case .createTodo: "checkmark.square"
    case .createNote: "note.text"
    case .draftCalendarEvent: "calendar.badge.plus"
    case .requestCodexTask: "terminal"
    }
  }

  private func receiptSymbol(_ receipt: AssistantActionReceipt) -> String {
    switch receipt.disposition {
    case .committedLocally, .handoffCompleted: "checkmark.circle.fill"
    case .nativeHandoffRequired: "arrow.up.forward.app"
    case .handoffCancelled: "xmark.circle"
    }
  }
}

private struct AssistantActionReviewPresentation {
  let title: String
  let body: String

  init(intent: AssistantActionIntent) {
    switch intent.payload {
    case let .createTodo(todo):
      title = todo.title
      var details = [todo.listName.map { "\($0) list" } ?? "Default list"]
      if let dueAt = todo.dueAt {
        details.append("Due \(Self.formatted(dueAt))")
      }
      body = details.joined(separator: "\n")

    case let .createNote(note):
      title = note.title
      body = note.body

    case let .calendarDraft(event):
      title = event.title
      let dateRange = event.isAllDay
        ? "\(Self.formatted(event.start, dateOnly: true)) – \(Self.formatted(event.end, dateOnly: true))"
        : "\(Self.formatted(event.start)) – \(Self.formatted(event.end))"
      var details = [dateRange]
      if let location = event.location { details.append(location) }
      if let notes = event.notes { details.append(notes) }
      if let calendar = event.calendarIdentifier { details.append("Calendar: \(calendar)") }
      body = details.joined(separator: "\n")

    case let .codexTaskRequest(request):
      title = "Codex request"
      var details = [request.prompt]
      if let workspace = request.workspaceIdentifier { details.append("Workspace: \(workspace)") }
      body = details.joined(separator: "\n")
    }
  }

  private static func formatted(
    _ value: AssistantActionDateTime,
    dateOnly: Bool = false
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = TimeZone(identifier: value.timeZoneID)
    formatter.dateStyle = .medium
    formatter.timeStyle = dateOnly ? .none : .short
    return formatter.string(from: value.instant)
  }
}

@MainActor
public final class AssistantActionCapabilitySettingsModel: ObservableObject {
  @Published public private(set) var policy: AssistantActionCapabilityPolicy
  @Published public private(set) var errorMessage: String?
  @Published public private(set) var updatingCapabilities: Set<AssistantActionCapability> = []

  private let store: AssistantActionCapabilityStore

  public init(store: AssistantActionCapabilityStore) {
    self.store = store
    policy = store.initialPolicy
    errorMessage = store.initialLoadErrorMessage
  }

  public func load() async {
    policy = await store.currentPolicy()
    errorMessage = store.initialLoadErrorMessage
  }

  public func isEnabled(_ capability: AssistantActionCapability) -> Bool {
    policy.rules[capability]?.mayPrepare == true
  }

  public func isUpdating(_ capability: AssistantActionCapability) -> Bool {
    updatingCapabilities.contains(capability)
  }

  public func setEnabled(_ enabled: Bool, capability: AssistantActionCapability) async {
    guard !updatingCapabilities.contains(capability) else { return }
    updatingCapabilities.insert(capability)
    defer { updatingCapabilities.remove(capability) }
    do {
      try await store.setPreparationEnabled(enabled, for: capability)
      policy = await store.currentPolicy()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

public struct AssistantActionCapabilitySettingsSection: View {
  @ObservedObject private var model: AssistantActionCapabilitySettingsModel

  public init(model: AssistantActionCapabilitySettingsModel) {
    self.model = model
  }

  public var body: some View {
    Section {
      ForEach(AssistantActionCapability.allCases, id: \.self) { capability in
        Toggle(
          isOn: Binding(
            get: { model.isEnabled(capability) },
            set: { enabled in
              Task { await model.setEnabled(enabled, capability: capability) }
            }
          )
        ) {
          VStack(alignment: .leading, spacing: 3) {
            Text(capability.settingsTitle)
            Text(capability.settingsExplanation)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .disabled(model.isUpdating(capability))
      }

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Assistant actions")
    } footer: {
      Text("New installs start with preparation enabled. Your saved choices stay as set. Enabling a capability only lets iAgent prepare a review card; every commit still requires your current, single-use explicit confirmation.")
    }
    .task { await model.load() }
  }
}

@MainActor
public final class AssistantCalendarDraftHandoff: ObservableObject, AssistantActionPermissionAuthorizing {
  public enum AccessState: Equatable {
    case idle
    case requesting
    case ready
    case denied
    case failed(String)
  }

  @Published public private(set) var accessState: AccessState = .idle
  public let eventStore: EKEventStore

  public init(eventStore: EKEventStore = EKEventStore()) {
    self.eventStore = eventStore
  }

  public func requestContextualWriteAccess() async -> Bool {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess, .writeOnly:
      accessState = .ready
      return true
    case .restricted, .denied:
      accessState = .denied
      return false
    case .notDetermined:
      accessState = .requesting
      do {
        let granted = try await eventStore.requestWriteOnlyAccessToEvents()
        accessState = granted ? .ready : .denied
        return granted
      } catch {
        accessState = .failed(error.localizedDescription)
        return false
      }
    @unknown default:
      accessState = .failed("Unknown Calendar permission state.")
      return false
    }
  }

  public func authorizeIfNeeded(for intent: AssistantActionIntent) async throws {
    guard intent.capability == .draftCalendarEvent else { return }
    guard await requestContextualWriteAccess() else {
      switch accessState {
      case let .failed(detail):
        throw AssistantActionPermissionError.unavailable(detail)
      default:
        throw AssistantActionPermissionError.denied("Calendar write-only access")
      }
    }
    guard case .calendarDraft(let draft) = intent.payload else { return }
    if let reviewedCalendarID = draft.calendarIdentifier {
      guard let calendar = eventStore.calendar(withIdentifier: reviewedCalendarID) else {
        throw AssistantActionBrokerError.staleTarget(
          "the reviewed calendar no longer exists"
        )
      }
      guard calendar.allowsContentModifications else {
        throw AssistantActionBrokerError.staleTarget(
          "the reviewed calendar is no longer writable"
        )
      }
    }
  }
}

public struct AssistantCalendarEventEditor: View {
  public enum Outcome: Sendable {
    case saved(identifier: String?, revision: String?)
    case cancelled
    case failed(String)
  }

  public let draft: CalendarEventDraftActionPayload
  public let eventStore: EKEventStore
  public let onFinish: (Outcome) -> Void

  public init(
    draft: CalendarEventDraftActionPayload,
    eventStore: EKEventStore,
    onFinish: @escaping (Outcome) -> Void
  ) {
    self.draft = draft
    self.eventStore = eventStore
    self.onFinish = onFinish
  }

  public var body: some View {
    if let error = reviewedCalendarError {
      NavigationStack {
        ContentUnavailableView(
          "Calendar unavailable",
          systemImage: "calendar.badge.exclamationmark",
          description: Text(error)
        )
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { onFinish(.failed(error)) }
          }
        }
      }
    } else {
      EventEditorController(draft: draft, eventStore: eventStore, onFinish: onFinish)
    }
  }

  private var reviewedCalendarError: String? {
    guard let reviewedCalendarID = draft.calendarIdentifier else { return nil }
    guard let calendar = eventStore.calendar(withIdentifier: reviewedCalendarID) else {
      return "The calendar reviewed for this draft no longer exists. No event was saved."
    }
    guard calendar.allowsContentModifications else {
      return "The calendar reviewed for this draft is no longer writable. No event was saved."
    }
    return nil
  }
}

private struct EventEditorController: UIViewControllerRepresentable {
  typealias UIViewControllerType = UIViewController

  let draft: CalendarEventDraftActionPayload
  let eventStore: EKEventStore
  let onFinish: (AssistantCalendarEventEditor.Outcome) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onFinish: onFinish)
  }

  func makeUIViewController(context: Context) -> UIViewController {
    let event = EKEvent(eventStore: eventStore)
    event.title = draft.title
    event.startDate = draft.start.instant
    event.endDate = draft.end.instant
    event.isAllDay = draft.isAllDay
    event.timeZone = TimeZone(identifier: draft.start.timeZoneID)
    event.location = draft.location
    event.notes = draft.notes
    if let calendarIdentifier = draft.calendarIdentifier {
      guard let calendar = eventStore.calendar(withIdentifier: calendarIdentifier) else {
        return failureController(
          "The calendar reviewed for this draft no longer exists. No event was saved."
        )
      }
      guard calendar.allowsContentModifications else {
        return failureController(
          "The calendar reviewed for this draft is no longer writable. No event was saved."
        )
      }
      // Assign the exact reviewed calendar. A non-nil reviewed identifier must never fall back to
      // EventKit's default calendar if the target changes between SwiftUI evaluation and controller
      // construction.
      event.calendar = calendar
    }

    let controller = EKEventEditViewController()
    controller.eventStore = eventStore
    controller.event = event
    controller.editViewDelegate = context.coordinator
    return controller
  }

  func updateUIViewController(
    _ uiViewController: UIViewController,
    context: Context
  ) {}

  private func failureController(_ message: String) -> UIViewController {
    UIHostingController(
      rootView: CalendarEditorFailureView(message: message, onFinish: onFinish)
    )
  }

  final class Coordinator: NSObject, EKEventEditViewDelegate {
    private let onFinish: (AssistantCalendarEventEditor.Outcome) -> Void

    init(onFinish: @escaping (AssistantCalendarEventEditor.Outcome) -> Void) {
      self.onFinish = onFinish
    }

    func eventEditViewController(
      _ controller: EKEventEditViewController,
      didCompleteWith action: EKEventEditViewAction
    ) {
      switch action {
      case .saved:
        let revision = controller.event?.lastModifiedDate?.ISO8601Format()
        onFinish(
          .saved(identifier: controller.event?.eventIdentifier, revision: revision)
        )
      case .canceled, .deleted:
        onFinish(.cancelled)
      @unknown default:
        onFinish(.cancelled)
      }
    }
  }
}

private struct CalendarEditorFailureView: View {
  let message: String
  let onFinish: (AssistantCalendarEventEditor.Outcome) -> Void

  var body: some View {
    NavigationStack {
      ContentUnavailableView(
        "Calendar unavailable",
        systemImage: "calendar.badge.exclamationmark",
        description: Text(message)
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { onFinish(.failed(message)) }
        }
      }
    }
  }
}

public struct AssistantCodexRequestHandoffView: View {
  public enum Outcome: Sendable {
    case completed
    case cancelled
  }

  public let request: CodexTaskRequestActionPayload
  public let onFinish: (Outcome) -> Void

  @State private var isPresentingShareSheet = false

  public init(
    request: CodexTaskRequestActionPayload,
    onFinish: @escaping (Outcome) -> Void
  ) {
    self.request = request
    self.onFinish = onFinish
  }

  public var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text("Codex request")
            .font(.title2.weight(.semibold))
          Text(
            "This is a handoff only. iAgent has not created a task, run the request, "
              + "or approved any Codex permission."
          )
            .font(.subheadline)
            .foregroundStyle(.secondary)
          if let workspaceIdentifier = request.workspaceIdentifier {
            LabeledContent("Workspace", value: workspaceIdentifier)
          }
          Text(request.prompt)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

          Button {
            isPresentingShareSheet = true
          } label: {
            Label("Choose handoff destination", systemImage: "square.and.arrow.up")
          }
          .buttonStyle(.borderedProminent)
        }
        .padding()
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { onFinish(.cancelled) }
        }
      }
      .sheet(isPresented: $isPresentingShareSheet) {
        AssistantCodexActivityView(item: request.prompt) { completed in
          isPresentingShareSheet = false
          guard completed else { return }
          onFinish(.completed)
        }
      }
    }
  }
}

private struct AssistantCodexActivityView: UIViewControllerRepresentable {
  let item: String
  let onFinish: (Bool) -> Void

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(
      activityItems: [item],
      applicationActivities: nil
    )
    controller.completionWithItemsHandler = { _, completed, _, _ in
      DispatchQueue.main.async { onFinish(completed) }
    }
    return controller
  }

  func updateUIViewController(
    _ uiViewController: UIActivityViewController,
    context: Context
  ) {}
}
#endif
