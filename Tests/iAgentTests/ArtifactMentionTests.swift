import XCTest
@testable import iAgentCore

final class ArtifactMentionTests: XCTestCase {
  func testQueryRequiresMentionBoundaryAndCanReplaceAtCursor() throws {
    XCTAssertNil(ArtifactMentionQuery(input: "mail@example.com"))
    XCTAssertEqual(ArtifactMentionQuery(input: "Plan @ship")?.text, "ship")
    XCTAssertEqual(ArtifactMentionQuery(input: "Plan @design review")?.text, "design review")
    XCTAssertEqual(ArtifactMentionQuery(input: "@first then @second")?.text, "second")
    XCTAssertNil(ArtifactMentionQuery(input: "Plan @roadmap; continue"))
    XCTAssertNil(ArtifactMentionQuery(input: "Plan @roadmap  continue"))

    var text = "Before @roadmap after"
    let cursor = try XCTUnwrap(text.range(of: " after")?.lowerBound)
    let query = try XCTUnwrap(ArtifactMentionQuery(input: text, cursor: cursor))
    let mention = ArtifactMention(
      kind: .note,
      artifactID: "B9A0B2B5-0000-4000-8000-000000000002",
      title: "Roadmap"
    )
    query.replacing(in: &text, with: mention, markdown: false)
    XCTAssertEqual(text, "Before Roadmap after")
  }

  func testMarkdownInsertionEscapesLabelAndUsesArtifactRoute() throws {
    let todo = ArtifactMention(
      kind: .todo,
      artifactID: "B9A0B2B5-0000-4000-8000-000000000001",
      title: "Ship [iPhone] *beta*"
    )
    var text = "Review @ship"
    let query = try XCTUnwrap(ArtifactMentionQuery(input: text))
    query.replacing(in: &text, with: todo, markdown: true)

    XCTAssertEqual(
      text,
      "Review [Ship \\[iPhone\\] \\*beta\\*](iagent://todos/b9a0b2b5-0000-4000-8000-000000000001)"
    )
  }

  func testSectionsLimitEveryNonemptyKindIndependently() {
    let todos = (0..<8).map {
      ArtifactMention(kind: .todo, artifactID: UUID().uuidString, title: "Todo \($0)")
    }
    let notes = (0..<5).map {
      ArtifactMention(kind: .note, artifactID: UUID().uuidString, title: "Note \($0)")
    }
    let events = (0..<4).map {
      ArtifactMention(kind: .calendarEvent, artifactID: "event-\($0)", title: "Event \($0)")
    }

    let sections = ArtifactMentionCatalog.sections(
      matching: "",
      in: todos + notes + events,
      itemsPerSection: 3
    )

    XCTAssertEqual(sections.map(\.kind), [.todo, .note, .calendarEvent])
    XCTAssertEqual(sections.map { $0.items.count }, [3, 3, 3])
  }

  func testCalendarEventMentionPreservesOpaqueIdentifier() throws {
    let identifier = "calendar/event id:Δ"
    let mention = ArtifactMention(
      kind: .calendarEvent,
      artifactID: identifier,
      title: "Design review"
    )
    let url = try XCTUnwrap(mention.url)

    XCTAssertEqual(IAgentDeepLink(url: url), .calendarEvent(identifier))
    XCTAssertEqual(url.host, "calendar")
    XCTAssertTrue(url.absoluteString.contains("/event/"))
  }

  func testLocalNoteMentionUsesSafePortableRelativePath() throws {
    let path = "Notes/2026-08-18-roadmap-a1b2c3.md"
    let mention = ArtifactMention(kind: .note, artifactID: path, title: "Roadmap")
    let url = try XCTUnwrap(mention.url)

    XCTAssertEqual(IAgentDeepLink(url: url), .notePath(path))
    XCTAssertNil(
      ArtifactMention(kind: .note, artifactID: "../Secrets.md", title: "Secrets").url
    )
  }

  func testCatalogKeepsSyncedCalendarIdentityWhenPhoneCopyIsNewer() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let end = start.addingTimeInterval(3_600)
    let synced = SyncedCalendarEvent(
      id: "synced-event",
      sourceIdentifier: "shared-source",
      title: "Design review",
      startDate: start,
      endDate: end,
      isAllDay: false,
      calendarTitle: "Work",
      location: nil,
      linkURLs: [],
      updatedAt: start
    )
    let phone = SyncedCalendarEvent(
      id: "phone-local-event",
      sourceIdentifier: "shared-source",
      title: "Design review — updated",
      startDate: start,
      endDate: end,
      isAllDay: false,
      calendarTitle: "Work",
      location: nil,
      linkURLs: [],
      updatedAt: start.addingTimeInterval(60)
    )
    let invalid = SyncedCalendarEvent(
      id: String(repeating: "x", count: 513),
      title: "Unrouteable",
      startDate: start.addingTimeInterval(7_200),
      endDate: end.addingTimeInterval(7_200),
      isAllDay: false,
      calendarTitle: "Work",
      location: nil,
      linkURLs: [],
      updatedAt: start
    )

    let catalog = ArtifactMentionCatalog.make(
      snapshot: IAgentDataSnapshot(calendarEvents: [synced, invalid]),
      calendarEvents: [phone]
    )
    let event = try XCTUnwrap(catalog.first(where: { $0.kind == .calendarEvent }))

    XCTAssertEqual(catalog.filter { $0.kind == .calendarEvent }.count, 1)
    XCTAssertEqual(event.artifactID, synced.id)
    XCTAssertEqual(event.title, phone.title)
    XCTAssertEqual(IAgentDeepLink(url: try XCTUnwrap(event.url)), .calendarEvent(synced.id))
  }

  func testMatchingRanksTitlePrefixWithoutStarvingOtherKinds() {
    let mentions = [
      ArtifactMention(kind: .todo, artifactID: UUID().uuidString, title: "Prep launch", subtitle: "Roadmap"),
      ArtifactMention(kind: .note, artifactID: UUID().uuidString, title: "Roadmap launch notes"),
      ArtifactMention(kind: .codexThread, artifactID: "thread-1", title: "Launch site"),
    ]

    let matches = ArtifactMentionCatalog.matching("launch", in: mentions)
    XCTAssertEqual(matches.map(\.title), ["Launch site", "Prep launch", "Roadmap launch notes"])
  }
}
