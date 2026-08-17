import Combine
import SwiftUI
import UIKit
import iAgentCore

struct MobileRootView: View {
  @ObservedObject var model: MobileAppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var voiceSession: MobileVoiceAgentSession
  @State private var noteEditor: NoteEditorRoute?
  @State private var isTodoCreationPresented: Bool
  @State private var pageSwipeStartTab: MobileAppModel.Tab?
  @State private var noteRowSwipeBlocksPageTransition = false
  @State private var isCreateMenuPresented: Bool
  @State private var isAskIAgentPresented: Bool
  @State private var isVoiceAskIAgentPresented = false
  @State private var pendingVoicePrompt: String?
  @State private var plusButtonFrame = CGRect.zero
  @State private var voiceMenuItemFrame = CGRect.zero
  @State private var voiceOriginFrame = CGRect.zero
  #if DEBUG
  @State private var didStartVoiceAgentFixture = false
  #endif

  init(model: MobileAppModel) {
    self.model = model
    _voiceSession = StateObject(wrappedValue: MobileVoiceAgentSession())
    _isTodoCreationPresented = State(
      initialValue: ProcessInfo.processInfo.arguments.contains("todo-composer")
    )
    _isCreateMenuPresented = State(
      initialValue: ProcessInfo.processInfo.arguments.contains("--create-menu-open")
    )
    _isAskIAgentPresented = State(
      initialValue: ProcessInfo.processInfo.arguments.contains("--ask-iagent")
    )
    _pendingVoicePrompt = State(initialValue: nil)
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .bottom) {
        ZStack {
          tabPage(.today, width: proxy.size.width) {
            NavigationStack {
              TodayView(
                model: model,
                onNavigateToTab: navigateToTab
              )
            }
          }

          tabPage(.codex, width: proxy.size.width) {
            NavigationStack {
              CodexMobileView(model: model)
            }
          }

          tabPage(.notes, width: proxy.size.width) {
            NavigationStack {
              NotesMobileView(
                model: model,
                noteEditor: $noteEditor,
                onNoteRowSwipeActivityChanged: {
                  noteRowSwipeBlocksPageTransition = $0
                }
              )
            }
          }

          tabPage(.todos, width: proxy.size.width) {
            NavigationStack {
              TodosMobileView(model: model) {
                isTodoCreationPresented = true
              }
            }
          }
        }
        .clipped()
        .frame(maxHeight: .infinity)
        .accessibilityHidden(
          isCreateMenuPresented || voiceSession.isVisible || isVoiceAskIAgentPresented
        )

        if isCreateMenuPresented {
          Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .onTapGesture { setCreateMenuPresented(false) }
            .accessibilityHidden(true)
            .zIndex(2)
        }

        JoiDockBackdropFade()
          .zIndex(3)

        // The root content is laid out to the safe-area bottom. Extend only
        // the inert drawer color through the remaining physical screen edge;
        // the dock and every scroll/tap target keep their existing safe-area
        // placement above the home indicator.
        if proxy.safeAreaInsets.bottom > 0 {
          Rectangle()
            .fill(PanelTheme.sheet)
            .frame(height: proxy.safeAreaInsets.bottom)
            .offset(y: proxy.safeAreaInsets.bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(3)
        }

        if voiceSession.isEffectVisible {
          VoiceEdgeEffectLayer(
            sourceFrame: voiceOriginFrame,
            safeAreaInsets: proxy.safeAreaInsets,
            isCommitted: voiceSession.isVisible,
            effectOpacity: voiceSession.effectOpacity,
            signal: voiceSession.effectSignal
          )
          .ignoresSafeArea()
          .transition(.identity)
          .zIndex(5)
        }

        if voiceSession.isVisible {
          VoiceAgentOverlay(
            session: voiceSession,
            safeAreaInsets: proxy.safeAreaInsets
          )
          .ignoresSafeArea()
          .transition(.identity)
          .zIndex(5.1)
        }

        JoiBottomDock(
          model: model,
          isCreateMenuPresented: $isCreateMenuPresented,
          isVoiceSessionActive: voiceSession.isVisible,
          voiceControlShowsStop: voiceSession.showsStopControl,
          voiceControlShowsDismiss: voiceSession.showsDismissControl,
          voiceControlIsFinishing: voiceSession.isFinishing,
          onNewChat: {
            pendingVoicePrompt = nil
            isAskIAgentPresented = true
          },
          onNewVoiceChat: beginVoiceChatFromMenu,
          onNewVoiceChatFromPlus: beginVoiceChatFromPlus,
          onVoiceTouchChanged: { isActive in
            if isActive {
              guard !isCreateMenuPresented,
                    !voiceSession.isVisible,
                    !voiceSession.showsStopControl,
                    !voiceSession.showsDismissControl,
                    !voiceSession.isFinishing
              else { return }
              if plusButtonFrame.width > 0 {
                voiceOriginFrame = plusButtonFrame
              }
              voiceSession.prepareLaunchFeedback()
              voiceSession.setPlusTouchActive(true)
            } else if voiceSession.ownsPlusTouch {
              voiceSession.setPlusTouchActive(false)
            }
          },
          onVoiceTap: {
            guard voiceSession.finishTap() else { return }
            setCreateMenuPresented(true)
          },
          onVoiceHoldBegan: {
            if plusButtonFrame.width > 0 {
              voiceOriginFrame = plusButtonFrame
            }
            voiceSession.recognizeHold()
          },
          onVoiceHoldReleased: voiceSession.releaseHold,
          onVoiceCancel: voiceSession.abandon,
          onVoiceStop: voiceSession.stopAndSubmit,
          onCreateNote: { noteEditor = NoteEditorRoute(note: nil) },
          onCreateTodo: {
            selectBottomTab(.todos)
            isTodoCreationPresented = true
          },
          onRecordMeeting: { model.presentRecorder() },
          onSelectTab: selectBottomTab
        )
        .padding(.horizontal, 26)
        .padding(.bottom, 8)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .accessibilityHidden(isVoiceAskIAgentPresented)
        .zIndex(voiceSession.isVisible ? 6 : 4)

        if isVoiceAskIAgentPresented, let pendingVoicePrompt {
          AskIAgentView(model: model, initialPrompt: pendingVoicePrompt) {
            isVoiceAskIAgentPresented = false
            self.pendingVoicePrompt = nil
            voiceSession.chatDidDismiss()
          }
          .background(PanelTheme.canvas.ignoresSafeArea())
          // The voice layer already performs the transcript handoff. Mount the
          // opaque chat root atomically; crossfading this whole hierarchy caused
          // 139 ms of sliced header/root composites in the captured transition.
          .transition(.identity)
          .task(id: pendingVoicePrompt) {
            // Keep the voice surface mounted behind the opaque chat root until
            // the crossfade has completed. Removing it from `onAppear` exposed
            // the retained tab root for one frame during handoff.
            if !reduceMotion {
              try? await Task.sleep(for: .milliseconds(180))
            }
            guard !Task.isCancelled, isVoiceAskIAgentPresented else { return }
            voiceSession.chatDidPresent()
          }
          .zIndex(10)
        }
      }
      .simultaneousGesture(pageTabSwipe)
    }
    .onPreferenceChange(VoicePlusButtonFramePreference.self) { frame in
      guard frame.width > 0, frame.height > 0 else { return }
      plusButtonFrame = frame
      if voiceOriginFrame == .zero { voiceOriginFrame = frame }
    }
    .onPreferenceChange(VoiceMenuItemFramePreference.self) { frame in
      guard frame.width > 0, frame.height > 0 else { return }
      voiceMenuItemFrame = frame
    }
    .tint(PanelTheme.primary)
    .background(PanelTheme.canvas.ignoresSafeArea())
    .fullScreenCover(item: $noteEditor) { route in
      if let note = route.note, note.kind == .meeting {
        MeetingNoteDetailView(model: model, noteID: note.id)
      } else {
        NoteEditorView(model: model, route: route)
      }
    }
    .fullScreenCover(isPresented: $model.isRecorderPresented, onDismiss: openPendingMeetingNote) {
      MeetingRecorderView(model: model)
    }
    .fullScreenCover(isPresented: $isTodoCreationPresented) {
      TodoCreationView(model: model)
    }
    .fullScreenCover(isPresented: $isAskIAgentPresented, onDismiss: {
      pendingVoicePrompt = nil
      voiceSession.chatDidDismiss()
    }) {
      AskIAgentView(model: model, initialPrompt: pendingVoicePrompt) {
        isAskIAgentPresented = false
      }
      .onAppear { voiceSession.chatDidPresent() }
    }
    .fullScreenCover(item: $model.deepLinkDestination) { destination in
      switch destination {
      case .note(let note):
        if let note, note.kind == .meeting {
          MeetingNoteDetailView(model: model, noteID: note.id)
        } else {
          NoteEditorView(model: model, route: NoteEditorRoute(note: note))
        }
      case .todo(let todo):
        TodoDetailView(model: model, todoID: todo.id)
      case .todoDraft:
        TodoCreationView(model: model)
      case .codex(let task):
        CodexThreadDetailView(model: model, thread: task)
      case .codexDraft:
        CodexRequestDraftView()
      }
    }
    .alert("Cannot open link", isPresented: Binding(
      get: { model.navigationNotice != nil },
      set: { if !$0 { model.navigationNotice = nil } }
    )) {
      Button("OK") { model.navigationNotice = nil }
    } message: {
      Text(model.navigationNotice ?? "")
    }
    .sheet(isPresented: $model.isSettingsPresented) {
      NavigationStack {
        MobileSettingsView(model: model)
      }
      .preferredColorScheme(.dark)
      .presentationDragIndicator(.visible)
    }
    .task {
      #if DEBUG
      await startVoiceAgentFixtureIfRequested()
      #endif
      guard model.isNoteEditorPresented, noteEditor == nil else { return }
      noteEditor = NoteEditorRoute(note: nil)
      model.isNoteEditorPresented = false
    }
    .onChange(of: voiceSession.handoffPrompt) { _, prompt in
      guard let prompt, !isAskIAgentPresented, !isVoiceAskIAgentPresented else { return }
      pendingVoicePrompt = prompt
      isVoiceAskIAgentPresented = true
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .background, voiceSession.isEffectVisible else { return }
      voiceSession.abandon()
    }
  }

  @ViewBuilder
  private func tabPage<Content: View>(
    _ tab: MobileAppModel.Tab,
    width: CGFloat,
    @ViewBuilder content: () -> Content
  ) -> some View {
    let tabIndex = tabOrder.firstIndex(of: tab) ?? 0
    let selectedIndex = tabOrder.firstIndex(of: model.selectedTab) ?? 0
    let isSelected = tab == model.selectedTab

    content()
      .frame(width: width)
      .offset(x: isSelected ? 0 : (tabIndex < selectedIndex ? -width : width))
      .zIndex(isSelected ? 1 : 0)
      .allowsHitTesting(isSelected)
      .accessibilityHidden(!isSelected)
  }

  private var tabOrder: [MobileAppModel.Tab] {
    [.today, .codex, .notes, .todos]
  }

  /*
   The tab roots intentionally remain mounted in the ZStack above so their
   NavigationStack and drawer state survive tab changes. Moving only the newly
   selected root also guarantees the requested directional transition for Home
   briefing links, which UIPageViewController did not animate reliably for an
   ObservableObject-backed programmatic selection.
   */

  private func openPendingMeetingNote() {
    guard let note = model.consumePendingMeetingNote() else { return }
    Task { @MainActor in
      await Task.yield()
      noteEditor = NoteEditorRoute(note: note)
    }
  }

  private var pageTabSwipe: some Gesture {
    DragGesture(minimumDistance: 14, coordinateSpace: .global)
      .onChanged { value in
        guard !isCreateMenuPresented,
              !voiceSession.isVisible,
              !isVoiceAskIAgentPresented,
              !voiceSession.ownsPlusTouch,
              pageSwipeStartTab == nil,
              PageSwipeGestureArbitration.shouldTrack(
                horizontalTranslation: Double(value.translation.width),
                verticalTranslation: Double(value.translation.height),
                localHorizontalGestureIsActive: noteRowSwipeBlocksPageTransition
              )
        else { return }
        pageSwipeStartTab = model.selectedTab
      }
      .onEnded { value in
        defer { pageSwipeStartTab = nil }
        guard let startTab = pageSwipeStartTab,
              model.selectedTab == startTab,
              let delta = PageSwipeGestureArbitration.pageDelta(
                predictedHorizontalTranslation: Double(value.predictedEndTranslation.width),
                predictedVerticalTranslation: Double(value.predictedEndTranslation.height),
                localHorizontalGestureIsActive: noteRowSwipeBlocksPageTransition
              )
        else { return }

        let orderedTabs: [MobileAppModel.Tab] = [.today, .codex, .notes, .todos]
        guard let index = orderedTabs.firstIndex(of: startTab) else { return }
        let target = min(max(0, index + delta), orderedTabs.count - 1)
        guard target != index else { return }
        navigateToTab(orderedTabs[target])
      }
  }

  private func navigateToTab(_ tab: MobileAppModel.Tab) {
    guard model.selectedTab != tab else { return }
    if reduceMotion {
      model.selectedTab = tab
    } else {
      withAnimation(PanelTheme.pageTransition) {
        model.selectedTab = tab
      }
    }
  }

  /// Bottom-dock tabs are direct destinations rather than navigation pushes.
  /// Disable the transaction so their retained page roots switch cleanly with
  /// no cross-fade or lateral movement. Home briefing links intentionally keep
  /// using `navigateToTab(_:)` for their directional navigation animation.
  private func selectBottomTab(_ tab: MobileAppModel.Tab) {
    guard model.selectedTab != tab else { return }
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      model.selectedTab = tab
    }
  }

  private func setCreateMenuPresented(_ isPresented: Bool) {
    if isPresented {
      // Warm the Taptic Engine while the menu opens so selecting Voice Chat
      // can land its causal launch impact on the same frame as the first ray.
      voiceSession.prepareLaunchFeedback()
    }
    let animation: Animation
    if reduceMotion {
      animation = .linear(duration: 0.12)
    } else {
      animation = isPresented ? PanelTheme.dockExpand : PanelTheme.dockCollapse
    }
    withAnimation(animation) {
      isCreateMenuPresented = isPresented
    }
  }

  private func beginVoiceChatFromMenu() {
    voiceOriginFrame = voiceMenuItemFrame.width > 0 ? voiceMenuItemFrame : plusButtonFrame
    setCreateMenuPresented(false)
    voiceSession.beginFromMenu()
  }

  private func beginVoiceChatFromPlus() {
    if plusButtonFrame.width > 0, plusButtonFrame.height > 0 {
      voiceOriginFrame = plusButtonFrame
    }
    setCreateMenuPresented(false)
    voiceSession.beginFromMenu()
  }

  #if DEBUG
  /// Starts deterministic Simulator-only voice flows after the dock has completed its
  /// first layout pass, so the activation bloom has the real plus-button origin.
  /// Speech itself remains owned by `MobileMeetingRecorder` and therefore requires
  /// the existing `--simulate-recorder` launch argument.
  @MainActor
  private func startVoiceAgentFixtureIfRequested() async {
    let arguments = ProcessInfo.processInfo.arguments
    let keepsListening = arguments.contains("--voice-agent-fixture-listening")
    let automaticallyHandsOff = arguments.contains("--voice-agent-fixture-handoff")
    let startsFromPlus = arguments.contains("--voice-agent-fixture-plus-origin")
    let startsFromMenu = arguments.contains("--voice-agent-fixture-menu-origin")
    guard !didStartVoiceAgentFixture,
          keepsListening || automaticallyHandsOff
    else { return }

    didStartVoiceAgentFixture = true
    let requestedDelay = arguments
      .first(where: { $0.hasPrefix("--voice-agent-fixture-start-delay-ms=") })
      .flatMap { argument in
        argument.split(separator: "=", maxSplits: 1).last.flatMap { Int($0) }
      }
    // 450 ms preserves existing fixture behavior. A longer explicit delay is
    // useful when profiling the effect independently from cold-launch model,
    // CloudKit, and retained-tab initialization work.
    let fixtureDelay = max(requestedDelay ?? 450, 0)
    try? await Task.sleep(for: .milliseconds(fixtureDelay))
    guard !Task.isCancelled else { return }

    if startsFromMenu {
      setCreateMenuPresented(true)
      // Wait for the real menu row preference to publish. This fixture follows
      // the same measured-origin route as a user tap instead of substituting a
      // guessed rectangle, which keeps menu morph regressions observable.
      try? await Task.sleep(for: .milliseconds(420))
      guard !Task.isCancelled else { return }
      beginVoiceChatFromMenu()
    } else if startsFromPlus {
      voiceOriginFrame = plusButtonFrame
      voiceSession.setPlusTouchActive(true)
      // Preserve the production hold threshold so captures include the local
      // trigger-border seed before ray ignition.
      try? await Task.sleep(for: .milliseconds(330))
      guard !Task.isCancelled else { return }
      voiceSession.recognizeHold()
      voiceSession.setPlusTouchActive(false)
      voiceSession.releaseHold()
    } else {
      beginVoiceChatFromMenu()
    }
    guard automaticallyHandsOff else { return }

    // Allow several growing partial callbacks to render before committing the
    // authoritative recorder transcript through the real stop/handoff path.
    try? await Task.sleep(for: .milliseconds(2_750))
    guard !Task.isCancelled, voiceSession.isVisible else { return }
    voiceSession.stopAndSubmit()
  }
  #endif
}

