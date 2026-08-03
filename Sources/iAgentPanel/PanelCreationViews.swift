import AppKit
import SwiftUI

struct InlineDictationThreadRow: View {
    let thread: AgentThread
    @ObservedObject var dictation: SpeechDictationService
    let statusMessage: String?
    let isSubmitting: Bool
    var isProjectChild = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(thread.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if !isProjectChild, let projectName = thread.projectName {
                    Text(projectName)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 96)
                        .layoutPriority(2)
                }
            }
            .frame(width: isProjectChild ? 194 : 300, alignment: .leading)

            LatestTranscriptLine(
                text: displayText,
                isPlaceholder: dictation.transcript.isEmpty
            )
            .frame(maxWidth: .infinity, minHeight: 20)

            DictationActivityCue(
                dictation: dictation,
                color: .agentBlue,
                isSubmitting: isSubmitting
            )
            .frame(width: 136, height: 24)

            NumberFlowText(
                dictation.elapsedText,
                fontSize: 10,
                weight: .semibold,
                color: .white.opacity(0.58),
                reservedWidth: 54
            )
        }
        .padding(.leading, isProjectChild ? 50 : 20)
        .padding(.trailing, 20)
        .frame(height: 36)
        .background(Color.agentBlue.opacity(0.085))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.agentBlue).frame(width: 2)
        }
    }

    private var displayText: String {
        if let statusMessage,
           isSubmitting || !dictation.isRecording || dictation.transcript.isEmpty
        {
            return statusMessage
        }
        if !dictation.transcript.isEmpty {
            return dictation.transcript
        }
        return dictation.isRecording ? "Listening" : "Ready to send"
    }
}

struct LatestTranscriptLine: View {
    let text: String
    let isPlaceholder: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    Text(text)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(isPlaceholder ? 0.38 : 0.7))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Color.clear
                        .frame(width: 1, height: 1)
                        .id("latest-transcript-word")
                }
            }
            .scrollIndicators(.hidden)
            .allowsHitTesting(false)
            .onAppear {
                proxy.scrollTo("latest-transcript-word", anchor: .trailing)
            }
            .onChange(of: text) { _, _ in
                proxy.scrollTo("latest-transcript-word", anchor: .trailing)
            }
        }
    }
}

struct DictationActivityCue: View {
    @ObservedObject var dictation: SpeechDictationService
    let color: Color
    var isSubmitting = false

    private var showShortcut: Bool {
        !isSubmitting && (dictation.isRecording || dictation.isReadyToSubmit)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 7) {
                if dictation.isRecording {
                    WaveformView(levels: dictation.levels, color: color)
                        .frame(maxWidth: .infinity)
                } else {
                    Spacer(minLength: 0)
                }

                ReturnKeyHint(color: color)
                    .opacity(showShortcut ? 1 : 0)
                    .scaleEffect(showShortcut ? 1 : 0.9)
            }
            .opacity(isSubmitting ? 0 : 1)

            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.agentGreen)
                .opacity(isSubmitting ? 1 : 0)
                .scaleEffect(isSubmitting ? 1 : 0.82)
        }
        .animation(
            .timingCurve(0.165, 0.84, 0.44, 1, duration: 0.22),
            value: showShortcut
        )
        .animation(
            .timingCurve(0.165, 0.84, 0.44, 1, duration: 0.22),
            value: isSubmitting
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isSubmitting ? "Sending" : "Listening. Press Return to send")
        .help(isSubmitting ? "Sending" : "Press Return to send")
    }
}

private struct ReturnKeyHint: View {
    let color: Color

    var body: some View {
        Text("↵")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color.opacity(0.88))
            .frame(width: 20, height: 17)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.white.opacity(0.13), lineWidth: 0.5)
            }
    }
}

struct WaveformView: View {
    let levels: [CGFloat]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let barCount = max(18, Int(size.width / 3.2))
            let samples = resampledLevels(count: barCount)
            let stride = size.width / CGFloat(barCount)
            let barWidth = max(1, min(1.7, stride * 0.48))

            for index in samples.indices {
                let signal = smoothedLevel(at: index, in: samples)
                let normalized = min(1, max(0, (signal - 0.06) / 0.5))
                let height = max(2, 2 + (size.height - 2) * pow(normalized, 0.72))
                let rect = CGRect(
                    x: CGFloat(index) * stride + (stride - barWidth) / 2,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(color.opacity(0.82))
                )
            }
        }
        .accessibilityLabel("Live audio level")
    }

    private func resampledLevels(count: Int) -> [CGFloat] {
        let source = Array(levels.suffix(max(count, 1)))
        if source.count >= count {
            return Array(source.suffix(count))
        }
        return Array(repeating: source.first ?? 0.08, count: count - source.count) + source
    }

    private func smoothedLevel(at index: Int, in samples: [CGFloat]) -> CGFloat {
        let previous = samples[max(0, index - 1)]
        let current = samples[index]
        let next = samples[min(samples.count - 1, index + 1)]
        return previous * 0.22 + current * 0.56 + next * 0.22
    }
}

struct CreationMenuView: View {
    @ObservedObject var controller: PanelController

