import Foundation
import XCTest

@testable import iAgentCore

final class AskIAgentKnowledgeTests: XCTestCase {
  func testQueryPlannerParsesSourceStatusCountAndRelativeWeekDeterministically() throws {
    let calendar = utcCalendar()
    let reference = try date(2026, 8, 7, 14)

    let plan = AskQueryPlanner.plan(
      "How many overdue todos are there this week?",
      referenceDate: reference,
      calendar: calendar
    )

    XCTAssertEqual(plan.sourceKinds, [.todo])
    XCTAssertEqual(plan.statusFilters, [.overdue])
    XCTAssertTrue(plan.requestsExactCount)
    XCTAssertEqual(plan.terms, [])
    XCTAssertEqual(plan.dateRange?.start, try date(2026, 8, 3))
    XCTAssertEqual(plan.dateRange?.end, try date(2026, 8, 10))
  }

  func testQueryPlannerDistinguishesScheduledMeetingsFromRecordedMeetingContent() throws {
    let calendar = utcCalendar()
    let reference = try date(2026, 8, 7, 14)

    let schedule = AskQueryPlanner.plan(
      "What meetings do I have tomorrow?",
      referenceDate: reference,
      calendar: calendar
    )
    XCTAssertEqual(schedule.sourceKinds, [.calendar])
    XCTAssertEqual(schedule.dateRange?.start, try date(2026, 8, 8))
    XCTAssertEqual(schedule.dateRange?.end, try date(2026, 8, 9))

    let transcript = AskQueryPlanner.plan(
      "Find meeting transcripts from yesterday",
      referenceDate: reference,
      calendar: calendar
    )
    XCTAssertEqual(transcript.sourceKinds, [.meeting])
    XCTAssertEqual(transcript.dateRange?.start, try date(2026, 8, 6))
    XCTAssertEqual(transcript.dateRange?.end, try date(2026, 8, 7))

    let discussion = AskQueryPlanner.plan(
      "What did we decide in the launch meeting?",
      referenceDate: reference,
      calendar: calendar
    )
    XCTAssertEqual(discussion.sourceKinds, [.meeting])
    XCTAssertEqual(discussion.terms, ["launch"])
  }

  func testResearchTreatsNeedToCompleteAsOpenActionableWork() throws {
    let now = try date(2026, 8, 7, 12)
    let openTodo = SyncedTodo(
      title: "Ship the release build",
      isCompleted: false,
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now
    )
    let completedTodo = SyncedTodo(
      title: "Archive the old release",
      isCompleted: true,
      completedAt: now,
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now
    )
    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(
        data: IAgentDataSnapshot(todos: [completedTodo, openTodo]),
        contextAsOf: now
      ))

    let plan = AskResearchPlanner.plan(
      "What tasks do I need to complete?",
      referenceDate: now,
      calendar: utcCalendar()
    )
    let todoSearch = try XCTUnwrap(
      plan.searches.first { $0.plan.sourceKinds == [.todo] }
    )
    let result = AskKnowledgeResearch.search(plan: plan, in: corpus)
    let returnedIDs = Set(result.evidence.map(\.chunk.source.entityID))

