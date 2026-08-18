import Foundation
import XCTest
@testable import iAgentPanel

final class NoteTitleIndependenceTests: XCTestCase {
  func testBlankTitleNeverComesFromMentionBody() throws {
    let root = temporaryLibrary(named: "mention-body")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalDocumentStore(rootURL: root)
    let body = "@Ada please review this draft.\n\nKeep the body unchanged."

    let document = try store.save(kind: .note, title: "", body: body)

    XCTAssertEqual(document.title, "Untitled note")
    XCTAssertEqual(document.body, body)
    XCTAssertFalse(document.title.contains("@"))
    XCTAssertEqual(
      try String(contentsOf: document.fileURL, encoding: .utf8),
      "# Untitled note\n\n\(body)\n"
    )
  }

  func testUpdateNeverInfersClearedTitleFromChangedBody() throws {
    let root = temporaryLibrary(named: "updated-draft")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalDocumentStore(rootURL: root)
    let original = try store.save(
      kind: .note,
      title: "Original title",
      body: "Original body"
    )

    let updated = try store.update(
      original,
      title: "   \n",
      body: "@Grace owns the follow-up."
    )

    XCTAssertEqual(updated.title, "Untitled note")
    XCTAssertEqual(updated.body, "@Grace owns the follow-up.")
    XCTAssertEqual(updated.id, original.id)
  }

  func testExplicitMeetingTitleSurvivesTranscriptAndSummaryChanges() throws {
    let root = temporaryLibrary(named: "meeting-title")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalDocumentStore(rootURL: root)
    let recorded = try store.save(
      kind: .note,
      title: "Weekly product sync",
      body: "@Maya opened the meeting."
    )

    let summarized = try store.update(
      recorded,
      title: recorded.title,
      body: "@Maya opened the meeting.\n\n## Summary\n\nShip Friday."
    )

    XCTAssertEqual(summarized.title, "Weekly product sync")
    XCTAssertEqual(
      summarized.body,
      "@Maya opened the meeting.\n\n## Summary\n\nShip Friday."
    )
  }

  private func temporaryLibrary(named name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "iagent-note-title-\(name)-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}