    var body: some View {
        VStack(spacing: 0) {
            ForEach(CreationOption.allCases) { option in
                Button {
                    controller.chooseCreationOption(option)
                } label: {
                    HStack(spacing: 12) {
                        Text(option.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))

                        Spacer()

                        Text(option.shortcutLabel)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.32))
                            .frame(width: 28, alignment: .trailing)

                        creationIcon(for: option)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                    .background(
                        .white.opacity(controller.selectedCreationOption == option ? 0.055 : 0)
                    )
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(.white.opacity(0.065)).frame(height: 1)
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        controller.selectedCreationOption = option
                    }
                }
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func creationIcon(for option: CreationOption) -> some View {
        let color = controller.selectedCreationOption == option
            ? Color.agentGreen
            : Color.white.opacity(0.3)

        if option == .codexThread {
            OpenAIBlossomIcon(size: 11, color: color)
                .frame(width: 18, height: 18)
        } else if option == .meetingRecorder {
            Circle()
                .fill(
                    controller.selectedCreationOption == option
                        ? Color.agentCoral
                        : Color.white.opacity(0.3)
                )
                .frame(width: 7, height: 7)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: option.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
        }
    }
}

struct FocusSessionView: View {
    @ObservedObject var controller: PanelController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.agentGreen.opacity(0.82))
                    .frame(width: 18)

                TextField("What will you focus on?", text: $controller.focusTask)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .onSubmit {
                        controller.toggleFocusSession()
                    }
            }
            .padding(.horizontal, 20)
            .frame(height: 42)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.065)).frame(height: 1)
            }

            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(FocusPreset.allCases) { preset in
                        Button {
                            controller.selectFocusPreset(preset)
                        } label: {
                            Text("\(preset.focusMinutes)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(
                                    controller.focusPreset == preset
                                        ? Color.agentGreen
                                        : Color.white.opacity(0.42)
                                )
                                .frame(width: 38, height: 24)
                                .background(
                                    .white.opacity(controller.focusPreset == preset ? 0.08 : 0),
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("\(preset.focusMinutes) minutes of focus, then \(preset.breakMinutes) minutes off")
                    }
                }
                .padding(2)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))

                HStack(spacing: 0) {
                    NumberFlowText(
                        "\(controller.focusPreset.breakMinutes)m",
                        fontSize: 10,
                        color: .white.opacity(0.38),
                        reservedWidth: 20,
                        alignment: .leading
                    )
                    Text(" break")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .frame(width: 62, alignment: .leading)

                Spacer(minLength: 12)

                NumberFlowText(
                    controller.focusTimeText,
                    fontSize: 25,
                    color: .white.opacity(0.92),
                    reservedWidth: 86,
                    lineHeight: 34
                )

                Button {
                    controller.toggleFocusSession()
                } label: {
                    Image(systemName: controller.focusIsRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Color.agentGreen, in: Circle())
                        .foregroundStyle(.black.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help(controller.focusIsRunning ? "Pause focus session" : "Start focus session")

                Button {
                    controller.resetFocusSession()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.045), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Reset focus session")
            }
            .padding(.horizontal, 20)
            .frame(height: 100)
        }
    }
}

struct LocalDocumentEditorView: View {
    @ObservedObject var controller: PanelController
    @ObservedObject private var dictation: SpeechDictationService
    let kind: LocalDocumentKind
    @FocusState private var titleFocused: Bool

    init(controller: PanelController, kind: LocalDocumentKind) {
        self.controller = controller
        self.kind = kind
        _dictation = ObservedObject(wrappedValue: controller.dictation)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: kind == .note ? "note.text" : "doc.text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(kind == .note ? Color.agentAmber : Color.agentBlue)

                TextField(kind == .note ? "Untitled note" : "Untitled page", text: $controller.editorTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .focused($titleFocused)
                    .layoutPriority(1)
                    .onSubmit {
                        controller.requestNoteEditorFocus()
                    }

                if kind == .note, !showingVoiceCapture {
                    NoteSaveIndicator(state: controller.noteSaveState)
                } else if showingVoiceCapture {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(dictation.isRecording ? Color.agentAmber : Color.agentGreen)
                            .frame(width: 5, height: 5)
                        NumberFlowText(
                            dictation.elapsedText,
                            fontSize: 10,
                            weight: .semibold,
                            color: .white.opacity(0.58),
                            reservedWidth: 34
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 42)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.065)).frame(height: 1)
            }

            if controller.noteFindVisible, !showingVoiceCapture {
                MarkdownNoteFindBar(isPresented: $controller.noteFindVisible)
            }

            if showingVoiceCapture {
                voiceCapture
            } else {
                textEditor
            }

