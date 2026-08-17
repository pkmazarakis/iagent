import SwiftUI

struct NotesListView: View {
    @ObservedObject var controller: PanelController
    @State private var hoveredNoteID: String?

    var body: some View {
        Group {
            if controller.notes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.notes) { note in
                            noteRow(note)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            controller.reloadNotes()
        }
    }

    private func noteRow(_ note: LocalDocument) -> some View {
        Button {
            controller.openNote(note)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isMeeting(note) ? "waveform.and.mic" : "note.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isMeeting(note) ? Color.agentBlue : Color.agentAmber)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(previewText(for: note))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(updatedText(for: note.updatedAt))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
                    .fixedSize()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(hoveredNoteID == note.id ? 0.5 : 0.22))
                    .frame(width: 12)
            }
            .padding(.horizontal, PanelPageLayout.contentInset)
            .frame(height: 48)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(hoveredNoteID == note.id ? 0.055 : 0))
                    .padding(.horizontal, 8)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.055))
                    .frame(height: 1)
                    .padding(.leading, 58)
                    .padding(.trailing, PanelPageLayout.contentInset)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveredNoteID = hovering ? note.id : nil
            }
        }
        .accessibilityLabel("Open note \(note.title)")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: controller.noteListIssue == nil ? "note.text" : "exclamationmark.icloud")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.34))

            Text(controller.noteListIssue == nil ? "No notes yet" : "Notes are unavailable")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))

            Text(controller.noteListIssue ?? "Create a note and it will appear here.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isMeeting(_ note: LocalDocument) -> Bool {
        MeetingNoteCodec.isMeetingNote(note.body)
    }

    private func previewText(for note: LocalDocument) -> String {
        let source: String
        if let meeting = MeetingNoteCodec.parse(note.body) {
            let summary = meeting.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty, summary != MeetingNoteCodec.pendingSummary {
                source = summary
            } else {
                source = meeting.transcriptSegments.map(\.text).joined(separator: " ")
            }
        } else {
            source = note.body
        }

        let plain = source
            .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(
                of: #"\[([^\]]+)\]\([^)]+\)"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?m)^\s{0,3}(?:#{1,6}\s+|>\s+|(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s*)?)"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"[`*_~]+"#, with: "", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return plain.isEmpty ? "Empty note" : plain
    }

    private func updatedText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
