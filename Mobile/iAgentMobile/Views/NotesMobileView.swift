import SwiftUI
import UIKit
import iAgentCore

struct NotesMobileView: View {
  @ObservedObject var model: MobileAppModel
  @Binding var noteEditor: NoteEditorRoute?
  let onNoteRowSwipeActivityChanged: (Bool) -> Void
  @State private var revealedNoteID: UUID?

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.38) {
        hero
      } drawer: {
        LazyVStack(spacing: 0) {
          JoiDrawerButton {
            noteEditor = NoteEditorRoute(note: nil)
          } label: {
            HStack(spacing: 12) {
              Text("Create new note")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PanelTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

              Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 36, height: 36)
                .background(PanelTheme.primary, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 66)
            .contentShape(Rectangle())
          }
          .buttonStyle(JoiNoteCreateButtonStyle())
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Create new note")
          .accessibilityHint("Opens the note editor")
          .accessibilityIdentifier("notes-create-button")

          JoiDottedDivider()
          JoiSectionHeader(title: "Library", count: model.visibleNotes.count)

          if model.visibleNotes.isEmpty {
            EmptyPanelState(
              symbol: "note.text",
              title: "A blank library",
              detail: "Write something here and it stays available offline."
            )
          } else {
            ForEach(Array(model.visibleNotes.enumerated()), id: \.element.id) { index, note in
              JoiSwipeNoteRow(
                note: note,
                isRevealed: revealedNoteID == note.id,
                isPageActive: model.selectedTab == .notes,
                onHorizontalSwipeActivityChanged: onNoteRowSwipeActivityChanged,
                onReveal: {
                  withAnimation(PanelTheme.quick) { revealedNoteID = note.id }
                },
                onClose: {
                  guard revealedNoteID == note.id else { return }
                  withAnimation(PanelTheme.quick) { revealedNoteID = nil }
                },
                onOpen: {
                  revealedNoteID = nil
                  noteEditor = NoteEditorRoute(note: note)
                },
                onDelete: {
                  revealedNoteID = nil
                  Task { await model.deleteNote(note) }
                }
              )

              if index < model.visibleNotes.count - 1 { JoiDottedDivider() }
            }
          }
        }
        .padding(.bottom, 96)
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .onChange(of: model.selectedTab) { _, selectedTab in
      guard selectedTab != .notes else { return }
      onNoteRowSwipeActivityChanged(false)
      guard revealedNoteID != nil else { return }
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        revealedNoteID = nil
      }
    }
    .onChange(of: model.visibleNotes, initial: true) { _, notes in
      guard ProcessInfo.processInfo.arguments.contains("--note-swipe-revealed-fixture"),
            revealedNoteID == nil,
            let firstNote = notes.first
      else { return }
      revealedNoteID = firstNote.id
    }
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

private struct JoiNoteCreateButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? PanelTheme.raisedSurface : Color.clear)
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
      .animation(PanelTheme.quick, value: configuration.isPressed)
  }
}

private struct JoiSwipeNoteRow: View {
  let note: SyncedNote
  let isRevealed: Bool
  let isPageActive: Bool
  let onHorizontalSwipeActivityChanged: (Bool) -> Void
  let onReveal: () -> Void
  let onClose: () -> Void
  let onOpen: () -> Void
  let onDelete: () -> Void

  @State private var dragTranslation: CGFloat = 0
  @State private var suppressesActivation = false
  @State private var isHorizontalSwipeActive = false
  @State private var swipeSequence = 0
  @Environment(\.joiDrawerActivationGate) private var drawerActivationGate

  private let deleteWidth: CGFloat = 92

  private var rowOffset: CGFloat {
    min(0, max(-deleteWidth, (isRevealed ? -deleteWidth : 0) + dragTranslation))
  }

  private var revealProgress: CGFloat {
    min(1, max(0, -rowOffset / deleteWidth))
  }

  private var showsDeleteAction: Bool {
    isPageActive && (isRevealed || dragTranslation < 0)
  }

  var body: some View {
    ZStack(alignment: .trailing) {
      if showsDeleteAction {
        JoiDrawerButton(role: .destructive) {
          onDelete()
        } label: {
          VStack(spacing: 3) {
            Image(systemName: "trash")
              .font(.system(size: 15, weight: .semibold))
            Text("Delete")
              .font(.system(size: 11, weight: .bold))
          }
          .foregroundStyle(.white)
          .frame(width: deleteWidth, height: 66)
          .background(PanelTheme.coral)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(!isRevealed)
      }

      HStack(spacing: 14) {
        Image(systemName: note.kind == .meeting ? "waveform" : "note.text")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(note.kind == .meeting ? PanelTheme.amber : PanelTheme.secondary)
          .frame(width: 22)

        Text(note.title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(PanelTheme.primary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
          .layoutPriority(1)

        Text(note.updatedAt.compactRelative())
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(PanelTheme.secondary)
          .monospacedDigit()
          .lineLimit(1)
      }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: 66, maxHeight: 66, alignment: .leading)
        .background(PanelTheme.sheet)
        .overlay(alignment: .trailing) {
          JoiNoteDrawerEdge(revealProgress: revealProgress)
        }
        .overlay {
          JoiNoteRowInteractionSurface(
            isEnabled: isPageActive,
            onTap: activateRow,
            onChanged: updateHorizontalReveal,
            onEnded: finishHorizontalReveal
          )
        }
        .contentShape(Rectangle())
        .offset(x: rowOffset)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(note.title)
        .accessibilityValue(
          "\(note.kind == .meeting ? "Meeting note" : "Note"), updated \(note.updatedAt.compactRelative())"
        )
        .accessibilityHint(
          isRevealed
            ? "Closes the note actions"
            : "Opens this \(note.kind == .meeting ? "meeting note" : "note")"
        )
        .accessibilityAction {
          if isRevealed { onClose() } else { onOpen() }
        }
        .accessibilityAction(named: "Delete note") { onDelete() }
    }
    .frame(maxWidth: .infinity, minHeight: 66, maxHeight: 66)
    .clipped()
    .onChange(of: isRevealed) { _, revealed in
      guard !revealed else { return }
      dragTranslation = 0
    }
    .onDisappear {
      onHorizontalSwipeActivityChanged(false)
    }
  }

  private func activateRow() {
    guard !suppressesActivation,
          drawerActivationGate?.blocksActivation != true
    else { return }

    if isRevealed {
      onClose()
    } else {
      onOpen()
    }
  }

  private func updateHorizontalReveal(_ translation: CGFloat) {
    if !isHorizontalSwipeActive {
      swipeSequence += 1
      isHorizontalSwipeActive = true
      onHorizontalSwipeActivityChanged(true)
    }
    suppressesActivation = true
    dragTranslation = translation
  }

  private func finishHorizontalReveal(
    translation: CGFloat,
    projectedTranslation: CGFloat,
    cancelled: Bool
  ) {
    guard !cancelled else {
      dragTranslation = 0
      if suppressesActivation { releaseHorizontalSwipe() }
      return
    }

    let projectedOffset = (isRevealed ? -deleteWidth : 0) + projectedTranslation
    if projectedOffset < -deleteWidth * 0.42 {
      onReveal()
    } else {
      onClose()
    }
    withAnimation(PanelTheme.quick) {
      dragTranslation = 0
    }

    // The tap recognizer waits for this horizontal recognizer to fail. Keep
    // activation suppressed through finger-up so a swipe can never open a note.
    releaseHorizontalSwipe()
  }

  private func releaseHorizontalSwipe() {
    isHorizontalSwipeActive = false
    let endingSequence = swipeSequence
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(160))
      guard endingSequence == swipeSequence, !isHorizontalSwipeActive else { return }
      suppressesActivation = false
      onHorizontalSwipeActivityChanged(false)
    }
  }
}