            editorFooter
        }
        .onAppear {
            titleFocused = showingVoiceCapture
            if !showingVoiceCapture {
                controller.requestNoteEditorFocus()
            }
        }
        .onChange(of: controller.editorTitle) { _, _ in
            controller.noteDraftDidChange()
        }
        .onChange(of: controller.editorBody) { _, _ in
            controller.noteDraftDidChange()
        }
    }

    private var showingVoiceCapture: Bool {
        controller.isStartingDictation || dictation.isRecording || !dictation.transcript.isEmpty
    }

    private var voiceCapture: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                DictationActivityCue(
                    dictation: dictation,
                    color: kind == .note ? .agentAmber : .agentBlue
                )
                .frame(width: 150, height: 32)

                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 1, height: 28)

                Text(dictation.transcript.isEmpty ? "Listening" : dictation.transcript)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(dictation.transcript.isEmpty ? 0.4 : 0.78))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    controller.toggleDictation()
                } label: {
                    Image(systemName: dictation.isRecording ? "stop.fill" : "waveform")
                }
                .buttonStyle(RecordingButtonStyle(isRecording: dictation.isRecording))
                .help(dictation.isRecording ? "Stop recording" : "Resume recording")

                Button {
                    controller.cancelDictation()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(EditorIconButtonStyle())
                .help("Cancel dictation")

                Button {
                    controller.commitDictation()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(EditorIconButtonStyle())
                .disabled(dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Use transcript")
            }

            if let message = controller.statusMessage {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(message == "Saved locally" ? Color.agentGreen : Color.white.opacity(0.48))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 20)
    }

    private var textEditor: some View {
        MarkdownNoteEditor(
            text: $controller.editorBody,
            documentID: controller.noteEditorDocumentID,
            rawSourceMode: controller.noteShowsRawMarkdown,
            placeholder: kind == .note ? "Write a note" : "Start a page"
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorFooter: some View {
        Group {
            if showingVoiceCapture {
                HStack {
                    Spacer()
                    Button {
                        controller.openLocalLibrary()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(EditorIconButtonStyle())
                    .help("Open iAgent Library")
                    .accessibilityLabel("Open iAgent Library")
                    .accessibilityIdentifier("note-open-library")
                }
            } else {
                MarkdownFormattingToolbar(
                    rawSourceMode: controller.noteShowsRawMarkdown,
                    showFind: {
                        controller.noteFindVisible = true
                    },
                    toggleSourceMode: {
                        controller.toggleNoteSourceMode()
                    },
                    openLibrary: {
                        controller.openLocalLibrary()
                    }
                )
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.065)).frame(height: 1)
        }
    }
}

private struct NoteSaveIndicator: View {
    let state: NoteSaveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch state {
            case .idle:
                Color.clear
            case .saving:
                NoteSavingSpinner(reduceMotion: reduceMotion)
            case .saved:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(Color.agentGreen.opacity(0.9))
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Color.agentCoral.opacity(0.9))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 18, height: 18)
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.17), value: state)
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityHidden(state == .idle)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("note-save-status")
    }

    private var helpText: String {
        switch state {
        case .idle: "Not saved yet"
        case .saving: "Saving locally"
        case .saved: "Saved locally"
        case .failed(let message): "Could not save: \(message)"
        }
    }
}

private struct NoteSavingSpinner: View {
    let reduceMotion: Bool
    @State private var rotating = false

    var body: some View {
        Image(systemName: "circle.dotted")
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.66))
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .animation(
                reduceMotion
                    ? nil
                    : .linear(duration: 0.9).repeatForever(autoreverses: false),
                value: rotating
            )
            .onAppear {
                rotating = !reduceMotion
            }
            .accessibilityHidden(true)
    }
}

enum TodoLayoutMetrics {
    static let composerHeight: CGFloat = 34
    static let rowHeight: CGFloat = 36
    static let bottomPadding: CGFloat = 12
}

struct TodoListView: View {
    private static let composerFocusMorphEnabled = false

    @ObservedObject var controller: PanelController
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var composerFocusProgress: CGFloat = 1
    @State private var composerNotchProgress: CGFloat = 0
    @State private var draftDueDate: Date?
    @State private var draftListName: String?
    @State private var showingDraftDueDatePicker = false
    @State private var showingDraftListPicker = false

