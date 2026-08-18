import AVFoundation
import EventKit
import Speech
import SwiftUI
import UIKit
import iAgentActionContracts
import iAgentActions
import iAgentCore

struct MobileSettingsView: View {
  @ObservedObject var model: MobileAppModel
  @ObservedObject private var actionSettings: AssistantActionCapabilitySettingsModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var permissions = MobilePermissionSnapshot.current()
  @State private var isSyncRequested = false
  @State private var messageReplyTransportEnabled = MessageReplyPreferences.isEnabled(
    in: .standard
  )

  init(model: MobileAppModel) {
    self.model = model
    _actionSettings = ObservedObject(
      wrappedValue: model.assistantActionRuntime.settings
    )
  }

  var body: some View {
    Form {
      syncSection
      permissionsSection
      messageRepliesSection
      assistantActionsSection
      liveActivitySection
      privacySection
      aboutSection
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
      }
    }
    .accessibilityIdentifier("settings.screen")
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      permissions = MobilePermissionSnapshot.current()
    }
  }

  private var syncPresentation: MobileSyncStatusPresentation {
    MobileSyncStatusPresentation(
      status: model.syncStatus,
      pendingCount: model.syncPendingCount,
      isUsingPreviewData: model.isUsingPreviewData
    )
  }

  private var lastSyncDate: Date? {
    model.lastSuccessfulSyncAt
  }

  private var syncSection: some View {
    Section {
      MobileSettingsStatusRow(
        symbol: syncPresentation.symbol,
        color: syncPresentation.tone.color,
        title: syncPresentation.title,
        detail: syncPresentation.detail
      )
      .accessibilityIdentifier("settings.sync.status")

      if let lastSyncDate, !model.isUsingPreviewData {
        LabeledContent("Last successful sync") {
          Text(
            lastSyncDate,
            format: .dateTime.year().month(.abbreviated).day().hour().minute()
          )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
      }

      Button {
        guard !isSyncRequested, model.syncStatus.phase != .syncing else { return }
        isSyncRequested = true
        Task {
          await model.refresh()
          isSyncRequested = false
        }
      } label: {
        if isSyncRequested || model.syncStatus.phase == .syncing {
          Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
        } else {
          Label(
            model.isUsingPreviewData ? "Reload Preview Data" : "Sync Now",
            systemImage: "arrow.triangle.2.circlepath"
          )
        }
      }
      .disabled(isSyncRequested || model.syncStatus.phase == .syncing)
      .accessibilityHint(
        model.isUsingPreviewData
          ? "Reloads the local sample data shown by this debug build"
          : "Checks iCloud and sends any local changes waiting to sync"
      )
      .accessibilityIdentifier("settings.sync.now")
    } header: {
      settingsSectionHeader("Sync")
    } footer: {
      Text(syncFooter)
    }
  }

  private var permissionsSection: some View {
    Section {
      MobilePermissionRow(
        symbol: "calendar",
        title: "Calendar",
        status: permissions.calendar
      )
      MobilePermissionRow(
        symbol: "mic",
        title: "Microphone",
        status: permissions.microphone
      )
      MobilePermissionRow(
        symbol: "waveform",
        title: "Speech Recognition",
        status: permissions.speechRecognition
      )

      Button {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        model.open(url)
      } label: {
        Label("Open iOS Settings", systemImage: "arrow.up.right.square")
      }
    } header: {
      settingsSectionHeader("Permissions")
    } footer: {
      Text(
        "Calendar access lets Ask iAgent read events on this iPhone and lets you show them in Calendar. Microphone and Speech Recognition support voice chat, dictation, and meeting recording."
      )
    }
  }

  private var assistantActionsSection: some View {
    Section {
      ForEach(AssistantActionCapability.allCases, id: \.self) { capability in
        Toggle(isOn: assistantActionBinding(for: capability)) {
          MobileAssistantActionRowLabel(
            capability: capability,
            availability: assistantActionAvailability(for: capability)
          )
        }
        .tint(PanelTheme.blue)
        .disabled(actionSettings.isUpdating(capability))
        .frame(minHeight: 44)
        .accessibilityHint(
          "Allows preparation of a review card only. Committing it still requires your current explicit confirmation. \(assistantActionAvailability(for: capability).detail)"
        )
        .accessibilityIdentifier(
          "settings.assistant-actions.\(capability.rawValue).toggle"
        )
      }

      if let errorMessage = actionSettings.errorMessage {
        Label {
          Text(errorMessage)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(PanelTheme.coral)
        }
        .font(.footnote)
        .accessibilityIdentifier("settings.assistant-actions.error")
      }
    } header: {
      settingsSectionHeader("Assistant actions")
    } footer: {
      Text(
        "All four preparation capabilities are enabled for a new install. Your saved choices stay as set. Enabled only means iAgent may prepare a review card—nothing is created, saved, sent, or handed off until you review that exact card and explicitly confirm it."
      )
    }
    .task { await actionSettings.load() }
  }

  private var messageRepliesSection: some View {
    Section {
      Toggle(isOn: messageReplyTransportBinding) {
        Label {
          VStack(alignment: .leading, spacing: 3) {
            Text("Messages reply handoff")
            Text(
              messageReplyTransportEnabled
                ? "System composer available in message history"
                : "Inbox stays read only"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: "message.badge")
            .foregroundStyle(messageReplyTransportEnabled ? PanelTheme.green : Color.secondary)
        }
      }
      .tint(PanelTheme.green)
      .frame(minHeight: 44)
      .accessibilityHint(
        messageReplyTransportEnabled
          ? "Turns off reply preparation and keeps message history read only"
          : "Allows local drafts to open in Apple's message composer for your review and Send confirmation"
      )
      .accessibilityIdentifier("settings.messages.reply-handoff.toggle")
    } header: {
      settingsSectionHeader("Messages")
    } footer: {
      Text(
        "Off by default. This setting applies to every eligible one-to-one conversation in your rolling 14-day Messages inbox. When enabled, iAgent can prepare a phone number and body, but Apple's composer always appears and you decide whether to send. iAgent cannot send in the background or confirm delivery. Recipient phone numbers come from your separately opted-in Mac Messages source through your private iCloud data."
      )
    }
  }

  private var messageReplyTransportBinding: Binding<Bool> {
    Binding(
      get: { messageReplyTransportEnabled },
      set: { enabled in
        MessageReplyPreferences.setEnabled(enabled, in: .standard)
        messageReplyTransportEnabled = enabled
      }
    )
  }

  private func assistantActionBinding(
    for capability: AssistantActionCapability
  ) -> Binding<Bool> {
    Binding(
      get: { actionSettings.isEnabled(capability) },
      set: { enabled in
        Task { await actionSettings.setEnabled(enabled, capability: capability) }
      }
    )
  }

  private func assistantActionAvailability(
    for capability: AssistantActionCapability
  ) -> MobileAssistantActionAvailability {
    switch capability {
    case .createTodo:
      MobileAssistantActionAvailability(
        detail: "Available locally. Creation always waits for review.",
        tone: .ready
      )
    case .createNote:
      MobileAssistantActionAvailability(
        detail: "Available locally. Creation always waits for review.",
        tone: .ready
      )
    case .draftCalendarEvent:
      switch permissions.calendar {
      case .granted:
        MobileAssistantActionAvailability(
          detail: "Calendar access is ready and checked again after confirmation.",
          tone: .ready
        )
      case .notRequested:
        MobileAssistantActionAvailability(
          detail: "Calendar permission is requested only after confirmation.",
          tone: .neutral
        )
      case .denied:
        MobileAssistantActionAvailability(
          detail: "Calendar access is denied; review cards can still be prepared.",
          tone: .blocked
        )
      case let .limited(label):
        MobileAssistantActionAvailability(
          detail: "Calendar access is \(label.lowercased()); review cards can still be prepared.",
          tone: label == "Add Only" ? .ready : .warning
        )
      }
    case .requestCodexTask:
      MobileAssistantActionAvailability(
        detail: "Review and handoff only. Nothing is sent automatically.",
        tone: .neutral
      )
    }
  }

  private var privacySection: some View {
    Section {
      MobileSettingsInfoRow(
        symbol: "iphone",
        title: "Local first",
        detail: "Notes, todos, and meeting transcripts are stored on this iPhone first."
      )
      MobileSettingsInfoRow(
        symbol: "icloud",
        title: "Private iCloud sync",
        detail: "When available, iAgent syncs app data through your private iCloud database."
      )
      MobileSettingsInfoRow(
        symbol: "waveform.badge.mic",
        title: "Recording",
        detail: "Microphone audio is processed only during voice input or a meeting recording. iAgent stores the transcript, not the audio."
      )
    } header: {
      settingsSectionHeader("Privacy")
    }
  }

  private var liveActivitySection: some View {
    Section {
      Toggle(isOn: priorityLiveActivityBinding) {
        Label {
          VStack(alignment: .leading, spacing: 3) {
            Text("Priority Live Activity")
            Text(
              model.isPriorityLiveActivityChanging
                ? "Updating…"
                : model.priorityLiveActivitySummary
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          }
        } icon: {
          Image(systemName: "livephoto")
            .foregroundStyle(
              model.isPriorityLiveActivityEnabled ? PanelTheme.green : Color.secondary
            )
        }
      }
      .tint(PanelTheme.green)
      .disabled(model.isPriorityLiveActivityChanging)
      .accessibilityValue(model.priorityLiveActivitySummary)
      .accessibilityHint(
        model.isPriorityLiveActivityEnabled
          ? "Turns off the private Lock Screen priority summary"
          : "Turns on a titled, time-bound Lock Screen list. Notes and note content stay excluded"
      )
      .accessibilityIdentifier("settings.priority-live-activity.toggle")
    } header: {
      settingsSectionHeader("Live Activity")
    } footer: {
      Text(
        "Shows privacy-sensitive, time-bound items from Codex, Calendar, and Todos on the Lock Screen and Dynamic Island. Notes stay excluded. Open iAgent periodically to keep it current."
      )
    }
  }

  private var priorityLiveActivityBinding: Binding<Bool> {
    Binding(
      get: { model.isPriorityLiveActivityEnabled },
      set: { isEnabled in
        Task { await model.setPriorityLiveActivityEnabled(isEnabled) }
      }
    )
  }

  private var aboutSection: some View {
    Section {
      LabeledContent("App", value: "iAgent")
      LabeledContent("Version", value: MobileAppMetadata.current.version)
      LabeledContent("Build", value: MobileAppMetadata.current.build)
      LabeledContent("Appearance", value: "Dark")
    } header: {
      settingsSectionHeader("About")
    }
  }

  private func settingsSectionHeader(_ title: LocalizedStringKey) -> some View {
    Text(title)
      .padding(.leading, 5)
  }

  private var syncFooter: String {
    if model.isUsingPreviewData {
      return "This debug build is showing local sample data and is not connected to iCloud."
    }
    return "Changes are saved locally first, then synced through your private iCloud database. A separate iAgent account is not required."
  }
}

private struct MobileAssistantActionAvailability: Equatable {
  enum Tone: Equatable {
    case ready
    case neutral
    case warning
    case blocked

    var color: Color {
      switch self {
      case .ready: .secondary
      case .neutral: .secondary
      case .warning: PanelTheme.amber
      case .blocked: PanelTheme.coral
      }
    }
  }

  let detail: String
  let tone: Tone
}

private struct MobileAssistantActionRowLabel: View {
  let capability: AssistantActionCapability
  let availability: MobileAssistantActionAvailability

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbolName)
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(capability.settingsTitle)
        Text(availability.detail)
          .font(.caption)
          .foregroundStyle(availability.tone.color)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 3)
  }

  private var symbolName: String {
    switch capability {
    case .createTodo: "checkmark.square"
    case .createNote: "note.text"
    case .draftCalendarEvent: "calendar.badge.plus"
    case .requestCodexTask: "sparkles"
    }
  }
}