struct NoteEditorRoute: Identifiable {
  let id = UUID()
  let note: SyncedNote?
}

private struct JoiBottomDock: View {
  @ObservedObject var model: MobileAppModel
  @Binding var isCreateMenuPresented: Bool
  let isVoiceSessionActive: Bool
  let voiceControlShowsStop: Bool
  let voiceControlShowsDismiss: Bool
  let voiceControlIsFinishing: Bool
  let onNewChat: () -> Void
  let onNewVoiceChat: () -> Void
  let onNewVoiceChatFromPlus: () -> Void
  let onVoiceTouchChanged: (Bool) -> Void
  let onVoiceTap: () -> Void
  let onVoiceHoldBegan: () -> Void
  let onVoiceHoldReleased: () -> Void
  let onVoiceCancel: () -> Void
  let onVoiceStop: () -> Void
  let onCreateNote: () -> Void
  let onCreateTodo: () -> Void
  let onRecordMeeting: () -> Void
  let onSelectTab: (MobileAppModel.Tab) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visualSelection: MobileAppModel.Tab
  @Namespace private var materialNamespace
  @Namespace private var selectionNamespace

  private let dockHeight: CGFloat = 58
  private let actionSize: CGFloat = 58
  private let itemSpacing: CGFloat = 10
  private let menuHeight: CGFloat = 344

