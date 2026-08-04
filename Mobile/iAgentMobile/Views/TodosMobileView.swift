import SwiftUI
import iAgentCore

struct TodosMobileView: View {
  @ObservedObject var model: MobileAppModel

  @State private var draft = ""
  @State private var selectedList: String?
  @State private var dueDate: Date?
  @State private var isShowingDatePicker = false
  @State private var isShowingNewListPrompt = false
  @State private var newListName = ""
  @State private var showsCompleted = false

  var body: some View {
    PanelScreen {
      JoiDrawerPage(restingFraction: 0.38) {
        hero
      } drawer: {
        LazyVStack(spacing: 0) {
          composer
          JoiDottedDivider()

          if model.openTodos.isEmpty {
            EmptyPanelState(
              symbol: "checkmark",
              title: "Nothing open",
              detail: "The rest of today is yours."
            )
          } else {
            JoiSectionHeader(title: "Today", count: model.openTodos.count)

            ForEach(Array(model.openTodos.enumerated()), id: \.element.id) { index, todo in
              JoiTodoRow(model: model, todo: todo)
                .contextMenu {
                  Button(role: .destructive) {
                    Task { await model.deleteTodo(todo) }
                  } label: {
                    Label("Delete", systemImage: "trash")
                  }
                }

              if index < model.openTodos.count - 1 { JoiDottedDivider() }
            }
          }

          if !model.completedTodos.isEmpty {
            Button {
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
                JoiTodoRow(model: model, todo: todo)
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
    .sheet(isPresented: $isShowingDatePicker) {
      dueDatePicker
        .presentationDetents([.height(390)])
        .presentationBackground(PanelTheme.sheet)
    }
    .alert("New list", isPresented: $isShowingNewListPrompt) {
      TextField("List name", text: $newListName)
      Button("Cancel", role: .cancel) {}
      Button("Add") {
        let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
          await model.createTodoList(named: name)
          selectedList = name
          newListName = ""
        }
      }
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

  private var composer: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(PanelTheme.secondary, lineWidth: 1.4)
        .frame(width: 22, height: 22)

      TextField("Create new task", text: $draft)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(PanelTheme.primary)
        .textFieldStyle(.plain)
        .submitLabel(.done)
        .onSubmit(submit)

      Button {
        isShowingDatePicker = true
      } label: {
        Image(systemName: dueDate == nil ? "calendar" : "calendar.badge.checkmark")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(dueDate == nil ? PanelTheme.secondary : PanelTheme.coral)
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Set due date")

      Menu {
        Button("No list") { selectedList = nil }
        ForEach(model.snapshot.todoLists) { list in
          Button(list.name) { selectedList = list.name }
        }
        Divider()
        Button("New list") { isShowingNewListPrompt = true }
      } label: {
        Image(systemName: "tag")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(selectedList == nil ? PanelTheme.secondary : PanelTheme.blue)
          .frame(width: 30, height: 30)
      }
      .accessibilityLabel(selectedList ?? "No list")

      Button(action: submit) {
        Image(systemName: "plus")
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(canSubmit ? .black : PanelTheme.tertiary)
          .frame(width: 34, height: 34)
          .background(canSubmit ? PanelTheme.primary : PanelTheme.surface, in: Circle())
      }
      .buttonStyle(.plain)
      .disabled(!canSubmit)
      .accessibilityLabel("Add todo")
    }
    .padding(.horizontal, 24)
    .frame(height: 66)
  }

  private var dueDatePicker: some View {
    NavigationStack {
      VStack(spacing: 0) {
        DatePicker(
          "Due",
          selection: Binding(
            get: { dueDate ?? Date() },
            set: { dueDate = $0 }
          ),
          displayedComponents: [.date, .hourAndMinute]
        )
        .datePickerStyle(.graphical)
        .tint(PanelTheme.coral)
        .padding(.horizontal, 12)
      }
      .background(PanelTheme.sheet)
      .navigationTitle("Due date")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(PanelTheme.sheet, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Clear") {
            dueDate = nil
            isShowingDatePicker = false
          }
          .foregroundStyle(PanelTheme.secondary)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { isShowingDatePicker = false }
            .fontWeight(.semibold)
            .foregroundStyle(PanelTheme.primary)
        }
      }
    }
  }

  private var canSubmit: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func submit() {
    let title = draft
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    draft = ""
    let list = selectedList
    let due = dueDate
    dueDate = nil
    Task { await model.createTodo(title: title, listName: list, dueDate: due) }
  }
}

private struct JoiTodoRow: View {
  @ObservedObject var model: MobileAppModel
  let todo: SyncedTodo

  var body: some View {
    JoiTimelineRow(minHeight: 62) {
      Button {
        Task { await model.toggleTodo(todo) }
      } label: {
        ZStack {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(todo.isCompleted ? PanelTheme.primary : .clear)
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(todo.isCompleted ? PanelTheme.primary : PanelTheme.secondary, lineWidth: 1.4)
          if todo.isCompleted {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(.black)
          }
        }
        .frame(width: 22, height: 22)
        .frame(width: 30, height: 30)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(todo.isCompleted ? "Reopen \(todo.title)" : "Complete \(todo.title)")
    } content: {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          todoTitle

          if let list = todo.listName {
            Text(list)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(PanelTheme.tertiary)
              .lineLimit(1)
          }
        }

        todoTitle
      }
    } trailing: {
      HStack(spacing: 10) {
        if let dueDate = todo.dueDate {
          Text(dueDate.formatted(.dateTime.month(.abbreviated).day()))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(dueDate < Date() && !todo.isCompleted ? PanelTheme.coral : PanelTheme.secondary)
        }

        Button {
          Task { await model.toggleStar(todo) }
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

  private var todoTitle: some View {
    Text(todo.title)
      .font(.system(size: 16, weight: .semibold))
      .foregroundStyle(todo.isCompleted ? PanelTheme.tertiary : PanelTheme.primary)
      .strikethrough(todo.isCompleted, color: PanelTheme.secondary)
      .lineLimit(1)
      .layoutPriority(1)
  }
}