    var body: some View {
        ZStack(alignment: .top) {
            if controller.showingPastTodos {
                pastTodoList
            } else {
                VStack(spacing: 0) {
                    todoComposer

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if controller.visibleTodos.isEmpty {
                                todoEmptyState("No open todos")
                            } else {
                                ForEach(controller.visibleTodos) { todo in
                                    todoRow(todo, isHistory: false)
                                        .transition(
                                            .asymmetric(
                                                insertion: .offset(y: -8).combined(with: .opacity),
                                                removal: .identity
                                            )
                                        )
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)

                    Color.clear
                        .frame(height: TodoLayoutMetrics.bottomPadding)
                }

            }
        }
        .onAppear {
            inputFocused = false
            controller.setTodoComposerFocused(false)
        }
        .onDisappear {
            controller.setTodoComposerFocused(false)
        }
        .onChange(of: controller.showingPastTodos) { _, showingHistory in
            if showingHistory {
                inputFocused = false
            }
        }
        .task(id: controller.todoComposerFocusRequest) {
            guard controller.todoComposerFocusRequest > 0 else { return }
            inputFocused = true
        }
        .task(id: inputFocused) {
            await animateComposerFocus(inputFocused)
        }
    }

    private var pastTodoList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if controller.pastTodos.isEmpty {
                        todoEmptyState("No completed todos yet")
                    } else {
                        ForEach(controller.pastTodos) { todo in
                            todoRow(todo, isHistory: true)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            Color.clear
                .frame(height: TodoLayoutMetrics.bottomPadding)
        }
    }

    private func todoEmptyState(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.32))
            .frame(maxWidth: .infinity, minHeight: 72)
            .transition(.identity)
    }

    private func todoRow(_ todo: LocalTodo, isHistory: Bool) -> some View {
        TodoRow(
            todo: todo,
            isFading: controller.fadingTodoIDs.contains(todo.id),
            insertionOpacity: 1,
            availableListNames: controller.todoListNames,
            animatesCompletion: controller.completingTodoIDs.contains(todo.id),
            showsHistoryMetadata: isHistory,
            onToggle: { controller.toggleTodo(todo.id) },
            onToggleStar: { controller.toggleTodoStar(todo.id) },
            onSetDueDate: { controller.setTodoDueDate(todo.id, dueDate: $0) },
            onSetList: { controller.setTodoList(todo.id, listName: $0) },
            onDelete: { controller.deleteTodo(todo.id) }
        )
    }

    private var todoComposer: some View {
        ZStack(alignment: .trailing) {
            TodoComposerSurfaceShape(notchProgress: composerNotchProgress)
                .fill(
                    Color.white.opacity(
                        0.026 + 0.016 * Double(composerFocusProgress)
                    )
                )
                .overlay {
                    TodoComposerSurfaceShape(notchProgress: composerNotchProgress)
                        .stroke(
                            Color.white.opacity(0.038 * Double(composerFocusProgress)),
                            lineWidth: 0.5
                        )
                }
                .shadow(
                    color: .black.opacity(0.22 * Double(composerFocusProgress)),
                    radius: 5,
                    y: 1
                )

            HStack(spacing: 0) {
                ReferenceTodoCheckbox(
                    fillProgress: 0,
                    pinchProgress: 0,
                    rightPullProgress: 0,
                    pressScale: 1,
                    checkProgress: 0
                )
                    .scaleEffect(0.64 + 0.36 * checkboxReveal)
                    .opacity(Double(checkboxReveal))
                    .offset(x: -4 * (1 - checkboxReveal))
                    .frame(width: 27 * checkboxReveal, height: 18, alignment: .leading)
                    .clipped()

                TextField("Create new task", text: $controller.todoDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .focused($inputFocused)
                    .onSubmit(submitTodo)

                Color.clear
                    .frame(width: 44 + 132 * composerFocusProgress)
            }
            .padding(.leading, 8)
            .padding(.trailing, 7)

            HStack(spacing: 4) {
                TodoComposerKeycap("⌘")
                TodoComposerKeycap("E")
            }
            .padding(.trailing, 8)
            .opacity(Double(1 - shortcutFadeProgress))
            .scaleEffect(
                x: 1 - 0.12 * shortcutFadeProgress,
                y: 1 - 0.06 * shortcutFadeProgress,
                anchor: .trailing
            )
            .offset(x: -4 * shortcutFadeProgress)

            HStack(spacing: 4) {
                Button {
                    showingDraftDueDatePicker.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: draftDueDate == nil ? "calendar" : "calendar.badge.checkmark")
                            .font(.system(size: 10, weight: .semibold))

                        if let draftDueDate {
                            Text(todoDueDateText(draftDueDate))
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(draftDueDate == nil ? Color.white.opacity(0.56) : Color.agentBlue)
                    .padding(.horizontal, draftDueDate == nil ? 0 : 7)
                    .frame(minWidth: 24)
                    .frame(height: 24)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(draftDueDate == nil ? "Add due date" : "Change due date")
                .popover(isPresented: $showingDraftDueDatePicker, arrowEdge: .bottom) {
                    TodoDueDatePopover(dueDate: draftDueDate) { dueDate in
                        draftDueDate = dueDate
                    }
                }

                Button {
                    showingDraftListPicker.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .stroke(.white.opacity(0.34), lineWidth: 1)
                            .frame(width: 6, height: 6)
                        Text(draftListName ?? "No list")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                            .frame(maxWidth: 70)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.28))
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Choose a local list")
                .popover(isPresented: $showingDraftListPicker, arrowEdge: .bottom) {
                    TodoListPickerPopover(
                        selectedList: draftListName,
                        availableLists: controller.todoListNames
                    ) { listName in
                        draftListName = listName
                        controller.rememberTodoList(listName)
                    }
                }
            }
            .padding(.trailing, 6)
            .opacity(Double(accessoryReveal))
            .scaleEffect(
                x: 0.76 + 0.24 * accessoryReveal,
                y: 0.9 + 0.1 * accessoryReveal,
                anchor: .trailing
            )
            .offset(x: 7 * (1 - accessoryReveal))
        }
        .frame(height: TodoLayoutMetrics.composerHeight)
        .padding(.horizontal, 12)
        .frame(height: TodoLayoutMetrics.composerHeight, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(inputFocused ? "New todo editor" : "Create new task")
    }

    private var checkboxReveal: CGFloat {
        phase(composerFocusProgress, from: 0.38, to: 1)
    }

    private var shortcutFadeProgress: CGFloat {
        phase(composerFocusProgress, from: 0, to: 0.48)
    }

    private var accessoryReveal: CGFloat {
        phase(composerFocusProgress, from: 0.12, to: 0.82)
    }

    private func phase(_ value: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        min(1, max(0, (value - start) / (end - start)))
    }

    private func submitTodo() {
        let insertedID: UUID?
        if reduceMotion {
            insertedID = controller.addTodo(dueDate: draftDueDate, listName: draftListName)
        } else {
            insertedID = withAnimation(
                .timingCurve(0.165, 0.84, 0.44, 1, duration: 0.22)
            ) {
                controller.addTodo(dueDate: draftDueDate, listName: draftListName)
            }
        }

        guard insertedID != nil else {
            return
        }
        draftDueDate = nil
    }

    @MainActor
    private func animateComposerFocus(_ focused: Bool) async {
        controller.setTodoComposerFocused(focused)

        guard Self.composerFocusMorphEnabled else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                composerFocusProgress = 1
                composerNotchProgress = 0
            }
            return
        }

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.08)) {
                composerFocusProgress = focused ? 1 : 0
                composerNotchProgress = 0
            }
            return
        }

        if focused {
            do {
                // The caret lands one frame before the surrounding controls begin to move.
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: 0.05)) {
                composerNotchProgress = 1
            }
            withAnimation(.linear(duration: 0.116)) {
                composerFocusProgress = 1
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.066)) {
                composerNotchProgress = 0
            }
        } else {
            withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.11)) {
                composerFocusProgress = 0
                composerNotchProgress = 0
            }
        }
    }

}

