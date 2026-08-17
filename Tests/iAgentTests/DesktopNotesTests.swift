import XCTest
@testable import iAgentPanel

final class DesktopNotesTests: XCTestCase {
    func testDatalessCloudPlaceholderIsNeverReadAsMaterialized() {
        XCTAssertTrue(LocalDocumentStore.isMaterialized(fileSystemFlags: 0))
        XCTAssertFalse(
            LocalDocumentStore.isMaterialized(
                fileSystemFlags: LocalDocumentStore.datalessFileFlag
            )
        )
    }

    func testDocumentStoreListsSavedNotesNewestFirstAndParsesMarkdown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iagent-note-list-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDocumentStore(rootURL: root)

        let older = try store.save(kind: .note, title: "Older note", body: "First body")
        let newer = try store.save(kind: .note, title: "Newer note", body: "**Styled** body")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.fileURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.fileURL.path
        )

        let notes = try store.documents(kind: .note)

        XCTAssertEqual(notes.map(\.title), ["Newer note", "Older note"])
        XCTAssertEqual(notes.map(\.body), ["**Styled** body", "First body"])
        XCTAssertEqual(notes.map(\.id), [newer.id, older.id])
        XCTAssertEqual(store.documentCount(for: .note), 2)
    }

    @MainActor
    func testHomeNotesRouteAndSavedNoteOpenInPanel() throws {
        let suiteName = "DesktopNotesTests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let controller = PanelController(smokeTest: true, preferences: preferences)

        controller.openHomeSection(.notes)

        XCTAssertEqual(controller.contentMode, .notes)
        XCTAssertEqual(controller.panelTitle, "Notes")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iagent-note-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try LocalDocumentStore(rootURL: root).save(
            kind: .note,
            title: "Integration note",
            body: "The newest desktop shell stays intact."
        )

        controller.openNote(note)

        XCTAssertEqual(controller.contentMode, .note)
        XCTAssertEqual(controller.editorTitle, note.title)
        XCTAssertEqual(controller.editorBody, note.body)
        XCTAssertEqual(controller.lastSavedDocument, note)
        XCTAssertEqual(controller.noteSaveState, .saved)
    }
}
