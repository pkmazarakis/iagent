import SwiftUI
import iAgentCore

struct CodexMobileView: View {
  @ObservedObject var model: MobileAppModel
  @State private var expandedProjects = Set<String>()
  @State private var knownProjectIDs = Set<String>()

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.38) {
        hero
      } drawer: {
        LazyVStack(spacing: 0) {
          if let syncNotice {
            CodexSyncNotice(message: syncNotice)
            JoiDottedDivider(inset: 20)
          }

          if model.snapshot.codexThreads.isEmpty {
            VStack(spacing: 0) {
              EmptyPanelState(
                symbol: model.hasDesktopSnapshot ? "sparkles" : "desktopcomputer",
                title: emptyStateTitle,
                detail: emptyStateDetail
              )

              JoiDrawerButton {
                Task { await model.refresh() }
              } label: {
                Label(
                  model.syncStatus.phase == .syncing ? "Syncing" : "Sync now",
                  systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(PanelTheme.primary)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(PanelTheme.surface, in: Capsule())
              }
              .buttonStyle(.plain)
              .disabled(model.syncStatus.phase == .syncing)
            }
            .padding(.top, 24)
          } else {
            if !model.activeThreads.isEmpty {
              JoiSectionHeader(title: "Live", count: model.activeThreads.count)
              threadList(model.activeThreads, showsProject: true)
            }

            JoiSectionHeader(title: "Projects", count: projectGroups.count)

            ForEach(projectGroups, id: \.id) { group in
              JoiProjectDisclosureRow(
                name: group.name,
                count: group.threads.count,
                isExpanded: expandedProjects.contains(group.id)
              ) {
                withAnimation(PanelTheme.disclosure) {
                  if expandedProjects.contains(group.id) {
                    expandedProjects.remove(group.id)
                  } else {
                    expandedProjects.insert(group.id)
                  }
                }
              }

              if expandedProjects.contains(group.id) {
                ForEach(Array(group.threads.enumerated()), id: \.element.id) { index, thread in
                  JoiDrawerNavigationLink {
                    CodexThreadDetailView(model: model, thread: thread)
                  } label: {
                    JoiProjectThreadRow(thread: thread)
                  }
                  .buttonStyle(.plain)
                  .transition(.opacity.combined(with: .move(edge: .top)))

                  if index < group.threads.count - 1 { JoiDottedDivider(inset: 62) }
                }
              }
            }
          }
        }
        .padding(.bottom, 96)
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .onAppear {
      revealNewProjects(projectIDs)
    }
    .onChange(of: projectIDs) { _, ids in
      revealNewProjects(ids)
    }
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 0) {
      JoiPageMasthead(
        title: "Codex",
        metric: "\(model.activeThreads.count)",
        metricLabel: model.activeThreads.count == 1 ? "task live" : "tasks live",
        accent: PanelTheme.green
      )

      codexBriefing
        .font(.system(size: 20, weight: .semibold))
        .lineSpacing(3)
        .padding(.top, 30)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, PanelTheme.horizontalPadding)
    .padding(.top, 14)
  }

  private var codexBriefing: Text {
    let active = model.activeThreads.count
    let attention = model.activeThreads.filter { $0.state == .needsApproval || $0.state == .waitingForInput }.count

    if !model.hasDesktopSnapshot {
      return Text("Waiting for your Mac. ")
        .foregroundStyle(PanelTheme.primary)
        + Text("No desktop snapshot has reached this iPhone yet.")
        .foregroundStyle(PanelTheme.secondary)
    }

    return Text(active == 0 ? "Everything is quiet. " : "Your agents are moving. ")
      .foregroundStyle(PanelTheme.secondary)
      + Text("\(active) \(active == 1 ? "thread" : "threads") live")
      .foregroundStyle(PanelTheme.primary)
      + Text(attention > 0 ? ", with " : ".")
      .foregroundStyle(PanelTheme.secondary)
      + Text(attention > 0 ? "\(attention) waiting for you." : "")
      .foregroundStyle(PanelTheme.primary)
  }

  private var emptyStateTitle: String {
    guard model.hasDesktopSnapshot else { return "Waiting for your Mac" }
    if let reportedCount = model.snapshot.desktopSnapshot?.activeCodexCount,
       reportedCount > 0 {
      return "Threads are still arriving"
    }
    return "No active Codex work"
  }

  private var emptyStateDetail: String {
    guard let desktop = model.snapshot.desktopSnapshot else {
      return "Keep iAgent open on your Mac, confirm both devices use the same iCloud account, then sync again."
    }
    if desktop.activeCodexCount > 0 {
      return "\(desktop.deviceName) reports \(desktop.activeCodexCount) live \(desktop.activeCodexCount == 1 ? "task" : "tasks"). Pull to fetch the thread details."
    }
    return "The latest snapshot from \(desktop.deviceName) reports no active threads."
  }

  @ViewBuilder
  private func threadList(_ threads: [SyncedCodexThread], showsProject: Bool) -> some View {
    ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
      JoiDrawerNavigationLink {
        CodexThreadDetailView(model: model, thread: thread)
      } label: {
        JoiCodexThreadRow(thread: thread, showsProject: showsProject)
      }
      .buttonStyle(.plain)

      if index < threads.count - 1 { JoiDottedDivider() }
    }
  }

  private var projectGroups: [(id: String, name: String, threads: [SyncedCodexThread])] {
    let visible = model.snapshot.codexThreads.filter { $0.deletedAt == nil && !$0.state.isActive }
    let grouped = Dictionary(grouping: visible) { thread in
      thread.workspaceID ?? thread.projectName.map { "project:\($0.lowercased())" } ?? "home"
    }
    let preferredOrder = model.snapshot.desktopSnapshot?.projectOrder ?? []
    return grouped.map {
      (
        id: $0.key,
        name: $0.value.first?.projectName ?? "Other",
        threads: $0.value.sorted { $0.updatedAt > $1.updatedAt }
      )
    }
      .sorted { lhs, rhs in
        let left = preferredOrder.firstIndex(of: lhs.id)
          ?? preferredOrder.firstIndex(of: lhs.name)
          ?? .max
        let right = preferredOrder.firstIndex(of: rhs.id)
          ?? preferredOrder.firstIndex(of: rhs.name)
          ?? .max
        return left == right
          ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
          : left < right
      }
  }

  private var projectIDs: [String] {
    projectGroups.map(\.id)
  }

  private func revealNewProjects(_ ids: [String]) {
    let next = Set(ids)
    expandedProjects.formUnion(next.subtracting(knownProjectIDs))
    knownProjectIDs = next
  }

  private var syncNotice: String? {
    if model.snapshot.desktopSnapshot?.codexAvailability == .unavailable {
      return "Mac task discovery is unavailable. Showing the last known tasks."
    }
    if let lastObserved = model.snapshot.desktopSnapshot?.codexLastObservedAt,
       Date().timeIntervalSince(lastObserved) > 10 * 60 {
      return "The Mac has not checked in recently. Showing the last known tasks."
    }
    switch model.syncStatus.phase {
    case .offline:
      return "Offline. Showing tasks saved on this device."
    case .accountUnavailable, .failed:
      return "Task sync is unavailable. Showing the last saved tasks."
    case .idle, .syncing:
      return nil
    }
  }
}

