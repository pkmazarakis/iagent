import SwiftUI
import iAgentCore

struct NotesMobileView: View {
  @ObservedObject var model: MobileAppModel
  @Binding var noteEditor: NoteEditorRoute?

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.38) {
        hero
      } drawer: {
        LazyVStack(spacing: 0) {
          HStack {
            JoiSectionHeader(title: "Library", count: model.visibleNotes.count)
            Button {
              noteEditor = NoteEditorRoute(note: nil)
            } label: {
              Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(PanelTheme.primary)
                .frame(width: 42, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New note")
          }

          if model.visibleNotes.isEmpty {
            EmptyPanelState(
              symbol: "note.text",
              title: "A blank library",
              detail: "Write something here and it stays available offline."
            )
          } else {
            ForEach(Array(model.visibleNotes.enumerated()), id: \.element.id) { index, note in
              Button {
                noteEditor = NoteEditorRoute(note: note)
              } label: {
                JoiNoteRow(note: note)
              }
              .buttonStyle(.plain)
              .contextMenu {
                Button(role: .destructive) {
                  Task { await model.deleteNote(note) }
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }

              if index < model.visibleNotes.count - 1 { JoiDottedDivider() }
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
        title: "Notes",
        metric: "\(model.visibleNotes.count)",
        metricLabel: "saved locally",
        accent: PanelTheme.violet
      )

      notesBriefing
        .font(.system(size: 20, weight: .semibold))
        .lineSpacing(3)
        .padding(.top, 30)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, PanelTheme.horizontalPadding)
    .padding(.top, 14)
  }

  private var notesBriefing: Text {
    let meetingCount = model.visibleNotes.filter { $0.kind == .meeting }.count
    return Text("Your ideas stay close. ")
      .foregroundStyle(PanelTheme.secondary)
      + Text("\(model.visibleNotes.count) notes")
      .foregroundStyle(PanelTheme.primary)
      + Text(meetingCount > 0 ? " including " : ".")
      .foregroundStyle(PanelTheme.secondary)
      + Text(meetingCount > 0 ? "\(meetingCount) meeting \(meetingCount == 1 ? "record" : "records")." : "")
      .foregroundStyle(PanelTheme.primary)
  }
}

private struct JoiNoteRow: View {
  let note: SyncedNote

  var body: some View {
    JoiTimelineRow(minHeight: 66) {
      Image(systemName: note.kind == .meeting ? "waveform" : "note.text")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(note.kind == .meeting ? PanelTheme.amber : PanelTheme.secondary)
    } content: {
      VStack(alignment: .leading, spacing: 4) {
        Text(note.title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(PanelTheme.primary)
          .lineLimit(1)

        Text(note.body.plainTextPreview)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(PanelTheme.tertiary)
          .lineLimit(1)
      }
    } trailing: {
      Text(note.updatedAt.compactRelative())
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
        .monospacedDigit()
    }
  }
}

struct NoteEditorView: View {
  enum Mode {
    case edit
    case preview
  }

  @ObservedObject var model: MobileAppModel
  let route: NoteEditorRoute

  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var bodyText: String
  @State private var mode: Mode = .edit
  @State private var isSaving = false

  init(model: MobileAppModel, route: NoteEditorRoute) {
    self.model = model
    self.route = route
    _title = State(initialValue: route.note?.title ?? "")
    _bodyText = State(initialValue: route.note?.body ?? "")
  }

  var body: some View {
    PanelScreen {
      VStack(spacing: 0) {
        editorHeader

        JoiTimelineSheet(minHeight: 0) {
          Group {
            if mode == .edit {
              editor
                .transition(.opacity)
            } else {
              preview
                .transition(.opacity)
            }
          }
          .animation(PanelTheme.quick, value: mode)
        }
        .frame(maxHeight: .infinity)
      }
    }
    .preferredColorScheme(.dark)
  }

  private var editorHeader: some View {
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

      Text(route.note == nil ? "New note" : "Note")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(PanelTheme.secondary)

      Spacer()

      Button {
        Task { await save() }
      } label: {
        Group {
          if isSaving {
            ProgressView().tint(.black)
          } else {
            Text("Save")
              .font(.system(size: 13, weight: .bold))
          }
        }
        .foregroundStyle(.black)
        .frame(width: 56, height: 40)
        .background(PanelTheme.primary, in: Capsule())
      }
      .buttonStyle(.plain)
      .disabled(isSaving)
    }
    .padding(.horizontal, 20)
    .frame(height: 82)
  }

  private var editor: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Title", text: $title, axis: .vertical)
          .font(.system(size: 30, weight: .bold))
          .foregroundStyle(PanelTheme.primary)
          .textFieldStyle(.plain)

        Button {
          mode = .preview
        } label: {
          Image(systemName: "doc.richtext")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(PanelTheme.secondary)
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview")
      }
      .padding(.horizontal, 24)
      .padding(.top, 28)
      .padding(.bottom, 16)

      JoiDottedDivider(inset: 24)

      TextEditor(text: $bodyText)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(PanelTheme.primary)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 19)
        .padding(.vertical, 18)
        .background(PanelTheme.sheet)
    }
  }

  private var preview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text(title.nonEmpty ?? "Untitled note")
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(PanelTheme.primary)
          Spacer()
          Button { mode = .edit } label: {
            Image(systemName: "pencil")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(PanelTheme.secondary)
              .frame(width: 38, height: 38)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Edit")
        }

        Text(markdownPreview)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(PanelTheme.primary)
          .lineSpacing(6)
          .textSelection(.enabled)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func save() async {
    isSaving = true
    _ = await model.saveNote(
      id: route.note?.id,
      title: title,
      body: bodyText,
      kind: route.note?.kind ?? .note
    )
    isSaving = false
    dismiss()
  }

  private var markdownPreview: AttributedString {
    (try? AttributedString(markdown: bodyText)) ?? AttributedString(bodyText)
  }
}

private extension String {
  var plainTextPreview: String {
    replacingOccurrences(of: "#", with: "")
      .replacingOccurrences(of: "*", with: "")
      .replacingOccurrences(of: "_", with: "")
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
      ?? "Empty note"
  }

  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
