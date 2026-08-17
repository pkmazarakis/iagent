import SwiftUI
import UIKit
import iAgentCore

struct TodoCreationView: View {
  @ObservedObject var model: MobileAppModel
  let todoID: UUID?

  @Environment(\.dismiss) private var dismiss
  @FocusState private var isTitleFocused: Bool

  @State private var title = ""
  @State private var notes = ""
  @State private var selectedCalendar: String?
  @State private var selectedDate = Date()
  @State private var selectedTime = Date.roundedUpToFiveMinutes()
  @State private var isBodyFocused = false
  @State private var markdownRequest: TodoMarkdownRequest?
  @State private var activeMarkdownCommands = Set<TodoMarkdownCommand>()
  @State private var activeSheet: TodoMetadataSheet?
  @State private var isSaving = false
  @State private var saveError: String?
  @State private var didConfigure = false
  @State private var persistedTitle = ""
  @State private var persistedNotes = ""

  private let arguments = ProcessInfo.processInfo.arguments

  init(model: MobileAppModel, todoID: UUID? = nil) {
    self.model = model
    self.todoID = todoID
  }

  var body: some View {
    ZStack(alignment: .top) {
      PanelTheme.canvas.ignoresSafeArea()

      editorSurface

      VStack(spacing: 0) {
        header
          .padding(.horizontal, 24)
          .padding(.top, 23)

        VStack(alignment: .leading, spacing: 13) {
          TextField("Todo title", text: $title)
            .focused($isTitleFocused)
            .defaultFocus($isTitleFocused, todoID == nil)
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(PanelTheme.primary)
            .tint(PanelTheme.coral)
            .textInputAutocapitalization(.sentences)
            .lineLimit(1)
            .submitLabel(.next)
            .onSubmit(focusDetailsEditor)
            .accessibilityIdentifier(todoID == nil ? "todo-composer-title" : "todo-detail-title")
            .accessibilityHint("Press Return to move to Write something")

          if let todoID, let todo = model.todo(id: todoID) {
            editingMetadata(for: todo)
          }

          ZStack(alignment: .topLeading) {
            if notes.isEmpty {
              Text("Write something…")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(PanelTheme.tertiary)
                .allowsHitTesting(false)
            }

            TodoMarkdownTextView(
              text: $notes,
              isFocused: $isBodyFocused,
              request: markdownRequest,
              activeCommands: $activeMarkdownCommands,
              accessibilityIdentifier: todoID == nil
                ? "todo-composer-editor"
                : "todo-detail-markdown-editor"
            )
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 31)
        .padding(.top, 35)
        .padding(.bottom, 18)
      }
    }
    .foregroundStyle(PanelTheme.primary)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      keyboardDock
    }
    .overlay { metadataOverlay }
    .alert(todoID == nil ? "Couldn’t create todo" : "Couldn’t save todo", isPresented: saveErrorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(saveError ?? "Please try again.")
    }
    .accessibilityIdentifier(todoID == nil ? "todo-composer" : "todo-detail-editor")
    .onAppear(perform: configureForLaunch)
    .onDisappear(perform: persistEditingDraftOnExit)
  }

  @ViewBuilder
  private var editorSurface: some View {
    if todoID == nil {
      RoundedRectangle(cornerRadius: 42, style: .continuous)
        .fill(PanelTheme.sheet)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .ignoresSafeArea(edges: .bottom)
    } else {
      UnevenRoundedRectangle(
        topLeadingRadius: 42,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: 42,
        style: .continuous
      )
      .fill(PanelTheme.sheet)
      .padding(.top, 8)
      .ignoresSafeArea(edges: .bottom)
    }
  }

  private var header: some View {
    HStack {
      circleButton(
        symbol: "xmark",
        accessibilityLabel: "Close",
        action: close
      )

      Spacer()

      HStack(spacing: 8) {
        Image(systemName: "checkmark.square")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(PanelTheme.coral)
        Text(todoID == nil ? "Todo" : "Edit todo")
          .font(.system(size: 16, weight: .semibold))
      }
      .padding(.horizontal, 16)
      .frame(height: 44)
      .background(PanelTheme.raisedSurface, in: Capsule())

      Spacer()

      Button(action: save) {
        Group {
          if isSaving {
            ProgressView()
              .tint(canSave ? .black : PanelTheme.tertiary)
          } else {
            Image(systemName: "arrow.up")
              .font(.system(size: 18, weight: .bold))
          }
        }
        .foregroundStyle(canSave ? .black : PanelTheme.tertiary)
        .frame(width: 48, height: 48)
        .background(canSave ? PanelTheme.primary : PanelTheme.raisedSurface, in: Circle())
      }
      .buttonStyle(.plain)
      .disabled(!canSave || isSaving)
      .accessibilityIdentifier("todo-composer-save")
      .accessibilityLabel(todoID == nil ? "Create todo" : "Save todo changes")
    }
  }

  private var keyboardDock: some View {
    VStack(spacing: 8) {
      if todoID == nil {
        metadataBar
      }
      markdownBar
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 9)
  }

  private var metadataBar: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        metadataButton(
          symbol: selectedCalendar == nil ? "calendar.badge.minus" : "calendar.badge.checkmark",
          title: selectedCalendar ?? "None",
          identifier: "todo-calendar-button",
          action: { present(.calendar) }
        )

        metadataButton(
          symbol: "calendar",
          title: dateLabel,
          identifier: "todo-date-button",
          action: { present(.date) }
        )