private struct CodexSyncNotice: View {
  let message: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "info.circle")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(PanelTheme.amber)
      Text(message)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(PanelTheme.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 20)
    .frame(minHeight: 48)
  }
}

private struct JoiProjectDisclosureRow: View {
  let name: String
  let count: Int
  let isExpanded: Bool
  let action: () -> Void

  var body: some View {
    JoiDrawerButton(action: action) {
      JoiTimelineRow(minHeight: 58) {
        Image(systemName: "folder")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(PanelTheme.secondary)
      } content: {
        HStack(spacing: 9) {
          Text(name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(PanelTheme.primary)
            .lineLimit(1)
          Text("\(count)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PanelTheme.tertiary)
            .contentTransition(.numericText())
        }
      } trailing: {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(PanelTheme.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
      }
    }
    .buttonStyle(.plain)
  }
}

private struct JoiCodexThreadRow: View {
  let thread: SyncedCodexThread
  let showsProject: Bool

  var body: some View {
    JoiTimelineRow(minHeight: 62) {
      CodexThreadStatusIndicator(state: thread.state)
    } content: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 10) {
          Text(thread.title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(thread.state == .completed ? PanelTheme.secondary : PanelTheme.primary)
            .lineLimit(1)
            .layoutPriority(1)

          if showsProject, let project = thread.projectName {
            Text(project)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(PanelTheme.tertiary)
              .lineLimit(1)
          }
        }

        Text(thread.activity)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(PanelTheme.tertiary)
          .lineLimit(1)
      }
    } trailing: {
      Text(thread.updatedAt.compactRelative())
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
        .monospacedDigit()
    }
  }
}

private struct JoiProjectThreadRow: View {
  let thread: SyncedCodexThread

  var body: some View {
    HStack(spacing: 14) {
      CodexThreadStatusIndicator(state: thread.state)
        .frame(width: 24, height: 24)

      Text(thread.title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(thread.state == .completed ? PanelTheme.secondary : PanelTheme.primary)
        .lineLimit(1)

      Spacer(minLength: 8)

      Text(thread.updatedAt.compactRelative())
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
        .monospacedDigit()
    }
    .padding(.leading, 24)
    .padding(.trailing, 24)
    .frame(minHeight: 54)
    .contentShape(Rectangle())
  }
}

/// A running thread gets a motion affordance local to the Codex list. Waiting,
/// approval, completed, and failed rows retain their existing static semantics.
private struct CodexThreadStatusIndicator: View {
  let state: SyncedCodexState