  init(
    model: MobileAppModel,
    isCreateMenuPresented: Binding<Bool>,
    isVoiceSessionActive: Bool,
    voiceControlShowsStop: Bool,
    voiceControlShowsDismiss: Bool,
    voiceControlIsFinishing: Bool,
    onNewChat: @escaping () -> Void,
    onNewVoiceChat: @escaping () -> Void,
    onNewVoiceChatFromPlus: @escaping () -> Void,
    onVoiceTouchChanged: @escaping (Bool) -> Void,
    onVoiceTap: @escaping () -> Void,
    onVoiceHoldBegan: @escaping () -> Void,
    onVoiceHoldReleased: @escaping () -> Void,
    onVoiceCancel: @escaping () -> Void,
    onVoiceStop: @escaping () -> Void,
    onCreateNote: @escaping () -> Void,
    onCreateTodo: @escaping () -> Void,
    onRecordMeeting: @escaping () -> Void,
    onSelectTab: @escaping (MobileAppModel.Tab) -> Void
  ) {
    self.model = model
    _isCreateMenuPresented = isCreateMenuPresented
    self.isVoiceSessionActive = isVoiceSessionActive
    self.voiceControlShowsStop = voiceControlShowsStop
    self.voiceControlShowsDismiss = voiceControlShowsDismiss
    self.voiceControlIsFinishing = voiceControlIsFinishing
    self.onNewChat = onNewChat
    self.onNewVoiceChat = onNewVoiceChat
    self.onNewVoiceChatFromPlus = onNewVoiceChatFromPlus
    self.onVoiceTouchChanged = onVoiceTouchChanged
    self.onVoiceTap = onVoiceTap
    self.onVoiceHoldBegan = onVoiceHoldBegan
    self.onVoiceHoldReleased = onVoiceHoldReleased
    self.onVoiceCancel = onVoiceCancel
    self.onVoiceStop = onVoiceStop
    self.onCreateNote = onCreateNote
    self.onCreateTodo = onCreateTodo
    self.onRecordMeeting = onRecordMeeting
    self.onSelectTab = onSelectTab
    _visualSelection = State(initialValue: model.selectedTab)
  }