        metadataButton(
          symbol: "clock.fill",
          title: selectedTime.formatted(date: .omitted, time: .shortened),
          identifier: "todo-time-button",
          action: { present(.time) }
        )
      }
    }
    .scrollIndicators(.hidden)
  }

  private var markdownBar: some View {
    TodoMarkdownToolbar(
      activeCommands: $activeMarkdownCommands,
      onCommand: applyMarkdownCommand
    )
  }

  @ViewBuilder
  private func metadataSheet(_ sheet: TodoMetadataSheet) -> some View {
    switch sheet {
    case .calendar:
      TodoCalendarPicker(
        calendarNames: model.availableTodoCalendars,
        selection: $selectedCalendar,
        onDone: dismissMetadataSheet
      )

    case .date:
      TodoDatePicker(
        selection: $selectedDate,
        onDone: dismissMetadataSheet
      )

    case .time:
      TodoTimePicker(selection: $selectedTime, onDone: dismissMetadataSheet)
    }
  }

  private var metadataOverlay: some View {
    ZStack(alignment: .bottom) {
      if let activeSheet {
        Color.black.opacity(0.56)
          .contentShape(Rectangle())
          .onTapGesture { dismissMetadataSheet() }
          .transition(.opacity)

        metadataSheet(activeSheet)
          .id(activeSheet.id)
          .frame(maxWidth: .infinity)
          .frame(height: metadataSheetHeight(activeSheet))
          .background(PanelTheme.sheetRaised)
          .clipShape(
            UnevenRoundedRectangle(
              topLeadingRadius: 36,
              bottomLeadingRadius: 0,
              bottomTrailingRadius: 0,
              topTrailingRadius: 36,
              style: .continuous
            )
          )
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .ignoresSafeArea()
    .allowsHitTesting(activeSheet != nil)
    .zIndex(10)
    .accessibilityAddTraits(activeSheet == nil ? [] : .isModal)
  }

  private func metadataSheetHeight(_ sheet: TodoMetadataSheet) -> CGFloat {
    switch sheet {
    case .calendar: calendarSheetHeight
    case .date: 438
    case .time: 468
    }
  }

  private func dismissMetadataSheet() {
    withAnimation(metadataSheetAnimation) { activeSheet = nil }
  }

  private var metadataSheetAnimation: Animation {
    .timingCurve(0.165, 0.84, 0.44, 1, duration: 0.2)
  }

  private func metadataButton(
    symbol: String,
    title: String,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Image(systemName: symbol)
          .font(.system(size: 14, weight: .semibold))
        Text(title)
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(1)
      }
      .foregroundStyle(PanelTheme.secondary)
      .padding(.horizontal, 14)
      .frame(height: 42)
      .background(PanelTheme.raisedSurface, in: Capsule())
      .overlay {
        Capsule().stroke(PanelTheme.border, lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }

  private func applyMarkdownCommand(_ command: TodoMarkdownCommand) {
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

  private func circleButton(
    symbol: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(PanelTheme.primary)
        .frame(width: 48, height: 48)
        .background(PanelTheme.raisedSurface, in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }

  private func editingMetadata(for todo: SyncedTodo) -> some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        Button {
          Task { await model.toggleTodo(id: todo.id) }
        } label: {
          Label(
            todo.isCompleted ? "Completed" : "Mark complete",
            systemImage: todo.isCompleted ? "checkmark.square.fill" : "square"
          )
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(todo.isCompleted ? PanelTheme.green : PanelTheme.primary)
          .padding(.horizontal, 13)
          .frame(height: 38)
          .background(PanelTheme.surface, in: Capsule())
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(todo.isCompleted ? "Reopen \(todo.title)" : "Complete \(todo.title)")
        .accessibilityValue(todo.isCompleted ? "Checked" : "Unchecked")
        .accessibilityIdentifier("todo-detail-completion")

        if let listName = todo.listName {
          editingBadge(symbol: "tray.full", text: listName)
        }
        if let dueDate = todo.dueDate {
          editingBadge(
            symbol: "calendar",
            text: dueDate.formatted(date: .abbreviated, time: .shortened)
          )
        }
      }
    }
    .scrollIndicators(.hidden)
    .accessibilityElement(children: .contain)
  }

  private func editingBadge(symbol: String, text: String) -> some View {
    Label(text, systemImage: symbol)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(PanelTheme.secondary)
      .padding(.horizontal, 13)
      .frame(height: 38)
      .background(PanelTheme.surface, in: Capsule())
  }

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var dateLabel: String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(selectedDate) { return "Today" }
    if calendar.isDateInTomorrow(selectedDate) { return "Tomorrow" }
    return selectedDate.formatted(.dateTime.month(.abbreviated).day())
  }

  private var calendarSheetHeight: CGFloat {
    min(510, max(240, CGFloat(model.availableTodoCalendars.count + 1) * 52 + 96))
  }

  private var saveErrorBinding: Binding<Bool> {
    Binding(
      get: { saveError != nil },
      set: { if !$0 { saveError = nil } }
    )
  }

  private func present(_ sheet: TodoMetadataSheet) {
    isTitleFocused = false
    isBodyFocused = false
    withAnimation(metadataSheetAnimation) {
      activeSheet = sheet
    }
  }

  private func focusDetailsEditor() {
    isTitleFocused = false
    // Moving first-responder ownership between SwiftUI and UIKit in one update
    // can leave hardware Return on the title. Hand the editor focus on the next
    // main-loop turn so both software and hardware keyboards follow `.next`.
    DispatchQueue.main.async {
      isBodyFocused = true
    }
  }

  private func close() {
    guard todoID != nil, hasUnsavedEditingDraft else {
      dismiss()
      return
    }
    save()
  }

  private func save() {
    guard canSave, !isSaving else { return }
    isSaving = true
    let dueDate = combinedDueDate

    Task {
      let saved: Bool
      if let todoID {
        saved = await model.updateTodo(id: todoID, title: title, notes: notes)
      } else {
        saved = await model.createTodo(
          title: title,
          notes: notes,
          listName: selectedCalendar,
          dueDate: dueDate
        )
      }
      isSaving = false
      if saved {
        persistedTitle = title
        persistedNotes = notes
        dismiss()
      } else {
        saveError = todoID == nil
          ? "Your todo stayed on this screen. Check sync and try again."
          : "Your changes stayed on this screen. Check sync and try again."
      }
    }
  }

  private var combinedDueDate: Date {
    let calendar = Calendar.autoupdatingCurrent
    let time = calendar.dateComponents([.hour, .minute], from: selectedTime)
    return calendar.date(
      bySettingHour: time.hour ?? 0,
      minute: time.minute ?? 0,
      second: 0,
      of: selectedDate
    ) ?? selectedDate
  }

  private func configureForLaunch() {
    guard !didConfigure else { return }
    didConfigure = true

    if let todoID, let todo = model.todo(id: todoID) {
      title = todo.title
      notes = todo.notes ?? ""
      persistedTitle = todo.title
      persistedNotes = todo.notes ?? ""
      selectedCalendar = todo.listName
      if let dueDate = todo.dueDate {
        selectedDate = dueDate
        selectedTime = dueDate
      }
    }

    if todoID == nil, arguments.contains("--todo-create-fixture") {
      title = "Review launch checklist"
      notes = "Confirm the release notes and assign owners."
    }

    let requestedSheet: TodoMetadataSheet?
    if arguments.contains("--todo-create-calendar-picker") {
      requestedSheet = .calendar
    } else if arguments.contains("--todo-create-date-picker") {
      requestedSheet = .date
    } else if arguments.contains("--todo-create-time-picker") {
      requestedSheet = .time
    } else {
      requestedSheet = nil
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      if let requestedSheet {
        activeSheet = requestedSheet
      } else if arguments.contains("--todo-bold-active-fixture") {
        isTitleFocused = false
        isBodyFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
          activeMarkdownCommands.insert(.bold)
          markdownRequest = TodoMarkdownRequest(command: .bold)
          if arguments.contains("--todo-bold-toggle-off-fixture") {
            // Leave enough time for the representable to consume the first
            // request; launch-time keyboard animation can otherwise coalesce
            // the two QA state updates into a single command.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
              activeMarkdownCommands.remove(.bold)
              markdownRequest = TodoMarkdownRequest(command: .bold)
            }
          }
        }
      } else if todoID == nil {
        isTitleFocused = true
      }
    }
  }

  private var hasUnsavedEditingDraft: Bool {
    guard todoID != nil else { return false }
    return title != persistedTitle || notes != persistedNotes
  }

  private func persistEditingDraftOnExit() {
    guard let todoID,
          !isSaving,
          hasUnsavedEditingDraft,
          canSave
    else { return }

    let exitingTitle = title
    let exitingNotes = notes
    Task {
      _ = await model.updateTodo(id: todoID, title: exitingTitle, notes: exitingNotes)
    }
  }
}