/// A row-local interaction surface whose pan recognizer fails before beginning
/// unless the gesture is decisively horizontal. SwiftUI's `DragGesture` begins
/// before its `onChanged` direction checks run, which prevents an enclosing
/// `UIScrollView` from receiving vertical drags that start on a note row.
private struct JoiNoteRowInteractionSurface: UIViewRepresentable {
  let isEnabled: Bool
  let onTap: () -> Void
  let onChanged: (CGFloat) -> Void
  let onEnded: (_ translation: CGFloat, _ projectedTranslation: CGFloat, _ cancelled: Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isEnabled: isEnabled,
      onTap: onTap,
      onChanged: onChanged,
      onEnded: onEnded
    )
  }

  func makeUIView(context: Context) -> UIView {
    let view = UIView(frame: .zero)
    view.backgroundColor = .clear
    view.isAccessibilityElement = false
    view.accessibilityElementsHidden = true

    let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panChanged(_:)))
    pan.delegate = context.coordinator
    pan.maximumNumberOfTouches = 1
    pan.cancelsTouchesInView = true

    let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
    tap.delegate = context.coordinator
    tap.require(toFail: pan)

    view.addGestureRecognizer(pan)
    view.addGestureRecognizer(tap)
    context.coordinator.pan = pan
    context.coordinator.tap = tap
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    context.coordinator.update(
      isEnabled: isEnabled,
      onTap: onTap,
      onChanged: onChanged,
      onEnded: onEnded
    )
    uiView.isUserInteractionEnabled = isEnabled
  }

  static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
    coordinator.pan?.delegate = nil
    coordinator.tap?.delegate = nil
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isEnabled: Bool
    var onTap: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat, Bool) -> Void
    weak var pan: UIPanGestureRecognizer?
    weak var tap: UITapGestureRecognizer?

    init(
      isEnabled: Bool,
      onTap: @escaping () -> Void,
      onChanged: @escaping (CGFloat) -> Void,
      onEnded: @escaping (CGFloat, CGFloat, Bool) -> Void
    ) {
      self.isEnabled = isEnabled
      self.onTap = onTap
      self.onChanged = onChanged
      self.onEnded = onEnded
    }

    func update(
      isEnabled: Bool,
      onTap: @escaping () -> Void,
      onChanged: @escaping (CGFloat) -> Void,
      onEnded: @escaping (CGFloat, CGFloat, Bool) -> Void
    ) {
      self.isEnabled = isEnabled
      self.onTap = onTap
      self.onChanged = onChanged
      self.onEnded = onEnded
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard isEnabled else { return false }
      guard gestureRecognizer === pan,
            let pan
      else { return true }

      let velocity = pan.velocity(in: pan.view)
      return HorizontalRowSwipeGestureArbitration.shouldBegin(
        horizontalVelocity: Double(velocity.x),
        verticalVelocity: Double(velocity.y)
      )
    }

    @objc func tapped(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended, isEnabled else { return }
      onTap()
    }

    @objc func panChanged(_ recognizer: UIPanGestureRecognizer) {
      guard let view = recognizer.view else { return }
      let translation = recognizer.translation(in: view).x

      switch recognizer.state {
      case .began, .changed:
        onChanged(translation)
      case .ended:
        let velocity = recognizer.velocity(in: view).x
        onEnded(translation, translation + velocity * 0.12, false)
      case .cancelled, .failed:
        onEnded(translation, translation, true)
      default:
        break
      }
    }
  }
}

/// A restrained dark-surface edge: inset highlight, hairline, and a short cast
/// shadow make the note face read as a drawer sliding over its action layer.
private struct JoiNoteDrawerEdge: View {
  let revealProgress: CGFloat

  var body: some View {
    ZStack(alignment: .trailing) {
      Rectangle()
        .fill(Color.black.opacity(0.48))
        .frame(width: 12)
        .blur(radius: 7)
        .offset(x: 10)

      LinearGradient(
        colors: [
          Color.white.opacity(0.025),
          Color.white.opacity(0.008),
          Color.clear,
        ],
        startPoint: .trailing,
        endPoint: .leading
      )
      .frame(width: 8)

      LinearGradient(
        colors: [
          Color.white.opacity(0.16),
          Color.white.opacity(0.055),
          Color.black.opacity(0.2),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(width: 1)
    }
    .frame(width: 20)
    .opacity(0.28 + revealProgress * 0.72)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct NoteEditorView: View {
  enum Mode {
    case edit
    case preview
  }

  @ObservedObject var model: MobileAppModel
  let route: NoteEditorRoute

  @StateObject private var dictation: MobileMeetingRecorder

  @Environment(\.dismiss) private var dismiss
  @FocusState private var isTitleFocused: Bool
  @State private var title: String
  @State private var bodyText: String
  @State private var mode: Mode = .edit
  @State private var isSaving = false
  @State private var isBodyFocused = false
  @State private var markdownRequest: TodoMarkdownRequest?
  @State private var activeMarkdownCommands = Set<TodoMarkdownCommand>()
  @State private var dictationBase = ""
  @State private var copiedNote = false
  @State private var dictationError: String?

  init(model: MobileAppModel, route: NoteEditorRoute) {
    self.model = model
    self.route = route
    _title = State(initialValue: route.note?.title ?? "")
    _bodyText = State(initialValue: route.note?.body ?? "")
    _dictation = StateObject(wrappedValue: MobileMeetingRecorder())
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
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.keyboard, edges: .bottom)
      }
    }
    .preferredColorScheme(.dark)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if mode == .edit {
        noteQuickStyleBar
      }
    }
    .onChange(of: dictation.transcript) { _, transcript in
      guard dictation.isRecording, !transcript.isEmpty else { return }
      applyDictationTranscript(transcript)
    }
    .task {
      guard route.note == nil else { return }
      // Wait until the full-screen cover has installed its responder chain.
      // Earlier requests can be discarded during the presentation animation.
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled, !isBodyFocused else { return }
      isTitleFocused = true
    }
    .onDisappear { dictation.reset() }
    .alert("Transcription unavailable", isPresented: dictationErrorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(dictationError ?? "Please try again.")
    }
  }

