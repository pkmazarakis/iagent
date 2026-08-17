import SwiftUI
import iAgentCore

enum MobileDeepLinkDestination: Identifiable, Equatable {
  case note(SyncedNote?)
  case todo(SyncedTodo)
  case todoDraft
  case codex(SyncedCodexThread)
  case codexDraft

  var id: String {
    switch self {
    case .note(let note): "note-\(note?.id.uuidString ?? "create")"
    case .todo(let todo): "todo-\(todo.id.uuidString)"
    case .todoDraft: "todo-create"
    case .codex(let task): "codex-\(task.id)"
    case .codexDraft: "codex-create"
    }
  }
}

struct CodexRequestDraftView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var prompt = ""
  @FocusState private var isPromptFocused: Bool

  var body: some View {
    PanelScreen {
      VStack(spacing: 0) {
        HStack {
          Button { dismiss() } label: {
            Image(systemName: "xmark")
              .font(.system(size: 14, weight: .bold))
              .foregroundStyle(PanelTheme.primary)
              .frame(width: 40, height: 40)
              .background(PanelTheme.surface, in: Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Close")

          Spacer()
          Text("New Codex request")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(PanelTheme.secondary)
          Spacer()
          Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 20)
        .frame(height: 82)

        JoiTimelineSheet(minHeight: 0) {
          VStack(alignment: .leading, spacing: 20) {
            Label("DRAFT ONLY", systemImage: "lock.shield")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(PanelTheme.green)

            Text("What should Codex work on?")
              .font(.system(size: 30, weight: .bold))
              .foregroundStyle(PanelTheme.primary)

            TextEditor(text: $prompt)
              .font(.system(size: 17, weight: .medium))
              .foregroundStyle(PanelTheme.primary)
              .scrollContentBackground(.hidden)
              .focused($isPromptFocused)
              .frame(minHeight: 180)
              .padding(14)
              .background(PanelTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
              .overlay(alignment: .topLeading) {
                if prompt.isEmpty {
                  Text("Describe the task…")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(PanelTheme.tertiary)
                    .padding(.horizontal, 19)
                    .padding(.vertical, 22)
                    .allowsHitTesting(false)
                }
              }

            Text("iAgent keeps this screen local. It does not create or run a Codex task from your widget.")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(PanelTheme.secondary)
              .lineSpacing(4)

            Button("Done") { dismiss() }
              .font(.system(size: 15, weight: .bold))
              .foregroundStyle(.black)
              .frame(maxWidth: .infinity)
              .frame(height: 48)
              .background(PanelTheme.primary, in: Capsule())
              .buttonStyle(.plain)

            Spacer()
          }
          .padding(24)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
    }
    .preferredColorScheme(.dark)
    .task { isPromptFocused = true }
  }
}