struct TodoDetailView: View {
  @ObservedObject var model: MobileAppModel
  let todoID: UUID

  var body: some View {
    TodoCreationView(model: model, todoID: todoID)
    .toolbar(.hidden, for: .navigationBar)
    .accessibilityIdentifier("todo-detail")
  }
}

private enum TodoMetadataSheet: String, Identifiable {
  case calendar
  case date
  case time

  var id: String { rawValue }
}

private struct TodoCalendarPicker: View {
  let calendarNames: [String]
  @Binding var selection: String?
  let onDone: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader(title: "Calendar", onDone: onDone)

      ScrollView {
        LazyVStack(spacing: 0) {
          calendarRow(name: nil, index: 0)
          ForEach(Array(calendarNames.enumerated()), id: \.element) { index, name in
            Rectangle()
              .fill(PanelTheme.border)
              .frame(height: 1)
              .padding(.leading, 54)
            calendarRow(name: name, index: index + 1)
          }
        }
        .padding(.horizontal, 16)
      }
      .scrollIndicators(.hidden)
    }
    .background(PanelTheme.sheetRaised)
    .accessibilityIdentifier("todo-calendar-picker")
  }

  private func calendarRow(name: String?, index: Int) -> some View {
    Button {
      selection = name
      onDone()
    } label: {
      HStack(spacing: 13) {
        Circle()
          .fill(name == nil ? PanelTheme.tertiary : calendarColor(index))
          .frame(width: 12, height: 12)

        Text(name ?? "None")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(PanelTheme.primary)

        Spacer()

        if selection == name {
          Image(systemName: "checkmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(PanelTheme.coral)
        }
      }
      .frame(height: 51)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func calendarColor(_ index: Int) -> Color {
    let colors = [PanelTheme.coral, PanelTheme.blue, PanelTheme.green, PanelTheme.sun, PanelTheme.violet]
    return colors[index % colors.count]
  }
}

private struct TodoDatePicker: View {
  @Binding var selection: Date
  let onDone: () -> Void

  @State private var displayedMonth: Date
  @State private var monthDirection = 1
  private let calendar = Calendar.autoupdatingCurrent

  init(selection: Binding<Date>, onDone: @escaping () -> Void) {
    _selection = selection
    self.onDone = onDone
    _displayedMonth = State(initialValue: Self.startOfMonth(containing: selection.wrappedValue))
  }

  var body: some View {
    VStack(spacing: 18) {
      HStack(spacing: 10) {
        Text(displayedMonth.formatted(.dateTime.month(.abbreviated).year()))
          .font(.system(size: 24, weight: .bold))
          .contentTransition(.opacity)

        Spacer()

        monthButton(symbol: "chevron.left") { changeMonth(by: -1) }

        Button {
          let today = Date()
          let todayMonth = Self.startOfMonth(containing: today)
          monthDirection = todayMonth >= displayedMonth ? 1 : -1
          withAnimation(.timingCurve(0.22, 0.8, 0.24, 1, duration: 0.32)) {
            displayedMonth = todayMonth
          }
          selection = today
        } label: {
          Text("Today")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(PanelTheme.primary)
            .padding(.horizontal, 17)
            .frame(height: 40)
            .background(PanelTheme.raisedSurface, in: Capsule())
        }
        .buttonStyle(.plain)

        monthButton(symbol: "chevron.right") { changeMonth(by: 1) }
      }

      ZStack {
        monthGrid(for: displayedMonth)
          .id(monthID(displayedMonth))
          .transition(monthTransition)
      }
      .clipped()
      .contentShape(Rectangle())
      .gesture(monthSwipe)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 25)
    .padding(.top, 25)
    .padding(.bottom, 20)
    .background(PanelTheme.sheetRaised)
    .foregroundStyle(PanelTheme.primary)
    .accessibilityIdentifier("todo-date-picker")
  }

  private var columns: [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
  }

  private var weekdaySymbols: [String] {
    let symbols = calendar.veryShortStandaloneWeekdaySymbols
    let offset = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
    return Array(symbols[offset...] + symbols[..<offset])
  }

  private func monthDays(for month: Date) -> [Date?] {
    let start = Self.startOfMonth(containing: month)
    let weekday = calendar.component(.weekday, from: start)
    let leading = (weekday - calendar.firstWeekday + 7) % 7
    guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
    let dates = range.compactMap { day in
      calendar.date(byAdding: .day, value: day - 1, to: start)
    }
    let populated = Array(repeating: nil, count: leading) + dates.map(Optional.some)
    return populated + Array(repeating: nil, count: max(0, 42 - populated.count))
  }

  private func monthButton(symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(PanelTheme.secondary)
        .frame(width: 40, height: 40)
        .background(PanelTheme.raisedSurface, in: Circle())
    }
    .buttonStyle(.plain)
  }

  private func changeMonth(by offset: Int) {
    guard let next = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
    monthDirection = offset >= 0 ? 1 : -1
    withAnimation(.timingCurve(0.22, 0.8, 0.24, 1, duration: 0.32)) {
      displayedMonth = Self.startOfMonth(containing: next)
    }
  }

  private func monthGrid(for month: Date) -> some View {
    LazyVGrid(columns: columns, spacing: 7) {
      ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
        Text(symbol)
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(PanelTheme.tertiary)
          .frame(height: 24)
      }

      ForEach(Array(monthDays(for: month).enumerated()), id: \.offset) { _, date in
        if let date {
          Button {
            selection = date
            onDone()
          } label: {
            Text("\(calendar.component(.day, from: date))")
              .font(.system(size: 16, weight: isSelected(date) ? .bold : .medium))
              .foregroundStyle(isSelected(date) ? .black : PanelTheme.primary)
              .frame(width: 38, height: 38)
              .background(isSelected(date) ? PanelTheme.coral : Color.clear, in: Circle())
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
          .accessibilityAddTraits(isSelected(date) ? .isSelected : [])
        } else {
          Color.clear.frame(width: 38, height: 38)
        }
      }
    }
  }

  private var monthTransition: AnyTransition {
    let insertionEdge: Edge = monthDirection > 0 ? .trailing : .leading
    let removalEdge: Edge = monthDirection > 0 ? .leading : .trailing
    return .asymmetric(
      insertion: .move(edge: insertionEdge).combined(with: .opacity),
      removal: .move(edge: removalEdge).combined(with: .opacity)
    )
  }

  private var monthSwipe: some Gesture {
    DragGesture(minimumDistance: 18)
      .onEnded { value in
        guard abs(value.translation.width) > abs(value.translation.height),
              abs(value.translation.width) > 38
        else { return }
        changeMonth(by: value.translation.width < 0 ? 1 : -1)
      }
  }

  private func monthID(_ month: Date) -> String {
    let components = calendar.dateComponents([.year, .month], from: month)
    return "\(components.year ?? 0)-\(components.month ?? 0)"
  }

  private func isSelected(_ date: Date) -> Bool {
    calendar.isDate(date, inSameDayAs: selection)
  }

  private static func startOfMonth(containing date: Date) -> Date {
    let calendar = Calendar.autoupdatingCurrent
    let components = calendar.dateComponents([.year, .month], from: date)
    return calendar.date(from: components) ?? calendar.startOfDay(for: date)
  }
}

private struct TodoTimePicker: View {
  @Binding var selection: Date
  let onDone: () -> Void

  @State private var flowDirection: CGFloat = 1
  @State private var feedbackTrigger = 0
  @State private var dragStartDate: Date?
  @State private var lastDragX: CGFloat = 0
  @State private var lastDragTime: Date?
  @State private var accumulatedMinutes: CGFloat = 0
  @State private var appliedMinutes = 0
  @State private var rulerPhase: CGFloat = 0
  @State private var scrubVelocity: CGFloat = 0

  var body: some View {
    GeometryReader { pickerProxy in
      VStack(spacing: 0) {
        Spacer(minLength: 74)

        Text("Start time")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(PanelTheme.secondary)

        MobileNumberFlowText(
          timeText,
          fontSize: 72,
          weight: .medium,
          color: PanelTheme.primary,
          direction: flowDirection,
          lineHeight: 98
        )
        .padding(.top, 4)
        .accessibilityIdentifier("todo-time-value")
        .accessibilityAdjustableAction { direction in
          switch direction {
          case .increment: shiftTime(by: 5)
          case .decrement: shiftTime(by: -5)
          @unknown default: break
          }
        }

        Spacer(minLength: 44)

        TodoTimeRuler(
          phase: rulerPhase,
          velocity: scrubVelocity
        )
        .frame(height: 68)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .highPriorityGesture(
        timeDrag(width: max(1, pickerProxy.size.width)),
        including: .all
      )
      .background(PanelTheme.sheetRaised)
      .overlay(alignment: .topTrailing) {
        Button(action: onDone) {
          Image(systemName: "xmark")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(PanelTheme.secondary)
            .frame(width: 36, height: 36)
            .background(PanelTheme.raisedSurface, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(20)
        .accessibilityLabel("Close time picker")
      }
    }
    .sensoryFeedback(.selection, trigger: feedbackTrigger)
    .accessibilityIdentifier("todo-time-picker")
    .accessibilityHint("Swipe left or right anywhere. A full slow swipe changes the time by three hours")
  }

  private var timeText: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: selection)
  }

  private func timeDrag(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { value in
        guard abs(value.translation.width) > abs(value.translation.height) else { return }

        let isFirstSample = dragStartDate == nil
        let startDate = dragStartDate ?? selection
        let previousX = isFirstSample ? 0 : lastDragX
        let previousTime = lastDragTime

        if isFirstSample {
          dragStartDate = startDate
          accumulatedMinutes = 0
          appliedMinutes = 0
        }

        // A very fast swipe can arrive as a single changed sample followed by
        // `onEnded`. Count that first sample from the gesture origin instead of
        // using it only to initialize state, or the whole swipe appears inert.
        let deltaX = value.translation.width - previousX
        let elapsed = previousTime.map {
          max(1.0 / 120.0, value.time.timeIntervalSince($0))
        }
        let velocity = elapsed.map { deltaX / CGFloat($0) } ?? 0
        let speed = min(1, max(0, (abs(velocity) - 250) / 1_150))
        let smoothSpeed = speed * speed * (3 - 2 * speed)
        let gain = 1 + 1.6 * smoothSpeed
        accumulatedMinutes += deltaX * (180 / width) * gain
        scrubVelocity = velocity
        rulerPhase = accumulatedMinutes / 5

        applyScrubbedTime(from: startDate, minutes: snappedMinutes(accumulatedMinutes))
        lastDragX = value.translation.width
        lastDragTime = value.time
      }
      .onEnded { value in
        guard abs(value.translation.width) > abs(value.translation.height) else {
          resetDragState()
          return
        }

        let startDate = dragStartDate ?? selection
        // Some very fast touch sequences proceed from recognition straight to
        // `onEnded` without publishing an intermediate changed value. Preserve
        // the complete translation in that case so a fast swipe still scrubs.
        let sampledMinutes = dragStartDate == nil
          ? value.translation.width * (180 / width)
          : accumulatedMinutes
        let projectedX = value.predictedEndTranslation.width - value.translation.width
        let cappedProjection = min(width * 0.75, max(-width * 0.75, projectedX))
        let speed = min(1, max(0, (abs(scrubVelocity) - 250) / 1_150))
        let smoothSpeed = speed * speed * (3 - 2 * speed)
        let projectedMinutes = sampledMinutes
          + cappedProjection * (180 / width) * (0.25 + 0.45 * smoothSpeed)
        let finalMinutes = snappedMinutes(projectedMinutes)

        withAnimation(.interpolatingSpring(stiffness: 235, damping: 24)) {
          rulerPhase = CGFloat(finalMinutes) / 5
        }
        applyScrubbedTime(from: startDate, minutes: finalMinutes)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) {
            rulerPhase = 0
          }
          resetDragState(keepPhase: true)
        }
      }
  }

  private func snappedMinutes(_ minutes: CGFloat) -> Int {
    Int((minutes / 5).rounded()) * 5
  }

  private func applyScrubbedTime(from startDate: Date, minutes: Int) {
    guard minutes != appliedMinutes,
          let next = Calendar.autoupdatingCurrent.date(byAdding: .minute, value: minutes, to: startDate)
    else { return }
    flowDirection = minutes > appliedMinutes ? 1 : -1
    appliedMinutes = minutes
    selection = next
    feedbackTrigger += 1
  }

  private func resetDragState(keepPhase: Bool = false) {
    dragStartDate = nil
    lastDragX = 0
    lastDragTime = nil
    accumulatedMinutes = 0
    appliedMinutes = 0
    scrubVelocity = 0
    if !keepPhase { rulerPhase = 0 }
  }

  private func shiftTime(by minutes: Int) {
    guard minutes != 0,
          let next = Calendar.autoupdatingCurrent.date(byAdding: .minute, value: minutes, to: selection)
    else { return }
    flowDirection = minutes > 0 ? 1 : -1
    selection = next
    feedbackTrigger += 1
  }
}