struct MobileSyncStatusPresentation: Equatable {
  enum Tone: Equatable {
    case neutral
    case progress
    case success
    case warning
    case error

    var color: Color {
      switch self {
      case .neutral: .secondary
      case .progress: PanelTheme.blue
      case .success: PanelTheme.green
      case .warning: PanelTheme.amber
      case .error: PanelTheme.coral
      }
    }
  }

  let symbol: String
  let tone: Tone
  let title: String
  let detail: String

  init(status: IAgentCloudSyncStatus, pendingCount: Int, isUsingPreviewData: Bool) {
    if isUsingPreviewData {
      symbol = "doc.text.magnifyingglass"
      tone = .neutral
      title = "Preview data"
      detail = "Local sample data is ready for UI testing."
      return
    }

    switch status.phase {
    case .idle where pendingCount > 0:
      symbol = "icloud.and.arrow.up"
      tone = .warning
      title = "Waiting to sync"
      detail = Self.pendingDetail(pendingCount)
    case .idle:
      if status.lastSuccessfulSyncAt == nil {
        symbol = "iphone"
        tone = .neutral
        title = "Stored locally"
        detail = status.message ?? "No successful iCloud sync has completed yet."
      } else {
        symbol = "checkmark.icloud"
        tone = .success
        title = "Up to date"
        detail = status.message ?? "Your local changes are safely stored."
      }
    case .syncing:
      symbol = "arrow.triangle.2.circlepath.icloud"
      tone = .progress
      title = "Syncing"
      detail = status.message ?? "Checking iCloud for changes."
    case .offline:
      symbol = "icloud.slash"
      tone = .warning
      title = "Offline"
      detail = status.message ?? "Changes will remain on this iPhone until a connection is available."
    case .accountUnavailable:
      symbol = "person.crop.circle.badge.exclamationmark"
      tone = .error
      title = "iCloud unavailable"
      detail = status.message ?? "Check the iCloud account in iOS Settings."
    case .failed:
      symbol = "exclamationmark.icloud"
      tone = .error
      title = "Sync issue"
      detail = status.message ?? "Your changes remain stored locally. Try syncing again."
    }
  }