  var body: some View {
    if state == .running {
      ProgressView()
        .progressViewStyle(.circular)
        .controlSize(.small)
        .tint(PanelTheme.green)
      .frame(width: 20, height: 20)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Active work in progress")
      .accessibilityValue("Running")
    } else {
      StatusMark(state: state)
    }
  }
}

struct CodexThreadDetailView: View {
  @ObservedObject var model: MobileAppModel
  let threadID: String
  let fallbackThread: SyncedCodexThread
  @Environment(\.dismiss) private var dismiss

  init(model: MobileAppModel, thread: SyncedCodexThread) {
    self.model = model
    threadID = thread.id
    fallbackThread = thread
  }

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.38) {
        threadHero
      } drawer: {
        threadActivity
      }
      .scrollIndicators(.hidden)
    }
    .toolbar(.hidden, for: .navigationBar)
    .accessibilityIdentifier("codex-thread-detail-page")
  }

  private var threadHero: some View {
    VStack(alignment: .leading, spacing: 22) {
      JoiBackButton { dismiss() }

      Text(thread.title)
        .font(.system(size: 36, weight: .bold))
        .foregroundStyle(PanelTheme.primary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        StatusMark(state: thread.state)
        Text(thread.state.accessibilityLabel)
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(statusColor)
        if let project = thread.projectName {
          Text("·")
            .foregroundStyle(PanelTheme.tertiary)
          Text(project)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PanelTheme.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, PanelTheme.horizontalPadding)
    .padding(.top, 8)
  }

  private var threadActivity: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("THREAD ACTIVITY")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(PanelTheme.tertiary)
        .padding(.bottom, 22)

      ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
        HStack(alignment: .top, spacing: 13) {
          Circle()
            .fill(index == 0 ? statusColor : PanelTheme.strongBorder)
            .frame(width: 7, height: 7)
            .padding(.top, 6)

          VStack(alignment: .leading, spacing: 6) {
            Text(activity.text)
              .font(.system(size: index == 0 ? 18 : 15, weight: .semibold))
              .foregroundStyle(index == 0 ? PanelTheme.primary : PanelTheme.secondary)
              .multilineTextAlignment(.leading)
              .lineSpacing(4)
              .fixedSize(horizontal: false, vertical: true)

            Text(activity.occurredAt.formatted(date: .abbreviated, time: .shortened))
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(PanelTheme.tertiary)
              .monospacedDigit()
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        if index < activities.count - 1 {
          JoiDottedDivider(inset: 20)
            .padding(.vertical, 18)
        }
      }

      if !thread.modes.isEmpty {
        JoiDottedDivider(inset: 0)
          .padding(.vertical, 20)

        HStack(spacing: 10) {
          ForEach(thread.modes, id: \.self) { mode in
            Label(mode.label, systemImage: mode.symbol)
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(PanelTheme.secondary)
          }
        }
      }

      Text("Created \(thread.createdAt.formatted(date: .abbreviated, time: .shortened)) · Updated \(thread.updatedAt.compactRelative())")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(PanelTheme.tertiary)
        .padding(.top, 24)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 24)
    .padding(.top, 30)
    .padding(.bottom, 100)
    .accessibilityIdentifier("codex-thread-activity-drawer")
  }

  private var thread: SyncedCodexThread {
    model.snapshot.codexThreads.first(where: { $0.id == threadID && $0.deletedAt == nil })
      ?? fallbackThread
  }

  private var activities: [SyncedCodexActivity] {
    var values = thread.activityHistory ?? []
    if !values.contains(where: { $0.text == thread.activity }) {
      values.append(
        SyncedCodexActivity(
          id: "\(thread.id)-latest-\(Int(thread.updatedAt.timeIntervalSince1970))",
          text: thread.activity,
          occurredAt: thread.updatedAt
        )
      )
    }
    return Array(values.sorted { $0.occurredAt > $1.occurredAt }.prefix(12))
  }

  private var statusColor: Color {
    switch thread.state {
    case .running: PanelTheme.green
    case .waitingForInput: PanelTheme.blue
    case .needsApproval: PanelTheme.amber
    case .completed: PanelTheme.secondary
    case .failed: PanelTheme.coral
    }
  }
}

private extension SyncedThreadMode {
  var label: String {
    switch self {
    case .plan: "Plan"
    case .goal: "Goal"
    case .voice: "Voice"
    }
  }

  var symbol: String {
    switch self {
    case .plan: "lightbulb"
    case .goal: "scope"
    case .voice: "waveform"
    }
  }
}