private struct TodoTimeRuler: View {
  let phase: CGFloat
  let velocity: CGFloat

  var body: some View {
    GeometryReader { proxy in
      let center = proxy.size.width / 2
      let spacing: CGFloat = 11

      ZStack {
        ForEach(-120...120, id: \.self) { index in
          let relativeIndex = CGFloat(index) - phase
          let distance = abs(relativeIndex)
          let influence = max(0, 1 - distance / 12)
          let height = 5 + influence * 23
          let tickWidth: CGFloat = distance < 8 ? 4 : 3
          let velocityLift = min(4, abs(velocity) / 700)

          Capsule()
            .fill(PanelTheme.primary.opacity(0.10 + influence * 0.22))
            .frame(width: tickWidth, height: height + velocityLift * influence)
            .position(
              x: center + relativeIndex * spacing,
              y: proxy.size.height - (height + velocityLift * influence) / 2
            )
        }

        Capsule()
          .fill(PanelTheme.coral)
          .frame(width: 6, height: 34)
          .position(x: center, y: proxy.size.height - 17)
          .zIndex(2)
      }
    }
    .clipped()
    .accessibilityHidden(true)
  }
}

@MainActor
private func sheetHeader(title: String, onDone: @escaping () -> Void) -> some View {
  HStack {
    Text(title)
      .font(.system(size: 20, weight: .bold))
      .foregroundStyle(PanelTheme.primary)

    Spacer()

    Button(action: onDone) {
      Image(systemName: "xmark")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(PanelTheme.secondary)
        .frame(width: 34, height: 34)
        .background(PanelTheme.raisedSurface, in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Close")
  }
  .padding(.horizontal, 22)
  .padding(.top, 20)
  .padding(.bottom, 10)
}

enum TodoMarkdownCommand: String, Hashable {
  case bold
  case italic
  case bulletList = "bullet-list"
  case checklist
  case code
  case quote
  case link
}

struct TodoMarkdownToolbar: View {
  @Binding var activeCommands: Set<TodoMarkdownCommand>
  let leadingControl: AnyView?
  let identifierPrefix: String
  let onCommand: (TodoMarkdownCommand) -> Void

  init(
    activeCommands: Binding<Set<TodoMarkdownCommand>>,
    identifierPrefix: String = "todo-markdown",
    onCommand: @escaping (TodoMarkdownCommand) -> Void
  ) {
    _activeCommands = activeCommands
    leadingControl = nil
    self.identifierPrefix = identifierPrefix
    self.onCommand = onCommand
  }

  init<Leading: View>(
    activeCommands: Binding<Set<TodoMarkdownCommand>>,
    identifierPrefix: String = "todo-markdown",
    onCommand: @escaping (TodoMarkdownCommand) -> Void,
    @ViewBuilder leading: () -> Leading
  ) {
    _activeCommands = activeCommands
    leadingControl = AnyView(leading())
    self.identifierPrefix = identifierPrefix
    self.onCommand = onCommand
  }

  var body: some View {
    HStack(spacing: 0) {
      if let leadingControl {
        leadingControl
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      ForEach(Self.controls, id: \.command) { control in
        button(control)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 49)
  }

  private func button(_ control: Control) -> some View {
    let isActive = activeCommands.contains(control.command)

    return Button {
      onCommand(control.command)
    } label: {
      Image(systemName: control.symbol)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(PanelTheme.primary.opacity(isActive ? 1 : 0.72))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isActive ? PanelTheme.primary.opacity(0.18) : PanelTheme.surface)
            .padding(4)
        }
        .overlay {
          if isActive {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(PanelTheme.primary.opacity(0.24), lineWidth: 1)
              .padding(4)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("\(identifierPrefix)-\(control.command.rawValue)")
    .accessibilityLabel(control.label)
    .accessibilityValue(isActive ? "On" : "Off")
    .accessibilityAddTraits(isActive ? .isSelected : [])
  }

  private struct Control {
    let command: TodoMarkdownCommand
    let symbol: String
    let label: String
  }

  private static let controls = [
    Control(command: .bold, symbol: "bold", label: "Bold"),
    Control(command: .italic, symbol: "italic", label: "Italic"),
    Control(command: .bulletList, symbol: "list.bullet", label: "Bulleted list"),
    Control(command: .checklist, symbol: "checklist", label: "Checklist"),
    Control(command: .code, symbol: "chevron.left.forwardslash.chevron.right", label: "Inline code"),
    Control(command: .quote, symbol: "text.quote", label: "Quote"),
    Control(command: .link, symbol: "link", label: "Link"),
  ]
}

struct TodoMarkdownRequest {
  let id = UUID()
  let command: TodoMarkdownCommand
}

private extension NSAttributedString.Key {
  static let todoBold = NSAttributedString.Key("iagent.todo.bold")
  static let todoItalic = NSAttributedString.Key("iagent.todo.italic")
  static let todoCode = NSAttributedString.Key("iagent.todo.code")
  static let todoLink = NSAttributedString.Key("iagent.todo.link")
  static let todoBlock = NSAttributedString.Key("iagent.todo.block")
  static let todoGeneratedPrefix = NSAttributedString.Key("iagent.todo.generated-prefix")
}

private enum TodoMarkdownBlock: String {
  case bullet
  case checklist
  case quote

  var visualPrefix: String {
    switch self {
    case .bullet: "• "
    case .checklist: "☐ "
    case .quote: "▏ "
    }
  }

  var markdownPrefix: String {
    switch self {
    case .bullet: "- "
    case .checklist: "- [ ] "
    case .quote: "> "
    }
  }
}

@MainActor
private enum TodoMarkdownCodec {
  private static let inlineExpression = try! NSRegularExpression(
    pattern: #"\*\*\*([^*]+)\*\*\*|\*\*([^*]+)\*\*|_([^_]+)_|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)"#
  )

  static var baseAttributes: [NSAttributedString.Key: Any] {
    renderedAttributes(from: [:])
  }

  static func decode(_ markdown: String) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "")
    let lines = markdown.components(separatedBy: "\n")

    for (index, originalLine) in lines.enumerated() {
      let parsed = parseBlock(in: originalLine)
      let lineStart = result.length

      if let block = parsed.block {
        result.append(
          NSAttributedString(
            string: block.visualPrefix,
            attributes: [
              .todoBlock: block.rawValue,
              .todoGeneratedPrefix: true,
            ]
          )
        )
      }

      appendInlineMarkdown(parsed.content, to: result)
      if index < lines.count - 1 {
        result.append(NSAttributedString(string: "\n"))
      }

      if let block = parsed.block {
        result.addAttribute(
          .todoBlock,
          value: block.rawValue,
          range: NSRange(location: lineStart, length: result.length - lineStart)
        )
      }
    }

    refreshVisualStyles(in: result)
    return result
  }

  static func encode(_ attributed: NSAttributedString) -> String {
    guard attributed.length > 0 else { return "" }
    let source = attributed.string as NSString
    var result = ""
    var location = 0

    while location < source.length {
      let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
      var contentLength = paragraph.length
      while contentLength > 0 {
        let character = source.character(at: paragraph.location + contentLength - 1)
        guard character == 10 || character == 13 else { break }
        contentLength -= 1
      }

      if let block = blockKind(in: attributed, at: paragraph.location) {
        result += block.markdownPrefix
      }
      let generatedLength = generatedPrefixLength(
        in: attributed,
        from: paragraph.location,
        maximum: contentLength
      )
      result += encodeInline(
        attributed,
        range: NSRange(
          location: paragraph.location + generatedLength,
          length: max(0, contentLength - generatedLength)
        )
      )

      let newlineLength = paragraph.length - contentLength
      if newlineLength > 0 {
        result += source.substring(
          with: NSRange(
            location: paragraph.location + contentLength,
            length: newlineLength
          )
        )
      }
      location = NSMaxRange(paragraph)
    }
    return result
  }

  static func refreshVisualStyles(
    in attributed: NSMutableAttributedString,
    range requestedRange: NSRange? = nil
  ) {
    guard attributed.length > 0 else { return }
    let range = requestedRange.map {
      NSIntersectionRange($0, NSRange(location: 0, length: attributed.length))
    } ?? NSRange(location: 0, length: attributed.length)
    guard range.length > 0 else { return }

    let snapshot = attributed.copy() as! NSAttributedString
    attributed.beginEditing()
    snapshot.enumerateAttributes(in: range) { attributes, runRange, _ in
      attributed.setAttributes(renderedAttributes(from: attributes), range: runRange)
    }
    attributed.endEditing()
  }

  static func renderedAttributes(
    from semanticAttributes: [NSAttributedString.Key: Any]
  ) -> [NSAttributedString.Key: Any] {
    var result = semanticAttributes
    [.font, .foregroundColor, .backgroundColor, .underlineStyle, .paragraphStyle].forEach {
      result.removeValue(forKey: $0)
    }

    let isBold = semanticAttributes[.todoBold] != nil
    let isItalic = semanticAttributes[.todoItalic] != nil
    let isCode = semanticAttributes[.todoCode] != nil
    let isGeneratedPrefix = semanticAttributes[.todoGeneratedPrefix] != nil
    let block = (semanticAttributes[.todoBlock] as? String).flatMap(TodoMarkdownBlock.init(rawValue:))

    let baseFont: UIFont
    if isCode {
      baseFont = .monospacedSystemFont(ofSize: 17, weight: .regular)
    } else {
      var traits: UIFontDescriptor.SymbolicTraits = []
      if isBold { traits.insert(.traitBold) }
      if isItalic { traits.insert(.traitItalic) }
      let descriptor = UIFont.systemFont(ofSize: 18).fontDescriptor.withSymbolicTraits(traits)
        ?? UIFont.systemFont(ofSize: 18).fontDescriptor
      baseFont = UIFont(descriptor: descriptor, size: 18)
    }
    result[.font] = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)

    var foreground = UIColor(white: 1, alpha: 0.96)
    if block == .quote { foreground = UIColor(white: 1, alpha: 0.58) }
    if semanticAttributes[.todoLink] != nil {
      foreground = UIColor(red: 0.16, green: 0.62, blue: 1, alpha: 1)
      result[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    if isGeneratedPrefix {
      foreground = block == .quote
        ? UIColor(white: 1, alpha: 0.28)
        : UIColor(red: 1, green: 0.32, blue: 0.29, alpha: 0.88)
    }
    result[.foregroundColor] = foreground
    if isCode {
      result[.backgroundColor] = UIColor(white: 1, alpha: 0.09)
    }

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 4
    paragraphStyle.paragraphSpacing = 5
    if block != nil {
      paragraphStyle.firstLineHeadIndent = 0
      paragraphStyle.headIndent = block == .quote ? 20 : 24
    }
    result[.paragraphStyle] = paragraphStyle
    return result
  }

  static func generatedPrefixLength(
    in attributed: NSAttributedString,
    from location: Int,
    maximum: Int
  ) -> Int {
    guard maximum > 0, location < attributed.length else { return 0 }
    var effectiveRange = NSRange()
    guard attributed.attribute(
      .todoGeneratedPrefix,
      at: location,
      effectiveRange: &effectiveRange
    ) != nil else { return 0 }
    return min(maximum, NSMaxRange(effectiveRange) - location)
  }

  static func blockKind(in attributed: NSAttributedString, at location: Int) -> TodoMarkdownBlock? {
    guard attributed.length > 0 else { return nil }
    let safeLocation = min(max(0, location), attributed.length - 1)
    guard let rawValue = attributed.attribute(.todoBlock, at: safeLocation, effectiveRange: nil) as? String
    else { return nil }
    return TodoMarkdownBlock(rawValue: rawValue)
  }

  private static func parseBlock(in line: String) -> (block: TodoMarkdownBlock?, content: String) {
    if line.hasPrefix("- [ ] ") { return (.checklist, String(line.dropFirst(6))) }
    if line.hasPrefix("- ") { return (.bullet, String(line.dropFirst(2))) }
    if line.hasPrefix("> ") { return (.quote, String(line.dropFirst(2))) }
    return (nil, line)
  }

  private static func appendInlineMarkdown(
    _ source: String,
    to result: NSMutableAttributedString
  ) {
    let sourceString = source as NSString
    let matches = inlineExpression.matches(
      in: source,
      range: NSRange(location: 0, length: sourceString.length)
    )
    var location = 0

    for match in matches {
      if match.range.location > location {
        result.append(
          NSAttributedString(
            string: sourceString.substring(
              with: NSRange(location: location, length: match.range.location - location)
            )
          )
        )
      }

      var attributes: [NSAttributedString.Key: Any] = [:]
      let contentRange: NSRange
      if match.range(at: 1).location != NSNotFound {
        contentRange = match.range(at: 1)
        attributes[.todoBold] = true
        attributes[.todoItalic] = true
      } else if match.range(at: 2).location != NSNotFound {
        contentRange = match.range(at: 2)
        attributes[.todoBold] = true
      } else if match.range(at: 3).location != NSNotFound {
        contentRange = match.range(at: 3)
        attributes[.todoItalic] = true
      } else if match.range(at: 4).location != NSNotFound {
        contentRange = match.range(at: 4)
        attributes[.todoCode] = true
      } else {
        contentRange = match.range(at: 5)
        attributes[.todoLink] = sourceString.substring(with: match.range(at: 6))
      }

      result.append(
        NSAttributedString(
          string: sourceString.substring(with: contentRange),
          attributes: attributes
        )
      )
      location = NSMaxRange(match.range)
    }

    if location < sourceString.length {
      result.append(
        NSAttributedString(
          string: sourceString.substring(
            with: NSRange(location: location, length: sourceString.length - location)
          )
        )
      )
    }
  }

  private static func encodeInline(_ attributed: NSAttributedString, range: NSRange) -> String {
    guard range.length > 0 else { return "" }
    var result = ""
    attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
      let content = (attributed.string as NSString).substring(with: runRange)
      let isBold = attributes[.todoBold] != nil
      let isItalic = attributes[.todoItalic] != nil

      if let url = attributes[.todoLink] as? String {
        result += "[\(content)](\(url))"
      } else if attributes[.todoCode] != nil {
        result += "`\(content)`"
      } else if isBold, isItalic {
        result += "***\(content)***"
      } else if isBold {
        result += "**\(content)**"
      } else if isItalic {
        result += "_\(content)_"
      } else {
        result += content
      }
    }
    return result
  }
}

struct TodoMarkdownTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  let request: TodoMarkdownRequest?
  @Binding var activeCommands: Set<TodoMarkdownCommand>
  let accessibilityIdentifier: String

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.delegate = context.coordinator
    textView.backgroundColor = .clear
    textView.tintColor = UIColor(PanelTheme.coral)
    textView.typingAttributes = TodoMarkdownCodec.baseAttributes
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.keyboardDismissMode = .interactive
    textView.autocorrectionType = .yes
    textView.smartQuotesType = .yes
    textView.smartDashesType = .yes
    textView.adjustsFontForContentSizeCategory = true
    textView.accessibilityIdentifier = accessibilityIdentifier
    context.coordinator.install(text, in: textView)
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    context.coordinator.parent = self

    if text != context.coordinator.lastEmittedMarkdown,
       textView.markedTextRange == nil
    {
      context.coordinator.install(text, in: textView)
    }

    if isFocused, !textView.isFirstResponder {
      DispatchQueue.main.async { textView.becomeFirstResponder() }
    } else if !isFocused, textView.isFirstResponder {
      textView.resignFirstResponder()
    }

    if let request, context.coordinator.lastRequestID != request.id {
      context.coordinator.lastRequestID = request.id
      context.coordinator.apply(request.command, to: textView)
    }
  }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: TodoMarkdownTextView
    var lastRequestID: UUID?
    var lastEmittedMarkdown = ""
    private var isInstallingDocument = false
    private var preservedTypingSelection: NSRange?
    private var preservedTypingAttributes: [NSAttributedString.Key: Any]?

    init(parent: TodoMarkdownTextView) {
      self.parent = parent
    }

    func install(_ markdown: String, in textView: UITextView) {
      isInstallingDocument = true
      preservedTypingSelection = nil
      preservedTypingAttributes = nil
      let selection = textView.selectedRange
      textView.attributedText = TodoMarkdownCodec.decode(markdown)
      textView.selectedRange = NSRange(
        location: min(selection.location, textView.textStorage.length),
        length: 0
      )
      textView.typingAttributes = TodoMarkdownCodec.baseAttributes
      lastEmittedMarkdown = markdown
      isInstallingDocument = false
      synchronizeTypingAttributesWithSelection(in: textView)
      publishActiveCommands(from: textView)
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !isInstallingDocument, textView.markedTextRange == nil else { return }
      emitMarkdown(from: textView)
      publishActiveCommands(from: textView)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      guard !isInstallingDocument else { return }
      if preservedTypingSelection == textView.selectedRange {
        publishActiveCommands(from: textView)
        return
      }
      preservedTypingSelection = nil
      preservedTypingAttributes = nil
      synchronizeTypingAttributesWithSelection(in: textView)
      publishActiveCommands(from: textView)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      parent.isFocused = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      parent.isFocused = false
      emitMarkdown(from: textView)
      publishActiveCommands(from: textView)
    }

    func apply(_ command: TodoMarkdownCommand, to textView: UITextView) {
      textView.becomeFirstResponder()

      switch command {
      case .bold:
        toggleInline(.todoBold, in: textView)
      case .italic:
        toggleInline(.todoItalic, in: textView)
      case .code:
        toggleInline(.todoCode, in: textView)
      case .link:
        toggleLink(in: textView)
      case .bulletList:
        toggleBlock(.bullet, in: textView)
      case .checklist:
        toggleBlock(.checklist, in: textView)
      case .quote:
        toggleBlock(.quote, in: textView)
      }

      emitMarkdown(from: textView)
      publishActiveCommands(from: textView)
    }

    private func toggleInline(_ key: NSAttributedString.Key, in textView: UITextView) {
      let selection = textView.selectedRange
      if selection.length == 0 {
        var attributes = preservedTypingSelection == selection
          ? (preservedTypingAttributes ?? textView.typingAttributes)
          : textView.typingAttributes
        if attributes[key] != nil {
          attributes.removeValue(forKey: key)
        } else {
          attributes[key] = true
        }
        // Tapping a toolbar button can generate a selection callback even though
        // the caret did not move. Preserve this explicit insertion-point choice
        // until the user actually changes the selection or begins typing.
        let rendered = TodoMarkdownCodec.renderedAttributes(from: attributes)
        preservedTypingSelection = selection
        preservedTypingAttributes = rendered
        textView.typingAttributes = rendered
        return
      }

      preservedTypingSelection = nil
      preservedTypingAttributes = nil

      let storage = textView.textStorage
      var isEnabledAcrossSelection = true
      storage.enumerateAttribute(key, in: selection) { value, _, stop in
        if value == nil {
          isEnabledAcrossSelection = false
          stop.pointee = true
        }
      }

      storage.beginEditing()
      if isEnabledAcrossSelection {
        storage.removeAttribute(key, range: selection)
      } else {
        storage.addAttribute(key, value: true, range: selection)
      }
      storage.endEditing()
      TodoMarkdownCodec.refreshVisualStyles(in: storage, range: selection)
      textView.selectedRange = selection
    }

    private func toggleLink(in textView: UITextView) {
      var selection = textView.selectedRange
      let storage = textView.textStorage

      if selection.length == 0 {
        var attributes = textView.typingAttributes
        attributes[.todoLink] = "https://"
        let link = NSAttributedString(
          string: "Link",
          attributes: TodoMarkdownCodec.renderedAttributes(from: attributes)
        )
        storage.insert(link, at: selection.location)
        selection = NSRange(location: selection.location, length: link.length)
      } else {
        var isLinkedAcrossSelection = true
        storage.enumerateAttribute(.todoLink, in: selection) { value, _, stop in
          if value == nil {
            isLinkedAcrossSelection = false
            stop.pointee = true
          }
        }
        if isLinkedAcrossSelection {
          storage.removeAttribute(.todoLink, range: selection)
        } else {
          storage.addAttribute(.todoLink, value: "https://", range: selection)
        }
        TodoMarkdownCodec.refreshVisualStyles(in: storage, range: selection)
      }
      textView.selectedRange = selection
    }

    private func toggleBlock(_ block: TodoMarkdownBlock, in textView: UITextView) {
      let storage = textView.textStorage
      var selection = textView.selectedRange
      let paragraphs = paragraphRanges(in: storage, selection: selection)
      let removeStyle = paragraphs.allSatisfy {
        TodoMarkdownCodec.blockKind(in: storage, at: $0.location) == block
      }
      let target: TodoMarkdownBlock? = removeStyle ? nil : block

      textView.undoManager?.beginUndoGrouping()
      for paragraph in paragraphs.reversed() {
        let prefixLength = TodoMarkdownCodec.generatedPrefixLength(
          in: storage,
          from: paragraph.location,
          maximum: paragraph.length
        )
        if prefixLength > 0 {
          let prefixRange = NSRange(location: paragraph.location, length: prefixLength)
          adjust(&selection, replacing: prefixRange, withLength: 0)
          storage.deleteCharacters(in: prefixRange)
        }

        if let target {
          var prefixAttributes = textView.typingAttributes
          [.todoBold, .todoItalic, .todoCode, .todoLink].forEach {
            prefixAttributes.removeValue(forKey: $0)
          }
          prefixAttributes[.todoBlock] = target.rawValue
          prefixAttributes[.todoGeneratedPrefix] = true
          let prefix = NSAttributedString(
            string: target.visualPrefix,
            attributes: TodoMarkdownCodec.renderedAttributes(from: prefixAttributes)
          )
          storage.insert(prefix, at: paragraph.location)
          adjust(
            &selection,
            replacing: NSRange(location: paragraph.location, length: 0),
            withLength: prefix.length
          )
        }

        guard storage.length > 0 else { continue }
        let safeLocation = min(paragraph.location, storage.length - 1)
        let updatedParagraph = (storage.string as NSString).paragraphRange(
          for: NSRange(location: safeLocation, length: 0)
        )
        if let target {
          storage.addAttribute(.todoBlock, value: target.rawValue, range: updatedParagraph)
        } else {
          storage.removeAttribute(.todoBlock, range: updatedParagraph)
        }
      }
      textView.undoManager?.endUndoGrouping()

      TodoMarkdownCodec.refreshVisualStyles(in: storage)
      let safeLocation = min(selection.location, storage.length)
      textView.selectedRange = NSRange(
        location: safeLocation,
        length: min(selection.length, max(0, storage.length - safeLocation))
      )
    }

    private func paragraphRanges(
      in attributed: NSAttributedString,
      selection: NSRange
    ) -> [NSRange] {
      guard attributed.length > 0 else { return [NSRange(location: 0, length: 0)] }
      let source = attributed.string as NSString
      let location = min(selection.location, source.length)
      let length = min(selection.length, max(0, source.length - location))
      let covered = source.paragraphRange(for: NSRange(location: location, length: length))
      var result: [NSRange] = []
      var cursor = covered.location

      while cursor < NSMaxRange(covered), cursor < source.length {
        let paragraph = source.paragraphRange(for: NSRange(location: cursor, length: 0))
        result.append(paragraph)
        let next = NSMaxRange(paragraph)
        guard next > cursor else { break }
        cursor = next
      }
      return result.isEmpty ? [covered] : result
    }

    private func adjust(
      _ selection: inout NSRange,
      replacing range: NSRange,
      withLength replacementLength: Int
    ) {
      let delta = replacementLength - range.length
      if range.location <= selection.location {
        selection.location = max(0, selection.location + delta)
      } else if range.location < NSMaxRange(selection) {
        selection.length = max(0, selection.length + delta)
      }
    }

    private func emitMarkdown(from textView: UITextView) {
      let markdown = TodoMarkdownCodec.encode(textView.attributedText)
      guard markdown != lastEmittedMarkdown else { return }
      lastEmittedMarkdown = markdown
      parent.text = markdown
    }

    /// UIKit updates visual typing attributes as the caret moves, but it does not
    /// understand the semantic Markdown attributes maintained by this editor.
    /// Rebuilding them from the run at the insertion point prevents toolbar state
    /// from leaking from a previously selected bold (or other inline) run.
    private func synchronizeTypingAttributesWithSelection(in textView: UITextView) {
      let selection = textView.selectedRange
      guard selection.length == 0, textView.markedTextRange == nil else { return }

      let storage = textView.textStorage
      guard storage.length > 0 else {
        textView.typingAttributes = TodoMarkdownCodec.baseAttributes
        return
      }
      let location = selection.location > 0
        ? min(selection.location - 1, storage.length - 1)
        : 0
      let attributes = storage.attributes(at: location, effectiveRange: nil)
      var typingAttributes = attributes
      // Prefix glyphs are presentation-only. If this marker leaks into typing
      // attributes, new list text is later mistaken for generated UI and omitted
      // by Markdown encoding.
      typingAttributes.removeValue(forKey: .todoGeneratedPrefix)
      textView.typingAttributes = TodoMarkdownCodec.renderedAttributes(from: typingAttributes)
    }

    private func publishActiveCommands(from textView: UITextView) {
      let storage = textView.textStorage
      let selection = textView.selectedRange
      var commands = Set<TodoMarkdownCommand>()

      func inlineIsActive(_ key: NSAttributedString.Key) -> Bool {
        if selection.length == 0 {
          if preservedTypingSelection == selection,
             let preservedTypingAttributes
          {
            return preservedTypingAttributes[key] != nil
          }
          return textView.typingAttributes[key] != nil
        }

        var foundRun = false
        var activeAcrossSelection = true
        storage.enumerateAttribute(key, in: selection) { value, _, stop in
          foundRun = true
          if value == nil {
            activeAcrossSelection = false
            stop.pointee = true
          }
        }
        return foundRun && activeAcrossSelection
      }

      if inlineIsActive(.todoBold) { commands.insert(.bold) }
      if inlineIsActive(.todoItalic) { commands.insert(.italic) }
      if inlineIsActive(.todoCode) { commands.insert(.code) }
      if inlineIsActive(.todoLink) { commands.insert(.link) }

      if storage.length > 0 {
        let location = min(selection.location, storage.length - 1)
        switch TodoMarkdownCodec.blockKind(in: storage, at: location) {
        case .bullet: commands.insert(.bulletList)
        case .checklist: commands.insert(.checklist)
        case .quote: commands.insert(.quote)
        case nil: break
        }
      }

      if parent.activeCommands != commands {
        // UIKit delegate and command callbacks can run from updateUIView. State
        // writes during that pass are not guaranteed to invalidate SwiftUI, so
        // publish on the next main-loop turn and keep the toolbar authoritative.
        DispatchQueue.main.async { [weak self] in
          guard let self, self.parent.activeCommands != commands else { return }
          self.parent.activeCommands = commands
        }
      }
    }
  }
}

private struct TodoMarkdownPreview: UIViewRepresentable {
  let markdown: String

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isSelectable = true
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.adjustsFontForContentSizeCategory = true
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    let rendered = TodoMarkdownCodec.decode(markdown)
    if !textView.attributedText.isEqual(to: rendered) {
      textView.attributedText = rendered
    }
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    uiView: UITextView,
    context: Context
  ) -> CGSize? {
    guard let width = proposal.width else { return nil }
    let fittingSize = CGSize(width: width, height: .greatestFiniteMagnitude)
    let measured = uiView.sizeThatFits(fittingSize)
    return CGSize(width: width, height: ceil(measured.height))
  }
}

private extension Date {
  static func roundedUpToFiveMinutes(from date: Date = Date()) -> Date {
    let interval: TimeInterval = 5 * 60
    return Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970 / interval) * interval)
  }
}