  private static func pendingDetail(_ count: Int) -> String {
    count == 1 ? "1 local change is waiting for iCloud." : "\(count) local changes are waiting for iCloud."
  }
}

struct MobilePermissionSnapshot: Equatable {
  enum Status: Equatable {
    case granted(String)
    case notRequested
    case limited(String)
    case denied

    var label: String {
      switch self {
      case .granted(let label), .limited(let label): label
      case .notRequested: "Not Asked"
      case .denied: "Denied"
      }
    }

    var symbol: String {
      switch self {
      case .granted: "checkmark.circle.fill"
      case .notRequested: "circle.dashed"
      case .limited: "exclamationmark.circle.fill"
      case .denied: "xmark.circle.fill"
      }
    }

    var color: Color {
      switch self {
      case .granted: PanelTheme.green
      case .notRequested: .secondary
      case .limited: PanelTheme.amber
      case .denied: PanelTheme.coral
      }
    }
  }

  let calendar: Status
  let microphone: Status
  let speechRecognition: Status

  @MainActor
  static func current() -> MobilePermissionSnapshot {
    MobilePermissionSnapshot(
      calendar: calendarStatus(EKEventStore.authorizationStatus(for: .event)),
      microphone: microphoneStatus(AVAudioApplication.shared.recordPermission),
      speechRecognition: speechStatus(SFSpeechRecognizer.authorizationStatus())
    )
  }

