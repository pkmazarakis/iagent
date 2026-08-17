import Foundation
import XCTest

@testable import iAgentCore

final class AskIAgentHistoryTests: XCTestCase {
  func testConversationPersistsAndDerivesTitleFromFirstPrompt() async throws {
    let directory = temporaryDirectory(named: "ask-history-persistence")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("history.json")
    let store = AskChatHistoryStore(fileURL: fileURL)
    let conversation = try await store.createConversation(at: Date(timeIntervalSince1970: 100))

    _ = try await store.append(
      AskChatMessage(
        role: .user,
        text: "  What should I focus on today?  ",
        createdAt: Date(timeIntervalSince1970: 101)
      ),
      to: conversation.id
    )

    let reloaded = AskChatHistoryStore(fileURL: fileURL)
    let conversations = await reloaded.conversations()
    XCTAssertEqual(conversations.count, 1)
    XCTAssertEqual(conversations.first?.title, "What should I focus on today?")
    XCTAssertEqual(conversations.first?.messages.count, 1)
  }

  func testConcurrentMessageMergesConvergeWithoutDroppingEitherDevice() async throws {
    let directory = temporaryDirectory(named: "ask-history-merge")
    defer { try? FileManager.default.removeItem(at: directory) }
    let baseDate = Date(timeIntervalSince1970: 200)
    let id = UUID()
    let first = AskChatMessage(
      id: UUID(),
      role: .user,
      text: "What changed?",
      createdAt: baseDate
    )
    let second = AskChatMessage(
      id: UUID(),
      role: .assistant,
      text: "The launch note changed.",
      createdAt: baseDate.addingTimeInterval(1)
    )
    let local = AskChatConversation(
      id: id,
      title: "What changed?",
      createdAt: baseDate,
      updatedAt: first.createdAt,
      messages: [first]
    )
    let remote = AskChatConversation(
      id: id,
      title: "What changed?",
      createdAt: baseDate,
      updatedAt: second.createdAt,
      messages: [second]
    )

    let storeA = AskChatHistoryStore(fileURL: directory.appendingPathComponent("a.json"))
    let storeB = AskChatHistoryStore(fileURL: directory.appendingPathComponent("b.json"))
    _ = try await storeA.mergeRemote(local)
    _ = try await storeB.mergeRemote(remote)
    let mergedA = try await storeA.mergeRemote(remote)
    let mergedB = try await storeB.mergeRemote(local)

    XCTAssertEqual(Set(mergedA.messages.map(\.id)), Set([first.id, second.id]))
    XCTAssertEqual(Set(mergedB.messages.map(\.id)), Set([first.id, second.id]))
  }

  func testDeleteWinsOverAConcurrentNonDeletedEdit() async throws {
    let directory = temporaryDirectory(named: "ask-history-delete")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AskChatHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
    let conversation = try await store.createConversation(at: Date(timeIntervalSince1970: 300))
    try await store.deleteConversation(id: conversation.id, at: Date(timeIntervalSince1970: 305))

    var remote = conversation
    remote.title = "Edited elsewhere"
    remote.updatedAt = Date(timeIntervalSince1970: 310)
    let merged = try await store.mergeRemote(remote)

    XCTAssertNotNil(merged.deletedAt)
    let visible = await store.conversations()
    XCTAssertTrue(visible.isEmpty)
  }

  func testPersistedSourceSnapshotIsBounded() async throws {
    let directory = temporaryDirectory(named: "ask-history-bounds")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AskChatHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
    let conversation = try await store.createConversation()
    let citation = AskChatCitation(
      id: "e1",
      sourceKind: "note",
      entityID: "note-1",
      revision: "r1",
      retrievedAt: Date()
    )
    let snapshot = AskChatSourceSnapshot(
      id: "e1",
      sourceKind: "note",
      title: String(repeating: "T", count: 400),
      excerpt: String(repeating: "E", count: 2_000),
      citation: citation
    )
    _ = try await store.append(
      AskChatMessage(
        role: .assistant,
        text: String(repeating: "A", count: 14_000),
        citations: [citation],
        sourceSnapshots: Array(repeating: snapshot, count: 15)
      ),
      to: conversation.id
    )

    let savedConversation = await store.conversation(id: conversation.id)
    let saved = try XCTUnwrap(savedConversation?.messages.first)
    XCTAssertLessThanOrEqual(saved.text.count, 12_000)
    XCTAssertEqual(saved.sourceSnapshots.count, 10)
    XCTAssertLessThanOrEqual(saved.sourceSnapshots[0].title.count, 240)
    XCTAssertLessThanOrEqual(saved.sourceSnapshots[0].excerpt?.count ?? 0, 1_200)
  }

  func testAssistantModelTierRoundTripsWithHistory() async throws {
    let directory = temporaryDirectory(named: "ask-history-model-tier")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("history.json")
    let store = AskChatHistoryStore(fileURL: fileURL)
    let conversation = try await store.createConversation()

    _ = try await store.append(
      AskChatMessage(
        role: .assistant,
        text: "A response from the Pro route.",
        modelTier: "pro"
      ),
      to: conversation.id
    )

    let reloaded = AskChatHistoryStore(fileURL: fileURL)
    let restoredConversation = await reloaded.conversation(id: conversation.id)
    let saved = try XCTUnwrap(restoredConversation?.messages.first)
    XCTAssertEqual(saved.modelTier, "pro")
  }

  func testLegacyAssistantWithoutModelTierStillDecodes() async throws {
    let directory = temporaryDirectory(named: "ask-history-legacy-model-tier")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("history.json")
    let store = AskChatHistoryStore(fileURL: fileURL)
    let conversation = try await store.createConversation()

    _ = try await store.append(
      AskChatMessage(role: .assistant, text: "A legacy response."),
      to: conversation.id
    )

    let reloaded = AskChatHistoryStore(fileURL: fileURL)
    let restoredConversation = await reloaded.conversation(id: conversation.id)
    let saved = try XCTUnwrap(restoredConversation?.messages.first)
    XCTAssertNil(saved.modelTier)
  }

  private func temporaryDirectory(named name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
