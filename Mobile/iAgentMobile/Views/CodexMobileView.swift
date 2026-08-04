import SwiftUI
import iAgentCore

struct CodexMobileView: View {
  @ObservedObject var model: MobileAppModel
  @State private var expandedProjects = Set<String>()

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.38) {
        hero
      } drawer: {
        LazyVStack(spacing: 0) {
          if model.snapshot.codexThreads.isEmpty {
            EmptyPanelState(
              symbol: "sparkles",
              title: "No synced work",
              detail: "Codex activity from your Mac will settle here."
            )
            .padding(.top, 36)
          } else {
            if !model.activeThreads.isEmpty {
              JoiSectionHeader(title: "Live", count: model.activeThreads.count)
              threadList(model.activeThreads, showsProject: true)
            }

            JoiSectionHeader(title: "Projects", count: projectGroups.count)

            ForEach(projectGroups, id: \.name) { group in
              JoiProjectDisclosureRow(
                name: group.name,
                count: group.threads.count,
                isExpanded: expandedProjects.contains(group.name)
              ) {
                withAnimation(PanelTheme.disclosure) {
                  if expandedProjects.contains(group.name) {
                    expandedProjects.remove(group.name)
                  } else {
                    expandedProjects.insert(group.name)
                  }
                }
              }

              if expandedProjects.contains(group.name) {
                ForEach(Array(group.threads.enumerated()), id: \.element.id) { index, thread in
                  NavigationLink {
                    CodexThreadDetailView(thread: thread)
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

    return Text(active == 0 ? "Everything is quiet. " : "Your agents are moving. ")
      .foregroundStyle(PanelTheme.secondary)
      + Text("\(active) \(active == 1 ? "thread" : "threads") live")
      .foregroundStyle(PanelTheme.primary)
      + Text(attention > 0 ? ", with " : ".")
      .foregroundStyle(PanelTheme.secondary)
      + Text(attention > 0 ? "\(attention) waiting for you." : "")
      .foregroundStyle(PanelTheme.primary)
  }

  @ViewBuilder
  private func threadList(_ threads: [SyncedCodexThread], showsProject: Bool) -> some View {
    ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
      NavigationLink {
        CodexThreadDetailView(thread: thread)
      } label: {
        JoiCodexThreadRow(thread: thread, showsProject: showsProject)
      }
      .buttonStyle(.plain)

      if index < threads.count - 1 { JoiDottedDivider() }
    }
  }

  private var projectGroups: [(name: String, threads: [SyncedCodexThread])] {
    let visible = model.snapshot.codexThreads.filter { $0.deletedAt == nil }
    let grouped = Dictionary(grouping: visible) { $0.projectName ?? "Other" }
    let preferredOrder = model.snapshot.desktopSnapshot?.projectOrder ?? []
    return grouped.map { (name: $0.key, threads: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
      .sorted { lhs, rhs in
        let left = preferredOrder.firstIndex(of: lhs.name) ?? .max
        let right = preferredOrder.firstIndex(of: rhs.name) ?? .max
        return left == right
          ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
          : left < right
      }
  }
}

private struct JoiProjectDisclosureRow: View {
  let name: String
  let count: Int
  let isExpanded: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
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
      StatusMark(state: thread.state)
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
      Color.clear.frame(width: 24, height: 24)

      Text(thread.title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(thread.state == .completed ? PanelTheme.secondary : PanelTheme.primary)
        .lineLimit(1)

      Spacer(minLength: 8)

      StatusMark(state: thread.state)

      Text(thread.updatedAt.compactRelative())
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
        .monospacedDigit()
    }
    .padding(.leading, 38)
    .padding(.trailing, 24)
    .frame(minHeight: 54)
    .contentShape(Rectangle())
  }
}

private struct CodexThreadDetailView: View {
  let thread: SyncedCodexThread
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    PanelScreen {
      ScrollView {
        VStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 22) {
            JoiBackButton { dismiss() }

            Text(thread.title)
              .font(.system(size: 36, weight: .bold))
              .foregroundStyle(PanelTheme.primary)
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
          .padding(.horizontal, PanelTheme.horizontalPadding)
          .padding(.top, 8)
          .padding(.bottom, 28)

          JoiTimelineSheet {
            VStack(alignment: .leading, spacing: 18) {
              Text("LATEST ACTIVITY")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(PanelTheme.tertiary)

              Text(thread.activity)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PanelTheme.primary)
                .lineSpacing(5)

              if !thread.modes.isEmpty {
                HStack(spacing: 10) {
                  ForEach(thread.modes, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.symbol)
                      .font(.system(size: 11, weight: .bold))
                      .foregroundStyle(PanelTheme.secondary)
                  }
                }
              }
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 100)
          }
        }
      }
    }
    .toolbar(.hidden, for: .navigationBar)
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