private struct TodoComposerSurfaceShape: Shape {
    var notchProgress: CGFloat

    var animatableData: CGFloat {
        get { notchProgress }
        set { notchProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(1, max(0, notchProgress))
        let radius = min(7, rect.height / 2)
        let left = rect.minX
        let right = rect.maxX
        let top = rect.minY
        let bottom = rect.maxY
        let edgeInset = 3.4 * progress

        var path = Path()
        path.move(to: CGPoint(x: left + radius, y: top))
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addQuadCurve(
            to: CGPoint(x: right, y: top + radius),
            control: CGPoint(x: right, y: top)
        )
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: right - radius, y: bottom),
            control: CGPoint(x: right, y: bottom)
        )
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addQuadCurve(
            to: CGPoint(x: left, y: bottom - radius),
            control: CGPoint(x: left, y: bottom)
        )
        path.addCurve(
            to: CGPoint(x: left + edgeInset, y: rect.midY),
            control1: CGPoint(x: left, y: bottom - radius - rect.height * 0.08),
            control2: CGPoint(x: left + edgeInset, y: rect.midY + rect.height * 0.12)
        )
        path.addCurve(
            to: CGPoint(x: left, y: top + radius),
            control1: CGPoint(x: left + edgeInset, y: rect.midY - rect.height * 0.12),
            control2: CGPoint(x: left, y: top + radius + rect.height * 0.08)
        )
        path.addQuadCurve(
            to: CGPoint(x: left + radius, y: top),
            control: CGPoint(x: left, y: top)
        )
        path.closeSubpath()
        return path
    }
}

private struct TodoComposerKeycap: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.48))
            .frame(width: 17, height: 17)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.white.opacity(0.045), lineWidth: 0.5)
            }
    }
}

private func todoDueDateText(_ date: Date, referenceDate: Date = Date()) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }

    if calendar.component(.year, from: date) == calendar.component(.year, from: referenceDate) {
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
}

private struct TodoDueDatePopover: View {
    let dueDate: Date?
    let onChange: (Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date

    init(dueDate: Date?, onChange: @escaping (Date?) -> Void) {
        self.dueDate = dueDate
        self.onChange = onChange
        _selectedDate = State(initialValue: dueDate ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Due date")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))

            DatePicker(
                "Due date",
                selection: $selectedDate,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.graphical)
            .tint(Color.agentBlue)

            Divider()
                .overlay(.white.opacity(0.08))

            HStack(spacing: 8) {
                if dueDate != nil {
                    Button("Clear") {
                        onChange(nil)
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.48))
                }

                Spacer()

                Button("Today") {
                    onChange(Date())
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.62))

                Button("Done") {
                    onChange(selectedDate)
                    dismiss()
                }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(Color.agentBlue)
            }
            .font(.system(size: 10, weight: .medium))
        }
        .padding(12)
        .frame(width: 248)
        .background(Color(red: 0.075, green: 0.078, blue: 0.086))
    }
}