    XCTAssertEqual(plan.intent, .actionableWork)
    XCTAssertEqual(todoSearch.plan.statusFilters, [.open])
    XCTAssertEqual(todoSearch.plan.terms, [])
    XCTAssertTrue(plan.searches.allSatisfy { !$0.plan.statusFilters.contains(.completed) })
    XCTAssertTrue(returnedIDs.contains(openTodo.id.uuidString.lowercased()))
    XCTAssertFalse(returnedIDs.contains(completedTodo.id.uuidString.lowercased()))
  }

  func testExplicitCodexTasksDoNotFanOutToTodos() throws {
    let now = try date(2026, 8, 7, 12)

    let plan = AskResearchPlanner.plan(
      "Which Codex tasks need attention?",
      referenceDate: now,
      calendar: utcCalendar()
    )

    XCTAssertEqual(plan.intent, .actionableWork)
    XCTAssertEqual(plan.searchedSourceKinds, [.codex])
    XCTAssertEqual(plan.searches.map(\.plan.sourceKinds), [[.codex]])
    XCTAssertTrue(plan.searches.allSatisfy { $0.plan.statusFilters == [.active] })
  }

  func testRecentUpdatesResearchesEveryKnownDataTypeIndependently() throws {
    let now = try date(2026, 8, 7, 12)
    let plan = AskResearchPlanner.plan(
      "What are my recent iAgent updates?",
      referenceDate: now,
      calendar: utcCalendar()
    )

    XCTAssertEqual(plan.intent, .recentUpdates)
    XCTAssertEqual(plan.searchedSourceKinds, Set(AskSourceKind.allCases))
    XCTAssertEqual(plan.searches.count, AskSourceKind.allCases.count)
    XCTAssertTrue(plan.searches.allSatisfy { $0.plan.sourceKinds.count == 1 })
    XCTAssertTrue(plan.searches.allSatisfy { $0.plan.temporalField == .updated })
    XCTAssertTrue(plan.searches.allSatisfy { $0.plan.terms == ["iagent"] })
  }

  func testResearchReportsEachSourceSpecificSearch() throws {
    let now = try date(2026, 8, 7, 12)
    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(data: IAgentDataSnapshot(), contextAsOf: now)
    )
    let plan = AskResearchPlanner.plan(
      "What are my recent iAgent updates?",
      referenceDate: now,
      calendar: utcCalendar()
    )
    let recorder = SearchSourceRecorder()

    _ = AskKnowledgeResearch.search(
      plan: plan,
      in: corpus,
      onSearch: { recorder.append($0) }
    )

    XCTAssertEqual(Set(recorder.values), Set(AskSourceKind.allCases))
  }

  func testMeetingNotesRouteToMeetingSummariesAndTranscripts() throws {
    let now = try date(2026, 8, 7, 12)
    let plan = AskResearchPlanner.plan(
      "What do my meeting notes say about launch?",
      referenceDate: now,
      calendar: utcCalendar()
    )

    XCTAssertEqual(plan.intent, .meetingRecall)
    XCTAssertEqual(plan.searchedSourceKinds, [.meeting])
    XCTAssertEqual(plan.searches.map(\.plan.sourceKinds), [[.meeting]])
    XCTAssertEqual(plan.searches.first?.plan.terms, ["launch"])
  }

  func testFollowUpCanOverrideSourceAndStatusWithoutLosingSubject() throws {
    let now = try date(2026, 8, 7, 12)
    let sourceChange = AskResearchPlanner.plan(
      "What about my notes?",
      recentUserQueries: ["What changed about iAgent in Codex?"],
      referenceDate: now,
      calendar: utcCalendar()
    )
    let statusChange = AskResearchPlanner.plan(
      "Which are unfinished?",
      recentUserQueries: ["Show my todos"],
      referenceDate: now,
      calendar: utcCalendar()
    )

    XCTAssertEqual(sourceChange.intent, .recentUpdates)
    XCTAssertEqual(sourceChange.searchedSourceKinds, [.note])
    XCTAssertEqual(sourceChange.searches.first?.plan.terms, ["iagent"])
    XCTAssertEqual(statusChange.intent, .actionableWork)
    XCTAssertEqual(statusChange.searchedSourceKinds, [.todo])
    XCTAssertEqual(statusChange.searches.first?.plan.statusFilters, [.open])
  }

  func testResearchKeepsExplicitCompletedTaskPhrasingCompleted() throws {
    let now = try date(2026, 8, 7, 12)
    let openTodo = SyncedTodo(
      title: "Prepare launch notes",
      isCompleted: false,
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now
    )
    let completedTodo = SyncedTodo(
      title: "Upload launch screenshots",
      isCompleted: true,
      completedAt: now,
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now
    )
    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(
        data: IAgentDataSnapshot(todos: [openTodo, completedTodo]),
        contextAsOf: now
      ))

    let plan = AskResearchPlanner.plan(
      "Which tasks have I completed?",
      referenceDate: now,
      calendar: utcCalendar()
    )
    let result = AskKnowledgeResearch.search(plan: plan, in: corpus)
    let returnedIDs = Set(result.evidence.map(\.chunk.source.entityID))

    XCTAssertEqual(plan.intent, .completedWork)
    XCTAssertEqual(plan.searchedSourceKinds, [.todo])
    XCTAssertTrue(plan.searches.allSatisfy { $0.plan.statusFilters == [.completed] })
    XCTAssertTrue(returnedIDs.contains(completedTodo.id.uuidString.lowercased()))
    XCTAssertFalse(returnedIDs.contains(openTodo.id.uuidString.lowercased()))
  }

  func testDailyOverviewResearchUsesOnlyAgendaSourcesAndStructuredStates() throws {
    let now = try date(2026, 8, 7, 12)
    let openTodo = SyncedTodo(
      title: "Review TestFlight feedback",
      isCompleted: false,
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now
    )
    let completedTodo = SyncedTodo(
      title: "Publish yesterday's build",
      isCompleted: true,
      completedAt: now,
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now
    )
    let unrelatedNote = SyncedNote(
      title: "Private research scratchpad",
      body: "This note was edited today but is not part of the user's agenda.",
      createdAt: now,
      updatedAt: now,
      sourceDeviceID: "test"
    )
    let todayEvent = SyncedCalendarEvent(
      id: "today-event",
      title: "Product review",
      startDate: now.addingTimeInterval(3_600),
      endDate: now.addingTimeInterval(7_200),
      isAllDay: false,
      calendarTitle: "Work",
      location: nil,
      linkURLs: [],
      updatedAt: now.addingTimeInterval(-86_400)
    )
    let runningCodex = SyncedCodexThread(
      id: "running-codex",
      projectName: "iAgent",
      title: "Improve Ask retrieval",
      activity: "Running regression tests",
      state: .running,
      modes: [],
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now
    )
    let completedCodex = SyncedCodexThread(
      id: "completed-codex",
      projectName: "iAgent",
      title: "Finished unrelated refactor",
      activity: "Done",
      state: .completed,
      modes: [],
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now
    )
    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(
        data: IAgentDataSnapshot(
          notes: [unrelatedNote],
          todos: [completedTodo, openTodo],
          codexThreads: [completedCodex, runningCodex],
          calendarEvents: [todayEvent]
        ),
        contextAsOf: now
      ))

    let plan = AskResearchPlanner.plan(
      "What do I have today?",
      referenceDate: now,
      calendar: utcCalendar()
    )
    let result = AskKnowledgeResearch.search(plan: plan, in: corpus)
    let returnedIDs = Set(result.evidence.map(\.chunk.source.entityID))

    XCTAssertEqual(plan.intent, .dailyOverview)
    XCTAssertEqual(plan.searchedSourceKinds, [.todo, .calendar, .codex])
    XCTAssertEqual(
      result.groupedSearchProgress.map(\.sourceKind),
      [.calendar, .todo, .codex]
    )
    XCTAssertEqual(result.groupedSearchProgress.map(\.totalMatches), [1, 1, 1])
    XCTAssertEqual(Set(result.evidence.map(\.chunk.source.kind)), [.todo, .calendar, .codex])
    XCTAssertTrue(returnedIDs.contains(openTodo.id.uuidString.lowercased()))
    XCTAssertTrue(returnedIDs.contains(todayEvent.id))
    XCTAssertTrue(returnedIDs.contains(runningCodex.id))
    XCTAssertFalse(returnedIDs.contains(completedTodo.id.uuidString.lowercased()))
    XCTAssertFalse(returnedIDs.contains(completedCodex.id))
    XCTAssertFalse(returnedIDs.contains(unrelatedNote.id.uuidString.lowercased()))
  }

  func testDayPlanningFansOutAcrossDecisionRelevantSourcesWithoutLiteralPromptTerms() throws {
    let now = try date(2026, 8, 7, 12)
    let plan = AskResearchPlanner.plan(
      "Plan my day",
      referenceDate: now,
      calendar: utcCalendar()
    )

    XCTAssertEqual(plan.intent, .dailyPlanning)
    XCTAssertEqual(plan.searchedSourceKinds, Set(AskSourceKind.allCases))

    let calendarSearch = try XCTUnwrap(
      plan.searches.first { $0.plan.sourceKinds == [.calendar] }
    )
    XCTAssertEqual(calendarSearch.plan.terms, [])
    XCTAssertEqual(calendarSearch.plan.temporalField, .occurrence)
    XCTAssertEqual(calendarSearch.plan.dateRange?.start, try date(2026, 8, 7))
    XCTAssertEqual(calendarSearch.plan.dateRange?.end, try date(2026, 8, 8))

    let todoSearches = plan.searches.filter { $0.plan.sourceKinds == [.todo] }
    XCTAssertEqual(todoSearches.count, 4)
    XCTAssertTrue(todoSearches.allSatisfy { $0.plan.terms.isEmpty })
    XCTAssertTrue(todoSearches.contains { $0.id == "plan-overdue-todos" })
    XCTAssertTrue(todoSearches.contains { $0.id == "plan-due-today-todos" })
    XCTAssertTrue(todoSearches.contains { $0.id == "plan-starred-todos" })
    XCTAssertTrue(todoSearches.contains { $0.id == "plan-open-todos" })

    let codexSearch = try XCTUnwrap(plan.searches.first { $0.plan.sourceKinds == [.codex] })
    XCTAssertEqual(codexSearch.plan.statusFilters, [.active])

    let meetingSearch = try XCTUnwrap(
      plan.searches.first { $0.plan.sourceKinds == [.meeting] }
    )
    XCTAssertTrue(meetingSearch.plan.terms.contains("action"))
    XCTAssertEqual(meetingSearch.plan.temporalField, .updated)

    let noteSearch = try XCTUnwrap(plan.searches.first { $0.plan.sourceKinds == [.note] })
    XCTAssertTrue(noteSearch.plan.terms.contains("priority"))
    XCTAssertEqual(noteSearch.plan.temporalField, .updated)
  }

  func testTodoSourceAliasesRecognizeNaturalHyphenatedAndPossessiveSpellings() throws {
    let now = try date(2026, 8, 7, 12)
    for prompt in [
      "Show my todo",
      "Show my to-do",
      "Show my to do list",
      "Include my to do's",
      "Include my to-do’s",
    ] {
      let plan = AskQueryPlanner.plan(
        prompt,
        referenceDate: now,
        calendar: utcCalendar()
      )

      XCTAssertEqual(plan.sourceKinds, [.todo], prompt)
    }

    // The verb phrase must remain broad rather than accidentally becoming a todo source alias.
    let verbPhrase = AskQueryPlanner.plan(
      "What should I plan to do this week?",
      referenceDate: now,
      calendar: utcCalendar()
    )
    XCTAssertTrue(verbPhrase.sourceKinds.isEmpty)
  }

  func testScreenshotPlanningPromptsUseBroadStructuredRetrievalAndReturnFixtureRecords() throws {
    let now = try date(2026, 8, 7, 12)
    let corpus = broadPlanningCorpus(now: now)
    let cases: [(prompt: String, intent: AskResearchIntent)] = [
      ("What should I build today?", .dailyPlanning),
      ("What are the three top things that I should plan to do this week?", .priorities),
      ("What should I accomplish for today? Include my to do's.", .dailyPlanning),
    ]

    for testCase in cases {
      let plan = AskResearchPlanner.plan(
        testCase.prompt,
        referenceDate: now,
        calendar: utcCalendar()
      )
      let result = AskKnowledgeResearch.search(plan: plan, in: corpus)

      XCTAssertEqual(plan.intent, testCase.intent, testCase.prompt)
      XCTAssertEqual(plan.searchedSourceKinds, Set(AskSourceKind.allCases), testCase.prompt)
      XCTAssertTrue(
        plan.searches.allSatisfy {
          $0.plan.terms.isEmpty
            || $0.plan.terms.allSatisfy { [
              "action", "deadline", "follow", "next", "owner", "priority",
            ].contains($0) }
        },
        "Broad decision prompts must not require literal output words: \(testCase.prompt)"
      )
      XCTAssertEqual(
        Set(result.groupedSearchProgress.filter { $0.totalMatches > 0 }.map(\.sourceKind)),
        Set(AskSourceKind.allCases),
        testCase.prompt
      )
      XCTAssertEqual(Set(result.evidence.map(\.chunk.source.kind)), Set(AskSourceKind.allCases))
    }
  }

  func testWeeklyPriorityPromptUsesRequestedWeekForCalendarInsteadOfHardCodedNextDay() throws {
    let now = try date(2026, 8, 7, 12)
    let plan = AskResearchPlanner.plan(
      "What are the three top things that I should plan to do this week?",
      referenceDate: now,
      calendar: utcCalendar()
    )
    let calendarSearch = try XCTUnwrap(
      plan.searches.first { $0.id == "priority-calendar" }
    )

    XCTAssertEqual(plan.intent, .priorities)
    XCTAssertEqual(calendarSearch.plan.terms, [])
    XCTAssertEqual(calendarSearch.plan.temporalField, .occurrence)
    XCTAssertEqual(calendarSearch.plan.dateRange?.start, try date(2026, 8, 3))
    XCTAssertEqual(calendarSearch.plan.dateRange?.end, try date(2026, 8, 10))
  }

  func testDayPlanningGroupsCoverageIntoFiveUniqueSourceRowsAndReportsProgressInOrder() throws {
    let now = try date(2026, 8, 7, 12)
    let plan = AskResearchPlanner.plan(
      "Plan my day",
      referenceDate: now,
      calendar: utcCalendar()
    )
    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(data: IAgentDataSnapshot(), contextAsOf: now)
    )
    let recorder = SearchSourceRecorder()

    let result = AskKnowledgeResearch.search(
      plan: plan,
      in: corpus,
      onProgress: { recorder.append($0.sourceKind) }
    )

    // The planner intentionally uses several independent todo lanes, but the bounded model/relay
    // contract and visible progress each expose one row per data domain.
    XCTAssertGreaterThan(result.coverage.count, AskSourceKind.allCases.count)
    XCTAssertEqual(result.groupedCoverage.count, AskSourceKind.allCases.count)
    XCTAssertEqual(
      result.groupedCoverage.map(\.sourceKind),
      [.calendar, .todo, .codex, .meeting, .note]
    )
    XCTAssertEqual(Set(result.groupedCoverage.map(\.sourceKind)).count, 5)
    XCTAssertTrue(result.groupedCoverage.allSatisfy { $0.queryID == "grouped-\($0.sourceKind.rawValue)" })
    XCTAssertEqual(recorder.values, [.calendar, .todo, .codex, .meeting, .note])
  }

  func testExplanationFollowUpsRetainThePlanWithoutPollutingSearchTerms() throws {
    let now = try date(2026, 8, 7, 12)
    for followUp in [
      "Why these things?", "Why this order?", "Why is this important?",
      "What’s important about them?", "Which of these can I defer?",
    ] {
      let plan = AskResearchPlanner.plan(
        followUp,
        recentUserQueries: ["Plan my day"],
        referenceDate: now,
        calendar: utcCalendar()
      )

      XCTAssertEqual(plan.intent, .explanation, followUp)
      XCTAssertTrue(plan.resolvedQuery.contains("Plan my day"), followUp)
      XCTAssertEqual(
        plan.searches.first { $0.plan.sourceKinds == [.calendar] }?.plan.terms,
        [],
        followUp
      )
      XCTAssertEqual(
        plan.searches.first { $0.plan.sourceKinds == [.todo] }?.plan.terms,
        [],
        followUp
      )
      XCTAssertFalse(plan.searches.flatMap(\.plan.terms).contains("why"), followUp)
      XCTAssertFalse(plan.searches.flatMap(\.plan.terms).contains("things"), followUp)
      XCTAssertFalse(plan.searches.flatMap(\.plan.terms).contains("order"), followUp)
      XCTAssertFalse(plan.searches.flatMap(\.plan.terms).contains("defer"), followUp)
      XCTAssertFalse(plan.searches.flatMap(\.plan.terms).contains("important"), followUp)
    }
  }

  func testExplanationChainUsesTheLastSubstantiveRequestAsItsAnchor() throws {
    let now = try date(2026, 8, 7, 12)
    let plan = AskResearchPlanner.plan(
      "What’s important about them?",
      recentUserQueries: ["Plan my day", "Why these things?"],
      referenceDate: now,
      calendar: utcCalendar()
    )

    XCTAssertEqual(plan.intent, .explanation)
    XCTAssertTrue(plan.resolvedQuery.hasPrefix("Plan my day"))
    XCTAssertFalse(plan.resolvedQuery.contains("Why these things?"))
    XCTAssertTrue(plan.searches.allSatisfy { $0.plan.terms.isEmpty })
  }

  func testDayPlanningHonorsAnExplicitCalendarOnlyScope() throws {
    let now = try date(2026, 8, 7, 12)
    for prompt in [
      "Plan my day using only my calendar",
      "Plan my day based on my calendar",
      "Plan my day around my calendar",
    ] {
      let plan = AskResearchPlanner.plan(
        prompt,
        referenceDate: now,
        calendar: utcCalendar()
      )

      XCTAssertEqual(plan.intent, .dailyPlanning, prompt)
      XCTAssertEqual(plan.searchedSourceKinds, [.calendar], prompt)
      XCTAssertEqual(plan.searches.map(\.id), ["plan-calendar"], prompt)
      XCTAssertEqual(plan.searches.first?.plan.terms, [], prompt)
    }
  }

  func testPlanningReservesCoverageForAnOlderOverdueTodo() throws {
    let now = try date(2026, 8, 7, 12)
    let overdue = SyncedTodo(
      title: "Submit overdue expenses",
      dueDate: now.addingTimeInterval(-3 * 86_400),
      createdAt: now.addingTimeInterval(-30 * 86_400),
      updatedAt: now.addingTimeInterval(-20 * 86_400)
    )
    let ordinary = (0..<8).map { index in
      SyncedTodo(
        title: "Recent task \(index)",
        createdAt: now,
        updatedAt: now.addingTimeInterval(Double(-index))
      )
    }
    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(
        data: IAgentDataSnapshot(todos: ordinary + [overdue]),
        contextAsOf: now
      ))
    let plan = AskResearchPlanner.plan(
      "Plan my day",
      referenceDate: now,
      calendar: utcCalendar()
    )
    let result = AskKnowledgeResearch.search(plan: plan, in: corpus, limit: 5)

    XCTAssertTrue(
      result.evidence.map(\.chunk.source.entityID)
        .contains(overdue.id.uuidString.lowercased())
    )
  }

  func testSummarizeLatestMeetingRoutesToMeetingRecall() throws {
    let now = try date(2026, 8, 7, 12)
    let plan = AskResearchPlanner.plan(
      "Summarize my latest meeting",
      referenceDate: now,
      calendar: utcCalendar()
    )

    XCTAssertEqual(plan.intent, .meetingRecall)
    XCTAssertEqual(plan.searchedSourceKinds, [.meeting])
    let search = try XCTUnwrap(plan.searches.first)
    XCTAssertEqual(search.id, "latest-meeting-content")
    XCTAssertEqual(search.plan.terms, [])
    XCTAssertEqual(search.plan.temporalField, .occurrence)
    XCTAssertEqual(search.selection, .latestCompletedOccurrence)
    XCTAssertEqual(search.maximumDocuments, 1)
    XCTAssertEqual(search.maximumChunksPerDocument, 6)
    XCTAssertEqual(search.resultLimit, 6)
  }

  func testLatestMeetingChoosesNewestOccurrenceInsteadOfOlderRecentlyEditedRecord() throws {
    let now = try date(2026, 8, 9, 12)
    let olderOccurrence = try date(2026, 8, 1, 10)
    let latestOccurrence = try date(2026, 8, 8, 16)
    let activeOccurrence = try date(2026, 8, 9, 9)
    let olderRecentEdit = try date(2026, 8, 9, 11)
    let latestEdit = try date(2026, 8, 8, 17)
    let corpus = AskKnowledgeCorpus(
      contextAsOf: now,
      documents: [],
      chunks: [
        meetingChunk(
          id: "older-summary",
          documentID: "meeting:older",
          entityID: "older",
          title: "Older meeting",
          text: "Older meeting summary with decisions.",
          anchor: "summary:0",
          occurrence: olderOccurrence,
          updatedAt: olderRecentEdit
        ),
        meetingChunk(
          id: "older-transcript",
          documentID: "meeting:older",
          entityID: "older",
          title: "Older meeting",
          text: "Older meeting transcript with discussion.",
          anchor: "transcript:0",
          occurrence: olderOccurrence,
          updatedAt: olderRecentEdit
        ),
        meetingChunk(
          id: "latest-summary",
          documentID: "meeting:latest",
          entityID: "latest",
          title: "Latest meeting",
          text: "Latest meeting summary with current decisions.",
          anchor: "summary:0",
          occurrence: latestOccurrence,
          updatedAt: latestEdit
        ),
        meetingChunk(
          id: "latest-transcript",
          documentID: "meeting:latest",
          entityID: "latest",
          title: "Latest meeting",
          text: "Latest meeting transcript with current discussion.",
          anchor: "transcript:0",
          occurrence: latestOccurrence,
          updatedAt: latestEdit
        ),
        meetingChunk(
          id: "active-transcript",
          documentID: "meeting:active",
          entityID: "active",
          title: "Active recording",
          text: "This meeting is still recording and must not be called the latest completed meeting.",
          anchor: "transcript:0",
          occurrence: activeOccurrence,
          updatedAt: activeOccurrence,
          status: .recording
        ),
      ]
    )
    let plan = AskResearchPlanner.plan(
      "Summarize my latest meeting",
      referenceDate: now,
      calendar: utcCalendar()
    )

    let result = AskKnowledgeResearch.search(
      plan: plan,
      in: corpus,
      limit: 6,
      maximumPerSourceKind: 6,
      maximumPerDocument: 2
    )

    XCTAssertEqual(Set(result.evidence.map(\.chunk.documentID)), ["meeting:latest"])
    XCTAssertEqual(result.evidence.map(\.chunk.source.anchor), ["summary:0", "transcript:0"])
    XCTAssertEqual(result.coverage.first?.totalMatches, 3)
    XCTAssertEqual(result.searchProgress.first?.items.map(\.id), ["meeting:latest"])
  }

  func testPriorityResearchBroadensToAnUnstarredOpenTodoWithoutADueDate() throws {
    let now = try date(2026, 8, 7, 12)
    let openTodo = SyncedTodo(
      title: "Prepare the customer update",
      isCompleted: false,
      isStarred: false,
      dueDate: nil,
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now
    )
    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(
        data: IAgentDataSnapshot(todos: [openTodo]),
        contextAsOf: now
      )
    )
    let plan = AskResearchPlanner.plan(
      "what is my number 1 priority for today",
      referenceDate: now,
      calendar: utcCalendar()
    )
    let broadTodoSearch = try XCTUnwrap(plan.searches.first { $0.id == "priority-open-todos" })

    let result = AskKnowledgeResearch.search(plan: plan, in: corpus)

    XCTAssertEqual(plan.intent, .priorities)
    XCTAssertEqual(broadTodoSearch.plan.sourceKinds, [.todo])
    XCTAssertEqual(broadTodoSearch.plan.statusFilters, [.open])
    XCTAssertEqual(broadTodoSearch.plan.terms, [])
    XCTAssertTrue(
      result.evidence.map(\.chunk.source.entityID)
        .contains(openTodo.id.uuidString.lowercased())
    )
  }

  func testTomorrowFollowUpRetainsCalendarContextWithoutLexicalScaffolding() throws {
    let now = try date(2026, 8, 7, 12)
    let todayEvent = SyncedCalendarEvent(
      id: "today-event",
      title: "Today review",
      startDate: try date(2026, 8, 7, 15),
      endDate: try date(2026, 8, 7, 16),
      isAllDay: false,
      calendarTitle: "Work",
      location: nil,
      linkURLs: [],
      updatedAt: now
    )
    let tomorrowEvent = SyncedCalendarEvent(
      id: "tomorrow-event",
      title: "Tomorrow planning",
      startDate: try date(2026, 8, 8, 10),
      endDate: try date(2026, 8, 8, 11),
      isAllDay: false,
      calendarTitle: "Work",
      location: nil,
      linkURLs: [],
      updatedAt: now
    )
    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(
        data: IAgentDataSnapshot(calendarEvents: [todayEvent, tomorrowEvent]),
        contextAsOf: now
      ))

    let plan = AskResearchPlanner.plan(
      "What about tomorrow?",
      recentUserQueries: ["What meetings do I have today?"],
      referenceDate: now,
      calendar: utcCalendar()
    )
    let search = try XCTUnwrap(plan.searches.first)
    let result = AskKnowledgeResearch.search(plan: plan, in: corpus)

    XCTAssertEqual(plan.intent, .schedule)
    XCTAssertEqual(plan.searchedSourceKinds, [.calendar])
    XCTAssertEqual(search.plan.terms, [])
    XCTAssertEqual(search.plan.dateRange?.start, try date(2026, 8, 8))
    XCTAssertEqual(search.plan.dateRange?.end, try date(2026, 8, 9))
    XCTAssertEqual(result.evidence.map(\.chunk.source.entityID), [tomorrowEvent.id])
  }

  func testResearchCoverageCountsAllUniqueDocumentsBeforeResultLimits() throws {
    let now = try date(2026, 8, 7, 12)
    let chunks = [
      chunk(
        id: "note-one-a", documentID: "note:one", kind: .note,
        text: "launch architecture", updatedAt: now),
      chunk(
        id: "note-one-b", documentID: "note:one", kind: .note,
        text: "launch implementation", updatedAt: now),
      chunk(
        id: "note-two", documentID: "note:two", kind: .note,
        text: "launch testing", updatedAt: now),
      chunk(
        id: "note-three", documentID: "note:three", kind: .note,
        text: "launch rollout", updatedAt: now),
    ]
    let corpus = AskKnowledgeCorpus(contextAsOf: now, documents: [], chunks: chunks)
    let plan = AskResearchPlan(
      originalQuery: "launch notes",
      resolvedQuery: "launch notes",
      intent: .lookup,
      searches: [
        AskResearchQuery(
          id: "lookup-note",
          reason: "matching note information",
          plan: AskQueryPlan(
            originalQuery: "launch notes",
            sourceKinds: [.note],
            terms: ["launch"]
          ),
          resultLimit: 2
        )
      ]
    )

    let result = AskKnowledgeResearch.search(
      plan: plan,
      in: corpus,
      maximumPerDocument: 1
    )
    let coverage = try XCTUnwrap(result.coverage.first)
    let progress = try XCTUnwrap(result.searchProgress.first)

    XCTAssertEqual(coverage.totalMatches, 3)
    XCTAssertEqual(coverage.returnedMatches, 2)
    XCTAssertEqual(result.evidence.count, 2)
    XCTAssertEqual(Set(result.evidence.map(\.chunk.documentID)).count, 2)
    XCTAssertEqual(progress.sourceKind, .note)
    XCTAssertEqual(progress.totalMatches, 3)
    XCTAssertEqual(Set(progress.items.map(\.id)), ["note:one", "note:two", "note:three"])
    XCTAssertEqual(
      Set(progress.items.map(\.title)),
      ["launch architecture", "launch testing", "launch rollout"]
    )
  }

  func testGroupedSearchProgressPreservesSourceOrderAndMergesRepeatedSourceQueries() {
    let plan = AskResearchPlan(
      originalQuery: "Plan my day",
      resolvedQuery: "Plan my day",
      intent: .dailyPlanning,
      searches: []
    )
    let result = AskResearchResult(
      plan: plan,
      contextAsOf: Date(timeIntervalSince1970: 0),
      evidence: [],
      coverage: [],
      searchProgress: [
        AskSearchProgress(
          queryID: "calendar",
          sourceKind: .calendar,
          items: [.init(id: "event:review", title: "Product review")]
        ),
        AskSearchProgress(
          queryID: "overdue-todos",
          sourceKind: .todo,
          items: [.init(id: "todo:ship", title: "Ship the build")]
        ),
        AskSearchProgress(
          queryID: "open-todos",
          sourceKind: .todo,
          items: [
            .init(id: "todo:ship", title: "Ship the build"),
            .init(id: "todo:notes", title: "Prepare review notes"),
          ]
        ),
        AskSearchProgress(
          queryID: "codex",
          sourceKind: .codex,
          items: [.init(id: "codex:agent", title: "Refine Ask iAgent")]
        ),
      ]
    )

    XCTAssertEqual(
      result.groupedSearchProgress.map(\.sourceKind),
      [.calendar, .todo, .codex]
    )
    XCTAssertEqual(result.groupedSearchProgress.map(\.totalMatches), [1, 2, 1])
    XCTAssertEqual(
      result.groupedSearchProgress[1].items.map(\.title),
      ["Ship the build", "Prepare review notes"]
    )
  }

  func testNormalizerBuildsAllSourcesAndDeduplicatesDeletedLinkedAndReplicatedData() throws {
    let now = try date(2026, 8, 7, 12)
    let meetingNoteID = try uuid("AAAAAAAA-0000-0000-0000-000000000001")
    let meetingID = try uuid("AAAAAAAA-0000-0000-0000-000000000002")
    let activeTodo = SyncedTodo(
      id: try uuid("AAAAAAAA-0000-0000-0000-000000000003"),
      title: "Ship TestFlight build",
      notes: "Verify launch checklist",
      isStarred: true,
      dueDate: now.addingTimeInterval(3_600),
      listName: "Launch",
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now
    )
    let deletedTodo = SyncedTodo(
      id: try uuid("AAAAAAAA-0000-0000-0000-000000000004"),
      title: "Deleted secret",
      createdAt: now,
      updatedAt: now,
      deletedAt: now
    )
    let ordinaryNote = SyncedNote(
      id: try uuid("AAAAAAAA-0000-0000-0000-000000000005"),
      title: "Launch checklist",
      body: "## QA\n\nCheck sign-in and onboarding.",
      createdAt: now,
      updatedAt: now,
      sourceDeviceID: "desktop"
    )
    let meetingNote = SyncedNote(
      id: meetingNoteID,
      kind: .meeting,
      title: "Mobile launch review",
      body: "Decision: ship after accessibility QA.",
      createdAt: now,
      updatedAt: now,
      sourceDeviceID: "mobile"
    )
    let meeting = SyncedMeetingSession(
      id: meetingID,
      noteID: meetingNoteID,
      title: "Mobile launch review",
      sourceDeviceID: "mobile",
      state: .completed,
      startedAt: now.addingTimeInterval(-1_800),
      endedAt: now,
      updatedAt: now,
      transcriptSegments: [
        SyncedTranscriptSegment(
          id: try uuid("AAAAAAAA-0000-0000-0000-000000000006"),
          source: .microphone,
          text: "We need to finish VoiceOver testing.",
          startOffset: 12,
          endOffset: 16
        )
      ],
      summaryGeneratedAt: now
    )
    let eventStart = now.addingTimeInterval(10_800)
    let olderEvent = SyncedCalendarEvent(
      id: "mac-event",
      sourceIdentifier: "shared-occurrence",
      title: "Product review",
      startDate: eventStart,
      endDate: eventStart.addingTimeInterval(3_600),
      isAllDay: false,
      calendarTitle: "Work",
      location: "Studio",
      linkURLs: [],
      updatedAt: now.addingTimeInterval(-60)
    )
    let newerReplica = SyncedCalendarEvent(
      id: "phone-event",
      sourceIdentifier: "shared-occurrence",
      title: "Product review",
      startDate: eventStart,
      endDate: eventStart.addingTimeInterval(3_600),
      isAllDay: false,
      calendarTitle: "Work",
      location: "Studio",
      linkURLs: [],
      updatedAt: now
    )
    let codex = SyncedCodexThread(
      id: "codex-1",
      projectName: "iAgent",
      title: "Ask iAgent architecture",
      activity: "Running retrieval tests",
      activityHistory: [
        SyncedCodexActivity(id: "a1", text: "hidden chain of thought", occurredAt: now)
      ],
      visibleOutputs: [
        SyncedCodexOutputExcerpt(id: "o1", text: "Built the index", occurredAt: now)
      ],
      state: .running,
      modes: [.plan],
      createdAt: now.addingTimeInterval(-3_600),
      updatedAt: now
    )
    let snapshot = IAgentDataSnapshot(
      notes: [ordinaryNote, meetingNote],
      todos: [activeTodo, deletedTodo],
      meetings: [meeting],
      codexThreads: [codex],
      calendarEvents: [olderEvent, newerReplica]
    )

    let corpus = AskKnowledgeCorpus(snapshot: AskDataSnapshot(data: snapshot, contextAsOf: now))

    XCTAssertEqual(corpus.documents.count, 5)
    XCTAssertEqual(
      Dictionary(grouping: corpus.documents, by: { $0.source.kind }).mapValues(\.count),
      [
        .todo: 1,
        .calendar: 1,
        .note: 1,
        .meeting: 1,
        .codex: 1,
      ])
    XCTAssertFalse(corpus.documents.contains { $0.title == deletedTodo.title })
    XCTAssertEqual(
      corpus.documents.first { $0.source.kind == .calendar }?.source.entityID, "phone-event")
    XCTAssertEqual(
      corpus.documents.filter { $0.source.kind == .meeting }.map(\.source.entityID),
      [
        meetingID.uuidString.lowercased()
      ])
    let meetingChunks = corpus.chunks.filter { $0.source.kind == .meeting }
    XCTAssertTrue(meetingChunks.contains { $0.source.anchor?.hasPrefix("summary:") == true })
    XCTAssertTrue(meetingChunks.contains { $0.source.anchor?.hasPrefix("transcript:") == true })
    XCTAssertTrue(meetingChunks.contains { $0.text.contains("VoiceOver testing") })
    let codexText = corpus.documents.first { $0.source.kind == .codex }?.text ?? ""
    XCTAssertTrue(codexText.contains("Built the index"))
    XCTAssertFalse(codexText.contains("hidden chain of thought"))
  }

  func testStructuredMeetingNoteSeparatesSummaryFromTranscriptEvidence() throws {
    let now = try date(2026, 8, 7, 12)
    let noteID = try uuid("AAAAAAAA-1000-0000-0000-000000000001")
    let transcript = "Alex confirmed the launch date."
    let note = SyncedNote(
      id: noteID,
      kind: .meeting,
      title: "Launch review",
      body: MeetingNoteContent(
        summary: "Decision: launch on Monday.",
        transcript: transcript
      ).markdown,
      createdAt: now,
      updatedAt: now,
      sourceDeviceID: "test"
    )
    let meeting = SyncedMeetingSession(
      noteID: noteID,
      title: "Launch review",
      sourceDeviceID: "test",
      state: .completed,
      startedAt: now.addingTimeInterval(-1_800),
      endedAt: now,
      updatedAt: now,
      transcriptSegments: [
        SyncedTranscriptSegment(source: .microphone, text: transcript)
      ],
      summaryGeneratedAt: now
    )

    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(
        data: IAgentDataSnapshot(notes: [note], meetings: [meeting]),
        contextAsOf: now
      ))
    let summaryChunks = corpus.chunks.filter { $0.source.anchor?.hasPrefix("summary:") == true }
    let transcriptChunks = corpus.chunks.filter {
      $0.source.anchor?.hasPrefix("transcript:") == true
    }

    XCTAssertEqual(summaryChunks.map(\.text), ["Decision: launch on Monday."])
    XCTAssertEqual(transcriptChunks.map(\.text), [transcript])
    XCTAssertEqual(corpus.chunks.filter { $0.text.contains(transcript) }.count, 1)
  }

  func testNormalizerAndResearchStopWhenCancellationIsRequested() throws {
    let now = try date(2026, 8, 7, 12)
    let snapshot = AskDataSnapshot(
      data: IAgentDataSnapshot(
        todos: [SyncedTodo(title: "Should not be indexed", createdAt: now, updatedAt: now)]
      ),
      contextAsOf: now
    )
    let corpus = AskKnowledgeNormalizer.normalize(snapshot: snapshot, shouldCancel: { true })
    let plan = AskResearchPlanner.plan(
      "What tasks do I need to complete?",
      referenceDate: now,
      calendar: utcCalendar()
    )
    let result = AskKnowledgeResearch.search(
      plan: plan,
      in: AskKnowledgeCorpus(
        contextAsOf: now,
        documents: [],
        chunks: [
          chunk(
            id: "cancelled",
            documentID: "todo:cancelled",
            kind: .todo,
            text: "Should not be searched",
            updatedAt: now
          )
        ]
      ),
      shouldCancel: { true }
    )

    XCTAssertTrue(corpus.documents.isEmpty)
    XCTAssertTrue(corpus.chunks.isEmpty)
    XCTAssertTrue(result.evidence.isEmpty)
  }

  func testNormalizerBoundsChunksWithoutDroppingLongWords() throws {
    let now = try date(2026, 8, 7)
    let longWord = String(repeating: "x", count: 260)
    let note = SyncedNote(
      title: "Large research note",
      body: "First paragraph with useful context.\n\n\(longWord)\n\nFinal paragraph.",
      createdAt: now,
      updatedAt: now,
      sourceDeviceID: "test"
    )

    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(data: IAgentDataSnapshot(notes: [note]), contextAsOf: now),
      maximumChunkCharacters: 120
    )
    let reconstructed = corpus.chunks.map(\.text).joined()

    XCTAssertTrue(corpus.chunks.count >= 3)
    XCTAssertTrue(corpus.chunks.allSatisfy { $0.text.count <= 120 })
    XCTAssertTrue(reconstructed.contains(longWord))
  }

  func testSearchAppliesLexicalSourceAndStatusFiltersBeforeRanking() throws {
    let now = try date(2026, 8, 7, 12)
    let openLaunch = SyncedTodo(
      title: "Prepare launch announcement",
      isCompleted: false,
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now.addingTimeInterval(-3_600)
    )
    let completedLaunch = SyncedTodo(
      title: "Prepare launch screenshots",
      isCompleted: true,
      completedAt: now,
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now
    )
    let unrelated = SyncedTodo(
      title: "Buy coffee",
      isCompleted: false,
      createdAt: now,
      updatedAt: now
    )
    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(
        data: IAgentDataSnapshot(todos: [completedLaunch, unrelated, openLaunch]),
        contextAsOf: now
      ))
    let plan = AskQueryPlanner.plan(
      "Find open launch todos", referenceDate: now, calendar: utcCalendar())

    let result = AskKnowledgeSearch.search(plan: plan, in: corpus)

    XCTAssertEqual(
      result.evidence.map(\.chunk.source.entityID), [openLaunch.id.uuidString.lowercased()])
    XCTAssertEqual(result.evidence.first?.id, "E1")
  }

  func testSearchUsesRecencyAsDeterministicTieBreaker() throws {
    let now = try date(2026, 8, 7, 12)
    let old = SyncedNote(
      id: try uuid("BBBBBBBB-0000-0000-0000-000000000001"),
      title: "Launch roadmap",
      body: "Milestones",
      createdAt: now.addingTimeInterval(-40 * 86_400),
      updatedAt: now.addingTimeInterval(-20 * 86_400),
      sourceDeviceID: "test"
    )
    let recent = SyncedNote(
      id: try uuid("BBBBBBBB-0000-0000-0000-000000000002"),
      title: "Launch roadmap",
      body: "Milestones",
      createdAt: now.addingTimeInterval(-2 * 86_400),
      updatedAt: now.addingTimeInterval(-3_600),
      sourceDeviceID: "test"
    )
    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(
        data: IAgentDataSnapshot(notes: [old, recent]),
        contextAsOf: now
      ))

    let result = AskKnowledgeSearch.search(
      plan: AskQueryPlanner.plan(
        "launch roadmap notes", referenceDate: now, calendar: utcCalendar()),
      in: corpus
    )

    XCTAssertEqual(
      result.evidence.map(\.chunk.source.entityID),
      [
        recent.id.uuidString.lowercased(),
        old.id.uuidString.lowercased(),
      ])
  }

  func testRefinementSearchCannotEscapeTheAuthorizedSubject() throws {
    let now = try date(2026, 8, 7, 12)
    let apollo = chunk(
      id: "apollo", documentID: "note:apollo", kind: .note,
      text: "Apollo launch roadmap", updatedAt: now)
    let salary = chunk(
      id: "salary", documentID: "note:salary", kind: .note,
      text: "Salary review", updatedAt: now)
    let apolloSalary = chunk(
      id: "apollo-salary", documentID: "note:apollo-salary", kind: .note,
      text: "Apollo salary planning", updatedAt: now)
    let corpus = AskKnowledgeCorpus(
      contextAsOf: now,
      documents: [],
      chunks: [apollo, salary, apolloSalary]
    )
    let authorized = AskQueryPlan(
      originalQuery: "Apollo",
      sourceKinds: [.note],
      terms: ["apollo"]
    )
    let refinement = AskQueryPlan(
      originalQuery: "salary",
      sourceKinds: [.note],
      terms: ["salary"]
    )

    let result = AskKnowledgeSearch.search(
      refinementPlan: refinement,
      constrainedBy: authorized,
      in: corpus
    )

    XCTAssertEqual(result.evidence.map(\.chunk.documentID), ["note:apollo-salary"])
  }

  func testSearchEnforcesSourceDiversityAndPerDocumentLimits() throws {
    let now = try date(2026, 8, 7, 12)
    let chunks = [
      chunk(id: "t1", documentID: "todo:1", kind: .todo, text: "launch", updatedAt: now),
      chunk(id: "t2", documentID: "todo:2", kind: .todo, text: "launch", updatedAt: now),
      chunk(id: "t3", documentID: "todo:3", kind: .todo, text: "launch", updatedAt: now),
      chunk(id: "n1", documentID: "note:1", kind: .note, text: "launch", updatedAt: now),
      chunk(id: "n2", documentID: "note:1", kind: .note, text: "launch details", updatedAt: now),
      chunk(id: "c1", documentID: "calendar:1", kind: .calendar, text: "launch", updatedAt: now),
    ]
    let corpus = AskKnowledgeCorpus(contextAsOf: now, documents: [], chunks: chunks)
    let plan = AskQueryPlan(originalQuery: "launch", terms: ["launch"])

    let result = AskKnowledgeSearch.search(
      plan: plan,
      in: corpus,
      limit: 8,
      maximumPerSourceKind: 1,
      maximumPerDocument: 1
    )

    XCTAssertEqual(result.evidence.count, 3)
    XCTAssertEqual(Set(result.evidence.map(\.chunk.source.kind)), [.todo, .note, .calendar])
    XCTAssertEqual(result.evidence.map(\.id), ["E1", "E2", "E3"])
  }

  func testPrioritySearchUsesStructuredFieldsRatherThanMatchingProse() throws {
    let now = try date(2026, 8, 7, 12)
    let starred = SyncedTodo(
      title: "Finish build",
      isStarred: true,
      createdAt: now,
      updatedAt: now
    )
    let ordinary = SyncedTodo(title: "Buy coffee", createdAt: now, updatedAt: now)
    let running = SyncedCodexThread(
      id: "running",
      projectName: "iAgent",
      title: "Ask architecture",
      activity: "Testing",
      state: .running,
      modes: [],
      createdAt: now,
      updatedAt: now
    )
    let corpus = AskKnowledgeCorpus(
      snapshot: AskDataSnapshot(
        data: IAgentDataSnapshot(todos: [ordinary, starred], codexThreads: [running]),
        contextAsOf: now
      ))

    let result = AskKnowledgeSearch.search(
      plan: AskQueryPlanner.plan(
        "What are my biggest priorities right now?",
        referenceDate: now,
        calendar: utcCalendar()
      ),
      in: corpus
    )

    XCTAssertEqual(
      Set(result.evidence.map(\.chunk.source.entityID)),
      [
        starred.id.uuidString.lowercased(),
        running.id,
      ])
  }

  func testCitationValidatorAllowsOnlyEvidenceFromTheCurrentTurn() throws {
    let now = try date(2026, 8, 7, 12)
    let first = chunk(id: "one", documentID: "note:one", kind: .note, text: "One", updatedAt: now)
    let second = chunk(id: "two", documentID: "todo:two", kind: .todo, text: "Two", updatedAt: now)
    let bundle = AskEvidenceBundle(
      queryPlan: AskQueryPlan(originalQuery: "test"),
      contextAsOf: now,
      evidence: [
        AskEvidence(id: "E1", chunk: first, score: 2),
        AskEvidence(id: "E2", chunk: second, score: 1),
      ]
    )

    let references = AskCitationValidator.validate(["E2", "FAKE", "E2", "E1"], against: bundle)
    XCTAssertEqual(references.accepted.map(\.citationID), ["E2", "E1"])
    XCTAssertEqual(references.rejectedIDs, ["FAKE"])
    XCTAssertEqual(references.accepted.first?.source, second.source)
    XCTAssertEqual(references.accepted.first?.retrievedAt, now)

    let claims = AskCitationValidator.validate(
      claims: [
        AskGroundedClaim(text: "Grounded", citationIDs: ["E1", "MADE_UP"]),
        AskGroundedClaim(text: "Fabricated", citationIDs: ["MADE_UP"]),
        AskGroundedClaim(text: "Uncited", citationIDs: []),
      ], against: bundle)
    XCTAssertEqual(claims.acceptedClaims, [AskGroundedClaim(text: "Grounded", citationIDs: ["E1"])])
    XCTAssertEqual(claims.rejectedClaims.map(\.text), ["Fabricated", "Uncited"])
    XCTAssertEqual(claims.rejectedCitationIDs, ["MADE_UP"])
  }

  func testExactSupportQARejectsUnknownIDsAndAbsentExcerpts() {
    let claims = AskCitationValidator.validateExactSupports(
      claims: [
        AskGroundedClaimDraft(
          text: "The launch review starts at 10.",
          supports: [
            AskGroundedSupportDraft(
              evidenceID: "E1",
              excerpt: "Starts at 10:00 AM — Studio"
            )
          ]
        ),
        AskGroundedClaimDraft(
          text: "This unsupported claim must disappear.",
          supports: [AskGroundedSupportDraft(evidenceID: "E1", excerpt: "Starts at noon")]
        ),
        AskGroundedClaimDraft(
          text: "This fabricated citation must disappear.",
          supports: [AskGroundedSupportDraft(evidenceID: "FAKE", excerpt: "anything")]
        ),
      ],
      evidenceTextByID: [
        "E1": "Launch review\nStarts at 10:00 AM - Studio. Bring the release scope."
      ]
    )

    XCTAssertEqual(
      claims,
      [AskGroundedClaim(text: "The launch review starts at 10.", citationIDs: ["E1"])]
    )
  }

  private func chunk(
    id: String,
    documentID: String,
    kind: AskSourceKind,
    text: String,
    updatedAt: Date
  ) -> AskKnowledgeChunk {
    let source = AskSourceReference(kind: kind, entityID: id, revision: updatedAt, anchor: "body:0")
    return AskKnowledgeChunk(
      id: id,
      documentID: documentID,
      source: source,
      title: text,
      text: text,
      updatedAt: updatedAt
    )
  }

  private func meetingChunk(
    id: String,
    documentID: String,
    entityID: String,
    title: String,
    text: String,
    anchor: String,
    occurrence: Date,
    updatedAt: Date,
    status: AskKnowledgeStatus = .completed
  ) -> AskKnowledgeChunk {
    AskKnowledgeChunk(
      id: id,
      documentID: documentID,
      source: AskSourceReference(
        kind: .meeting,
        entityID: entityID,
        revision: updatedAt,
        anchor: anchor
      ),
      title: title,
      text: text,
      updatedAt: updatedAt,
      facets: AskKnowledgeFacets(
        status: status,
        temporalRange: AskDateRange(
          start: occurrence,
          end: occurrence.addingTimeInterval(3_600)
        )
      )
    )
  }

  private func broadPlanningCorpus(now: Date) -> AskKnowledgeCorpus {
    let calendarRange = AskDateRange(
      start: now.addingTimeInterval(3_600),
      end: now.addingTimeInterval(7_200)
    )
    let fixtures: [(id: String, kind: AskSourceKind, title: String, text: String, facets: AskKnowledgeFacets)] = [
      (
        "todo-ship", .todo, "Ship the candidate build", "Finish the release candidate.",
        AskKnowledgeFacets(
          status: .open,
          isStarred: true,
          dueDate: now.addingTimeInterval(4 * 3_600)
        )
      ),
      (
        "calendar-review", .calendar, "Product review", "Review the release plan.",
        AskKnowledgeFacets(status: .scheduled, temporalRange: calendarRange)
      ),
      (
        "note-priorities", .note, "Product priorities", "Priority next action for launch.",
        AskKnowledgeFacets()
      ),
      (
        "meeting-standup", .meeting, "Launch standup", "Action owner and next deadline.",
        AskKnowledgeFacets(
          status: .completed,
          temporalRange: AskDateRange(
            start: now.addingTimeInterval(-86_400),
            end: now.addingTimeInterval(-82_800)
          )
        )
      ),
      (
        "codex-agent", .codex, "Improve Ask iAgent", "Running retrieval quality checks.",
        AskKnowledgeFacets(status: .running)
      ),
    ]
    let chunks = fixtures.map { fixture in
      AskKnowledgeChunk(
        id: fixture.id,
        documentID: "\(fixture.kind.rawValue):\(fixture.id)",
        source: AskSourceReference(
          kind: fixture.kind,
          entityID: fixture.id,
          revision: now,
          anchor: "body:0"
        ),
        title: fixture.title,
        text: fixture.text,
        updatedAt: now,
        facets: fixture.facets
      )
    }
    return AskKnowledgeCorpus(contextAsOf: now, documents: [], chunks: chunks)
  }

  private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.firstWeekday = 2
    return calendar
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) throws -> Date {
    try XCTUnwrap(
      utcCalendar().date(
        from: DateComponents(
          timeZone: TimeZone(secondsFromGMT: 0),
          year: year,
          month: month,
          day: day,
          hour: hour
        )))
  }

  private func uuid(_ value: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: value))
  }
}

private final class SearchSourceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [AskSourceKind] = []

  var values: [AskSourceKind] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }

  func append(_ value: AskSourceKind) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }
}