  static func calendarStatus(_ status: EKAuthorizationStatus) -> Status {
    switch status {
    case .fullAccess, .authorized: .granted("Full Access")
    case .writeOnly: .limited("Add Only")
    case .notDetermined: .notRequested
    case .restricted: .limited("Restricted")
    case .denied: .denied
    @unknown default: .limited("Limited")
    }
  }

  static func microphoneStatus(_ status: AVAudioApplication.recordPermission) -> Status {
    switch status {
    case .granted: .granted("Allowed")
    case .undetermined: .notRequested
    case .denied: .denied
    @unknown default: .limited("Limited")
    }
  }

  static func speechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> Status {
    switch status {
    case .authorized: .granted("Allowed")
    case .notDetermined: .notRequested
    case .restricted: .limited("Restricted")
    case .denied: .denied
    @unknown default: .limited("Limited")
    }
  }
}

struct MobileAppMetadata: Equatable {
  let version: String
  let build: String

  static var current: MobileAppMetadata {
    MobileAppMetadata(
      version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    )
  }
}

private struct MobileSettingsStatusRow: View {
  let symbol: String
  let color: Color
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.title3.weight(.semibold))
        .foregroundStyle(color)
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

private struct MobilePermissionRow: View {
  let symbol: String
  let title: String
  let status: MobilePermissionSnapshot.Status

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        permissionLabel
        Spacer(minLength: 12)
        statusLabel
      }

      VStack(alignment: .leading, spacing: 8) {
        permissionLabel
        statusLabel
          .padding(.leading, 36)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title), \(status.label)")
    .frame(minHeight: 44)
  }

  private var permissionLabel: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .accessibilityHidden(true)
      Text(title)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private var statusLabel: some View {
    Label(status.label, systemImage: status.symbol)
      .font(.subheadline)
      .foregroundStyle(status.color)
      .labelStyle(.titleAndIcon)
      .fixedSize(horizontal: true, vertical: false)
  }
}

private struct MobileSettingsInfoRow: View {
  let symbol: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
