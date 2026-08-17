import Foundation
import XCTest

@testable import iAgentCore

final class AskIAgentQueryFoundationTests: XCTestCase {
  func testRuntimeCatalogRoundTripsWithoutPrivateRecordContent() throws {
    let context = temporalContext("2026-08-10T09:00:00Z")
    let secret = "PRIVATE-CONTENT-MUST-NOT-ENTER-MANIFEST"
    let noteID = UUID()
    let data = IAgentDataSnapshot(
      notes: [
        SyncedNote(
          id: noteID,
          title: secret,
          body: "\(secret)-body",
          sourceDeviceID: "private-device"
        )
      ],
      todos: [
        SyncedTodo(title: "\(secret)-todo", notes: "\(secret)-notes")
      ],
      meetings: [
        SyncedMeetingSession(
          noteID: noteID,
          title: "\(secret)-meeting",
          sourceDeviceID: "private-device",
          state: .completed,
          startedAt: date("2026-08-10T07:00:00Z"),
          endedAt: date("2026-08-10T08:00:00Z"),
          updatedAt: date("2026-08-10T08:00:00Z")
        )
      ],
      codexThreads: [
        SyncedCodexThread(
          id: "secret-codex-id",
          projectName: secret,
          title: secret,
          activity: secret,
          state: .running,
          modes: [.plan],
          createdAt: date("2026-08-10T07:00:00Z"),
          updatedAt: date("2026-08-10T08:00:00Z")
        )
      ],
      calendarEvents: [
        calendarEvent(
          id: "secret-calendar-id",
          title: secret,
          start: date("2026-08-10T10:00:00Z"),
          end: date("2026-08-10T11:00:00Z"),
          updated: date("2026-08-10T08:00:00Z")
        )
      ],
      lastSuccessfulSyncAt: date("2026-08-10T08:59:00Z")
    )
    let catalog = AskDataCatalogBuilder.build(
      snapshot: AskDataSnapshot(data: data, contextAsOf: context.contextAsOf),
      snapshotID: "snapshot-privacy",
      temporalContext: context
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(catalog)
    let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

    XCTAssertFalse(json.contains(secret))
    XCTAssertFalse(json.contains("secret-codex-id"))
    XCTAssertFalse(json.contains("secret-calendar-id"))
    XCTAssertFalse(json.contains("private-device"))
    XCTAssertTrue(json.contains("snapshot-privacy"))
    XCTAssertTrue(json.contains("Europe/Athens"))
    XCTAssertEqual(catalog.domains.count, AskSourceKind.allCases.count)
    XCTAssertEqual(catalog.domains.first(where: { $0.domain == .todo })?.recordCount, 1)
    XCTAssertEqual(catalog.domains.first(where: { $0.domain == .meeting })?.recordCount, 1)
    // The linked meeting note is represented by the meeting domain, not leaked or double-counted.
    XCTAssertEqual(catalog.domains.first(where: { $0.domain == .note })?.recordCount, 0)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    XCTAssertEqual(try decoder.decode(AskDataCatalog.self, from: encoded), catalog)
  }

  func testEmptyCalendarCaptureKeepsItsExactCoverageOverride() throws {
    let context = temporalContext("2026-08-10T09:00:00Z")
    let expected = AskCatalogCoverage(
      start: date("2025-08-09T21:00:00Z"),
      end: date("2028-08-10T21:00:00Z"),
      isCompleteWithinRange: true,
      isTruncated: false
    )
    let snapshot = AskDataSnapshot(
      data: IAgentDataSnapshot(),
      contextAsOf: context.contextAsOf,
      coverageOverrides: [.calendar: expected]
    )

    let catalog = AskDataCatalogBuilder.build(
      snapshot: snapshot,
      snapshotID: "empty-calendar-capture",
      temporalContext: context
    )

    let calendar = try XCTUnwrap(catalog.domains.first { $0.domain == .calendar })
    XCTAssertEqual(calendar.recordCount, 0)
    XCTAssertEqual(calendar.coverage, expected)
  }

  func testCalendarOccurrenceReadOutsidePinnedCaptureReturnsOutOfCoverageWithoutUsingBudget()
    async throws
  {
    let context = temporalContext("2026-08-10T09:00:00Z")
    let coverage = AskCatalogCoverage(
      start: date("2026-08-01T00:00:00Z"),
      end: date("2026-09-01T00:00:00Z"),
      isCompleteWithinRange: true,
      isTruncated: false
    )
    let executor = try AskPinnedQueryExecutor(
      snapshot: AskDataSnapshot(
        data: IAgentDataSnapshot(),
        contextAsOf: context.contextAsOf,
        coverageOverrides: [.calendar: coverage]
      ),
      snapshotID: "calendar-coverage",
      temporalContext: context
    )
    let outside = AskCalendarQuery(
      queryID: "outside-calendar-capture",
      time: AskQueryTimeFilter(
        field: .occurrence,
        preset: .absolute,
        start: date("2026-09-01T00:00:00Z"),
        end: date("2026-09-02T00:00:00Z")
      )
    )

    do {
      _ = try await executor.execute(outside)
      XCTFail("An occurrence query outside the captured EventKit range must fail truthfully.")
    } catch let failure as AskQueryFailure {
      XCTAssertEqual(failure.code, .outOfCoverage)
      XCTAssertEqual(failure.queryID, outside.queryID)
      XCTAssertEqual(failure.field, "time")
    }
    let usageAfterRejectedQuery = await executor.usage()
    XCTAssertEqual(usageAfterRejectedQuery.calls, 0)

    let inside = AskCalendarQuery(
      queryID: "inside-empty-calendar-capture",
      time: AskQueryTimeFilter(
        field: .occurrence,
        preset: .absolute,
        start: date("2026-08-12T00:00:00Z"),
        end: date("2026-08-13T00:00:00Z")
      )
    )
    let page = try await executor.execute(inside)
    XCTAssertEqual(page.completeness, .complete)
    XCTAssertEqual(page.totalMatched, 0)
    XCTAssertTrue(page.items.isEmpty)
    XCTAssertEqual(page.budgetUsage.calls, 1)
  }

  func testAllFiveToolSchemasAreStrictAndRoundTrip() throws {
    XCTAssertEqual(
      AskReadToolSchemas.all.map(\.name),
      ["query_todos", "query_calendar", "query_notes", "query_meetings", "query_codex"]
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for schema in AskReadToolSchemas.all {
      let data = try encoder.encode(schema)
      XCTAssertEqual(try JSONDecoder().decode(AskStrictReadToolSchema.self, from: data), schema)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(object["type"] as? String, "function")
      XCTAssertEqual(object["strict"] as? Bool, true)
      let parameters = try XCTUnwrap(object["parameters"] as? [String: Any])
      assertStrictSchema(parameters, path: schema.name)
    }
  }

  func testExternalReadToolContractHasStableVersionDigestAndAllowlist() {
    XCTAssertEqual(AskReadToolSchemas.schemaVersion, 1)
    XCTAssertEqual(
      AskReadToolSchemas.allowedNames,
      ["query_todos", "query_calendar", "query_notes", "query_meetings", "query_codex"]
    )
    XCTAssertEqual(AskReadToolSchemas.schemaDigest.count, 64)
    XCTAssertEqual(
      AskReadToolSchemas.schemaDigest,
      "8b8df423c5f84945c54ba2f467cdf774ba7f3a3a399025278924ccc629eb1ba5"
    )
    XCTAssertTrue(
      AskReadToolSchemas.schemaDigest.allSatisfy {
        $0.isNumber || ("a"..."f").contains(String($0))
      }
    )
  }

  func testExternalReadToolDecoderStrictlyDecodesAllFiveDomains() throws {
    let calls: [(String, String, AskSourceKind, String)] = [
      (
        "query_todos",
        #"{"query_id":"remote-todo","text":"launch","record_ids":[],"states":["open"],"starred":null,"due":"any","list_names":[],"time":{"field":"updated","preset":"any","start":null,"end":null},"sort":"attentionDesc","content":"preview","limit":4,"cursor":null}"#,
        .todo,
        "remote-todo"
      ),
      (
        "query_calendar",
        #"{"query_id":"remote-calendar","text":null,"record_ids":[],"calendar_titles":[],"all_day":null,"time":{"field":"occurrence","preset":"today","start":null,"end":null},"sort":"startAsc","content":"details","limit":6,"cursor":null}"#,
        .calendar,
        "remote-calendar"
      ),
      (
        "query_notes",
        #"{"query_id":"remote-note","text":"launch","record_ids":[],"time":{"field":"updated","preset":"last7Days","start":null,"end":null},"sort":"relevanceDesc","content":"full","limit":3,"cursor":null}"#,
        .note,
        "remote-note"
      ),
      (
        "query_meetings",
        #"{"query_id":"remote-meeting","text":null,"record_ids":[],"states":["completed"],"has_readable_content":true,"time":{"field":"occurrence","preset":"past","start":null,"end":null},"sort":"occurrenceDesc","content":"summaryAndTranscriptPassages","limit":1,"cursor":null}"#,
        .meeting,
        "remote-meeting"
      ),
      (
        "query_codex",
        #"{"query_id":"remote-codex","text":null,"record_ids":[],"states":["running","needsApproval"],"modes":["plan"],"project_names":[],"time":{"field":"updated","preset":"any","start":null,"end":null},"sort":"updatedDesc","content":"activity","limit":5,"cursor":null}"#,
        .codex,
        "remote-codex"
      ),
    ]

    for (name, json, domain, queryID) in calls {
      let decoded = try AskReadToolCallDecoder.decode(
        name: name,
        argumentsJSON: Data(json.utf8)
      )
      XCTAssertEqual(decoded.name, name)
      XCTAssertEqual(decoded.query.domain, domain)
      XCTAssertEqual(decoded.query.queryID, queryID)
      XCTAssertEqual(decoded.payloadDigest.count, 64)
      XCTAssertEqual(
        try JSONSerialization.jsonObject(with: decoded.canonicalArgumentsJSON) as? NSDictionary,
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
      )
    }
  }

  func testExternalReadToolDecoderCanonicalizesKeyOrderForReplayIdentity() throws {
    let first = Data(
      #"{"query_id":"same","text":null,"record_ids":[],"time":{"field":"updated","preset":"any","start":null,"end":null},"sort":"updatedDesc","content":"preview","limit":2,"cursor":null}"#.utf8
    )
    let reordered = Data(
      #"{"cursor":null,"limit":2,"content":"preview","sort":"updatedDesc","time":{"end":null,"start":null,"preset":"any","field":"updated"},"record_ids":[],"text":null,"query_id":"same"}"#.utf8
    )

    let firstCall = try AskReadToolCallDecoder.decode(
      name: "query_notes", argumentsJSON: first)
    let replay = try AskReadToolCallDecoder.decode(
      name: "query_notes", argumentsJSON: reordered)

    XCTAssertEqual(firstCall.query, replay.query)
    XCTAssertEqual(firstCall.canonicalArgumentsJSON, replay.canonicalArgumentsJSON)
    XCTAssertEqual(firstCall.payloadDigest, replay.payloadDigest)
  }

  func testExternalReadToolDecoderRejectsUnknownMissingAndExtraFields() throws {
    let valid =
      #"{"query_id":"strict","text":null,"record_ids":[],"time":{"field":"updated","preset":"any","start":null,"end":null},"sort":"updatedDesc","content":"preview","limit":2,"cursor":null}"#

    XCTAssertThrowsError(
      try AskReadToolCallDecoder.decode(
        name: "query_everything", argumentsJSON: Data(valid.utf8))
    ) { error in
      XCTAssertEqual((error as? AskReadToolCallFailure)?.code, .unsupportedTool)
    }

    let missing = valid.replacingOccurrences(of: #","cursor":null"#, with: "")
    XCTAssertThrowsError(
      try AskReadToolCallDecoder.decode(name: "query_notes", argumentsJSON: Data(missing.utf8))
    ) { error in
      XCTAssertEqual((error as? AskReadToolCallFailure)?.code, .missingArgument)
      XCTAssertEqual((error as? AskReadToolCallFailure)?.field, "cursor")
    }

    let extra = valid.replacingOccurrences(of: #""limit":2"#, with: #""limit":2,"secret":true"#)
    XCTAssertThrowsError(
      try AskReadToolCallDecoder.decode(name: "query_notes", argumentsJSON: Data(extra.utf8))
    ) { error in
      XCTAssertEqual((error as? AskReadToolCallFailure)?.code, .unexpectedArgument)
      XCTAssertEqual((error as? AskReadToolCallFailure)?.field, "secret")
    }

    let nestedExtra = valid.replacingOccurrences(
      of: #""end":null"#,
      with: #""end":null,"timezone":"invented""#
    )
    XCTAssertThrowsError(
      try AskReadToolCallDecoder.decode(
        name: "query_notes", argumentsJSON: Data(nestedExtra.utf8))
    ) { error in
      XCTAssertEqual((error as? AskReadToolCallFailure)?.code, .unexpectedArgument)
      XCTAssertEqual((error as? AskReadToolCallFailure)?.field, "time.timezone")
    }

    XCTAssertThrowsError(
      try AskReadToolCallDecoder.decode(
        name: "query_notes", argumentsJSON: Data("[]".utf8))
    ) { error in
      XCTAssertEqual((error as? AskReadToolCallFailure)?.code, .malformedArguments)
    }
  }

  func testExternalReadToolDecoderRejectsWrongTypesAndOversizedPayloads() throws {
    let wrongType = Data(
      #"{"query_id":"wrong","text":null,"record_ids":[],"time":{"field":"updated","preset":"any","start":null,"end":null},"sort":"updatedDesc","content":"preview","limit":"2","cursor":null}"#.utf8
    )
    XCTAssertThrowsError(
      try AskReadToolCallDecoder.decode(name: "query_notes", argumentsJSON: wrongType)
    ) { error in
      XCTAssertEqual((error as? AskReadToolCallFailure)?.code, .invalidArgument)
      XCTAssertEqual((error as? AskReadToolCallFailure)?.field, "limit")
    }

    let oversized = Data(
      repeating: UInt8(ascii: " "),
      count: AskReadToolCallDecoder.maximumArgumentsBytes + 1
    )
    XCTAssertThrowsError(
      try AskReadToolCallDecoder.decode(name: "query_notes", argumentsJSON: oversized)
    ) { error in
      XCTAssertEqual((error as? AskReadToolCallFailure)?.code, .payloadTooLarge)
    }
  }

  func testAllTypedQueryEnvelopesRoundTripWithStableDomainDiscriminator() throws {
    let queries: [AskReadQuery] = [
      .todo(AskTodoQuery(queryID: "q-todo", states: [.open], starred: true)),
      .calendar(
        AskCalendarQuery(
          queryID: "q-calendar",
          time: AskQueryTimeFilter(field: .occurrence, preset: .today))),
      .note(AskNoteQuery(queryID: "q-note", text: "launch")),
      .meeting(AskMeetingQuery.latestCompletedReadable(queryID: "q-meeting")),
      .codex(
        AskCodexQuery(
          queryID: "q-codex", states: [.needsApproval], modes: [.plan])),
    ]

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    for query in queries {
      let data = try encoder.encode(query)
      XCTAssertEqual(try decoder.decode(AskReadQuery.self, from: data), query)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(object["domain"] as? String, query.domain.rawValue)
      XCTAssertNotNil(object["arguments"] as? [String: Any])
    }
  }

  func testTemporalContextResolvesAthensDSTAndHalfOpenDays() throws {
    let context = temporalContext("2026-03-29T12:00:00Z")
    let today = try XCTUnwrap(
      AskQueryTimeFilter(field: .occurrence, preset: .today).resolvedRange(in: context))

    // Europe/Athens advances from UTC+2 to UTC+3 on this date.
    XCTAssertEqual(today.end.timeIntervalSince(today.start), 23 * 60 * 60, accuracy: 0.1)
    XCTAssertTrue(today.contains(today.start))
    XCTAssertFalse(today.contains(today.end))
    XCTAssertEqual(today.start, date("2026-03-28T22:00:00Z"))
    XCTAssertEqual(today.end, date("2026-03-29T21:00:00Z"))
  }

  func testValidatorRejectsInvalidTemporalAndDomainInvariants() throws {
    let context = temporalContext("2026-08-10T09:00:00Z")
    let budget = AskQueryBudget()

    XCTAssertThrowsError(
      try AskQueryValidator.validate(
        .calendar(
          AskCalendarQuery(
            queryID: "absolute-missing-end",
            time: AskQueryTimeFilter(
              field: .occurrence,
              preset: .absolute,
              start: date("2026-08-10T00:00:00Z"),
              end: nil
            ))),
        temporalContext: context,
        budget: budget
      )
    ) { error in
      XCTAssertEqual((error as? AskQueryFailure)?.code, .invalidTemporalRange)
    }

    XCTAssertThrowsError(
      try AskQueryValidator.validate(
        .note(
          AskNoteQuery(
            queryID: "note-occurrence",
            time: AskQueryTimeFilter(field: .occurrence, preset: .today))),
        temporalContext: context,
        budget: budget
      )
    ) { error in
      XCTAssertEqual((error as? AskQueryFailure)?.code, .unsupportedTemporalField)
    }

    XCTAssertThrowsError(
      try AskQueryValidator.validate(
        .todo(
          AskTodoQuery(
            queryID: "bad-due-window",
            due: .dueInWindow,
            time: AskQueryTimeFilter(field: .updated))),
        temporalContext: context,
        budget: budget
      )
    ) { error in
      XCTAssertEqual((error as? AskQueryFailure)?.code, .invalidQuery)
    }

    XCTAssertNoThrow(
      try AskQueryValidator.validate(
        .calendar(
          AskCalendarQuery(
            queryID: "calendar-past",
            time: AskQueryTimeFilter(field: .occurrence, preset: .past)
          )
        ),
        temporalContext: context,
        budget: budget
      )
    )

    XCTAssertThrowsError(
      try AskQueryValidator.validate(
        .todo(
          AskTodoQuery(
            queryID: "duplicate-state",
            states: [.open, .open]
          )
        ),
        temporalContext: context,
        budget: budget
      )
    ) { error in
      XCTAssertEqual((error as? AskQueryFailure)?.code, .invalidQuery)
    }

    var invalidCalendarContext = context
    invalidCalendarContext.calendarIdentifier = "model-invented-calendar"
    XCTAssertThrowsError(try invalidCalendarContext.calendar()) { error in
      XCTAssertEqual((error as? AskQueryFailure)?.code, .invalidTemporalContext)
    }
  }

  func testExecutorAdvertisesAllImplementedReadDomains() async throws {
    let context = temporalContext("2026-08-10T09:00:00Z")
    let executor = try executor(data: IAgentDataSnapshot(), context: context)

    XCTAssertEqual(
      executor.catalog.domains.first(where: { $0.domain == .todo })?.availability,
      .available
    )
    XCTAssertEqual(
      executor.catalog.domains.first(where: { $0.domain == .calendar })?.availability,
      .available
    )
    XCTAssertEqual(
      executor.catalog.domains.first(where: { $0.domain == .meeting })?.availability,
      .available
    )
    XCTAssertEqual(
      executor.catalog.domains.first(where: { $0.domain == .note })?.availability,
      .available
    )
    XCTAssertEqual(
      executor.catalog.domains.first(where: { $0.domain == .codex })?.availability,
      .available
    )

    let recorder = LockedProgressRecorder()
    let page = try await executor.execute(.note(AskNoteQuery(queryID: "empty-note"))) {
      recorder.append($0)
    }
    XCTAssertEqual(page.items, [])
    XCTAssertEqual(
      recorder.values.map(\.phase),
      [.validated, .executing, .pageProduced, .completed]
    )
  }

  func testTodoExecutorFiltersRanksPaginatesAndBindsCursor() async throws {
    let context = temporalContext("2026-08-10T09:00:00Z")
    let calendar = try context.calendar()
    let today = calendar.startOfDay(for: context.contextAsOf)
    let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
    let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
    let deletedAt = date("2026-08-10T08:00:00Z")
    let todos = [
      SyncedTodo(
        title: "Overdue release task",
        dueDate: yesterday,
        createdAt: date("2026-08-01T08:00:00Z"),
        updatedAt: date("2026-08-09T08:00:00Z")),
      SyncedTodo(
        title: "Due today",
        dueDate: today,
        createdAt: date("2026-08-02T08:00:00Z"),
        updatedAt: date("2026-08-10T08:00:00Z")),
      SyncedTodo(
        title: "Starred follow-up",
        isStarred: true,
        createdAt: date("2026-08-03T08:00:00Z"),
        updatedAt: date("2026-08-10T07:00:00Z")),
      SyncedTodo(
        title: "Ordinary work",
        dueDate: tomorrow,
        createdAt: date("2026-08-04T08:00:00Z"),
        updatedAt: date("2026-08-10T06:00:00Z")),
      SyncedTodo(
        title: "Deleted secret",
        createdAt: date("2026-08-04T08:00:00Z"),
        updatedAt: deletedAt,
        deletedAt: deletedAt),
    ]
    let executor = try executor(
      data: IAgentDataSnapshot(todos: todos),
      context: context,
      budget: AskQueryBudget(
        maximumCalls: 4,
        maximumCallsPerDomain: 4,
        maximumPagesPerDomain: 4,
        maximumRecordsPerPage: 2,
        maximumTotalRecords: 8,
        maximumEvidencePassages: 8,
        maximumEvidenceCharacters: 4_000
      )
    )
    var query = AskTodoQuery(
      queryID: "plan-todos",
      states: [.open],
      sort: .attentionDesc,
      content: .preview,
      limit: 2
    )
    let first = try await executor.execute(query)

    XCTAssertEqual(first.totalMatched, 4)
    XCTAssertEqual(first.items.map(\.title), ["Overdue release task", "Due today"])
    XCTAssertTrue(first.hasMore)
    XCTAssertNotNil(first.nextCursor)
    XCTAssertTrue(first.warnings.contains(.legacyDueSemantics))
    XCTAssertFalse(first.items.map(\.title).contains("Deleted secret"))

    query.cursor = first.nextCursor
    let second = try await executor.execute(query)
    XCTAssertEqual(second.items.map(\.title), ["Starred follow-up", "Ordinary work"])
    XCTAssertFalse(second.hasMore)
    XCTAssertNil(second.nextCursor)
    XCTAssertEqual(Set((first.items + second.items).map(\.source.entityID)).count, 4)

    var changedQuery = query
    changedQuery.sort = .dueAsc
    do {
      _ = try await executor.execute(changedQuery)
      XCTFail("Expected the cursor to be bound to the original query fingerprint")
    } catch {
      XCTAssertEqual((error as? AskQueryFailure)?.code, .invalidCursor)
    }
  }

  func testRecordIDInputAndDuplicateSnapshotRowsReturnOneTodo() async throws {
    let context = temporalContext("2026-08-10T09:00:00Z")
    let id = UUID()
    let old = SyncedTodo(
      id: id,
      title: "Old replica",
      createdAt: date("2026-08-01T08:00:00Z"),
      updatedAt: date("2026-08-09T08:00:00Z"))
    let current = SyncedTodo(
      id: id,
      title: "Current replica",
      createdAt: date("2026-08-01T08:00:00Z"),
      updatedAt: date("2026-08-10T08:00:00Z"))
    let executor = try executor(
      data: IAgentDataSnapshot(todos: [old, current]),
      context: context
    )
    let page = try await executor.execute(
      AskTodoQuery(
        queryID: "dedup-todo",
        recordIDs: [id.uuidString, id.uuidString.lowercased()],
        sort: .updatedDesc
      ))

    XCTAssertEqual(page.totalMatched, 1)
    XCTAssertEqual(page.items.map(\.title), ["Current replica"])
  }

  func testCalendarExecutorDeduplicatesReplicasAndUsesHalfOpenIntersection() async throws {
    let context = temporalContext("2026-08-10T09:00:00Z")
    let calendar = try context.calendar()
    let start = calendar.startOfDay(for: context.contextAsOf)
    let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
    let events = [
      calendarEvent(
        id: "cloud-copy",
        sourceIdentifier: "occurrence-1",
        title: "Stale replica",
        start: start.addingTimeInterval(2 * 60 * 60),
        end: start.addingTimeInterval(3 * 60 * 60),
        updated: date("2026-08-09T08:00:00Z")),
      calendarEvent(
        id: "phone-copy",
        sourceIdentifier: "occurrence-1",
        title: "Current replica",
        start: start.addingTimeInterval(2 * 60 * 60),
        end: start.addingTimeInterval(3 * 60 * 60),
        updated: date("2026-08-10T08:00:00Z")),
      calendarEvent(
        id: "overlap",
        title: "Overlaps day start",
        start: start.addingTimeInterval(-60 * 60),
        end: start.addingTimeInterval(60 * 60),
        updated: date("2026-08-10T08:00:00Z")),
      calendarEvent(
        id: "ends-at-start",
        title: "Ends at exclusive boundary",
        start: start.addingTimeInterval(-2 * 60 * 60),
        end: start,
        updated: date("2026-08-10T08:00:00Z")),
      calendarEvent(
        id: "starts-at-end",
        title: "Starts at exclusive boundary",
        start: end,
        end: end.addingTimeInterval(60 * 60),
        updated: date("2026-08-10T08:00:00Z")),
    ]
    let executor = try executor(
      data: IAgentDataSnapshot(calendarEvents: events),
      context: context
    )
    let page = try await executor.execute(
      AskCalendarQuery(
        queryID: "calendar-today",
        time: AskQueryTimeFilter(field: .occurrence, preset: .today),
        sort: .startAsc,
        content: .details
      ))

    XCTAssertEqual(page.totalMatched, 2)
    XCTAssertEqual(page.items.map(\.title), ["Overlaps day start", "Current replica"])
    XCTAssertFalse(page.items.map(\.title).contains("Stale replica"))
    XCTAssertFalse(page.items.map(\.title).contains("Ends at exclusive boundary"))
    XCTAssertFalse(page.items.map(\.title).contains("Starts at exclusive boundary"))
  }

  func testLatestCompletedReadableMeetingUsesOccurrenceNotEditTime() async throws {
    let context = temporalContext("2026-08-10T12:00:00Z")
    let olderNoteID = UUID()
    let latestNoteID = UUID()
    let unreadableNoteID = UUID()
    let futureNoteID = UUID()
    let notes = [
      meetingNote(
        id: olderNoteID,
        title: "Older meeting",
        summary: "Old decision",
        transcript: "An older transcript."),
      meetingNote(
        id: latestNoteID,
        title: "Latest meeting",
        summary: "Ship the typed query foundation.",
        transcript: "Alice will add the executor tests."),
      SyncedNote(
        id: unreadableNoteID,
        kind: .meeting,
        title: "Unreadable meeting",
        body: "",
        sourceDeviceID: "test"),
      meetingNote(
        id: futureNoteID,
        title: "Future completed meeting",
        summary: "Must not be selected yet.",
        transcript: "Future transcript."),
    ]
    let meetings = [
      SyncedMeetingSession(
        noteID: olderNoteID,
        title: "Older meeting",
        sourceDeviceID: "test",
        state: .completed,
        startedAt: date("2026-08-09T09:00:00Z"),
        endedAt: date("2026-08-09T10:00:00Z"),
        // Edited after every other record; this must not make it latest by occurrence.
        updatedAt: date("2026-08-10T11:59:00Z")),
      SyncedMeetingSession(
        noteID: latestNoteID,
        title: "Latest meeting",
        sourceDeviceID: "test",
        state: .completed,
        startedAt: date("2026-08-10T10:00:00Z"),
        endedAt: date("2026-08-10T11:00:00Z"),
        updatedAt: date("2026-08-10T11:01:00Z")),
      SyncedMeetingSession(
        noteID: unreadableNoteID,
        title: "Unreadable meeting",
        sourceDeviceID: "test",
        state: .completed,
        startedAt: date("2026-08-10T11:10:00Z"),
        endedAt: date("2026-08-10T11:20:00Z"),
        updatedAt: date("2026-08-10T11:20:00Z")),
      SyncedMeetingSession(
        noteID: futureNoteID,
        title: "Future completed meeting",
        sourceDeviceID: "test",
        state: .completed,
        startedAt: date("2026-08-10T12:30:00Z"),
        endedAt: date("2026-08-10T13:00:00Z"),
        updatedAt: date("2026-08-10T13:00:00Z")),
      SyncedMeetingSession(
        noteID: latestNoteID,
        title: "Failed newer meeting",
        sourceDeviceID: "test",
        state: .failed,
        startedAt: date("2026-08-10T11:30:00Z"),
        endedAt: date("2026-08-10T11:40:00Z"),
        updatedAt: date("2026-08-10T11:40:00Z")),
    ]
    let executor = try executor(
      data: IAgentDataSnapshot(notes: notes, meetings: meetings),
      context: context
    )
    let page = try await executor.execute(
      AskMeetingQuery.latestCompletedReadable(queryID: "latest-meeting"))

    XCTAssertEqual(page.totalMatched, 2)
    XCTAssertEqual(page.items.map(\.title), ["Latest meeting"])
    XCTAssertEqual(page.items.first?.startsAt, date("2026-08-10T10:00:00Z"))
    XCTAssertEqual(
      page.items.first?.evidence.map(\.anchor),
      ["summary:0", "transcript:0"]
    )
    XCTAssertTrue(
      page.items.first?.evidence.first?.excerpt.contains("typed query foundation") == true)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(page)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    XCTAssertEqual(try decoder.decode(AskQueryPage.self, from: data), page)
  }

  func testNoteExecutorDeduplicatesAndExcludesMeetingLinkedOrDeletedContent() async throws {
    let context = temporalContext("2026-08-10T12:00:00Z")
    let noteID = UUID()
    let linkedNoteID = UUID()
    let deletedAt = date("2026-08-10T10:00:00Z")
    let notes = [
      SyncedNote(
        id: noteID,
        title: "Old launch notes",
        body: "Stale launch draft",
        createdAt: date("2026-08-01T08:00:00Z"),
        updatedAt: date("2026-08-09T08:00:00Z"),
        sourceDeviceID: "test"),
      SyncedNote(
        id: noteID,
        title: "Launch notes",
        body: "The Simulator retrieval fixture is ready.",
        createdAt: date("2026-08-01T08:00:00Z"),
        updatedAt: date("2026-08-10T09:00:00Z"),
        sourceDeviceID: "test"),
      SyncedNote(
        id: linkedNoteID,
        kind: .note,
        title: "Launch meeting backing document",
        body: "Must be represented only through the meeting provider.",
        createdAt: date("2026-08-10T08:00:00Z"),
        updatedAt: date("2026-08-10T10:00:00Z"),
        sourceDeviceID: "test"),
      SyncedNote(
        title: "Deleted launch secret",
        body: "Must never be returned.",
        createdAt: date("2026-08-10T08:00:00Z"),
        updatedAt: deletedAt,
        deletedAt: deletedAt,
        sourceDeviceID: "test"),
    ]
    let meeting = SyncedMeetingSession(
      noteID: linkedNoteID,
      title: "Launch meeting",
      sourceDeviceID: "test",
      state: .completed,
      startedAt: date("2026-08-10T08:00:00Z"),
      endedAt: date("2026-08-10T09:00:00Z"),
      updatedAt: date("2026-08-10T09:00:00Z")
    )
    let executor = try executor(
      data: IAgentDataSnapshot(notes: notes, meetings: [meeting]),
      context: context
    )
    let page = try await executor.execute(
      AskNoteQuery(
        queryID: "launch-note",
        text: "launch",
        time: AskQueryTimeFilter(field: .updated, preset: .today),
        sort: .updatedDesc,
        content: .preview
      ))

    XCTAssertEqual(page.totalMatched, 1)
    XCTAssertEqual(page.items.map(\.title), ["Launch notes"])
    XCTAssertEqual(page.items.first?.source.entityID, noteID.uuidString.lowercased())
    XCTAssertTrue(page.items.first?.evidence.first?.excerpt.contains("fixture is ready") == true)
    XCTAssertFalse(page.items.first?.evidence.first?.excerpt.contains("Stale") == true)
  }

  func testCodexExecutorUsesOnlySafeVisibleOutputsAndExactFilters() async throws {
    let context = temporalContext("2026-08-10T12:00:00Z")
    let safeThread = SyncedCodexThread(
      id: "task-safe",
      projectName: "iAgent",
      title: "Retrieval harness",
      activity: "Waiting for the Simulator fixture review.",
      activityHistory: [
        SyncedCodexActivity(
          id: "legacy-reasoning",
          text: "HIDDEN LEGACY REASONING MUST NOT LEAK",
          occurredAt: date("2026-08-10T09:15:00Z"))
      ],
      visibleOutputs: [
        SyncedCodexOutputExcerpt(
          id: "output-1",
          text: "Old visible output",
          occurredAt: date("2026-08-10T09:00:00Z")),
        SyncedCodexOutputExcerpt(
          id: "output-1",
          text: "Simulator fixture ready for integrated review.",
          occurredAt: date("2026-08-10T09:30:00Z")),
        SyncedCodexOutputExcerpt(
          id: "output-yesterday",
          text: "Yesterday's visible result",
          occurredAt: date("2026-08-09T09:30:00Z")),
      ],
      state: .needsApproval,
      modes: [.plan],
      createdAt: date("2026-08-01T08:00:00Z"),
      updatedAt: date("2026-08-10T10:00:00Z")
    )
    let unrelated = SyncedCodexThread(
      id: "task-other",
      projectName: "Other",
      title: "Simulator fixture elsewhere",
      activity: "Completed",
      visibleOutputs: [
        SyncedCodexOutputExcerpt(
          id: "output-other",
          text: "Simulator fixture from another project",
          occurredAt: date("2026-08-10T10:00:00Z"))
      ],
      state: .completed,
      modes: [.goal],
      createdAt: date("2026-08-01T08:00:00Z"),
      updatedAt: date("2026-08-10T10:00:00Z")
    )
    let executor = try executor(
      data: IAgentDataSnapshot(codexThreads: [safeThread, unrelated]),
      context: context
    )
    let page = try await executor.execute(
      AskCodexQuery(
        queryID: "codex-safe-output",
        text: "Simulator fixture",
        states: [.needsApproval],
        modes: [.plan],
        projectNames: ["iAgent"],
        time: AskQueryTimeFilter(field: .visibleOutput, preset: .today),
        sort: .updatedDesc,
        content: .visibleOutputs
      ))

    XCTAssertEqual(page.totalMatched, 1)
    XCTAssertEqual(page.items.map(\.title), ["Retrieval harness"])
    XCTAssertEqual(page.items.first?.status, .needsApproval)
    XCTAssertEqual(page.items.first?.evidence.map(\.anchor), ["visible_output:output-1"])
    let excerpts = page.items.flatMap(\.evidence).map(\.excerpt).joined(separator: "\n")
    XCTAssertTrue(excerpts.contains("integrated review"))
    XCTAssertFalse(excerpts.contains("Old visible output"))
    XCTAssertFalse(excerpts.contains("HIDDEN LEGACY REASONING"))
    XCTAssertFalse(excerpts.contains("Yesterday's visible result"))
  }

  func testBudgetExhaustionIsHardAndDoesNotIssueUnusableCursor() async throws {
    let context = temporalContext("2026-08-10T09:00:00Z")
    let executor = try executor(
      data: IAgentDataSnapshot(todos: [
        SyncedTodo(title: "One", updatedAt: date("2026-08-10T08:00:00Z")),
        SyncedTodo(title: "Two", updatedAt: date("2026-08-10T07:00:00Z")),
      ]),
      context: context,
      budget: AskQueryBudget(
        maximumCalls: 1,
        maximumCallsPerDomain: 1,
        maximumPagesPerDomain: 1,
        maximumRecordsPerPage: 1,
        maximumTotalRecords: 1,
        maximumEvidencePassages: 2,
        maximumEvidenceCharacters: 1_000
      )
    )
    let recorder = LockedProgressRecorder()
    let query = AskTodoQuery(
      queryID: "budgeted",
      sort: .updatedDesc,
      limit: 1
    )
    let page = try await executor.execute(query) { recorder.append($0) }

    XCTAssertEqual(page.items.map(\.title), ["One"])
    XCTAssertTrue(page.hasMore)
    XCTAssertNil(page.nextCursor)
    XCTAssertTrue(page.warnings.contains(.resultBudgetReached))
    XCTAssertEqual(page.budgetUsage.calls, 1)
    XCTAssertEqual(page.budgetUsage.records, 1)
    XCTAssertEqual(
      recorder.values.map(\.phase),
      [.validated, .executing, .pageProduced, .completed]
    )
    XCTAssertEqual(recorder.values.map(\.sequence), [1, 2, 3, 4])

    do {
      _ = try await executor.execute(query)
      XCTFail("Expected the hard call budget to reject another query")
    } catch {
      XCTAssertEqual((error as? AskQueryFailure)?.code, .budgetExceeded)
    }
  }

  // MARK: Helpers

  private func executor(
    data: IAgentDataSnapshot,
    context: AskTemporalContext,
    budget: AskQueryBudget = AskQueryBudget()
  ) throws -> AskPinnedQueryExecutor {
    try AskPinnedQueryExecutor(
      snapshot: AskDataSnapshot(data: data, contextAsOf: context.contextAsOf),
      snapshotID: "snapshot-tests",
      temporalContext: context,
      budget: budget
    )
  }

  private func temporalContext(_ value: String) -> AskTemporalContext {
    AskTemporalContext(
      contextAsOf: date(value),
      timeZoneIdentifier: "Europe/Athens",
      localeIdentifier: "en_GR",
      calendarIdentifier: "gregorian",
      firstWeekday: 2
    )
  }

  private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
  }

  private func calendarEvent(
    id: String,
    sourceIdentifier: String? = nil,
    title: String,
    start: Date,
    end: Date,
    updated: Date
  ) -> SyncedCalendarEvent {
    SyncedCalendarEvent(
      id: id,
      sourceIdentifier: sourceIdentifier,
      title: title,
      startDate: start,
      endDate: end,
      isAllDay: false,
      calendarTitle: "Work",
      location: nil,
      notes: "Private calendar details",
      linkURLs: [],
      updatedAt: updated
    )
  }

  private func meetingNote(
    id: UUID,
    title: String,
    summary: String,
    transcript: String
  ) -> SyncedNote {
    SyncedNote(
      id: id,
      kind: .meeting,
      title: title,
      body: "## Summary\n\n\(summary)\n\n## Transcript\n\n\(transcript)",
      createdAt: date("2026-08-01T08:00:00Z"),
      updatedAt: date("2026-08-10T08:00:00Z"),
      sourceDeviceID: "test"
    )
  }

  private func assertStrictSchema(_ schema: [String: Any], path: String) {
    let rawType = schema["type"]
    let scalarType = rawType as? String
    if scalarType == "object" {
      XCTAssertEqual(schema["additionalProperties"] as? Bool, false, path)
      let properties = schema["properties"] as? [String: Any] ?? [:]
      let required = Set(schema["required"] as? [String] ?? [])
      XCTAssertEqual(required, Set(properties.keys), path)
      for (name, value) in properties {
        guard let child = value as? [String: Any] else {
          XCTFail("\(path).\(name) is not a schema object")
          continue
        }
        assertStrictSchema(child, path: "\(path).\(name)")
      }
    } else if scalarType == "array" {
      guard let child = schema["items"] as? [String: Any] else {
        XCTFail("\(path).items is not a schema object")
        return
      }
      assertStrictSchema(child, path: "\(path).items")
    } else if let union = rawType as? [String] {
      XCTAssertTrue(
        Set(union) == Set(["string", "null"])
          || Set(union) == Set(["boolean", "null"]), path)
    } else {
      XCTAssertTrue(["string", "integer", "boolean"].contains(scalarType ?? ""), path)
    }
  }
}

private final class LockedProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [AskQueryProgress] = []

  func append(_ value: AskQueryProgress) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  var values: [AskQueryProgress] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