private struct TodoListPickerPopover: View {
    let selectedList: String?
    let availableLists: [String]
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newListName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("List")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 4)

            listButton(title: "No list", value: nil)

            if !availableLists.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(availableLists, id: \.self) { listName in
                            listButton(title: listName, value: listName)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 112)
            }

            Divider()
                .overlay(.white.opacity(0.08))

            HStack(spacing: 6) {
                TextField("New list", text: $newListName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .onSubmit(createList)

                Button(action: createList) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.white.opacity(0.2)
                        : Color.agentGreen
                )
                .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .frame(width: 196)
        .background(Color(red: 0.075, green: 0.078, blue: 0.086))
    }

    private func listButton(title: String, value: String?) -> some View {
        Button {
            onSelect(value)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .stroke(.white.opacity(0.34), lineWidth: 1)
                    .frame(width: 7, height: 7)

                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                Spacer()

                if selectedList == value {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.agentGreen)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func createList() {
        let value = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSelect(value)
        dismiss()
    }
}

private struct TodoRow: View {
    let todo: LocalTodo
    let isFading: Bool
    let insertionOpacity: Double
    let availableListNames: [String]
    let animatesCompletion: Bool
    let showsHistoryMetadata: Bool
    let onToggle: () -> Void
    let onToggleStar: () -> Void
    let onSetDueDate: (Date?) -> Void
    let onSetList: (String?) -> Void
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var fillProgress: CGFloat = 0
    @State private var pinchProgress: CGFloat = 0
    @State private var rightPullProgress: CGFloat = 0
    @State private var pressScale: CGFloat = 1
    @State private var checkProgress: CGFloat = 0
    @State private var strikeProgress: CGFloat = 0
    @State private var showingDueDatePicker = false
    @State private var showingListPicker = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                ReferenceTodoCheckbox(
                    fillProgress: fillProgress,
                    pinchProgress: pinchProgress,
                    rightPullProgress: rightPullProgress,
                    pressScale: pressScale,
                    checkProgress: checkProgress
                )
            }
            .buttonStyle(TodoCheckboxButtonStyle())
            .help(todo.isCompleted ? "Mark incomplete" : "Mark complete")

            HStack(spacing: 12) {
                Text(todo.title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.82 - Double(strikeProgress) * 0.36))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .overlay {
                        GeometryReader { proxy in
                            Path { path in
                                let y = proxy.size.height * 0.54
                                path.move(to: CGPoint(x: -1, y: y))
                                path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                            }
                            .trim(from: 0, to: strikeProgress)
                            .stroke(
                                Color.white.opacity(0.58),
                                style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
                            )
                        }
                    }

                if let listName = todo.listName {
                    Button {
                        showingListPicker.toggle()
                    } label: {
                        Text(listName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.34))
                            .lineLimit(1)
                            .frame(maxWidth: 72)
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Change list")
                    .popover(isPresented: $showingListPicker, arrowEdge: .bottom) {
                        TodoListPickerPopover(
                            selectedList: todo.listName,
                            availableLists: availableListNames
                        ) { listName in
                            onSetList(listName)
                        }
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            if showsHistoryMetadata {
                starButton

                dueDateButton
                    .opacity(todo.dueDate == nil ? 0 : 1)
                    .allowsHitTesting(todo.dueDate != nil)

                Text(todo.createdRelativeText())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
                    .frame(width: 36, alignment: .trailing)
            } else {
                starButton
                    .opacity(todo.isStarred || hovering ? 1 : 0)

                dueDateButton
                    .opacity(todo.dueDate != nil || hovering ? 1 : 0)

                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Delete todo")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 36)
        .background(.white.opacity(hovering ? 0.035 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .opacity(isFading ? 0 : insertionOpacity)
        .blur(radius: isFading ? 1.25 : 0)
        .allowsHitTesting(!isFading)
        .animation(.easeOut(duration: 0.18), value: isFading)
        .task(id: todo.isCompleted) {
            if todo.isCompleted, !animatesCompletion {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    fillProgress = 1
                    pinchProgress = 0
                    rightPullProgress = 0
                    pressScale = 1
                    checkProgress = 1
                    strikeProgress = 1
                }
                return
            }
            await animateCompletion(todo.isCompleted)
        }
    }

    private var starButton: some View {
        Button(action: onToggleStar) {
            Image(systemName: todo.isStarred ? "star.fill" : "star")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(todo.isStarred ? Color.agentAmber : .white.opacity(0.36))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(todo.isStarred ? "Remove star" : "Star todo")
    }

    private var dueDateButton: some View {
        Button {
            showingDueDatePicker.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: todo.dueDate == nil ? "calendar" : "calendar.badge.checkmark")
                    .font(.system(size: 10, weight: .medium))

                if let dueDate = todo.dueDate {
                    Text(todoDueDateText(dueDate))
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(todo.dueDate == nil ? Color.white.opacity(0.36) : Color.agentBlue)
            .frame(minWidth: 22)
            .frame(height: 22)
        }
        .buttonStyle(.plain)
        .help(todo.dueDate == nil ? "Add due date" : "Change due date")
        .popover(isPresented: $showingDueDatePicker, arrowEdge: .bottom) {
            TodoDueDatePopover(dueDate: todo.dueDate, onChange: onSetDueDate)
        }
    }

    @MainActor
    private func animateCompletion(_ completed: Bool) async {
        if !completed {
            withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.16)) {
                fillProgress = 0
                pinchProgress = 0
                rightPullProgress = 0
                pressScale = 1
                checkProgress = 0
                strikeProgress = 0
            }
            return
        }

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.14)) {
                fillProgress = 1
                checkProgress = 1
                strikeProgress = 1
            }
            return
        }

        // These checkpoints are sampled from the reference's live 24x20 SVG path.
        // Keeping the axes independent prevents the diagonal corner distortion that
        // a single generic spring introduces.
        withAnimation(.linear(duration: 0.066)) {
            fillProgress = 1
            pinchProgress = 1
            pressScale = 0.948
        }
        withAnimation(.easeOut(duration: 0.12)) {
            checkProgress = 1
        }

        guard await sleepForCompletion(milliseconds: 66) else { return }
        guard await sleepForCompletion(milliseconds: 67) else { return }

        withAnimation(.linear(duration: 0.033)) {
            pinchProgress = 0.85
            rightPullProgress = 0.0875
            pressScale = 0.9315
        }
        guard await sleepForCompletion(milliseconds: 33) else { return }

        withAnimation(.linear(duration: 0.017)) {
            pinchProgress = 0.65
            rightPullProgress = 0.30
            pressScale = 0.9546
        }
        guard await sleepForCompletion(milliseconds: 17) else { return }

        withAnimation(.linear(duration: 0.017)) {
            pinchProgress = 0.50
            rightPullProgress = 0.455
            pressScale = 0.9674
        }
        guard await sleepForCompletion(milliseconds: 17) else { return }

        withAnimation(.linear(duration: 0.083)) {
            pinchProgress = 0.08
            rightPullProgress = 0.9125
            pressScale = 0.9764
        }
        guard await sleepForCompletion(milliseconds: 83) else { return }

        withAnimation(.linear(duration: 0.058)) {
            pinchProgress = 0
            rightPullProgress = 1
            pressScale = 1
        }
        guard await sleepForCompletion(milliseconds: 58) else { return }

        // The strike begins only after the right edge has reached its full pull.
        withAnimation(.timingCurve(0.165, 0.84, 0.44, 1, duration: 0.134)) {
            strikeProgress = 1
        }
        guard await sleepForCompletion(milliseconds: 34) else { return }

        withAnimation(.linear(duration: 0.016)) {
            rightPullProgress = 0.745
        }
        guard await sleepForCompletion(milliseconds: 16) else { return }

        withAnimation(.linear(duration: 0.05)) {
            rightPullProgress = 0.365
        }
        guard await sleepForCompletion(milliseconds: 50) else { return }

        withAnimation(.timingCurve(0.2, 0.72, 0.38, 1, duration: 0.084)) {
            rightPullProgress = 0
        }
    }

    private func sleepForCompletion(milliseconds: Int) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}

