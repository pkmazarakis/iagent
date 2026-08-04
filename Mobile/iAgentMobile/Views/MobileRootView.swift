import SwiftUI
import iAgentCore

struct MobileRootView: View {
  @ObservedObject var model: MobileAppModel
  @State private var noteEditor: NoteEditorRoute?

  var body: some View {
    VStack(spacing: 0) {
      TabView(selection: $model.selectedTab) {
        NavigationStack {
          TodayView(model: model)
        }
        .tag(MobileAppModel.Tab.today)

        NavigationStack {
          CodexMobileView(model: model)
        }
        .tag(MobileAppModel.Tab.codex)

        NavigationStack {
          NotesMobileView(model: model, noteEditor: $noteEditor)
        }
        .tag(MobileAppModel.Tab.notes)

        NavigationStack {
          TodosMobileView(model: model)
        }
        .tag(MobileAppModel.Tab.todos)
      }
      .tabViewStyle(.page(indexDisplayMode: .never))
      .frame(maxHeight: .infinity)

      JoiBottomDock(model: model, noteEditor: $noteEditor)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
    .tint(PanelTheme.primary)
    .background(PanelTheme.canvas.ignoresSafeArea())
    .fullScreenCover(item: $noteEditor) { route in
      NoteEditorView(model: model, route: route)
    }
    .fullScreenCover(isPresented: $model.isRecorderPresented) {
      MeetingRecorderView(model: model)
    }
    .task {
      guard model.isNoteEditorPresented, noteEditor == nil else { return }
      noteEditor = NoteEditorRoute(note: nil)
      model.isNoteEditorPresented = false
    }
  }
}

struct NoteEditorRoute: Identifiable {
  let id = UUID()
  let note: SyncedNote?
}

private struct JoiBottomDock: View {
  @ObservedObject var model: MobileAppModel
  @Binding var noteEditor: NoteEditorRoute?

  var body: some View {
    HStack(spacing: 3) {
      tabButton(.today, symbol: "calendar")
      tabButton(.codex, symbol: "sparkles")

      createMenu

      tabButton(.notes, symbol: "note.text")
      tabButton(.todos, symbol: "checkmark.square")
    }
    .padding(.horizontal, 22)
    .padding(.top, 8)
    .padding(.bottom, 14)
    .frame(height: 72)
    .background(PanelTheme.sheet.ignoresSafeArea(edges: .bottom))
    .overlay(alignment: .top) {
      JoiDottedDivider(inset: 24)
    }
  }

  private func tabButton(_ tab: MobileAppModel.Tab, symbol: String) -> some View {
    Button {
      withAnimation(PanelTheme.quick) { model.selectedTab = tab }
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(model.selectedTab == tab ? PanelTheme.primary : PanelTheme.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background {
          if model.selectedTab == tab {
            Circle()
              .fill(PanelTheme.selectedSurface)
              .frame(width: 38, height: 38)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tab.accessibilityLabel)
  }

  private var createMenu: some View {
    Menu {
      Button {
        noteEditor = NoteEditorRoute(note: nil)
      } label: {
        Label("New note", systemImage: "square.and.pencil")
      }

      Button {
        model.selectedTab = .todos
      } label: {
        Label("New todo", systemImage: "checkmark.square")
      }

      Button {
        model.presentRecorder()
      } label: {
        Label("Meeting recorder", systemImage: "waveform")
      }

      Button {
        Task { await model.refresh() }
      } label: {
        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(.black)
        .frame(width: 42, height: 42)
        .background(PanelTheme.primary, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .accessibilityLabel("Create")
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
}