  private var editorHeader: some View {
    ZStack {
      HStack(spacing: 8) {
        noteHeaderButton(
          symbol: "xmark",
          label: "Close",
          action: { dismiss() }
        )

        Spacer()

        noteHeaderButton(
          symbol: "doc.richtext",
          label: "Preview",
          color: PanelTheme.secondary,
          action: { mode = .preview }
        )

        noteHeaderButton(
          symbol: copiedNote ? "checkmark" : "doc.on.doc",
          label: copiedNote ? "Note copied" : "Copy note",
          color: copiedNote ? PanelTheme.green : PanelTheme.secondary,
          action: copyNote
        )

        ShareLink(item: shareText) {
          Image(systemName: "square.and.arrow.up")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(PanelTheme.secondary)
            .frame(width: 40, height: 40)
            .background(PanelTheme.surface, in: Circle())
        }
        .accessibilityLabel("Share note")

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
    }
    .padding(.horizontal, 20)
    .frame(height: 82)
  }

  private var editor: some View {
    VStack(spacing: 0) {
      TextField("Title", text: $title)
        .focused($isTitleFocused)
        .defaultFocus($isTitleFocused, route.note == nil)
        .font(.system(size: 34, weight: .bold))
        .foregroundStyle(PanelTheme.primary)
        .tint(PanelTheme.violet)
        .textFieldStyle(.plain)
        .textInputAutocapitalization(.sentences)
        .lineLimit(1)
        .submitLabel(.next)
        .onSubmit(focusDescriptionEditor)
        .accessibilityIdentifier("note-editor-title")
        .accessibilityHint("Press Return to move to Write something")
        .padding(.horizontal, 31)
        .padding(.top, 35)
        .padding(.bottom, 18)

      JoiDottedDivider(inset: 24)

      ZStack(alignment: .topLeading) {
        if bodyText.isEmpty {
          Text("Write something…")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(PanelTheme.tertiary)
            .allowsHitTesting(false)
        }

        TodoMarkdownTextView(
          text: $bodyText,
          isFocused: $isBodyFocused,
          request: markdownRequest,
          activeCommands: $activeMarkdownCommands,
          accessibilityIdentifier: "note-editor-body"
        )
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var noteQuickStyleBar: some View {
    TodoMarkdownToolbar(
      activeCommands: $activeMarkdownCommands,
      identifierPrefix: "note-markdown",
      onCommand: applyNoteMarkdownCommand
    ) {
      Button {
        Task { await toggleDictation() }
      } label: {
        ZStack {
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(dictation.isRecording ? PanelTheme.coral.opacity(0.24) : PanelTheme.surface)

          if dictation.isStarting || dictation.isStopping {
            ProgressView().tint(PanelTheme.primary)
          } else {
            Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(dictation.isRecording ? PanelTheme.coral : PanelTheme.primary)
          }
        }
        .frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .disabled(dictation.isStarting || dictation.isStopping)
      .accessibilityLabel(dictation.isRecording ? "Stop transcription" : "Transcribe into note")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  private func focusDescriptionEditor() {
    isTitleFocused = false
    DispatchQueue.main.async { isBodyFocused = true }
  }

  private func applyNoteMarkdownCommand(_ command: TodoMarkdownCommand) {
    let isActive = activeMarkdownCommands.contains(command)
    isTitleFocused = false
    isBodyFocused = true
    if isActive {
      activeMarkdownCommands.remove(command)
    } else {
      activeMarkdownCommands.insert(command)
    }
    markdownRequest = TodoMarkdownRequest(command: command)
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
    if dictation.isRecording || dictation.isStopping {
      applyDictationTranscript(await dictation.stop())
    }
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

  private var shareText: String {
    let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Untitled note"
    return "# \(resolvedTitle)\n\n\(bodyText)"
  }

  private var dictationErrorBinding: Binding<Bool> {
    Binding(
      get: { dictationError != nil },
      set: { if !$0 { dictationError = nil } }
    )
  }

  private func noteHeaderButton(
    symbol: String,
    label: String,
    color: Color = PanelTheme.primary,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 40, height: 40)
        .background(PanelTheme.surface, in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func copyNote() {
    UIPasteboard.general.string = shareText
    copiedNote = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.3))
      copiedNote = false
    }
  }

  private func toggleDictation() async {
    if dictation.isRecording {
      applyDictationTranscript(await dictation.stop())
      isBodyFocused = true
      return
    }

    dictationBase = bodyText
    let started = await dictation.start()
    if !started {
      dictationError = dictation.errorMessage ?? "Speech recognition could not start."
    }
  }

  private func applyDictationTranscript(_ transcript: String) {
    guard !transcript.isEmpty else { return }
    bodyText = dictationBase
      + (dictationBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n")
      + transcript
  }

  private var markdownPreview: AttributedString {
    (try? AttributedString(markdown: bodyText)) ?? AttributedString(bodyText)
  }
}

struct MeetingNoteDetailView: View {
  private enum Tab: String, CaseIterable {
    case summary = "Summary"
    case transcript = "Transcript"
  }

  private enum SummaryStatus: Equatable {
    case none
    case transcribing
    case enhancing
  }

  @ObservedObject var model: MobileAppModel
  let noteID: UUID

  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var meetingSummary: MeetingSummaryModel
  @State private var selectedTab: Tab
  @State private var summaryRevealCount = Int.max
  @State private var summaryStatus: SummaryStatus = .none
  @State private var keepsBottomTranscribingStatus = false
  @State private var summaryRunID: UUID?
  @State private var copiedSummary = false
  @State private var copiedMeetingNote = false
  @State private var editingNote: SyncedNote?
  @State private var summarySaveError: String?
  @State private var summarySourceBody: String?
  @State private var summaryPersistedBody: String?

  init(model: MobileAppModel, noteID: UUID) {
    self.model = model
    self.noteID = noteID
    let markdown = model.note(id: noteID)?.body ?? ""
    let content = MeetingNoteContent(markdown: markdown)
    _meetingSummary = StateObject(wrappedValue: MeetingSummaryModel(markdown: markdown))
    _selectedTab = State(initialValue: content.summary == nil ? .transcript : .summary)
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--force-summary-motion") {
      _summaryRevealCount = State(initialValue: 0)
      _summaryStatus = State(initialValue: .enhancing)
    }
    #endif
  }

  var body: some View {
    PanelScreen {
      if let note = model.note(id: noteID) {
        VStack(spacing: 0) {
          meetingHero(note)
            .frame(height: 260, alignment: .top)

          JoiTimelineSheet(minHeight: 0) {
            VStack(spacing: 0) {
              tabBar
              JoiDottedDivider(inset: 24)

              Group {
                if selectedTab == .summary {
                  summaryView(note)
                    .transition(.opacity)
                } else {
                  transcriptView(note)
                    .transition(.opacity)
                }
              }
              .animation(PanelTheme.quick, value: selectedTab)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .ignoresSafeArea(edges: .bottom)
          .simultaneousGesture(meetingTabSwipe)
          .overlay(alignment: .bottom) {
            if summaryStatus == .transcribing || keepsBottomTranscribingStatus {
              MeetingSummaryStatusPill(isTranscribing: true, expands: false)
                .padding(.bottom, 22)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .accessibilityIdentifier("meeting-summary-status")
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      } else {
        EmptyPanelState(
          symbol: "waveform",
          title: "Meeting note unavailable",
          detail: "This note may have been removed on another device."
        )
      }
    }
    .preferredColorScheme(.dark)
    .accessibilityIdentifier("meeting-note-detail")
    .task(id: noteID) {
      meetingSummary.update(markdown: currentNoteBody)
      meetingSummary.refreshAvailability()
      await runSummaryAnimationIfNeeded()
      await runAutomaticSummaryIfNeeded()
    }
    #if DEBUG
    .task(id: "forced-summary-motion-\(noteID)") {
      guard ProcessInfo.processInfo.arguments.contains("--force-summary-motion") else { return }
      // Scene restoration can recreate a full-screen note before the fixture model's
      // initial refresh settles. Replay once after that refresh so deterministic visual
      // captures exercise the production animation instead of its stale-data guard.
      try? await Task.sleep(for: .milliseconds(900))
      guard !Task.isCancelled else { return }
      await runSummaryAnimationIfNeeded()
    }
    #endif
    .onChange(of: currentNoteBody) { _, markdown in
      let sourceChanged = summarySourceBody.map { markdown != $0 } ?? false
      let persistedBodyChanged = summaryPersistedBody.map { markdown != $0 } ?? false
      if sourceChanged || persistedBodyChanged {
        cancelSummaryPresentation(showTranscript: true)
      }
      meetingSummary.update(markdown: markdown)
    }
    .onChange(of: meetingSummary.completionRevision) { _, revision in
      guard revision > 0, let runID = summaryRunID else { return }
      summaryRevealCount = 0
      Task { await persistGeneratedSummary(runID: runID) }
    }
    .onChange(of: meetingSummary.state) { _, state in
      if case .failed = state {
        summaryStatus = .none
        keepsBottomTranscribingStatus = false
        summaryRunID = nil
        summarySourceBody = nil
        summaryPersistedBody = nil
      }
    }
    .onChange(of: meetingSummary.availability) { _, availability in
      if availability != .available, meetingSummary.summary == nil {
        cancelSummaryPresentation(showTranscript: true)
        selectedTab = .transcript
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        meetingSummary.refreshAvailability()
      } else {
        cancelSummaryPresentation(showTranscript: false)
      }
    }
    .onDisappear { cancelSummaryPresentation(showTranscript: false) }
    .fullScreenCover(item: $editingNote) { note in
      NoteEditorView(model: model, route: NoteEditorRoute(note: note))
    }
    .alert("Couldn’t save summary", isPresented: summarySaveErrorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(summarySaveError ?? "The transcript is safe. Please try saving the summary again.")
    }
  }

  private var currentNoteBody: String { model.note(id: noteID)?.body ?? "" }

  private func meetingHero(_ note: SyncedNote) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack {
        HStack(spacing: 8) {
          Button { dismiss() } label: {
            Image(systemName: "xmark")
              .font(.system(size: 14, weight: .bold))
              .foregroundStyle(PanelTheme.primary)
              .frame(width: 40, height: 40)
              .background(PanelTheme.surface, in: Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Close meeting note")

          Spacer()

          Button { editingNote = note } label: {
            Image(systemName: "pencil")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(PanelTheme.secondary)
              .frame(width: 40, height: 40)
              .background(PanelTheme.surface, in: Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Edit meeting note Markdown")
          .accessibilityHint("Opens the meeting title, summary, and transcript editor")

          Button { copyMeetingNote(note) } label: {
            Image(systemName: copiedMeetingNote ? "checkmark" : "doc.on.doc")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(copiedMeetingNote ? PanelTheme.green : PanelTheme.secondary)
              .frame(width: 40, height: 40)
              .background(PanelTheme.surface, in: Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(copiedMeetingNote ? "Meeting note copied" : "Copy meeting note")

          ShareLink(item: meetingShareText(note)) {
            Image(systemName: "square.and.arrow.up")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(PanelTheme.secondary)
              .frame(width: 40, height: 40)
              .background(PanelTheme.surface, in: Circle())
          }
          .accessibilityLabel("Share meeting note")
        }
      }

      Spacer(minLength: 24)

      Text(note.title)
        .font(.system(size: 34, weight: .bold))
        .foregroundStyle(PanelTheme.primary)
        .multilineTextAlignment(.leading)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)

      Spacer(minLength: 18)

      meetingMetadata(note)
    }
    .padding(.horizontal, PanelTheme.horizontalPadding)
    .padding(.top, 10)
    .padding(.bottom, 22)
  }

  private func meetingMetadata(_ note: SyncedNote) -> some View {
    let session = model.meetingSession(for: note.id)
    let duration = session.flatMap { session -> TimeInterval? in
      guard let endedAt = session.endedAt else { return nil }
      return max(0, endedAt.timeIntervalSince(session.startedAt))
    }
    let calendarTitle = model.calendarEvent(id: session?.calendarEventID)?.calendarTitle

    return HStack(spacing: 16) {
      MeetingMetadataItem(
        symbol: "calendar",
        value: note.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
      )

      if let duration {
        MeetingMetadataItem(symbol: "clock", value: duration.meetingDurationText)
      }

      if let calendarTitle {
        MeetingMetadataItem(symbol: "rectangle.stack", value: calendarTitle)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var tabBar: some View {
    HStack(spacing: 30) {
      ForEach(Tab.allCases, id: \.self) { tab in
        Button {
          withAnimation(PanelTheme.quick) { selectedTab = tab }
          #if DEBUG
          if tab == .summary,
             ProcessInfo.processInfo.arguments.contains("--force-summary-motion") {
            Task { await runSummaryAnimationIfNeeded() }
          }
          #endif
        } label: {
          VStack(spacing: 0) {
            Text(tab.rawValue)
              .font(.system(size: 15, weight: selectedTab == tab ? .bold : .semibold))
              .foregroundStyle(selectedTab == tab ? PanelTheme.primary : PanelTheme.secondary)
              .frame(height: 56)

            Capsule()
              .fill(selectedTab == tab ? PanelTheme.primary : .clear)
              .frame(height: 2)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(tab == .summary ? "summary-tab" : "transcript-tab")
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
      }

      Spacer()
    }
    .padding(.horizontal, 24)
  }

  private func summaryView(_ note: SyncedNote) -> some View {
    let content = MeetingNoteContent(markdown: note.body)
    let summary = meetingSummary.summary ?? content.summary

    return VStack(spacing: 0) {
      HStack(spacing: 12) {
        Label("ON-DEVICE SUMMARY", systemImage: "sparkles")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(PanelTheme.tertiary)

        Spacer()

        summaryAction

        if let summary {
          Button {
            UIPasteboard.general.string = summary
            copiedSummary = true
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(1.4))
              copiedSummary = false
            }
          } label: {
            Label(copiedSummary ? "Copied" : "Copy", systemImage: copiedSummary ? "checkmark" : "doc.on.doc")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(copiedSummary ? PanelTheme.green : PanelTheme.secondary)
              .frame(height: 36)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(copiedSummary ? "Summary copied" : "Copy summary")
        }
      }
      .padding(.horizontal, 24)
      .frame(height: 52)

      JoiDottedDivider(inset: 24)

      ScrollViewReader { proxy in
        ScrollView {
          if meetingSummary.state == .generating {
            MeetingSummaryAnimationView(
              summary: "",
              transcript: content.transcript,
              revealedLineCount: 0,
              showsEnhancingStatus: false
            )
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .accessibilityIdentifier("summary-generation")
            .accessibilityLabel("Creating a meeting summary on this iPhone")
          } else if case .failed(let message) = meetingSummary.state {
            VStack(spacing: 18) {
              EmptyPanelState(
                symbol: "exclamationmark.arrow.triangle.2.circlepath",
                title: "Couldn’t create summary",
                detail: message
              )
              if meetingSummary.availability == .available, meetingSummary.hasTranscript {
                summaryRetryButton
              }
            }
            .padding(.top, 42)
          } else if let summary {
            MeetingSummaryAnimationView(
              summary: summary,
              transcript: content.transcript,
              revealedLineCount: summaryRevealCount,
              showsEnhancingStatus: summaryStatus == .enhancing
            )
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .accessibilityIdentifier("meeting-summary-markdown")
          } else if !meetingSummary.hasTranscript {
            EmptyPanelState(
              symbol: "text.quote",
              title: "No transcript captured",
              detail: "A summary needs recognizable speech."
            )
            .padding(.top, 50)
          } else if meetingSummary.availability != .available {
            EmptyPanelState(
              symbol: "iphone.gen3",
              title: meetingSummary.availability.message,
              detail: "The complete transcript remains available and never leaves your devices."
            )
            .padding(.top, 50)
            .accessibilityLabel("\(meetingSummary.availability.message). The transcript remains available.")
          } else {
            VStack(spacing: 18) {
              EmptyPanelState(
                symbol: "sparkles",
                title: "Create meeting summary",
                detail: "Apple Intelligence can summarize this transcript locally on your iPhone."
              )
              summaryRetryButton
            }
            .padding(.top, 42)
          }
        }
        .scrollIndicators(.hidden)
        .onChange(of: summaryRevealCount) { _, count in
          guard summaryStatus == .enhancing, count > 0 else { return }
          Task { @MainActor in
            await Task.yield()
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)) {
              proxy.scrollTo(MeetingSummaryAnimationView.frontierID, anchor: .bottom)
            }
          }
        }
        .onChange(of: summaryStatus) { _, status in
          guard status == .enhancing else { return }
          Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(MeetingSummaryAnimationView.frontierID, anchor: .top)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var summaryAction: some View {
    if meetingSummary.state == .generating {
      Button("Cancel") { cancelSummaryPresentation(showTranscript: true) }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(PanelTheme.secondary)
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Cancel local meeting summary")
    } else if meetingSummary.availability == .available, meetingSummary.hasTranscript {
      Button(meetingSummary.summary == nil ? "Create" : "Refresh") {
        beginSummaryGeneration()
      }
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(PanelTheme.primary)
      .buttonStyle(.plain)
      .frame(minWidth: 44, minHeight: 44)
      .accessibilityLabel(
        meetingSummary.summary == nil
          ? "Create local meeting summary"
          : "Refresh local meeting summary"
      )
      .accessibilityHint("Uses Apple Intelligence on this iPhone. The transcript is not uploaded.")
    }
  }

  private var summaryRetryButton: some View {
    Button {
      beginSummaryGeneration()
    } label: {
      Label(
        meetingSummary.state == .idle ? "Create locally" : "Try again",
        systemImage: "sparkles"
      )
      .font(.system(size: 13, weight: .bold))
      .foregroundStyle(.black)
      .padding(.horizontal, 20)
      .frame(height: 44)
      .background(PanelTheme.primary, in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      meetingSummary.state == .idle
        ? "Create local meeting summary"
        : "Try creating local meeting summary again"
    )
  }

  private func beginSummaryGeneration() {
    let runID = UUID()
    summaryRunID = runID
    summarySourceBody = currentNoteBody
    summaryPersistedBody = nil
    summaryRevealCount = 0
    keepsBottomTranscribingStatus = false
    summaryStatus = .transcribing
    selectedTab = .summary
    meetingSummary.generate()
    UIAccessibility.post(
      notification: .announcement,
      argument: "Creating meeting summary on this iPhone"
    )
  }

  private func transcriptView(_ note: SyncedNote) -> some View {
    let content = MeetingNoteContent(markdown: note.body)
    let session = model.meetingSession(for: note.id)
    let storedSegments = session?.transcriptSegments
    let segments: [SyncedTranscriptSegment]
    if let storedSegments {
      segments = storedSegments.sorted {
        ($0.startOffset ?? 0) < ($1.startOffset ?? 0)
      }
    } else if content.transcript.nonEmpty != nil,
              content.transcript != "_No speech was recognized._" {
      segments = [
        SyncedTranscriptSegment(source: .unknown, text: content.transcript)
      ]
    } else {
      segments = []
    }

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        MeetingTranscriptLegend()
          .padding(.horizontal, 24)
          .padding(.vertical, 20)

        JoiDottedDivider(inset: 24)

        if segments.isEmpty {
          EmptyPanelState(
            symbol: "text.quote",
            title: "No transcript captured",
            detail: "No recognizable speech was available in this recording."
          )
          .padding(.top, 42)
        } else {
          ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
            MeetingTranscriptSegmentRow(segment: segment)
              .padding(.horizontal, 24)
              .padding(.vertical, 22)
              .accessibilityIdentifier("transcript-segment-\(segment.id.uuidString)")

            if index < segments.count - 1 { JoiDottedDivider(inset: 24) }
          }
        }
      }
      .padding(.bottom, 40)
    }
    .scrollIndicators(.hidden)
  }

  private func persistGeneratedSummary(runID: UUID) async {
    guard summaryRunID == runID,
          let summary = meetingSummary.summary,
          let expectedBody = summarySourceBody
    else {
      cancelSummaryPresentation(showTranscript: true)
      return
    }

    let expectedPersistedBody = MeetingNoteContent(markdown: expectedBody)
      .markdown(replacingSummary: summary)
    summarySourceBody = nil
    summaryPersistedBody = expectedPersistedBody

    guard await model.saveMeetingSummary(
      noteID: noteID,
      summary: summary,
      expectedBody: expectedBody
    ) else {
      guard summaryRunID == runID else { return }
      cancelSummaryPresentation(showTranscript: true)
      summarySaveError = "The local summary was created, but it could not be saved. The transcript was not changed."
      return
    }

    guard summaryRunID == runID, currentNoteBody == expectedPersistedBody else {
      cancelSummaryPresentation(showTranscript: true)
      return
    }

    selectedTab = .summary
    if reduceMotion {
      finishSummaryPresentation(runID: runID)
      UIAccessibility.post(notification: .announcement, argument: "Summary ready")
      return
    }

    keepsBottomTranscribingStatus = true
    withAnimation(.easeOut(duration: 0.16)) {
      summaryStatus = .enhancing
    }
    await revealSummaryLines(
      summary,
      runID: runID,
      expectedBody: expectedPersistedBody
    )
  }

  private func runSummaryAnimationIfNeeded() async {
    guard model.consumeMeetingSummaryAnimation(for: noteID) else {
      summaryRevealCount = Int.max
      return
    }
    #if DEBUG
    let forcesSummaryMotion = ProcessInfo.processInfo.arguments.contains("--force-summary-motion")
    #else
    let forcesSummaryMotion = false
    #endif
    guard (!reduceMotion || forcesSummaryMotion),
          let summary = MeetingNoteContent(markdown: currentNoteBody).summary
    else {
      summaryRevealCount = Int.max
      return
    }

    let runID = UUID()
    summaryRunID = runID
    summaryPersistedBody = currentNoteBody
    summaryRevealCount = 0
    keepsBottomTranscribingStatus = false
    summaryStatus = .enhancing
    selectedTab = .summary
    UIAccessibility.post(notification: .announcement, argument: "Summarizing meeting notes")
    await revealSummaryLines(summary, runID: runID, expectedBody: currentNoteBody)
  }

  private func runAutomaticSummaryIfNeeded() async {
    guard model.consumeAutomaticMeetingSummary(for: noteID) else { return }

    meetingSummary.update(markdown: currentNoteBody)
    meetingSummary.refreshAvailability()
    let content = MeetingNoteContent(markdown: currentNoteBody)
    guard meetingSummary.availability == .available,
          meetingSummary.hasTranscript,
          meetingSummary.summary == nil,
          content.summary == nil,
          model.meetingSession(for: noteID)?.summaryGeneratedAt == nil
    else {
      summaryStatus = .none
      keepsBottomTranscribingStatus = false
      selectedTab = .transcript
      return
    }

    // Keep the newly persisted, complete transcript on screen with the same bottom
    // Transcribing status that will remain through local generation and persistence.
    let sourceBody = currentNoteBody
    summaryStatus = .transcribing
    keepsBottomTranscribingStatus = false
    selectedTab = .transcript
    try? await Task.sleep(for: .milliseconds(450))
    guard !Task.isCancelled,
          currentNoteBody == sourceBody,
          selectedTab == .transcript
    else {
      summaryStatus = .none
      keepsBottomTranscribingStatus = false
      return
    }

    beginSummaryGeneration()
  }

  private func revealSummaryLines(
    _ summary: String,
    runID: UUID,
    expectedBody: String
  ) async {
    let lines = MeetingSummaryLine.parse(summary)
    guard !lines.isEmpty else {
      finishSummaryPresentation(runID: runID)
      return
    }

    let holdsAnimation = ProcessInfo.processInfo.arguments.contains("--hold-summary-animation")
    try? await Task.sleep(for: .milliseconds(holdsAnimation ? 3_000 : 300))
    guard summaryRunID == runID, currentNoteBody == expectedBody else {
      cancelSummaryPresentation(showTranscript: true)
      return
    }

    if keepsBottomTranscribingStatus {
      withAnimation(.easeOut(duration: 0.12)) {
        keepsBottomTranscribingStatus = false
      }
    }

    try? await Task.sleep(for: .milliseconds(holdsAnimation ? 3_000 : 320))
    guard summaryRunID == runID, currentNoteBody == expectedBody else {
      cancelSummaryPresentation(showTranscript: true)
      return
    }

    for (index, line) in lines.enumerated() {
      guard !Task.isCancelled,
            summaryRunID == runID,
            currentNoteBody == expectedBody
      else {
        cancelSummaryPresentation(showTranscript: true)
        return
      }
      withAnimation(
        .timingCurve(0.22, 1, 0.36, 1, duration: line.revealDuration)
      ) {
        summaryRevealCount = index + 1
      }
      try? await Task.sleep(
        for: .milliseconds(holdsAnimation ? 3_000 : line.revealCadenceMilliseconds)
      )
    }

    guard summaryRunID == runID, currentNoteBody == expectedBody else {
      cancelSummaryPresentation(showTranscript: true)
      return
    }
    try? await Task.sleep(for: .milliseconds(holdsAnimation ? 3_000 : 260))
    guard summaryRunID == runID, currentNoteBody == expectedBody else {
      cancelSummaryPresentation(showTranscript: true)
      return
    }
    finishSummaryPresentation(runID: runID)
    UIAccessibility.post(notification: .announcement, argument: "Summary ready")
  }

  private func finishSummaryPresentation(runID: UUID) {
    guard summaryRunID == runID else { return }
    summaryRevealCount = Int.max
    keepsBottomTranscribingStatus = false
    if reduceMotion {
      summaryStatus = .none
    } else {
      withAnimation(.easeOut(duration: 0.16)) {
        summaryStatus = .none
      }
    }
    summaryRunID = nil
    summarySourceBody = nil
    summaryPersistedBody = nil
  }

  private func cancelSummaryPresentation(showTranscript: Bool) {
    summaryRunID = nil
    summarySourceBody = nil
    summaryPersistedBody = nil
    summaryStatus = .none
    keepsBottomTranscribingStatus = false
    summaryRevealCount = meetingSummary.summary == nil ? 0 : Int.max
    meetingSummary.cancel()
    if showTranscript { selectedTab = .transcript }
  }

  private var meetingTabSwipe: some Gesture {
    DragGesture(minimumDistance: 18)
      .onEnded { value in
        let horizontal = value.predictedEndTranslation.width
        guard abs(horizontal) > abs(value.predictedEndTranslation.height), abs(horizontal) > 64 else {
          return
        }
        withAnimation(PanelTheme.disclosure) {
          selectedTab = horizontal < 0 ? .transcript : .summary
        }
      }
  }

  private func meetingShareText(_ note: SyncedNote) -> String {
    "# \(note.title)\n\n\(note.body)"
  }

  private func copyMeetingNote(_ note: SyncedNote) {
    UIPasteboard.general.string = meetingShareText(note)
    copiedMeetingNote = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.3))
      copiedMeetingNote = false
    }
  }

  private var summarySaveErrorBinding: Binding<Bool> {
    Binding(
      get: { summarySaveError != nil },
      set: { if !$0 { summarySaveError = nil } }
    )
  }
}

private struct MeetingMetadataItem: View {
  let symbol: String
  let value: String

  var body: some View {
    Label(value, systemImage: symbol)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(PanelTheme.secondary)
      .lineLimit(1)
  }
}

private struct MeetingSummaryAnimationView: View {
  static let frontierID = "meeting-summary-frontier"

  let summary: String
  let transcript: String
  let revealedLineCount: Int
  let showsEnhancingStatus: Bool

  private var lines: [MeetingSummaryLine] {
    MeetingSummaryLine.parse(summary)
  }

  private var visibleLineCount: Int {
    min(lines.count, max(0, revealedLineCount))
  }

  private var showsSourceTranscript: Bool {
    lines.isEmpty || (revealedLineCount == 0 && !showsEnhancingStatus)
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      if showsSourceTranscript {
        Text(transcript)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(PanelTheme.primary)
          .lineSpacing(7)
          .frame(maxWidth: .infinity, alignment: .leading)
          .transition(.opacity)
          .accessibilityIdentifier("summary-source-transcript")
      }

      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.prefix(visibleLineCount).enumerated()), id: \.element.id) { index, line in
          MeetingSummaryLineRevealView(
            line: line,
            shouldAnimate: showsEnhancingStatus
          )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 15)
            .accessibilityIdentifier("summary-transition-line-\(index)")
        }

        if showsEnhancingStatus {
          MeetingSummaryFrontierView()
            .id(Self.frontierID)
            .padding(.top, visibleLineCount == 0 ? 0 : -8)
            .zIndex(2)
            .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(minHeight: 430, alignment: .top)
    .animation(.easeIn(duration: 0.15), value: showsSourceTranscript)
  }
}

private struct MeetingSummaryStatusPill: View {
  let isTranscribing: Bool
  let expands: Bool

  private var freezesTestAnimation: Bool {
    ProcessInfo.processInfo.arguments.contains("--freeze-summary-status")
  }

  var body: some View {
    HStack(spacing: 10) {
      if isTranscribing {
        if freezesTestAnimation {
          Image(systemName: "waveform")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(PanelTheme.primary)
        } else {
          Image(systemName: "waveform")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(PanelTheme.primary)
            .symbolEffect(.variableColor.iterative, options: .repeating)
        }
      } else {
        if freezesTestAnimation {
          Image(systemName: "sparkles")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(PanelTheme.amber)
        } else {
          ProgressView()
            .tint(PanelTheme.amber)
            .controlSize(.small)
        }
      }

      Text(isTranscribing ? "Transcribing" : "Enhancing notes")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
        .contentTransition(.opacity)
    }
    .padding(.horizontal, 18)
    .frame(height: 48)
    .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
    .background(PanelTheme.sheetRaised, in: Capsule())
    .overlay { Capsule().stroke(PanelTheme.strongBorder, lineWidth: 0.5) }
    .shadow(color: .black.opacity(0.38), radius: 16, y: 8)
  }
}

private struct MeetingSummaryFrontierView: View {
  @State private var isVisible = false

  var body: some View {
    MeetingSummaryStatusPill(isTranscribing: false, expands: true)
      .opacity(isVisible ? 1 : 0)
      .scaleEffect(isVisible ? 1 : 0.985, anchor: .top)
      .accessibilityIdentifier("meeting-summary-frontier")
      .onAppear {
        withAnimation(.easeOut(duration: 0.08).delay(0.23)) {
          isVisible = true
        }
      }
  }
}

private struct MeetingSummaryLine: Identifiable {
  enum Kind {
    case heading
    case bullet
    case paragraph
  }

  let id: Int
  let kind: Kind
  let text: String

  var revealDuration: TimeInterval {
    min(0.24, max(0.13, 0.10 + Double(text.count) * 0.0018))
  }

  var revealCadenceMilliseconds: Int {
    Int(min(170, max(125, revealDuration * 780)))
  }

  var renderedRowHeight: CGFloat {
    switch kind {
    case .heading: 29
    case .bullet, .paragraph: 26
    }
  }

  static func parse(_ markdown: String) -> [MeetingSummaryLine] {
    markdown
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .enumerated()
      .map { index, value in
        if value.hasPrefix("### ") {
          return MeetingSummaryLine(id: index, kind: .heading, text: String(value.dropFirst(4)))
        }
        if value.hasPrefix("- ") || value.hasPrefix("* ") {
          return MeetingSummaryLine(id: index, kind: .bullet, text: String(value.dropFirst(2)))
        }
        return MeetingSummaryLine(id: index, kind: .paragraph, text: value)
      }
  }
}

private struct MeetingSummaryLineRevealView: View {
  let line: MeetingSummaryLine
  let shouldAnimate: Bool

  @State private var revealStartedAt: Date?
  @State private var revealFinished: Bool

  private var effectiveRevealDuration: TimeInterval {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--slow-summary-wipe") {
      return 10
    }
    #endif
    return line.revealDuration
  }

  init(line: MeetingSummaryLine, shouldAnimate: Bool) {
    self.line = line
    self.shouldAnimate = shouldAnimate
    _revealStartedAt = State(initialValue: nil)
    _revealFinished = State(initialValue: !shouldAnimate)
  }

  var body: some View {
    TimelineView(
      .animation(
        minimumInterval: 1 / 60,
        paused: !shouldAnimate || revealFinished || revealStartedAt == nil
      )
    ) { timeline in
      let progress = revealProgress(at: timeline.date)
      ZStack(alignment: .topLeading) {
        MeetingSummaryLineView(line: line)
          .mask {
            MeetingSummarySettledMask(
              progress: progress,
              rowHeight: line.renderedRowHeight
            )
          }

        MeetingSummaryLineView(
          line: line,
          textStyle: AnyShapeStyle(spectralGradient),
          bulletStyle: AnyShapeStyle(spectralGradient)
        )
        .mask {
          MeetingSummarySpectralEdgeMask(
            progress: progress,
            rowHeight: line.renderedRowHeight
          )
        }
        .accessibilityHidden(true)
      }
    }
    .onAppear { beginRevealIfNeeded() }
    .onChange(of: shouldAnimate) { _, isAnimating in
      if !isAnimating { revealFinished = true }
    }
  }

  private var spectralGradient: LinearGradient {
    LinearGradient(
      colors: [
        PanelTheme.amber.opacity(0.9),
        PanelTheme.coral.opacity(0.9),
        PanelTheme.violet.opacity(0.92),
        PanelTheme.primary.opacity(0.2),
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  private func beginRevealIfNeeded() {
    guard shouldAnimate, !revealFinished, revealStartedAt == nil else { return }
    Task { @MainActor in
      await Task.yield()
      revealStartedAt = Date()
      try? await Task.sleep(for: .seconds(effectiveRevealDuration))
      revealFinished = true
    }
  }

  private func revealProgress(at date: Date) -> CGFloat {
    guard shouldAnimate, !revealFinished else { return 1 }
    guard let revealStartedAt else { return 0 }
    return min(1, max(0, date.timeIntervalSince(revealStartedAt) / effectiveRevealDuration))
  }
}

private struct MeetingSummarySettledMask: View {
  let progress: CGFloat
  let rowHeight: CGFloat

  var body: some View {
    Canvas { context, size in
      let rows = max(1, Int(ceil(size.height / rowHeight)))
      let scaledProgress = min(1, max(0, progress)) * CGFloat(rows)

      for row in 0 ..< rows {
        let rowProgress = min(1, max(0, scaledProgress - CGFloat(row)))
        guard rowProgress > 0 else { continue }
        let rect = CGRect(
          x: 0,
          y: CGFloat(row) * rowHeight,
          width: size.width * rowProgress,
          height: min(rowHeight + 2, size.height - CGFloat(row) * rowHeight)
        )
        context.fill(Path(rect), with: .color(.white))
      }
    }
  }
}

private struct MeetingSummarySpectralEdgeMask: View {
  let progress: CGFloat
  let rowHeight: CGFloat

  var body: some View {
    Canvas { context, size in
      guard progress > 0, progress < 1 else { return }
      let rows = max(1, Int(ceil(size.height / rowHeight)))
      let scaledProgress = min(0.999_9, max(0, progress)) * CGFloat(rows)
      let activeRow = min(rows - 1, Int(floor(scaledProgress)))
      let rowProgress = scaledProgress - CGFloat(activeRow)
      let frontierX = size.width * rowProgress
      let bandWidth = min(132, max(92, size.width * 0.34))
      let startX = frontierX - bandWidth * 0.76
      let endX = frontierX + bandWidth * 0.24
      let rect = CGRect(
        x: startX,
        y: CGFloat(activeRow) * rowHeight,
        width: bandWidth,
        height: min(rowHeight + 2, size.height - CGFloat(activeRow) * rowHeight)
      )
      let gradient = Gradient(stops: [
        .init(color: .clear, location: 0),
        .init(color: .white.opacity(0.45), location: 0.18),
        .init(color: .white, location: 0.52),
        .init(color: .white.opacity(0.72), location: 0.76),
        .init(color: .clear, location: 1),
      ])
      context.fill(
        Path(rect),
        with: .linearGradient(
          gradient,
          startPoint: CGPoint(x: startX, y: 0),
          endPoint: CGPoint(x: endX, y: 0)
        )
      )
    }
  }
}

private struct MeetingSummaryLineView: View {
  let line: MeetingSummaryLine
  var textStyle = AnyShapeStyle(PanelTheme.primary)
  var bulletStyle = AnyShapeStyle(PanelTheme.amber)

  var body: some View {
    switch line.kind {
    case .heading:
      Text(line.text)
        .font(.system(size: 19, weight: .bold))
        .foregroundStyle(textStyle)
        .padding(.top, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .bullet:
      HStack(alignment: .firstTextBaseline, spacing: 11) {
        Image(systemName: "circle.fill")
          .font(.system(size: 5, weight: .bold))
          .foregroundStyle(bulletStyle)
        Text(line.text)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(textStyle)
          .lineSpacing(5)
      }
    case .paragraph:
      Text(line.text)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(textStyle)
        .lineSpacing(5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct MeetingTranscriptLegend: View {
  var body: some View {
    HStack(spacing: 10) {
      MeetingSourceBadge(source: .microphone)
      MeetingSourceBadge(source: .meetingAudio)
      Spacer()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Transcript sources: your microphone and call audio")
  }
}

private struct MeetingTranscriptSegmentRow: View {
  let segment: SyncedTranscriptSegment

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let offset = segment.startOffset {
        Text(offset.meetingTimestampText)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(PanelTheme.tertiary)
          .monospacedDigit()
      }

      HStack(alignment: .top, spacing: 13) {
        Capsule()
          .fill(segment.source.tint)
          .frame(width: 3)

        Text(segment.text)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(PanelTheme.primary)
          .lineSpacing(6)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(segment.accessibilityDescription)
  }
}

private struct MeetingSourceBadge: View {
  let source: SyncedTranscriptSource

  var body: some View {
    Label(source.label, systemImage: source.symbol)
      .font(.system(size: 10, weight: .bold))
      .foregroundStyle(source.tint)
      .padding(.horizontal, 10)
      .frame(height: 28)
      .background(source.tint.opacity(0.11), in: Capsule())
  }
}

private extension SyncedTranscriptSource {
  var label: String {
    switch self {
    case .microphone: "Your mic"
    case .meetingAudio: "Call audio"
    case .unknown: "Unattributed"
    }
  }

  var symbol: String {
    switch self {
    case .microphone: "mic.fill"
    case .meetingAudio: "waveform"
    case .unknown: "questionmark.circle"
    }
  }

  var tint: Color {
    switch self {
    case .microphone: PanelTheme.coral
    case .meetingAudio: PanelTheme.amber
    case .unknown: PanelTheme.secondary
    }
  }
}

private extension SyncedTranscriptSegment {
  var accessibilityDescription: String {
    let timestamp = startOffset.map { ", \($0.meetingTimestampText)" } ?? ""
    return "\(source.label)\(timestamp), \(text)"
  }
}

private extension TimeInterval {
  var meetingTimestampText: String {
    let seconds = max(0, Int(self.rounded(.down)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  var meetingDurationText: String {
    let totalMinutes = max(1, Int((self / 60).rounded()))
    return "\(totalMinutes) min"
  }
}

private extension String {
  var plainTextPreview: String {
    replacingOccurrences(of: "#", with: "")
      .replacingOccurrences(of: "*", with: "")
      .replacingOccurrences(of: "_", with: "")
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first(where: {
        !$0.isEmpty && !["summary", "transcript"].contains($0.lowercased())
      })
      ?? "Empty note"
  }

  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