struct ReferenceTodoCheckbox: View {
    let fillProgress: CGFloat
    let pinchProgress: CGFloat
    let rightPullProgress: CGFloat
    let pressScale: CGFloat
    let checkProgress: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            ReferenceTodoCheckboxShape(
                pinchProgress: pinchProgress,
                rightPullProgress: rightPullProgress
            )
            .fill(Color.white.opacity(0.10 + 0.90 * Double(fillProgress)))

            ReferenceTodoCheckboxShape(
                pinchProgress: pinchProgress,
                rightPullProgress: rightPullProgress
            )
            .stroke(
                Color.white.opacity(0.30 * Double(1 - fillProgress)),
                style: StrokeStyle(lineWidth: 1.05, lineJoin: .round)
            )

            TodoCheckmarkShape()
                .trim(from: 0, to: checkProgress)
                .stroke(
                    Color.black.opacity(0.82),
                    style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 12.8, height: 12.8)
                .offset(x: 1.6)
        }
        .frame(width: 19.2, height: 16, alignment: .leading)
        .scaleEffect(
            pressScale,
            anchor: UnitPoint(x: 10.0 / 24.0, y: 0.5)
        )
        .frame(width: 20, height: 18, alignment: .leading)
    }
}

private struct ReferenceTodoCheckboxShape: Shape {
    var pinchProgress: CGFloat
    var rightPullProgress: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pinchProgress, rightPullProgress) }
        set {
            pinchProgress = newValue.first
            rightPullProgress = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let pinch = min(1, max(0, pinchProgress))
        let pull = min(1, max(0, rightPullProgress))
        let edgeInset = 0.21 * pinch
        let centerInset = 0.86 * pinch
        let pullBlend = min(1, pull / 0.0875)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x / 24,
                y: rect.minY + rect.height * y / 20
            )
        }

        func mix(_ from: CGFloat, _ to: CGFloat, _ amount: CGFloat) -> CGFloat {
            from + (to - from) * amount
        }

        let leftEdge = edgeInset
        let topEdge = edgeInset
        let bottomEdge = 20 - edgeInset
        let topCenter = centerInset
        let bottomCenter = 20 - centerInset

        let pinchedRightEdge = 20 - edgeInset
        let pinchedRightCenter = 20 - centerInset
        let pulledRightEdge: CGFloat = 20
        let pulledTip = 20 + 4 * pull
        let rightEdge = mix(pinchedRightEdge, pulledRightEdge, pullBlend)
        let upperControlOneX = mix(pinchedRightEdge, 20 + 0.2748 * pull, pullBlend)
        let upperControlOneY = mix(7, 7 - 0.03849 * pull, pullBlend)
        let upperControlTwoX = mix(pinchedRightCenter, 20 + 2 * pull, pullBlend)
        let upperControlTwoY = mix(8, 8 + 0.5 * pull, pullBlend)
        let rightCenter = mix(pinchedRightCenter, pulledTip, pullBlend)
        let lowerControlOneX = mix(pinchedRightCenter, 20 + 2 * pull, pullBlend)
        let lowerControlOneY = mix(12, 12 - 0.5 * pull, pullBlend)
        let lowerControlTwoX = mix(pinchedRightEdge, 20 + 0.2748 * pull, pullBlend)
        let lowerControlTwoY = mix(13, 13 + 0.03849 * pull, pullBlend)

        var path = Path()
        path.move(to: point(leftEdge, 5.9998))
        path.addCurve(
            to: point(5.9998, topEdge),
            control1: point(leftEdge, 2.68609),
            control2: point(2.68609, topEdge)
        )
        path.addCurve(
            to: point(10, topCenter),
            control1: point(6.99777, topEdge),
            control2: point(8, topCenter)
        )
        path.addCurve(
            to: point(13.998, topEdge),
            control1: point(12, topCenter),
            control2: point(13, topEdge)
        )
        path.addCurve(
            to: point(rightEdge, 5.9998),
            control1: point(17.3117, topEdge),
            control2: point(rightEdge, 2.68609)
        )
        path.addCurve(
            to: point(rightCenter, 10),
            control1: point(upperControlOneX, upperControlOneY),
            control2: point(upperControlTwoX, upperControlTwoY)
        )
        path.addCurve(
            to: point(rightEdge, 14.0002),
            control1: point(lowerControlOneX, lowerControlOneY),
            control2: point(lowerControlTwoX, lowerControlTwoY)
        )
        path.addCurve(
            to: point(13.998, bottomEdge),
            control1: point(rightEdge, 17.3139),
            control2: point(17.3117, bottomEdge)
        )
        path.addCurve(
            to: point(10, bottomCenter),
            control1: point(12.9978, bottomEdge),
            control2: point(12, bottomCenter)
        )
        path.addCurve(
            to: point(5.9998, bottomEdge),
            control1: point(8, bottomCenter),
            control2: point(7, bottomEdge)
        )
        path.addCurve(
            to: point(leftEdge, 14.0002),
            control1: point(2.68609, bottomEdge),
            control2: point(leftEdge, 17.3139)
        )
        path.addCurve(
            to: point(centerInset, 10),
            control1: point(leftEdge, 13),
            control2: point(centerInset, 12)
        )
        path.addCurve(
            to: point(leftEdge, 5.9998),
            control1: point(centerInset, 8),
            control2: point(leftEdge, 7)
        )
        path.closeSubpath()
        return path
    }
}