  var body: some View {
    GeometryReader { proxy in
      let mainWidth = max(238, proxy.size.width - actionSize - itemSpacing)

      HStack(alignment: .bottom, spacing: itemSpacing) {
        Group {
          if isVoiceSessionActive {
            Color.clear
          } else if isCreateMenuPresented {
            creationPanel(width: mainWidth)
          } else {
            tabPill(width: mainWidth)
          }
        }
        .frame(width: mainWidth, alignment: .bottomLeading)

        createButton
          .frame(width: actionSize, height: actionSize)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
    .frame(height: isVoiceSessionActive ? dockHeight : (isCreateMenuPresented ? menuHeight : dockHeight))
    .sensoryFeedback(.impact(weight: .light, intensity: 0.52), trigger: isCreateMenuPresented) {
      wasPresented, isPresented in
      // Voice launch owns one prepared medium impact on the exact frame its
      // source morph commits. Suppress the menu-close impact on that route so
      // the two feedback events cannot blur into a double tap.
      !(wasPresented && !isPresented && isVoiceSessionActive)
    }
    .sensoryFeedback(.selection, trigger: visualSelection)
    .onChange(of: model.selectedTab) { _, tab in
      guard visualSelection != tab else { return }
      withAnimation(selectionAnimation) {
        visualSelection = tab
      }
    }
    .accessibilityAction(named: "Close create menu") {
      guard isCreateMenuPresented else { return }
      setCreateMenuPresented(false)
    }
  }

  private func tabPill(width: CGFloat) -> some View {
    HStack(spacing: 0) {
      tabButton(.today)
      tabButton(.codex)
      tabButton(.notes)
      tabButton(.todos)
    }
    .frame(width: width, height: dockHeight)
    .background {
      JoiDockMaterial(cornerRadius: dockHeight / 2)
        .matchedGeometryEffect(id: "dock-material", in: materialNamespace)
    }
    .contentShape(RoundedRectangle(cornerRadius: dockHeight / 2, style: .continuous))
    .transition(
      reduceMotion
        ? .opacity
        : .asymmetric(
          insertion: .opacity.combined(with: .offset(y: 4)),
          removal: .opacity.combined(with: .offset(y: 8))
        )
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Main tabs")
  }

  private func tabButton(_ tab: MobileAppModel.Tab) -> some View {
    return Button {
      withAnimation(selectionAnimation) {
        visualSelection = tab
      }
      onSelectTab(tab)
    } label: {
      tabIcon(tab)
        .foregroundStyle(visualSelection == tab ? PanelTheme.primary : PanelTheme.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: dockHeight)
        .background {
          if visualSelection == tab {
            JoiDockSelectionMaterial()
              .matchedGeometryEffect(id: "dock-selection", in: selectionNamespace)
              .padding(4)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(JoiDockPressStyle())
    .accessibilityLabel(tab.accessibilityLabel)
    .accessibilityAddTraits(visualSelection == tab ? .isSelected : [])
    .accessibilityIdentifier("bottom-tab-\(tab.accessibilityLabel.lowercased())")
  }

  @ViewBuilder
  private func tabIcon(_ tab: MobileAppModel.Tab) -> some View {
    if tab == .codex {
      Image("CodexBlossom")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 20, height: 20)
    } else {
      Image(systemName: tab.dockSymbol)
        .font(.system(size: 19, weight: .semibold))
        .symbolRenderingMode(.monochrome)
    }
  }

  private func creationPanel(width: CGFloat) -> some View {
    VStack(spacing: 0) {
      HStack {
        Text("Create")
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(PanelTheme.primary)
        Spacer()
        Text("NEW")
          .font(.system(size: 9, weight: .bold))
          .tracking(1.4)
          .foregroundStyle(PanelTheme.tertiary)
      }
      .padding(.horizontal, 20)
      .frame(height: 52)

      Rectangle()
        .fill(
          LinearGradient(
            colors: [.clear, PanelTheme.strongBorder, .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
        )
        .frame(height: 0.5)
        .padding(.horizontal, 16)

      creationButton(
        title: "New voice chat",
        symbol: "waveform",
        tint: PanelTheme.violet,
        hint: "Starts listening for a request",
        identifier: "create-voice-chat"
      ) {
        performCreateAction(onNewVoiceChat)
      }

      creationButton(
        title: "New chat",
        symbol: "sparkles",
        tint: PanelTheme.amber,
        hint: "Opens Ask iAgent",
        identifier: "create-chat"
      ) {
        performCreateAction(onNewChat)
      }

      creationButton(
        title: "Record a meeting",
        symbol: "waveform",
        tint: PanelTheme.coral,
        hint: "Opens the meeting recorder",
        identifier: "create-meeting"
      ) {
        performCreateAction(onRecordMeeting)
      }

      creationButton(
        title: "New note",
        symbol: "square.and.pencil",
        tint: PanelTheme.violet,
        hint: "Opens a blank note",
        identifier: "create-note"
      ) {
        performCreateAction(onCreateNote)
      }

      creationButton(
        title: "New to-do",
        symbol: "checkmark.square",
        tint: PanelTheme.blue,
        hint: "Opens the to-do composer",
        identifier: "create-todo"
      ) {
        performCreateAction(onCreateTodo)
      }
    }
    .padding(.bottom, 6)
    .frame(width: width, height: menuHeight, alignment: .top)
    .background {
      JoiDockMaterial(cornerRadius: 30)
        .matchedGeometryEffect(id: "dock-material", in: materialNamespace)
    }
    .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    .transition(
      reduceMotion
        ? .opacity
        : .asymmetric(
          insertion: .opacity.combined(with: .offset(y: 10)),
          removal: .opacity.combined(with: .offset(y: 5))
        )
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Create menu")
    .accessibilityIdentifier("create-menu")
  }

  private func creationButton(
    title: String,
    symbol: String,
    tint: Color,
    hint: String,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: symbol)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 24)

        Text(title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(PanelTheme.primary)

        Spacer(minLength: 0)

        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(PanelTheme.tertiary)
      }
      .padding(.horizontal, 20)
      .frame(height: 56)
      .contentShape(Rectangle())
    }
    .buttonStyle(JoiDockPressStyle(showsPressedFill: true))
    .background {
      if identifier == "create-voice-chat" {
        GeometryReader { proxy in
          Color.clear.preference(
            key: VoiceMenuItemFramePreference.self,
            value: proxy.frame(in: .global)
          )
        }
      }
    }
    .accessibilityLabel(title)
    .accessibilityHint(hint)
    .accessibilityIdentifier(identifier)
  }

  private var createButton: some View {
    ZStack {
      JoiDockMaterial(cornerRadius: actionSize / 2)

      Image(systemName: createButtonSymbol)
        .font(.system(size: createButtonSymbol == "stop.fill" ? 15 : 23, weight: .medium))
        .foregroundStyle(PanelTheme.primary)
        .rotationEffect(.degrees(isCreateMenuPresented && !reduceMotion && !isVoiceSessionActive ? 45 : 0))
        .frame(width: actionSize, height: actionSize)

      VoiceDockPressCapture(
        holdEnabled: !isCreateMenuPresented && !isVoiceSessionActive,
        stopMode: voiceControlShowsStop || voiceControlShowsDismiss || voiceControlIsFinishing,
        onTouchChanged: onVoiceTouchChanged,
        onTap: {
          if isCreateMenuPresented {
            setCreateMenuPresented(false)
          } else if voiceControlShowsDismiss {
            onVoiceCancel()
          } else if voiceControlShowsStop {
            onVoiceStop()
          } else if voiceControlIsFinishing {
            return
          } else if !isVoiceSessionActive {
            onVoiceTap()
          }
        },
        onHold: onVoiceHoldBegan,
        onHoldRelease: onVoiceHoldReleased,
        onCancel: onVoiceCancel
      )
    }
    .frame(width: actionSize, height: actionSize)
    .contentShape(Circle())
    .background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: VoicePlusButtonFramePreference.self,
          value: proxy.frame(in: .global)
        )
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(createButtonAccessibilityLabel)
    .accessibilityHint(
      voiceControlIsFinishing
        ? "Finishing and sending the voice request"
        : voiceControlShowsDismiss
        ? "Dismisses this voice-input error"
        : voiceControlShowsStop
        ? "Stops listening and sends the request"
        : isCreateMenuPresented
        ? "Closes the creation options"
        : "Shows creation options. Press and hold to start a voice chat"
    )
    .accessibilityAction {
      if voiceControlIsFinishing {
        return
      } else if voiceControlShowsDismiss {
        onVoiceCancel()
      } else if voiceControlShowsStop {
        onVoiceStop()
      } else if !isVoiceSessionActive {
        setCreateMenuPresented(!isCreateMenuPresented)
      }
    }
    .accessibilityAction(named: "Start voice chat") {
      guard !isVoiceSessionActive else { return }
      onNewVoiceChatFromPlus()
    }
    .accessibilityIdentifier("bottom-create-button")
  }

  private var createButtonSymbol: String {
    if voiceControlIsFinishing { return "ellipsis" }
    if voiceControlShowsDismiss { return "xmark" }
    if voiceControlShowsStop { return "stop.fill" }
    if isCreateMenuPresented && reduceMotion { return "xmark" }
    return "plus"
  }

  private var createButtonAccessibilityLabel: String {
    if voiceControlIsFinishing { return "Finishing voice request" }
    if voiceControlShowsDismiss { return "Dismiss voice input error" }
    if voiceControlShowsStop { return "Stop listening and send" }
    if isVoiceSessionActive { return "Listening" }
    return isCreateMenuPresented ? "Close create menu" : "Create"
  }

  private var selectionAnimation: Animation {
    reduceMotion ? .linear(duration: 0.12) : PanelTheme.dockSelection
  }

  private func setCreateMenuPresented(_ isPresented: Bool) {
    let animation: Animation
    if reduceMotion {
      animation = .linear(duration: 0.12)
    } else {
      animation = isPresented ? PanelTheme.dockExpand : PanelTheme.dockCollapse
    }
    withAnimation(animation) {
      isCreateMenuPresented = isPresented
    }
  }

  private func performCreateAction(_ action: () -> Void) {
    setCreateMenuPresented(false)
    action()
  }
}

private struct JoiDockMaterial: View {
  let cornerRadius: CGFloat
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    ZStack {
      if reduceTransparency {
        shape.fill(Color(red: 0.105, green: 0.105, blue: 0.115))
      } else {
        shape.fill(.ultraThinMaterial)
        shape.fill(Color.black.opacity(0.4))
      }

      shape.fill(
        LinearGradient(
          stops: [
            .init(color: Color.white.opacity(0.075), location: 0),
            .init(color: Color.white.opacity(0.025), location: 0.34),
            .init(color: Color.black.opacity(0.08), location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      )

      shape.strokeBorder(
        LinearGradient(
          stops: [
            .init(color: Color.white.opacity(0.18), location: 0),
            .init(color: Color.white.opacity(0.055), location: 0.38),
            .init(color: Color.white.opacity(0.025), location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        ),
        lineWidth: 0.75
      )

      shape
        .inset(by: 1)
        .strokeBorder(
          LinearGradient(
            colors: [Color.white.opacity(0.025), Color.black.opacity(0.22)],
            startPoint: .top,
            endPoint: .bottom
          ),
          lineWidth: 1
        )
    }
    .shadow(color: .black.opacity(0.68), radius: 22, x: 0, y: 14)
    .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 4)
    .shadow(color: .white.opacity(0.025), radius: 1, x: 0, y: -1)
  }
}

private struct JoiDockSelectionMaterial: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 25, style: .continuous)
      .fill(
        LinearGradient(
          colors: [Color.white.opacity(0.16), Color.white.opacity(0.09)],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .overlay {
        RoundedRectangle(cornerRadius: 25, style: .continuous)
          .strokeBorder(
            LinearGradient(
              colors: [Color.white.opacity(0.12), Color.white.opacity(0.025)],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 0.75
          )
      }
      .shadow(color: .black.opacity(0.34), radius: 8, x: 0, y: 5)
  }
}

private struct JoiDockBackdropFade: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    ZStack {
      if !reduceTransparency {
        Rectangle()
          .fill(.ultraThinMaterial)
          .mask(
            LinearGradient(
              stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.42), location: 0.42),
                .init(color: .black, location: 0.82),
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
      }

      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: PanelTheme.sheet.opacity(0.22), location: 0.42),
          // The persistent Calendar, Codex, Notes, and Todos drawers all sit
          // behind the dock. Finish with their surface color so the inert
          // background continues through the home-indicator region instead
          // of revealing the black page canvas below the drawer.
          .init(color: PanelTheme.sheet, location: 0.82),
          .init(color: PanelTheme.sheet, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .frame(maxWidth: .infinity)
    .frame(height: 148)
    .ignoresSafeArea(edges: .bottom)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct JoiDockPressStyle: ButtonStyle {
  var showsPressedFill = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        PanelTheme.raisedSurface.opacity(showsPressedFill && configuration.isPressed ? 1 : 0),
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(configuration.isPressed ? 0.9 : 1)
      .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
  }
}

/// A small UIKit touch surface keeps the plus button's tap and press-and-hold
/// paths mutually exclusive. SwiftUI's `Button` plus `onLongPressGesture`
/// combination can still deliver the tap on finger-up after a committed hold.
fileprivate struct VoiceDockPressCapture: UIViewRepresentable {
  let holdEnabled: Bool
  let stopMode: Bool
  let onTouchChanged: (Bool) -> Void
  let onTap: () -> Void
  let onHold: () -> Void
  let onHoldRelease: () -> Void
  let onCancel: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onTouchChanged: onTouchChanged,
      onTap: onTap,
      onHold: onHold,
      onHoldRelease: onHoldRelease,
      onCancel: onCancel
    )
  }

  func makeUIView(context: Context) -> VoiceDockTouchView {
    let view = VoiceDockTouchView()
    view.backgroundColor = .clear
    view.isExclusiveTouch = true
    view.isAccessibilityElement = false
    view.coordinator = context.coordinator
    return view
  }

  func updateUIView(_ view: VoiceDockTouchView, context: Context) {
    context.coordinator.onTouchChanged = onTouchChanged
    context.coordinator.onTap = onTap
    context.coordinator.onHold = onHold
    context.coordinator.onHoldRelease = onHoldRelease
    context.coordinator.onCancel = onCancel
    view.holdEnabled = holdEnabled
    view.stopMode = stopMode
  }

  @MainActor
  final class Coordinator {
    var onTouchChanged: (Bool) -> Void
    var onTap: () -> Void
    var onHold: () -> Void
    var onHoldRelease: () -> Void
    var onCancel: () -> Void

    init(
      onTouchChanged: @escaping (Bool) -> Void,
      onTap: @escaping () -> Void,
      onHold: @escaping () -> Void,
      onHoldRelease: @escaping () -> Void,
      onCancel: @escaping () -> Void
    ) {
      self.onTouchChanged = onTouchChanged
      self.onTap = onTap
      self.onHold = onHold
      self.onHoldRelease = onHoldRelease
      self.onCancel = onCancel
    }
  }
}

@MainActor
fileprivate final class VoiceDockTouchView: UIView {
  weak var coordinator: VoiceDockPressCapture.Coordinator?
  var holdEnabled = true
  var stopMode = false

  private var holdTask: Task<Void, Never>?
  private var committedHold = false
  private var trackingTouch = false
  private var isTouchFeedbackActive = false

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    guard !touches.isEmpty else { return }
    trackingTouch = true
    committedHold = false
    isTouchFeedbackActive = false

    guard holdEnabled, !stopMode else { return }
    isTouchFeedbackActive = true
    coordinator?.onTouchChanged(true)
    holdTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(320))
      guard let self, !Task.isCancelled, self.trackingTouch else { return }
      self.committedHold = true
      self.coordinator?.onHold()
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesMoved(touches, with: event)
    guard let location = touches.first?.location(in: self), trackingTouch else { return }
    if !bounds.insetBy(dx: -36, dy: -36).contains(location), !committedHold {
      cancelTracking()
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    guard trackingTouch else { return }
    trackingTouch = false
    holdTask?.cancel()
    holdTask = nil

    if committedHold {
      coordinator?.onHoldRelease()
    } else {
      coordinator?.onTap()
    }
    committedHold = false
    endTouchFeedback()
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    guard trackingTouch else { return }
    trackingTouch = false
    holdTask?.cancel()
    holdTask = nil

    // A first-use speech or microphone authorization sheet can cancel the
    // originating touch after the hold has already committed. Treat that as
    // the documented early release (latched listening) instead of abandoning
    // the session behind the system prompt.
    if committedHold {
      committedHold = false
      coordinator?.onHoldRelease()
      endTouchFeedback()
    } else {
      committedHold = false
      if isTouchFeedbackActive {
        endTouchFeedback()
        coordinator?.onCancel()
      }
    }
  }

  private func cancelTracking() {
    guard trackingTouch else { return }
    trackingTouch = false
    holdTask?.cancel()
    holdTask = nil
    committedHold = false
    if isTouchFeedbackActive {
      endTouchFeedback()
      coordinator?.onCancel()
    }
  }

  private func endTouchFeedback() {
    guard isTouchFeedbackActive else { return }
    isTouchFeedbackActive = false
    coordinator?.onTouchChanged(false)
  }
}

private struct VoicePlusButtonFramePreference: PreferenceKey {
  static let defaultValue = CGRect.zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next.width > 0, next.height > 0 {
      value = next
    }
  }
}

private struct VoiceMenuItemFramePreference: PreferenceKey {
  static let defaultValue = CGRect.zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next.width > 0, next.height > 0 {
      value = next
    }
  }
}

private struct VoiceEdgeEffectLayer: View {
  let sourceFrame: CGRect
  let safeAreaInsets: EdgeInsets
  let isCommitted: Bool
  let effectOpacity: CGFloat
  let signal: VoiceEdgeEffectSignal

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    GeometryReader { proxy in
      VoiceEdgeEffectView(
        sourceFrame: resolvedSource(
          in: proxy.size,
          overlayFrame: proxy.frame(in: .global)
        ),
        // Zero is an illuminated trigger-border seed. The Metal render loop
        // owns the transition to one, so SwiftUI never publishes display-rate
        // progress updates through the retained four-tab root hierarchy.
        phaseProgress: debugFrozenProgress ?? (isCommitted ? 1 : 0),
        signal: signal,
        effectOpacity: effectOpacity,
        reduceMotion: reduceMotion,
        reduceTransparency: reduceTransparency,
        isActive: true,
        debugFrozenTime: debugFrozenTime
      )
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func resolvedSource(in size: CGSize, overlayFrame: CGRect) -> CGRect {
    guard sourceFrame.width > 0, sourceFrame.height > 0 else {
      return CGRect(
        x: size.width - 84,
        y: size.height - safeAreaInsets.bottom - 66,
        width: 58,
        height: 58
      )
    }
    return sourceFrame.offsetBy(dx: -overlayFrame.minX, dy: -overlayFrame.minY)
  }

  private var debugFrozenTime: TimeInterval? {
    #if DEBUG
    guard let argument = ProcessInfo.processInfo.arguments.first(where: {
      $0.hasPrefix("--voice-edge-frozen-time=")
    }),
      let value = argument.split(separator: "=", maxSplits: 1).last,
      let time = TimeInterval(value)
    else { return nil }
    return max(0, time)
    #else
    return nil
    #endif
  }

  private var debugFrozenProgress: CGFloat? {
    #if DEBUG
    guard let argument = ProcessInfo.processInfo.arguments.first(where: {
      $0.hasPrefix("--voice-edge-frozen-progress=")
    }),
      let value = argument.split(separator: "=", maxSplits: 1).last,
      let progress = Double(value)
    else { return nil }
    return min(1, max(0, progress))
    #else
    return nil
    #endif
  }
}

private struct VoiceAgentOverlay: View {
  @ObservedObject var session: MobileVoiceAgentSession
  @ObservedObject private var transcriptState: MobileVoiceTranscriptState
  let safeAreaInsets: EdgeInsets

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var textVisible = false

  init(session: MobileVoiceAgentSession, safeAreaInsets: EdgeInsets) {
    self.session = session
    self.safeAreaInsets = safeAreaInsets
    _transcriptState = ObservedObject(wrappedValue: session.transcriptState)
  }

  var body: some View {
    GeometryReader { proxy in
      transcriptLayer(in: proxy.size)
        .frame(width: proxy.size.width, height: proxy.size.height)
        .contentShape(Rectangle())
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Voice input")
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier("voice-agent-overlay")
    .task { await revealText() }
  }

  private func transcriptLayer(in size: CGSize) -> some View {
    let isHandingOff = session.isHandingOff
    let isPlaceholder = !isHandingOff && transcriptState.isEmpty
    let text = isHandingOff
      ? session.transcript
      : (session.errorText ?? transcriptState.displayText)

    // Keep one transcript view alive for the entire listening -> handoff path.
    // Conditional matched-geometry source/destination branches briefly rendered
    // both text layers during removal, producing a duplicated last voice frame.
    return VoiceTranscriptText(
      text: text,
      isListening: !isHandingOff && session.isListening,
      isPlaceholder: isPlaceholder,
      fontSize: isHandingOff ? 18 : (isPlaceholder ? 22 : 30),
      alignment: isHandingOff ? .leading : .center
    )
    .padding(.horizontal, isHandingOff ? 18 : 0)
    .padding(.vertical, isHandingOff ? 12 : 0)
    .background {
      RoundedRectangle(cornerRadius: 25, style: .continuous)
        .fill(PanelTheme.selectedSurface)
        .opacity(isHandingOff ? 1 : 0)
    }
    .frame(
      maxWidth: isHandingOff ? size.width * 0.82 : size.width * 0.8,
      alignment: isHandingOff ? .trailing : .center
    )
    .padding(.trailing, isHandingOff ? 28 : 0)
    .padding(.top, isHandingOff ? safeAreaInsets.top + 82 : 0)
    .frame(
      width: size.width,
      height: size.height,
      alignment: isHandingOff ? .topTrailing : .center
    )
    .offset(y: isHandingOff ? 0 : -size.height * 0.04)
    // Recognition may publish its first volatile partial while the solar front
    // is still crossing the retained app surface. Keep that text buffered until
    // the same measured wrap milestone has produced an opaque reading plane;
    // otherwise fast speech can visually collide with the page underneath.
    .opacity(isHandingOff || textVisible ? 1 : 0)
    // Reduced Motion changes state without moving the transcript across the
    // viewport. The ordinary path remains interruptible because the spring
    // retargets this one view from its current presentation geometry.
    .animation(reduceMotion ? nil : handoffAnimation, value: isHandingOff)
  }

  private var handoffAnimation: Animation {
    .spring(response: 0.46, dampingFraction: 1, blendDuration: 0)
  }

  private var accessibilityValue: String {
    if session.isHandingOff { return "Request sent" }
    if session.errorText != nil { return "Voice input unavailable" }
    return transcriptState.isEmpty ? "Listening" : "Speech detected"
  }

  @MainActor
  private func revealText() async {
    // The ordinary launch reaches its fully wrapped, solid surface at about
    // 515 ms. Reduced Motion uses a 180 ms non-spatial cross-fade instead.
    let delay = reduceMotion ? 180 : 515
    try? await Task.sleep(for: .milliseconds(delay))
    guard !Task.isCancelled else { return }
    withAnimation(reduceMotion ? nil : PanelTheme.quick) {
      textVisible = true
    }
  }
}

private struct VoiceTranscriptText: View {
  let text: String
  let isListening: Bool
  let isPlaceholder: Bool
  let fontSize: CGFloat
  let alignment: TextAlignment

  var body: some View {
    VoiceTranscriptLabelRepresentable(
      text: text,
      isListening: isListening,
      isPlaceholder: isPlaceholder,
      fontSize: fontSize,
      alignment: alignment
    )
    .fixedSize(horizontal: false, vertical: true)
    // The UIKit label is deliberately retained while recognition replaces its
    // backing text. Keep SwiftUI from snapshotting/cross-fading the surface.
    .transaction { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
    }
  }
}

/// A retained UIKit text surface for the high-frequency partial transcript.
///
/// SwiftUI's `Text(AttributedString)` recreates and measures a new render tree
/// for every speech callback. Keeping one `UILabel` means partials replace the
/// backing text layer in place; only the label's multiline height is remeasured.
private struct VoiceTranscriptLabelRepresentable: UIViewRepresentable {
  let text: String
  let isListening: Bool
  let isPlaceholder: Bool
  let fontSize: CGFloat
  let alignment: TextAlignment

  func makeUIView(context: Context) -> VoiceTranscriptLabel {
    VoiceTranscriptLabel()
  }

  func updateUIView(_ uiView: VoiceTranscriptLabel, context: Context) {
    let configuration = VoiceTranscriptLabel.Configuration(
      text: text,
      isListening: isListening,
      isPlaceholder: isPlaceholder,
      fontSize: fontSize,
      alignment: alignment == .leading ? .left : .center,
      contentSizeCategory: uiView.traitCollection.preferredContentSizeCategory
    )

    UIView.performWithoutAnimation {
      uiView.apply(configuration)
    }
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    uiView: VoiceTranscriptLabel,
    context: Context
  ) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    if uiView.preferredMaxLayoutWidth != width {
      uiView.preferredMaxLayoutWidth = width
    }
    let measured = uiView.sizeThatFits(
      CGSize(width: width, height: .greatestFiniteMagnitude)
    )
    return CGSize(width: width, height: ceil(measured.height))
  }
}

private final class VoiceTranscriptLabel: UILabel {
  struct Configuration: Equatable {
    let text: String
    let isListening: Bool
    let isPlaceholder: Bool
    let fontSize: CGFloat
    let alignment: NSTextAlignment
    let contentSizeCategory: UIContentSizeCategory
  }

  private struct TextStyleKey: Equatable {
    let isPlaceholder: Bool
    let fontSize: CGFloat
    let alignment: NSTextAlignment
    let contentSizeCategory: UIContentSizeCategory
  }

  private var configuration: Configuration?
  private var cachedTextStyleKey: TextStyleKey?
  private var cachedTextAttributes: [NSAttributedString.Key: Any] = [:]

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    numberOfLines = 0
    lineBreakMode = .byWordWrapping
    adjustsFontSizeToFitWidth = false
    allowsDefaultTighteningForTruncation = false
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setContentHuggingPriority(.required, for: .vertical)
    setContentCompressionResistancePriority(.required, for: .vertical)
    isAccessibilityElement = true
    accessibilityIdentifier = "voice-agent-transcript"
    registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
      (label: VoiceTranscriptLabel, _: UITraitCollection) in
      label.refreshForContentSizeCategory()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(_ next: Configuration) {
    guard configuration != next else { return }
    configuration = next
    applyCurrentConfiguration()
  }

  private func refreshForContentSizeCategory() {
    guard var configuration else { return }

    configuration = Configuration(
      text: configuration.text,
      isListening: configuration.isListening,
      isPlaceholder: configuration.isPlaceholder,
      fontSize: configuration.fontSize,
      alignment: configuration.alignment,
      contentSizeCategory: traitCollection.preferredContentSizeCategory
    )
    self.configuration = configuration
    applyCurrentConfiguration()
  }

  private func applyCurrentConfiguration() {
    guard let configuration else { return }

    let primaryColor = UIColor.white.withAlphaComponent(0.96)
    let renderedText = NSMutableAttributedString(
      string: configuration.text,
      attributes: textAttributes(for: configuration, primaryColor: primaryColor)
    )

    if configuration.isListening, !configuration.isPlaceholder {
      dimTrailingToken(in: renderedText, text: configuration.text, primaryColor: primaryColor)
    }

    textAlignment = configuration.alignment
    attributedText = renderedText
    accessibilityLabel = configuration.isPlaceholder ? "Listening" : configuration.text
    accessibilityTraits = configuration.isListening
      ? [.staticText, .updatesFrequently]
      : .staticText
  }

  private func textAttributes(
    for configuration: Configuration,
    primaryColor: UIColor
  ) -> [NSAttributedString.Key: Any] {
    let styleKey = TextStyleKey(
      isPlaceholder: configuration.isPlaceholder,
      fontSize: configuration.fontSize,
      alignment: configuration.alignment,
      contentSizeCategory: configuration.contentSizeCategory
    )
    if cachedTextStyleKey == styleKey { return cachedTextAttributes }

    let baseFont = UIFont.systemFont(
      ofSize: configuration.fontSize,
      weight: configuration.isPlaceholder ? .medium : .regular
    )
    let compatibleTraits = UITraitCollection(
      preferredContentSizeCategory: configuration.contentSizeCategory
    )
    let scaledFont = UIFontMetrics(forTextStyle: .body).scaledFont(
      for: baseFont,
      maximumPointSize: configuration.fontSize * 1.65,
      compatibleWith: compatibleTraits
    )
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = configuration.alignment
    paragraphStyle.lineBreakMode = .byWordWrapping
    paragraphStyle.lineSpacing = configuration.fontSize >= 28 ? 4 : 2
    let defaultColor = configuration.isPlaceholder
      ? UIColor(red: 0.71, green: 0.76, blue: 0.81, alpha: 0.74)
      : primaryColor

    cachedTextStyleKey = styleKey
    cachedTextAttributes = [
      .font: scaledFont,
      .foregroundColor: defaultColor,
      .paragraphStyle: paragraphStyle,
    ]
    return cachedTextAttributes
  }

  private func dimTrailingToken(
    in renderedText: NSMutableAttributedString,
    text: String,
    primaryColor: UIColor
  ) {
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    let whitespace = CharacterSet.whitespacesAndNewlines
    let trimmedRange = nsText.rangeOfCharacter(
      from: whitespace.inverted,
      options: .backwards,
      range: fullRange
    )
    guard trimmedRange.location != NSNotFound else {
      renderedText.addAttribute(
        .foregroundColor,
        value: primaryColor.withAlphaComponent(0.7),
        range: fullRange
      )
      return
    }

    var tokenStart = trimmedRange.location
    while tokenStart > 0 {
      let previousRange = nsText.rangeOfComposedCharacterSequence(at: tokenStart - 1)
      let previousText = nsText.substring(with: previousRange)
      if previousText.rangeOfCharacter(from: whitespace) != nil { break }
      tokenStart = previousRange.location
    }

    let trailingRange = NSRange(
      location: tokenStart,
      length: fullRange.length - tokenStart
    )
    renderedText.addAttribute(
      .foregroundColor,
      value: primaryColor.withAlphaComponent(0.66),
      range: trailingRange
    )
  }
}

private struct VoiceMorphingPerimeterField: View {
  let sourceFrame: CGRect
  let progress: CGFloat
  let audioIntensity: CGFloat
  let reduceMotion: Bool
  let reduceTransparency: Bool

  var body: some View {
    GeometryReader { proxy in
      let amplitude = min(1, max(0, audioIntensity))
      let shape = VoiceMorphingRoundedRectangle(
        sourceFrame: sourceFrame,
        progress: progress
      )
      let gradient = AngularGradient(
        stops: [
          .init(color: Color(red: 0.28, green: 0.57, blue: 0.98), location: 0),
          .init(color: Color(red: 0.42, green: 0.49, blue: 0.84), location: 0.20),
          .init(color: Color(red: 1.0, green: 0.28, blue: 0.42), location: 0.45),
          .init(color: Color(red: 0.84, green: 0.39, blue: 0.69), location: 0.69),
          .init(color: Color(red: 0.36, green: 0.52, blue: 0.95), location: 0.88),
          .init(color: Color(red: 0.28, green: 0.57, blue: 0.98), location: 1),
        ],
        center: .center,
        angle: .degrees(-28)
      )

      ZStack {
        shape
          .fill(Color.black.opacity(reduceTransparency ? 1 : 0.995))

        shape
          .stroke(gradient, lineWidth: 3.5)
          .blur(radius: 0.8)
          .blendMode(.screen)

        shape
          .stroke(gradient, lineWidth: 18 + amplitude * 6)
          .blur(radius: 13)
          .opacity(0.52)
          .blendMode(.screen)

        shape
          .stroke(gradient, lineWidth: 32 + amplitude * 6)
          .blur(radius: 24)
          .opacity(0.22)
          .blendMode(.screen)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .animation(reduceMotion ? nil : PanelTheme.quick, value: amplitude)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Interpolates a single continuous path from the measured trigger border to
/// the physical display perimeter. Only `progress` is animated, so a new state
/// can retarget the in-flight morph instead of restarting a keyframe sequence.
private struct VoiceMorphingRoundedRectangle: Shape {
  let sourceFrame: CGRect
  var progress: CGFloat

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func path(in bounds: CGRect) -> Path {
    let t = min(1, max(0, progress))
    let destination = bounds.insetBy(dx: 3, dy: 3)
    let source = sanitizedSource(in: bounds).insetBy(dx: 0.5, dy: 0.5)
    let rect = CGRect(
      x: interpolate(source.minX, destination.minX, t),
      y: interpolate(source.minY, destination.minY, t),
      width: interpolate(source.width, destination.width, t),
      height: interpolate(source.height, destination.height, t)
    )
    let startRadius = min(source.width, source.height) / 2
    let endRadius = min(58, max(44, destination.width * 0.13))
    let radius = interpolate(startRadius, endRadius, t)
    return Path(
      roundedRect: rect,
      cornerSize: CGSize(width: radius, height: radius),
      style: .continuous
    )
  }

  private func sanitizedSource(in bounds: CGRect) -> CGRect {
    guard sourceFrame.width > 0,
          sourceFrame.height > 0,
          sourceFrame.intersects(bounds.insetBy(dx: -80, dy: -80))
    else {
      return CGRect(x: bounds.maxX - 84, y: bounds.maxY - 66, width: 58, height: 58)
    }
    return sourceFrame
  }

  private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
    start + (end - start) * progress
  }
}

private struct VoiceBottomParticleField: View {
  let intensity: CGFloat
  let isActive: Bool
  let reduceMotion: Bool

  private let colors = [
    Color.white,
    Color(red: 0.35, green: 0.78, blue: 1),
    Color(red: 0.72, green: 0.63, blue: 1),
  ]

  var body: some View {
    ZStack(alignment: .bottom) {
      Ellipse()
        .fill(
          RadialGradient(
            colors: [
              Color(red: 0.30, green: 0.56, blue: 1).opacity(0.26 + intensity * 0.12),
              Color(red: 0.48, green: 0.36, blue: 0.92).opacity(0.12),
              .clear,
            ],
            center: .center,
            startRadius: 0,
            endRadius: 240
          )
        )
        .frame(height: 150)
        .scaleEffect(x: 1.45, y: 1)
        .offset(y: 66)
        .blur(radius: 22)

      if !reduceMotion {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive)) { timeline in
          Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let normalizedIntensity = Double(intensity)
            for index in 0..<34 {
              let seedA = hash(index * 17 + 3)
              let seedB = hash(index * 31 + 11)
              let seedC = hash(index * 47 + 19)
              let lifetime = 1.4 + seedB * 1.4
              let progress = fractional(time / lifetime + seedA)
              let startY = size.height - CGFloat(seedC) * 82
              let travel = CGFloat(120 + seedB * Double(min(340, size.height * 0.42)))
              let drift = CGFloat(sin((progress + seedA) * .pi * 2) * (3 + seedC * 6))
              let x = size.width * (0.08 + CGFloat(seedA) * 0.84) + drift
              let y = startY - CGFloat(progress) * travel
              let baseSize: CGFloat = seedC > 0.95 ? 3.2 : (seedC > 0.80 ? 2.1 : 1.2)
              let fade = pow(max(0, 1 - progress), 1.75)
              let alpha = fade * (0.17 + seedB * 0.56) * (0.76 + normalizedIntensity * 0.48)
              let rect = CGRect(
                x: x - baseSize / 2,
                y: y - baseSize / 2,
                width: baseSize,
                height: baseSize
              )
              context.fill(
                Path(ellipseIn: rect),
                with: .color(colors[index % colors.count].opacity(alpha))
              )
            }
          }
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func hash(_ value: Int) -> Double {
    fractional(sin(Double(value) * 12.9898) * 43_758.5453)
  }

  private func fractional(_ value: Double) -> Double {
    value - floor(value)
  }
}

@MainActor
private final class MobileVoiceTranscriptState: ObservableObject {
  @Published private(set) var text = ""

  var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var displayText: String {
    isEmpty ? "listening..." : text
  }

  func update(_ newValue: String) {
    guard newValue != text else { return }
    text = newValue
  }
}

@MainActor
private final class MobileVoiceAgentSession: ObservableObject {
  @Published private(set) var phase: VoiceEntryPhase = .idle
  @Published private(set) var errorText: String?
  @Published private(set) var isVisible = false
  @Published private(set) var ownsPlusTouch = false
  @Published private(set) var handoffPrompt: String?
  @Published private(set) var effectOpacity: CGFloat = 1
  @Published private(set) var isEffectDismissing = false

  let transcriptState = MobileVoiceTranscriptState()
  let effectSignal = VoiceEdgeEffectSignal()

  private let recorder = MobileMeetingRecorder()
  private var machine = VoiceEntryInteractionStateMachine()
  private var silenceEndpointDetector = VoiceSilenceEndpointDetector()
  private var cancellables = Set<AnyCancellable>()
  private var startTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var emptyTranscriptCleanupTask: Task<Void, Never>?
  private var emptyTranscriptCleanupSessionID: VoiceEntrySessionID?
  private var effectDismissTask: Task<Void, Never>?
  private let launchHaptic = UIImpactFeedbackGenerator(style: .medium)

  init() {
    recorder.$transcript
      .removeDuplicates()
      .sink { [weak self] transcript in
        self?.receiveRecorderTranscript(transcript)
      }
      .store(in: &cancellables)

    recorder.$levels
      .sink { [weak self] levels in
        guard let self else { return }
        // Metering now bypasses ObservableObject entirely. The single Metal
        // render loop samples this scalar and applies its own attack/release,
        // so decorative audio cannot invalidate the retained app pages.
        let recent = levels.suffix(10)
        let average = recent.isEmpty
          ? 0
          : recent.reduce(CGFloat.zero, +) / CGFloat(recent.count)
        self.effectSignal.setTargetAudioLevel(average)
        self.receiveRecorderLevel(average)
      }
      .store(in: &cancellables)

    recorder.$errorMessage
      .compactMap { $0 }
      .sink { [weak self] message in
        guard let self, self.isVisible else { return }
        self.errorText = message
      }
      .store(in: &cancellables)
  }

  var showsStopControl: Bool {
    switch phase {
    case .requestingPermission(_, .latched),
         .starting(_, .latched),
         .listening(_, .latched, _):
      true
    case .idle,
         .pressing,
         .requestingPermission(_, .pressAndHold),
         .starting(_, .pressAndHold),
         .listening(_, .pressAndHold, _),
         .stopping,
         .handingOff,
         .failed:
      false
    }
  }

  var showsDismissControl: Bool {
    if case .failed = phase { return true }
    return false
  }

  var isFinishing: Bool {
    if case .stopping = phase { return true }
    return false
  }

  var isHandingOff: Bool {
    if case .handingOff = phase { return true }
    return false
  }

  var isListening: Bool {
    switch phase {
    case .requestingPermission, .starting, .listening, .stopping:
      true
    case .idle, .pressing, .handingOff, .failed:
      false
    }
  }

  var isEffectVisible: Bool {
    ownsPlusTouch || isVisible || isEffectDismissing
  }

  var transcript: String {
    get { transcriptState.text }
    set { transcriptState.update(newValue) }
  }

  /// Prime the causal launch feedback on touch-down so the committed morph and
  /// haptic land on the same frame instead of paying Taptic warm-up latency.
  func prepareLaunchFeedback() {
    launchHaptic.prepare()
  }

  func setPlusTouchActive(_ isActive: Bool) {
    if isActive {
      cancelEmptyTranscriptCleanup()
    }
    ownsPlusTouch = isActive
    if !isActive, !isVisible {
      dismissPrimedEffect()
      return
    }
    guard isActive, !isVisible else { return }
    effectDismissTask?.cancel()
    effectDismissTask = nil
    isEffectDismissing = false
    effectOpacity = 1
    synchronize(machine.pressBegan())
  }

  /// Returns true only for the uncommitted tap path that should open Create.
  func finishTap() -> Bool {
    guard !isVisible else { return false }
    let actions = machine.pressEnded()
    synchronizeState()
    return actions.contains(.openCreateMenu)
  }

  func recognizeHold() {
    guard !isVisible else { return }
    synchronize(machine.holdRecognized())
  }

  func releaseHold() {
    let wasHeldWithoutWords: Bool
    switch phase {
    case .requestingPermission(_, .pressAndHold),
         .starting(_, .pressAndHold),
         .listening(_, .pressAndHold, false):
      wasHeldWithoutWords = true
    default:
      wasHeldWithoutWords = false
    }

    synchronize(machine.pressEnded())
    if wasHeldWithoutWords, showsStopControl {
      UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.62)
    }
  }

  func beginFromMenu() {
    guard !isVisible else { return }
    cancelEmptyTranscriptCleanup()
    recorder.reset()
    prepareLaunchFeedback()
    synchronize(machine.beginVoiceChatFromMenu())
  }

  func stopAndSubmit() {
    if case .failed = phase {
      abandon()
      return
    }
    silenceEndpointDetector.reset()
    UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.62)
    synchronize(machine.stopTapped())
  }

  func abandon() {
    let shouldFadeEffect = isEffectVisible
    startTask?.cancel()
    stopTask?.cancel()
    cancelEmptyTranscriptCleanup()
    effectDismissTask?.cancel()
    startTask = nil
    stopTask = nil
    effectDismissTask = nil
    silenceEndpointDetector.reset()
    synchronize(machine.abandon())
    recorder.reset()
    transcript = ""
    effectSignal.setTargetAudioLevel(0)
    errorText = nil
    handoffPrompt = nil
    isVisible = false
    ownsPlusTouch = false
    if shouldFadeEffect {
      dismissPrimedEffect()
    } else {
      isEffectDismissing = false
      effectOpacity = 1
    }
  }

  func chatDidPresent() {
    guard handoffPrompt != nil else { return }
    silenceEndpointDetector.reset()
    isVisible = false
    recorder.reset()
    effectSignal.setTargetAudioLevel(0)
  }

  func chatDidDismiss() {
    cancelEmptyTranscriptCleanup()
    silenceEndpointDetector.reset()
    _ = machine.abandon()
    synchronizeState()
    handoffPrompt = nil
    transcript = ""
    errorText = nil
    isVisible = false
  }

  private func synchronize(_ actions: [VoiceEntryAction]) {
    synchronizeState()
    for action in actions {
      perform(action)
    }
  }

  private func synchronizeState() {
    if phase != machine.phase {
      phase = machine.phase
    }
    transcript = machine.transcript
  }

  private func perform(_ action: VoiceEntryAction) {
    switch action {
    case .openCreateMenu:
      break

    case .presentVoiceOverlay:
      cancelEmptyTranscriptCleanup()
      silenceEndpointDetector.reset()
      errorText = nil
      transcript = ""
      effectSignal.setTargetAudioLevel(0.18)
      handoffPrompt = nil
      effectDismissTask?.cancel()
      effectDismissTask = nil
      isEffectDismissing = false
      effectOpacity = 1
      isVisible = true
      launchHaptic.impactOccurred(intensity: 0.82)
      UIAccessibility.post(notification: .announcement, argument: "Listening")

    case .requestPermission(let sessionID):
      startCapture(sessionID: sessionID)

    case .startListening:
      // `MobileMeetingRecorder.start()` requests permission and starts the
      // selected on-device engine as one atomic operation. The coordinator
      // acknowledges this action after that operation succeeds.
      break

    case .stopListening(let sessionID):
      silenceEndpointDetector.reset()
      finishCapture(sessionID: sessionID)

    case .cancelSession:
      startTask?.cancel()
      stopTask?.cancel()
      cancelEmptyTranscriptCleanup()
      silenceEndpointDetector.reset()
      recorder.reset()
      transcript = ""
      effectSignal.setTargetAudioLevel(0)
      errorText = nil
      handoffPrompt = nil
      isVisible = false
      ownsPlusTouch = false
      isEffectDismissing = false
      effectOpacity = 1

    case .handOff(_, let transcript):
      beginHandoff(transcript: transcript)
    }
  }

  private func startCapture(sessionID: VoiceEntrySessionID) {
    startTask?.cancel()
    startTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let started = await self.recorder.start()
      guard !Task.isCancelled, self.machine.currentSessionID == sessionID else {
        if started { self.recorder.reset() }
        return
      }

      if started {
        _ = self.machine.resolvePermission(sessionID: sessionID, granted: true)
        _ = self.machine.listeningStarted(sessionID: sessionID)
        self.errorText = nil
        self.synchronizeState()
      } else {
        let message = self.recorder.errorMessage ?? "Voice recognition could not start."
        let isPermissionFailure = message.localizedCaseInsensitiveContains("permission")
        if isPermissionFailure {
          _ = self.machine.resolvePermission(sessionID: sessionID, granted: false)
        } else {
          _ = self.machine.resolvePermission(sessionID: sessionID, granted: true)
          _ = self.machine.listeningStartFailed(sessionID: sessionID)
        }
        self.errorText = message
        self.synchronizeState()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        UIAccessibility.post(notification: .announcement, argument: message)
      }
      self.startTask = nil
    }
  }

  private func finishCapture(sessionID: VoiceEntrySessionID) {
    guard stopTask == nil else { return }
    stopTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let finalTranscript = await self.recorder.stop()
      guard !Task.isCancelled, self.machine.currentSessionID == sessionID else { return }

      _ = self.machine.receiveTranscript(
        sessionID: sessionID,
        transcript: finalTranscript
      )
      let actions = self.machine.transcriptionFinished(
        sessionID: sessionID,
        finalTranscript: finalTranscript
      )
      self.synchronizeState()
      self.stopTask = nil

      if actions.isEmpty {
        self.recorder.reset()
        self.errorText = "I didn’t catch that."
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        self.scheduleEmptyTranscriptCleanup(sessionID: sessionID)
        return
      }

      self.recorder.reset()
      for action in actions { self.perform(action) }
    }
  }

  private func beginHandoff(transcript: String) {
    cancelEmptyTranscriptCleanup()
    errorText = nil
    UIAccessibility.post(
      notification: .announcement,
      argument: "Sending: \(transcript)"
    )
    guard isHandingOff else { return }
    // Publish immediately so Ask iAgent can begin loading and submitting while
    // the retained voice surface crossfades behind its opaque root.
    handoffPrompt = transcript
  }

  private func scheduleEmptyTranscriptCleanup(sessionID: VoiceEntrySessionID) {
    cancelEmptyTranscriptCleanup()
    emptyTranscriptCleanupSessionID = sessionID
    emptyTranscriptCleanupTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(900))
      guard let self,
            !Task.isCancelled,
            self.emptyTranscriptCleanupSessionID == sessionID,
            self.machine.phase == .idle,
            self.handoffPrompt == nil
      else { return }

      self.emptyTranscriptCleanupTask = nil
      self.emptyTranscriptCleanupSessionID = nil
      self.abandon()
    }
  }

  private func cancelEmptyTranscriptCleanup() {
    emptyTranscriptCleanupTask?.cancel()
    emptyTranscriptCleanupTask = nil
    emptyTranscriptCleanupSessionID = nil
  }

  private func receiveRecorderTranscript(_ transcript: String) {
    guard let sessionID = machine.currentSessionID else { return }
    _ = machine.receiveTranscript(sessionID: sessionID, transcript: transcript)
    synchronizeState()
    silenceEndpointDetector.observeTranscript(
      phase: machine.phase,
      transcript: machine.transcript,
      now: ProcessInfo.processInfo.systemUptime
    )
  }

  private func receiveRecorderLevel(_ level: CGFloat) {
    guard let endpoint = silenceEndpointDetector.observeLevel(
      phase: machine.phase,
      transcript: machine.transcript,
      level: Double(level),
      now: ProcessInfo.processInfo.systemUptime
    ), endpoint.sessionID == machine.currentSessionID,
      endpoint.transcript == machine.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return }

    // Feed the endpoint through the same idempotent transition as the visible Stop control.
    // This preserves recorder finalization and exact-once handoff behavior without a second timer.
    synchronize(machine.stopTapped())
  }

