import SwiftUI
import iAgentCore

struct TodosMobileView: View {
  @ObservedObject var model: MobileAppModel
  @ObservedObject private var todoDictation: MobileMeetingRecorder
  let onCreateTodo: () -> Void

  @FocusState private var isQuickCreateFocused: Bool
  @State private var quickTitle = ""
  @State private var quickMentionSelectionID: String?
  @State private var isQuickCreateActive = false
  @State private var isQuickSaveInFlight = false
  @State private var showsCompleted = false
  @State private var voiceStatusMessage: String?
  @State private var selectedTodoID: UUID?

  init(model: MobileAppModel, onCreateTodo: @escaping () -> Void) {
    self.model = model
    self.onCreateTodo = onCreateTodo
    _todoDictation = ObservedObject(wrappedValue: model.todoDictation)
  }

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.38) {
        hero
      } drawer: {
        LazyVStack(spacing: 0) {
          createTodoButton
          JoiDottedDivider()

          if model.displayedOpenTodos.isEmpty {
            EmptyPanelState(
              symbol: "checkmark",
              title: "Nothing open",
              detail: "The rest of today is yours."
            )
          } else {
            JoiSectionHeader(title: "Today", count: model.openTodos.count)

            ForEach(Array(model.displayedOpenTodos.enumerated()), id: \.element.id) { index, todo in
              JoiTodoRow(
                model: model,
                todoID: todo.id,
                onOpen: { selectedTodoID = todo.id }
              )
                .id("open-\(todo.id.uuidString)")
                .contextMenu {
                  Button(role: .destructive) {
                    Task { await model.deleteTodo(id: todo.id) }
                  } label: {
                    Label("Delete", systemImage: "trash")
                  }
                }

              if index < model.displayedOpenTodos.count - 1 { JoiDottedDivider() }
            }
          }

          if !model.completedTodos.isEmpty {
            JoiDrawerButton {
              withAnimation(PanelTheme.disclosure) { showsCompleted.toggle() }
            } label: {
              HStack(spacing: 8) {
                Text("DONE")
                Text("\(model.completedTodos.count)")
                  .contentTransition(.numericText())
                Spacer()
                Image(systemName: "chevron.right")
                  .font(.system(size: 10, weight: .bold))
                  .rotationEffect(.degrees(showsCompleted ? 90 : 0))
              }
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(PanelTheme.tertiary)
              .padding(.horizontal, 24)
              .frame(height: 44)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsCompleted {
              ForEach(Array(model.completedTodos.enumerated()), id: \.element.id) { index, todo in
                JoiTodoRow(
                  model: model,
                  todoID: todo.id,
                  onOpen: { selectedTodoID = todo.id }
                )
                  .id("done-\(todo.id.uuidString)")
                  .transition(.opacity.combined(with: .move(edge: .top)))
                if index < model.completedTodos.count - 1 { JoiDottedDivider() }
              }
            }
          }
        }
        .padding(.bottom, 96)
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .navigationDestination(item: $selectedTodoID) { todoID in
      TodoDetailView(model: model, todoID: todoID)
    }
    .onChange(of: model.selectedTab) { _, tab in
      guard tab != .todos,
            todoDictation.isRecording || todoDictation.isStarting || todoDictation.isStopping
      else { return }
      todoDictation.reset()
      voiceStatusMessage = nil
    }
    .onChange(of: todoDictation.transcript) { _, transcript in
      guard isQuickCreateActive, todoDictation.isRecording else { return }
      quickTitle = transcript
    }
    .onChange(of: model.snapshot.todos, initial: true) { _, todos in
      guard ProcessInfo.processInfo.arguments.contains("--todo-detail-fixture"),
            selectedTodoID == nil,
            let todo = todos.first(where: { !$0.isCompleted && $0.deletedAt == nil })
      else { return }
      selectedTodoID = todo.id
    }
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 0) {
      JoiPageMasthead(
        title: "Todos",
        metric: "\(model.openTodos.count)",
        metricLabel: model.openTodos.count == 1 ? "task left" : "tasks left",
        accent: PanelTheme.blue
      )

      todoBriefing
        .font(.system(size: 20, weight: .semibold))
        .lineSpacing(3)
        .padding(.top, 30)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, PanelTheme.horizontalPadding)
    .padding(.top, 14)
  }

  private var todoBriefing: Text {
    let starred = model.openTodos.filter(\.isStarred).count
    return Text(model.openTodos.isEmpty ? "Everything is handled. " : "Keep the day light. ")
      .foregroundStyle(PanelTheme.secondary)
      + Text("\(model.openTodos.count) open")
      .foregroundStyle(PanelTheme.primary)
      + Text(starred > 0 ? " with " : ".")
      .foregroundStyle(PanelTheme.secondary)
      + Text(starred > 0 ? "\(starred) starred." : "")
      .foregroundStyle(PanelTheme.primary)
  }

  private var createTodoButton: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Group {
          if isQuickCreateActive {
            ArtifactMentionAttachedField(
              text: $quickTitle,
              mentions: model.artifactMentions,
              writesMarkdown: false,
              isActive: isQuickCreateFocused,
              selectedMentionID: $quickMentionSelectionID
            ) {
              TextField("New To-do", text: $quickTitle)
                .focused($isQuickCreateFocused)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PanelTheme.primary)
                .tint(PanelTheme.coral)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit { Task { await submitQuickTodo() } }
                .onKeyPress(.upArrow) { handleQuickMentionKey(.previous) }
                .onKeyPress(.downArrow) { handleQuickMentionKey(.next) }
                .onKeyPress(.return) { handleQuickMentionKey(.select) }
                .accessibilityIdentifier("todo-quick-title")
            }
          } else {
            JoiDrawerButton(action: activateQuickCreate) {
              Text("Create new task")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PanelTheme.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }

        if isQuickCreateActive {
          JoiDrawerButton(action: onCreateTodo) {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(PanelTheme.secondary)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Add details")
          .accessibilityHint("Opens dates, lists, notes, and formatting")
        }

        JoiDrawerButton {
          Task { await performQuickCreateAction() }
        } label: {
          ZStack {
            Circle()
              .fill(quickCanSubmit ? PanelTheme.primary : voiceButtonColor)
              .frame(width: 36, height: 36)

            if todoDictation.isStarting || todoDictation.isStopping || isQuickSaveInFlight {
              ProgressView()
                .tint(quickCanSubmit ? .black : PanelTheme.primary)
            } else {
              Image(systemName: quickActionSymbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(quickCanSubmit ? .black : voiceSymbolColor)
                .contentTransition(.symbolEffect(.replace))
            }
          }
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(todoDictation.isStarting || todoDictation.isStopping || isQuickSaveInFlight)
        .accessibilityLabel(quickCanSubmit ? "Create todo" : "Create todo by voice")
      }
      .frame(minHeight: 58)

      if let voiceStatusMessage {
        Text(voiceStatusMessage)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(PanelTheme.coral)
          .padding(.bottom, 8)
      } else if todoDictation.isRecording {
        JoiAudioWaveform(
          levels: todoDictation.levels,
          color: PanelTheme.coral,
          isActive: true
        )
        .frame(height: 12)
        .padding(.bottom, 8)
        .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 24)
    .animation(PanelTheme.quick, value: quickCanSubmit)
    .accessibilityIdentifier("todo-create-button")
  }

  private var quickCanSubmit: Bool {
    !quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var quickActionSymbol: String {
    if quickCanSubmit { return "arrow.up" }
    return todoDictation.isRecording ? "stop.fill" : "mic.fill"
  }

  private var voiceButtonColor: Color {
    todoDictation.isRecording ? PanelTheme.coral : PanelTheme.primary
  }

  private var voiceSymbolColor: Color {
    todoDictation.isRecording ? .white : .black
  }

  private func handleQuickMentionKey(
    _ command: ArtifactMentionKeyCommand
  ) -> KeyPress.Result {
    handleArtifactMentionKeyCommand(
      command,
      text: $quickTitle,
      mentions: model.artifactMentions,
      writesMarkdown: false,
      selectedMentionID: $quickMentionSelectionID
    ) ? .handled : .ignored
  }

  private func activateQuickCreate() {
    isQuickCreateActive = true
    voiceStatusMessage = nil
    DispatchQueue.main.async { isQuickCreateFocused = true }
  }

  private func performQuickCreateAction() async {
    if quickCanSubmit {
      await submitQuickTodo()
    } else {
      await toggleQuickVoiceInput()
    }
  }

  private func toggleQuickVoiceInput() async {
    activateQuickCreate()
    if todoDictation.isRecording {
      let finalTranscript = await todoDictation.stop()
      if !finalTranscript.isEmpty { quickTitle = finalTranscript }
      todoDictation.reset()
      isQuickCreateFocused = true
      return
    }

    todoDictation.reset()
    let started = await todoDictation.start()
    if !started {
      voiceStatusMessage = todoDictation.errorMessage ?? "Microphone unavailable"
    }
  }

  private func submitQuickTodo() async {
    guard !isQuickSaveInFlight else { return }
    var title = quickTitle
    if todoDictation.isRecording || todoDictation.isStopping {
      let finalTranscript = await todoDictation.stop()
      if !finalTranscript.isEmpty { title = finalTranscript }
    }
    title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      voiceStatusMessage = "Add a title before creating this todo"
      todoDictation.reset()
      return
    }

    isQuickSaveInFlight = true
    let saved = await model.createTodo(title: title)
    isQuickSaveInFlight = false
    todoDictation.reset()

    guard saved else {
      quickTitle = title
      voiceStatusMessage = "Couldn’t save that todo—try again"
      isQuickCreateFocused = true
      return
    }

    quickTitle = ""
    voiceStatusMessage = nil
    isQuickCreateActive = false
    isQuickCreateFocused = false
  }
}

private struct JoiTodoRow: View {
  @ObservedObject var model: MobileAppModel
  let todoID: UUID
  let onOpen: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var fillProgress: CGFloat = 0
  @State private var pinchProgress: CGFloat = 0
  @State private var rightPullProgress: CGFloat = 0
  @State private var pressScale: CGFloat = 1
  @State private var checkProgress: CGFloat = 0
  @State private var strikeProgress: CGFloat = 0

  var body: some View {
    if let todo = model.todo(id: todoID) {
      row(todo)
        .opacity(isFading ? 0 : 1)
        .blur(radius: isFading ? 1.25 : 0)
        .allowsHitTesting(!isFading)
        .animation(.easeOut(duration: 0.18), value: isFading)
        .task(id: todo.isCompleted) {
          if todo.isCompleted, !model.completingTodoIDs.contains(todoID) {
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
  }

  private func row(_ todo: SyncedTodo) -> some View {
    JoiTimelineRow(minHeight: 62) {
      JoiDrawerButton {
        Task { await model.toggleTodo(id: todoID) }
      } label: {
        MobileReferenceTodoCheckbox(
          fillProgress: fillProgress,
          pinchProgress: pinchProgress,
          rightPullProgress: rightPullProgress,
          pressScale: pressScale,
          checkProgress: checkProgress
        )
        .frame(width: 36, height: 36)
      }
      .buttonStyle(MobileTodoCheckboxButtonStyle())
      .accessibilityLabel(todo.isCompleted ? "Reopen \(todo.title)" : "Complete \(todo.title)")
      .accessibilityValue(todo.isCompleted ? "Checked" : "Unchecked")
    } content: {
      JoiDrawerButton(action: onOpen) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            todoTitle(todo)

            if let list = todo.listName {
              Text(list)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PanelTheme.tertiary)
                .lineLimit(1)
            }
          }

          todoTitle(todo)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open \(todo.title)")
      .accessibilityHint("Shows todo details")
      .accessibilityIdentifier("todo-row-open-\(todoID.uuidString)")
    } trailing: {
      HStack(spacing: 10) {
        if let dueDate = todo.dueDate {
          Text(dueDate.formatted(.dateTime.month(.abbreviated).day()))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(dueDate < Date() && !todo.isCompleted ? PanelTheme.coral : PanelTheme.secondary)
        }

        JoiDrawerButton {
          Task { await model.toggleStar(id: todoID) }
        } label: {
          Image(systemName: todo.isStarred ? "star.fill" : "star")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(todo.isStarred ? PanelTheme.amber : PanelTheme.tertiary)
            .frame(width: 28, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(todo.isStarred ? "Unstar \(todo.title)" : "Star \(todo.title)")
      }
    }
  }

  private func todoTitle(_ todo: SyncedTodo) -> some View {
    Text(todo.title)
      .font(.system(size: 16, weight: .semibold))
      .foregroundStyle(PanelTheme.primary.opacity(1 - Double(strikeProgress) * 0.52))
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
            PanelTheme.primary.opacity(0.58),
            style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
          )
        }
      }
  }

  private var isFading: Bool {
    model.fadingTodoIDs.contains(todoID)
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

private struct MobileReferenceTodoCheckbox: View {
  let fillProgress: CGFloat
  let pinchProgress: CGFloat
  let rightPullProgress: CGFloat
  let pressScale: CGFloat
  let checkProgress: CGFloat

  var body: some View {
    ZStack(alignment: .leading) {
      MobileReferenceTodoCheckboxShape(
        pinchProgress: pinchProgress,
        rightPullProgress: rightPullProgress
      )
      .fill(PanelTheme.primary.opacity(0.10 + 0.90 * Double(fillProgress)))

      MobileReferenceTodoCheckboxShape(
        pinchProgress: pinchProgress,
        rightPullProgress: rightPullProgress
      )
      .stroke(
        PanelTheme.primary.opacity(0.30 * Double(1 - fillProgress)),
        style: StrokeStyle(lineWidth: 1.05, lineJoin: .round)
      )

      MobileTodoCheckmarkShape()
        .trim(from: 0, to: checkProgress)
        .stroke(
          Color.black.opacity(0.82),
          style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round)
        )
        .frame(width: 16, height: 16)
        .offset(x: 2)
    }
    .frame(width: 24, height: 20, alignment: .leading)
    .scaleEffect(
      pressScale,
      anchor: UnitPoint(x: 10.0 / 24.0, y: 0.5)
    )
    .frame(width: 30, height: 26, alignment: .leading)
  }
}

private struct MobileReferenceTodoCheckboxShape: Shape {
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
    let rightEdge = mix(pinchedRightEdge, 20, pullBlend)
    let pulledTip = 20 + 4 * pull
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

private struct MobileTodoCheckmarkShape: Shape {
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

private struct MobileTodoCheckboxButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.82 : 1)
      .animation(.easeOut(duration: 0.055), value: configuration.isPressed)
  }
}