private struct TodoCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x / 16,
                y: rect.minY + rect.height * y / 16
            )
        }

        var path = Path()
        path.move(to: point(3.5, 8.5))
        path.addLine(to: point(6.5, 11.5))
        path.addLine(to: point(12.5, 5.5))
        return path
    }
}

private struct TodoCheckboxButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.055), value: configuration.isPressed)
    }
}

@MainActor
private final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    var placeholderColor = NSColor.white.withAlphaComponent(0.25) {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let origin = textContainerOrigin
        let drawingRect = NSRect(
            x: origin.x,
            y: origin.y,
            width: max(0, bounds.width - origin.x * 2),
            height: max(0, bounds.height - origin.y)
        )
        (placeholder as NSString).draw(
            in: drawingRect,
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: placeholderColor,
            ]
        )
    }
}

private struct AlignedTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let shouldFocus: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = PlaceholderTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor.white.withAlphaComponent(0.78)
        textView.insertionPointColor = NSColor.white.withAlphaComponent(0.9)
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.placeholder = placeholder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }
        context.coordinator.text = $text
        textView.placeholder = placeholder
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }

        if shouldFocus, !context.coordinator.didRequestFocus {
            context.coordinator.didRequestFocus = true
            Task { @MainActor [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        } else if !shouldFocus {
            context.coordinator.didRequestFocus = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var didRequestFocus = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PlaceholderTextView else { return }
            text.wrappedValue = textView.string
            textView.needsDisplay = true
        }
    }
}

struct NewCodexThreadView: View {
    @ObservedObject var controller: PanelController
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if controller.editorBody.isEmpty {
                    Text("What should Codex work on?")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.25))
                        .padding(.horizontal, 24)
                        .padding(.top, 17)
                }

                TextEditor(text: $controller.editorBody)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .focused($editorFocused)
            }

            HStack {
                if let statusMessage = controller.statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    controller.createCodexThread()
                } label: {
                    if controller.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black.opacity(0.72))
                    } else {
                        Image(systemName: "arrow.up")
                    }
                }
                .buttonStyle(PrimaryEditorButtonStyle(color: .agentGreen))
                .help("Start Codex task")
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.065)).frame(height: 1)
            }
        }
        .onAppear { editorFocused = true }
    }
}

struct HeaderIconButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(
                isActive
                    ? Color.agentGreen
                    : Color.white.opacity(configuration.isPressed ? 0.52 : 0.76)
            )
            .frame(width: 28, height: 28)
            .background(.white.opacity(isActive ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

struct EditorIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.45 : 0.64))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

struct RecordingButtonStyle: ButtonStyle {
    let isRecording: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(isRecording ? Color.black.opacity(0.82) : Color.agentAmber)
            .frame(width: 30, height: 30)
            .background(
                isRecording ? Color.agentAmber : Color.agentAmber.opacity(0.1),
                in: Circle()
            )
            .contentShape(Circle())
    }
}

struct PrimaryEditorButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.82))
            .frame(width: 30, height: 30)
            .background(color.opacity(configuration.isPressed ? 0.72 : 0.96), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}