  private func dismissPrimedEffect() {
    effectDismissTask?.cancel()
    isEffectDismissing = true
    effectOpacity = 0
    effectDismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(180))
      guard let self, !Task.isCancelled, !self.isVisible, !self.ownsPlusTouch else { return }
      self.isEffectDismissing = false
      self.effectOpacity = 1
      self.effectDismissTask = nil
    }
  }
}

private struct MobileSyncStatusView: View {
  @ObservedObject var model: MobileAppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack(alignment: .top, spacing: 14) {
            Image(systemName: statusSymbol)
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(statusColor)
              .frame(width: 42, height: 42)
              .background(PanelTheme.surface, in: Circle())

            VStack(alignment: .leading, spacing: 5) {
              Text(model.syncHealthTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(PanelTheme.primary)
              Text(model.syncHealthDetail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PanelTheme.secondary)
                .lineSpacing(3)
            }
          }

          VStack(spacing: 0) {
            detailRow(
              label: "Last successful sync",
              value: model.lastSuccessfulSyncAt?.formatted(date: .abbreviated, time: .shortened)
                ?? "Never"
            )
            JoiDottedDivider(inset: 16)
            detailRow(label: "Pending changes", value: "\(model.syncPendingCount)")
            JoiDottedDivider(inset: 16)
            detailRow(label: "CloudKit environment", value: model.syncEnvironmentName)
            JoiDottedDivider(inset: 16)
            detailRow(label: "Mac", value: macFreshness)
            JoiDottedDivider(inset: 16)
            detailRow(
              label: "Synced records",
              value: "\(model.snapshot.calendarEvents.count) events · \(model.snapshot.codexThreads.count) Codex · \(model.snapshot.todos.count) todos"
            )
          }
          .background(
            PanelTheme.surface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
          )

          if !model.hasDesktopSnapshot {
            Label(
              "Keep iAgent open on your Mac and verify both devices use the same iCloud account.",
              systemImage: "desktopcomputer.trianglebadge.exclamationmark"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PanelTheme.secondary)
          } else if !model.isDesktopSnapshotFresh {
            Label(
              "The latest Mac snapshot is stale. Open iAgent on the Mac to publish a fresh snapshot.",
              systemImage: "clock.badge.exclamationmark"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PanelTheme.amber)
          }

          Button {
            Task { await model.refresh() }
          } label: {
            HStack(spacing: 9) {
              if model.syncStatus.phase == .syncing {
                ProgressView()
                  .tint(.black)
              } else {
                Image(systemName: "arrow.triangle.2.circlepath")
              }
              Text(model.syncStatus.phase == .syncing ? "Syncing" : "Sync now")
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(PanelTheme.primary, in: Capsule())
          }
          .buttonStyle(.plain)
          .disabled(model.syncStatus.phase == .syncing)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
      .scrollIndicators(.hidden)
      .background(PanelTheme.sheet)
      .navigationTitle("Sync details")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
            .fontWeight(.semibold)
        }
      }
    }
    .tint(PanelTheme.primary)
    .accessibilityIdentifier("sync-details-sheet")
  }

  private func detailRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      Text(label)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
      Spacer(minLength: 8)
      Text(value)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(PanelTheme.primary)
        .multilineTextAlignment(.trailing)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 48)
  }

  private var macFreshness: String {
    guard let desktop = model.snapshot.desktopSnapshot else { return "Not seen" }
    return model.isDesktopSnapshotFresh
      ? "\(desktop.deviceName) · live"
      : "\(desktop.deviceName) · \(desktop.freshnessDate.compactRelative())"
  }

  private var statusSymbol: String {
    switch model.syncStatus.phase {
    case .idle:
      model.syncPendingCount > 0 ? "icloud.and.arrow.up" : "checkmark.icloud"
    case .syncing: "arrow.triangle.2.circlepath.icloud"
    case .offline: "icloud.slash"
    case .accountUnavailable: "person.crop.circle.badge.exclamationmark"
    case .failed: "exclamationmark.icloud"
    }
  }

  private var statusColor: Color {
    switch model.syncStatus.phase {
    case .idle: model.syncPendingCount > 0 ? PanelTheme.amber : PanelTheme.green
    case .syncing: PanelTheme.blue
    case .offline: PanelTheme.secondary
    case .accountUnavailable, .failed: PanelTheme.coral
    }
  }
}

private extension MobileAppModel.Tab {
  var accessibilityLabel: String {
    switch self {
    case .today: "Today"
    case .codex: "Codex"
    case .notes: "Notes"
    case .todos: "Todos"
    }
  }

  var dockSymbol: String {
    switch self {
    case .today: "house"
    case .codex: "sparkles"
    case .notes: "note.text"
    case .todos: "checkmark.square"
    }
  }
}
