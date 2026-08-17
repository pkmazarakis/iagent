import Foundation

public typealias AskQueryProgressHandler = @Sendable (AskQueryProgress) -> Void

// MARK: - Content-free catalog construction

public enum AskDataCatalogBuilder {
  public static func build(
    snapshot: AskDataSnapshot,
    snapshotID: String,
    temporalContext: AskTemporalContext,
    queryableDomains: Set<AskSourceKind> = Set(AskSourceKind.allCases),
    staleAfter: TimeInterval = 15 * 60
  ) -> AskDataCatalog {
    let data = snapshot.data
    let calendarEvents = coalescedCalendarEvents(data.calendarEvents)
    let linkedMeetingNoteIDs = Set(
      data.meetings.lazy.filter { $0.deletedAt == nil }.map(\.noteID))
    let lastRead = data.lastSuccessfulSyncAt
    let freshness: AskCatalogFreshness
    if let lastRead {
      freshness =
        temporalContext.contextAsOf.timeIntervalSince(lastRead) <= staleAfter
        ? .current : .stale
    } else {
      freshness = .unknown
    }

    func entry(
      _ domain: AskSourceKind,
      count: Int,
      coverage: AskCatalogCoverage = AskCatalogCoverage()
    ) -> AskDomainCatalogEntry {
      let isQueryable = queryableDomains.contains(domain)
      return AskDomainCatalogEntry(
        domain: domain,
        availability: isQueryable ? .available : .unavailable,
        availabilityReason: isQueryable ? .none : .notLoaded,
        recordCount: count,
        observedAt: temporalContext.contextAsOf,
        lastSuccessfulReadAt: lastRead,
        freshness: freshness,
        coverage: coverage
      )
    }

    let calendarCoverage =
      snapshot.coverageOverrides[.calendar]
      ?? coverage(
        starts: calendarEvents.map(\.startDate),
        ends: calendarEvents.map(\.endDate)
      )
    let activeMeetings = data.meetings.filter { $0.deletedAt == nil }
    let meetingCoverage = coverage(
      starts: activeMeetings.map(\.startedAt),
      ends: activeMeetings.map { $0.endedAt ?? $0.startedAt.addingTimeInterval(1) }
    )

    return AskDataCatalog(
      snapshotID: snapshotID,
      temporalContext: temporalContext,
      domains: [
        entry(.todo, count: uniqueActiveTodos(data.todos).count),
        entry(.calendar, count: calendarEvents.count, coverage: calendarCoverage),
        entry(
          .note,
          count: data.notes.filter {
            $0.deletedAt == nil && $0.kind == .note && !linkedMeetingNoteIDs.contains($0.id)
          }.count
        ),
        entry(
          .meeting, count: uniqueActiveMeetings(data.meetings).count, coverage: meetingCoverage),
        entry(.codex, count: uniqueActiveCodexThreads(data.codexThreads).count),
      ]
    )
  }

  fileprivate static func coalescedCalendarEvents(
    _ events: [SyncedCalendarEvent]
  ) -> [SyncedCalendarEvent] {
    let active = events.filter { $0.deletedAt == nil }.sorted {
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
      return $0.id < $1.id
    }
    var result: [SyncedCalendarEvent] = []
    for event in active where !result.contains(where: { $0.isSameOccurrence(as: event) }) {
      result.append(event)
    }
    return result
  }

  fileprivate static func uniqueActiveTodos(_ todos: [SyncedTodo]) -> [SyncedTodo] {
    uniqueNewest(todos.filter { $0.deletedAt == nil }, id: { $0.id }, updatedAt: { $0.updatedAt })
  }

  fileprivate static func uniqueActiveNotes(_ notes: [SyncedNote]) -> [SyncedNote] {
    uniqueNewest(notes.filter { $0.deletedAt == nil }, id: { $0.id }, updatedAt: { $0.updatedAt })
  }

  fileprivate static func uniqueActiveMeetings(
    _ meetings: [SyncedMeetingSession]
  ) -> [SyncedMeetingSession] {
    uniqueNewest(
      meetings.filter { $0.deletedAt == nil }, id: { $0.id }, updatedAt: { $0.updatedAt })
  }

  fileprivate static func uniqueActiveCodexThreads(
    _ threads: [SyncedCodexThread]
  ) -> [SyncedCodexThread] {
    uniqueNewest(
      threads.filter { $0.deletedAt == nil }, id: { $0.id }, updatedAt: { $0.updatedAt })
  }

  private static func uniqueNewest<Value, ID: Hashable>(
    _ values: [Value],
    id: (Value) -> ID,
    updatedAt: (Value) -> Date
  ) -> [Value] {
    var newest: [ID: Value] = [:]
    for value in values {
      let key = id(value)
      if let existing = newest[key], updatedAt(existing) >= updatedAt(value) { continue }
      newest[key] = value
    }
    return Array(newest.values)
  }

  private static func coverage(starts: [Date], ends: [Date]) -> AskCatalogCoverage {
    AskCatalogCoverage(
      start: starts.min(),
      end: ends.max(),
      isCompleteWithinRange: true,
      isTruncated: false
    )
  }
}

// MARK: - Pinned in-memory executor spike

/// A deterministic, read-only executor over a value-semantic turn snapshot.
/// No production path uses it until the versioned Ask harness explicitly opts in.
public actor AskPinnedQueryExecutor {
  public nonisolated let catalog: AskDataCatalog
  public nonisolated let budget: AskQueryBudget

  private let snapshot: AskDataSnapshot
  private let temporalContext: AskTemporalContext
  private var calls = 0
  private var callsByDomain: [AskSourceKind: Int] = [:]
  private var pagesByDomain: [AskSourceKind: Int] = [:]
  private var records = 0
  private var evidencePassages = 0
  private var evidenceCharacters = 0
  private var evidenceSequence = 0
  private var progressSequence = 0

  public init(
    snapshot: AskDataSnapshot,
    snapshotID: String,
    temporalContext: AskTemporalContext,
    budget: AskQueryBudget = AskQueryBudget()
  ) throws {
    guard !snapshotID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AskQueryFailure(code: .invalidQuery, field: "snapshotID")
    }
    try budget.validate()
    _ = try temporalContext.calendar()
    self.snapshot = snapshot
    self.temporalContext = temporalContext
    self.budget = budget
    catalog = AskDataCatalogBuilder.build(
      snapshot: snapshot,
      snapshotID: snapshotID,
      temporalContext: temporalContext
    )
  }

  public func usage() -> AskQueryBudgetUsage { currentUsage() }

  public func execute(
    _ query: AskReadQuery,
    progress: AskQueryProgressHandler = { _ in }
  ) throws -> AskQueryPage {
    do {
      guard !Task.isCancelled else {
        throw AskQueryFailure(code: .cancelled, queryID: query.queryID)
      }
      try AskQueryValidator.validate(query, temporalContext: temporalContext, budget: budget)

      switch query {
      case .todo(let value):
        return try executeTodo(value, progress: progress)
      case .calendar(let value):
        return try executeCalendar(value, progress: progress)
      case .meeting(let value):
        return try executeMeeting(value, progress: progress)
      case .note(let value):
        return try executeNote(value, progress: progress)
      case .codex(let value):
        return try executeCodex(value, progress: progress)
      }
    } catch {
      progress(nextProgress(query, phase: .failed))
      throw error
    }
  }

  public func execute(
    _ query: AskTodoQuery,
    progress: AskQueryProgressHandler = { _ in }
  ) throws -> AskQueryPage {
    try execute(.todo(query), progress: progress)
  }

  public func execute(
    _ query: AskCalendarQuery,
    progress: AskQueryProgressHandler = { _ in }
  ) throws -> AskQueryPage {
    try execute(.calendar(query), progress: progress)
  }

  public func execute(
    _ query: AskMeetingQuery,
    progress: AskQueryProgressHandler = { _ in }
  ) throws -> AskQueryPage {
    try execute(.meeting(query), progress: progress)
  }

  public func execute(
    _ query: AskNoteQuery,
    progress: AskQueryProgressHandler = { _ in }
  ) throws -> AskQueryPage {
    try execute(.note(query), progress: progress)
  }

  public func execute(
    _ query: AskCodexQuery,
    progress: AskQueryProgressHandler = { _ in }
  ) throws -> AskQueryPage {
    try execute(.codex(query), progress: progress)
  }

  private func executeTodo(
    _ query: AskTodoQuery,
    progress: AskQueryProgressHandler
  ) throws -> AskQueryPage {
    let request = AskReadQuery.todo(query)
    let offset = try begin(request, cursor: query.cursor, progress: progress)
    let timeRange = try query.time.resolvedRange(in: temporalContext)
    let calendar = try temporalContext.calendar()
    let today = calendar.startOfDay(for: temporalContext.contextAsOf)
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
    let nextWeek = calendar.date(byAdding: .day, value: 7, to: today) ?? tomorrow
    let wantedIDs = normalizedSet(query.recordIDs)
    let wantedStates = Set(query.states)
    let wantedLists = normalizedSet(query.listNames)

    var values = AskDataCatalogBuilder.uniqueActiveTodos(snapshot.data.todos).filter { todo in
      let id = todo.id.uuidString.lowercased()
      guard wantedIDs.isEmpty || wantedIDs.contains(id),
        wantedStates.isEmpty
          || wantedStates.contains(todo.isCompleted ? .completed : .open),
        query.starred == nil || query.starred == todo.isStarred,
        wantedLists.isEmpty
          || wantedLists.contains(normalized(todo.listName ?? "")),
        textMatches(query.text, in: [todo.title, todo.notes, todo.listName])
      else { return false }

      switch query.due {
      case .any:
        break
      case .hasDueDate:
        guard todo.dueDate != nil else { return false }
      case .noDueDate:
        guard todo.dueDate == nil else { return false }
      case .overdue:
        guard !todo.isCompleted, let due = todo.dueDate, due < today else { return false }
      case .dueInWindow:
        guard let due = todo.dueDate, let timeRange, timeRange.contains(due) else { return false }
      }

      guard let timeRange else { return true }
      let date: Date?
      switch query.time.field {
      case .due: date = todo.dueDate
      case .completed: date = todo.completedAt
      case .created: date = todo.createdAt
      case .updated: date = todo.updatedAt
      default: date = nil
      }
      return date.map(timeRange.contains) ?? false
    }

    values.sort { lhs, rhs in
      let order: ComparisonResult
      switch query.sort {
      case .relevanceDesc:
        order = compareDescending(
          relevance(query.text, title: lhs.title, body: [lhs.notes, lhs.listName]),
          relevance(query.text, title: rhs.title, body: [rhs.notes, rhs.listName]))
      case .attentionDesc:
        order = compareDescending(
          todoAttention(lhs, today: today, tomorrow: tomorrow, nextWeek: nextWeek),
          todoAttention(rhs, today: today, tomorrow: tomorrow, nextWeek: nextWeek))
      case .dueAsc:
        order = compareOptionalDatesAscending(lhs.dueDate, rhs.dueDate)
      case .updatedDesc:
        order = compareDescending(lhs.updatedAt, rhs.updatedAt)
      case .createdDesc:
        order = compareDescending(lhs.createdAt, rhs.createdAt)
      case .completedDesc:
        order = compareOptionalDatesDescending(lhs.completedAt, rhs.completedAt)
      }
      if order != .orderedSame { return order == .orderedAscending }
      if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }

    let candidates = values.map { todo -> Candidate in
      let source = AskSourceReference(
        kind: .todo,
        entityID: todo.id.uuidString.lowercased(),
        revision: todo.updatedAt
      )
      let body: String
      switch query.content {
      case .metadata:
        body = todo.title
      case .preview:
        body = joined([todo.title, todo.notes.map { bounded($0, to: 320) }])
      case .full:
        body = joined([todo.title, todo.notes, todo.listName])
      }
      return Candidate(
        source: source,
        title: todo.title,
        status: todo.isCompleted ? .completed : .open,
        dueAt: todo.dueDate,
        startsAt: nil,
        endsAt: nil,
        updatedAt: todo.updatedAt,
        isStarred: todo.isStarred,
        isAllDay: nil,
        collectionName: todo.listName,
        passages: [("body", body)]
      )
    }

    return try finish(
      request,
      offset: offset,
      limit: query.limit,
      candidates: candidates,
      baseWarnings: [.legacyDueSemantics],
      progress: progress
    )
  }

  private func executeCalendar(
    _ query: AskCalendarQuery,
    progress: AskQueryProgressHandler
  ) throws -> AskQueryPage {
    let request = AskReadQuery.calendar(query)
    let timeRange = try query.time.resolvedRange(in: temporalContext)
    if query.time.field == .occurrence,
      let coverage = snapshot.coverageOverrides[.calendar],
      let coverageStart = coverage.start,
      let coverageEnd = coverage.end
    {
      guard coverage.isCompleteWithinRange, !coverage.isTruncated,
        let timeRange,
        timeRange.start >= coverageStart,
        timeRange.end <= coverageEnd
      else {
        throw AskQueryFailure(
          code: .outOfCoverage,
          queryID: query.queryID,
          field: "time"
        )
      }
    }
    let offset = try begin(request, cursor: query.cursor, progress: progress)
    let wantedIDs = normalizedSet(query.recordIDs)
    let wantedCalendars = normalizedSet(query.calendarTitles)

    var values = AskDataCatalogBuilder.coalescedCalendarEvents(snapshot.data.calendarEvents)
      .filter { event in
        guard wantedIDs.isEmpty || wantedIDs.contains(normalized(event.id)),
          wantedCalendars.isEmpty
            || wantedCalendars.contains(normalized(event.calendarTitle)),
          query.allDay == nil || query.allDay == event.isAllDay,
          textMatches(
            query.text,
            in: [event.title, event.notes, event.location, event.calendarTitle])
        else { return false }

        guard let timeRange else { return true }
        switch query.time.field {
        case .occurrence:
          return AskDateRange(
            start: event.startDate,
            end: max(event.startDate.addingTimeInterval(1), event.endDate)
          ).intersects(timeRange)
        case .updated:
          return timeRange.contains(event.updatedAt)
        default:
          return false
        }
      }

    values.sort { lhs, rhs in
      let order: ComparisonResult
      switch query.sort {
      case .relevanceDesc:
        order = compareDescending(
          relevance(
            query.text, title: lhs.title,
            body: [lhs.notes, lhs.location, lhs.calendarTitle]),
          relevance(
            query.text, title: rhs.title,
            body: [rhs.notes, rhs.location, rhs.calendarTitle]))
      case .startAsc:
        order = compareAscending(lhs.startDate, rhs.startDate)
      case .startDesc:
        order = compareDescending(lhs.startDate, rhs.startDate)
      case .updatedDesc:
        order = compareDescending(lhs.updatedAt, rhs.updatedAt)
      }
      if order != .orderedSame { return order == .orderedAscending }
      return lhs.id < rhs.id
    }

    let candidates = values.map { event -> Candidate in
      let source = AskSourceReference(
        kind: .calendar,
        entityID: event.id,
        revision: event.updatedAt
      )
      let body: String
      switch query.content {
      case .metadata:
        body = event.title
      case .details:
        body = joined([
          event.title,
          event.calendarTitle,
          event.location,
          event.notes,
        ])
      }
      return Candidate(
        source: source,
        title: event.title,
        status: .scheduled,
        dueAt: nil,
        startsAt: event.startDate,
        endsAt: event.endDate,
        updatedAt: event.updatedAt,
        isStarred: nil,
        isAllDay: event.isAllDay,
        collectionName: event.calendarTitle,
        passages: [("details", body)]
      )
    }

    return try finish(
      request,
      offset: offset,
      limit: query.limit,
      candidates: candidates,
      progress: progress
    )
  }

  private func executeMeeting(
    _ query: AskMeetingQuery,
    progress: AskQueryProgressHandler
  ) throws -> AskQueryPage {
    let request = AskReadQuery.meeting(query)
    let offset = try begin(request, cursor: query.cursor, progress: progress)
    let timeRange = try query.time.resolvedRange(in: temporalContext)
    let wantedIDs = normalizedSet(query.recordIDs)
    let wantedStates = Set(query.states)
    let notesByID = Dictionary(
      uniqueKeysWithValues: snapshot.data.notes
        .filter { $0.deletedAt == nil }
        .map { ($0.id, $0) }
    )

    var records = AskDataCatalogBuilder.uniqueActiveMeetings(snapshot.data.meetings)
      .map { meeting -> MeetingRecord in
        meetingRecord(meeting, note: notesByID[meeting.noteID])
      }
      .filter { value in
        let meeting = value.meeting
        let state = meetingState(meeting.state)
        guard
          wantedIDs.isEmpty
            || wantedIDs.contains(meeting.id.uuidString.lowercased()),
          wantedStates.isEmpty || wantedStates.contains(state),
          query.hasReadableContent == nil || query.hasReadableContent == value.isReadable,
          textMatches(
            query.text,
            in: [meeting.title, value.summary, value.transcript])
        else { return false }

        guard let timeRange else { return true }
        switch query.time.field {
        case .occurrence:
          // Meeting occurrence is a completed-session point for deterministic "latest" semantics.
          // It intentionally ignores updatedAt, so an older edited note cannot become the last meeting.
          return timeRange.contains(value.occurrenceDate)
        case .updated:
          return timeRange.contains(meeting.updatedAt)
        default:
          return false
        }
      }

    records.sort { lhs, rhs in
      let order: ComparisonResult
      switch query.sort {
      case .relevanceDesc:
        order = compareDescending(
          relevance(
            query.text, title: lhs.meeting.title,
            body: [lhs.summary, lhs.transcript]),
          relevance(
            query.text, title: rhs.meeting.title,
            body: [rhs.summary, rhs.transcript]))
      case .occurrenceDesc:
        order = compareDescending(lhs.occurrenceDate, rhs.occurrenceDate)
      case .occurrenceAsc:
        order = compareAscending(lhs.occurrenceDate, rhs.occurrenceDate)
      case .updatedDesc:
        order = compareDescending(lhs.meeting.updatedAt, rhs.meeting.updatedAt)
      }
      if order != .orderedSame { return order == .orderedAscending }
      return lhs.meeting.id.uuidString < rhs.meeting.id.uuidString
    }

    let candidates = records.map { value -> Candidate in
      let meeting = value.meeting
      let source = AskSourceReference(
        kind: .meeting,
        entityID: meeting.id.uuidString.lowercased(),
        revision: meeting.updatedAt
      )
      let passages: [(String, String)]
      switch query.content {
      case .metadata:
        passages = [("metadata", meeting.title)]
      case .summary:
        passages = [("summary:0", value.summary ?? value.transcript ?? meeting.title)]
      case .summaryAndTranscriptPassages:
        var values: [(String, String)] = []
        if let summary = value.summary { values.append(("summary:0", summary)) }
        if let transcript = value.transcript {
          values.append(contentsOf: passageChunks(transcript, prefix: "transcript", maximum: 2))
        }
        passages = values.isEmpty ? [("metadata", meeting.title)] : values
      }
      return Candidate(
        source: source,
        title: meeting.title,
        status: meetingStatus(meeting.state),
        dueAt: nil,
        startsAt: meeting.startedAt,
        endsAt: meeting.endedAt,
        updatedAt: meeting.updatedAt,
        isStarred: nil,
        isAllDay: nil,
        collectionName: nil,
        passages: passages
      )
    }

    return try finish(
      request,
      offset: offset,
      limit: query.limit,
      candidates: candidates,
      progress: progress
    )
  }

  private func executeNote(
    _ query: AskNoteQuery,
    progress: AskQueryProgressHandler
  ) throws -> AskQueryPage {
    let request = AskReadQuery.note(query)
    let offset = try begin(request, cursor: query.cursor, progress: progress)
    let timeRange = try query.time.resolvedRange(in: temporalContext)
    let wantedIDs = normalizedSet(query.recordIDs)
    let linkedMeetingNoteIDs = Set(
      snapshot.data.meetings.lazy
        .filter { $0.deletedAt == nil }
        .map(\.noteID)
    )

    var values = AskDataCatalogBuilder.uniqueActiveNotes(snapshot.data.notes).filter { note in
      guard note.kind == .note,
        !linkedMeetingNoteIDs.contains(note.id),
        wantedIDs.isEmpty || wantedIDs.contains(note.id.uuidString.lowercased()),
        textMatches(query.text, in: [note.title, note.body])
      else { return false }

      guard let timeRange else { return true }
      switch query.time.field {
      case .created:
        return timeRange.contains(note.createdAt)
      case .updated:
        return timeRange.contains(note.updatedAt)
      default:
        return false
      }
    }

    values.sort { lhs, rhs in
      let order: ComparisonResult
      switch query.sort {
      case .relevanceDesc:
        order = compareDescending(
          relevance(query.text, title: lhs.title, body: [lhs.body]),
          relevance(query.text, title: rhs.title, body: [rhs.body]))
      case .updatedDesc:
        order = compareDescending(lhs.updatedAt, rhs.updatedAt)
      case .createdDesc:
        order = compareDescending(lhs.createdAt, rhs.createdAt)
      }
      if order != .orderedSame { return order == .orderedAscending }
      if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }

    let candidates = values.map { note -> Candidate in
      let source = AskSourceReference(
        kind: .note,
        entityID: note.id.uuidString.lowercased(),
        revision: note.updatedAt
      )
      let passages: [(String, String)]
      switch query.content {
      case .metadata:
        passages = [("metadata", note.title)]
      case .preview:
        passages = [("body:0", joined([note.title, bounded(note.body, to: 600)]))]
      case .full:
        let chunks = passageChunks(note.body, prefix: "body", maximum: 3)
        passages = chunks.isEmpty ? [("metadata", note.title)] : chunks
      }
      return Candidate(
        source: source,
        title: note.title,
        status: nil,
        dueAt: nil,
        startsAt: nil,
        endsAt: nil,
        updatedAt: note.updatedAt,
        isStarred: nil,
        isAllDay: nil,
        collectionName: nil,
        passages: passages
      )
    }

    return try finish(
      request,
      offset: offset,
      limit: query.limit,
      candidates: candidates,
      progress: progress
    )
  }

  private func executeCodex(
    _ query: AskCodexQuery,
    progress: AskQueryProgressHandler
  ) throws -> AskQueryPage {
    let request = AskReadQuery.codex(query)
    let offset = try begin(request, cursor: query.cursor, progress: progress)
    let timeRange = try query.time.resolvedRange(in: temporalContext)
    let wantedIDs = normalizedSet(query.recordIDs)
    let wantedStates = Set(query.states)
    let wantedModes = Set(query.modes)
    let wantedProjects = normalizedSet(query.projectNames)

    var records = AskDataCatalogBuilder.uniqueActiveCodexThreads(snapshot.data.codexThreads)
      .map { thread in
        CodexRecord(
          thread: thread, visibleOutputs: uniqueVisibleOutputs(thread.visibleOutputs ?? []))
      }
      .filter { value in
        let thread = value.thread
        let state = codexState(thread.state)
        let modes = Set(thread.modes.map(codexMode))
        let searchableOutputs = value.visibleOutputs.map { Optional($0.text) }
        guard wantedIDs.isEmpty || wantedIDs.contains(normalized(thread.id)),
          wantedStates.isEmpty || wantedStates.contains(state),
          wantedModes.isEmpty || !wantedModes.isDisjoint(with: modes),
          wantedProjects.isEmpty
            || wantedProjects.contains(normalized(thread.projectName ?? "")),
          textMatches(
            query.text,
            in: [thread.title, thread.projectName, thread.activity] + searchableOutputs)
        else { return false }

        guard let timeRange else { return true }
        switch query.time.field {
        case .created:
          return timeRange.contains(thread.createdAt)
        case .updated:
          return timeRange.contains(thread.updatedAt)
        case .visibleOutput:
          return value.visibleOutputs.contains { timeRange.contains($0.occurredAt) }
        default:
          return false
        }
      }

    records.sort { lhs, rhs in
      let order: ComparisonResult
      switch query.sort {
      case .relevanceDesc:
        order = compareDescending(
          codexRelevance(query.text, record: lhs),
          codexRelevance(query.text, record: rhs))
      case .updatedDesc:
        order = compareDescending(lhs.thread.updatedAt, rhs.thread.updatedAt)
      case .createdDesc:
        order = compareDescending(lhs.thread.createdAt, rhs.thread.createdAt)
      }
      if order != .orderedSame { return order == .orderedAscending }
      if lhs.thread.updatedAt != rhs.thread.updatedAt {
        return lhs.thread.updatedAt > rhs.thread.updatedAt
      }
      return lhs.thread.id < rhs.thread.id
    }

    let candidates = records.map { value -> Candidate in
      let thread = value.thread
      let source = AskSourceReference(
        kind: .codex,
        entityID: thread.id,
        revision: thread.updatedAt
      )
      let passages: [(String, String)]
      switch query.content {
      case .metadata:
        passages = [
          ("metadata", joined([thread.title, thread.projectName, thread.state.rawValue]))
        ]
      case .activity:
        passages = [
          ("activity", joined([thread.title, thread.projectName, thread.activity]))
        ]
      case .visibleOutputs:
        let outputs: [SyncedCodexOutputExcerpt]
        if query.time.field == .visibleOutput, let timeRange {
          outputs = value.visibleOutputs.filter { timeRange.contains($0.occurredAt) }
        } else {
          outputs = value.visibleOutputs
        }
        passages = outputs.suffix(3).map { output in
          ("visible_output:\(output.id)", output.text)
        }
      }
      return Candidate(
        source: source,
        title: thread.title,
        status: codexStatus(thread.state),
        dueAt: nil,
        startsAt: nil,
        endsAt: nil,
        updatedAt: thread.updatedAt,
        isStarred: nil,
        isAllDay: nil,
        collectionName: thread.projectName,
        passages: passages.isEmpty ? [("metadata", thread.title)] : passages
      )
    }

    return try finish(
      request,
      offset: offset,
      limit: query.limit,
      candidates: candidates,
      progress: progress
    )
  }

  private func begin(
    _ query: AskReadQuery,
    cursor: String?,
    progress: AskQueryProgressHandler
  ) throws -> Int {
    let offset = try decodedOffset(cursor, for: query)
    try ensureBudgetAvailable(for: query)
    progress(nextProgress(query, phase: .validated))
    progress(nextProgress(query, phase: .executing))
    return offset
  }

  private func finish(
    _ query: AskReadQuery,
    offset: Int,
    limit: Int,
    candidates: [Candidate],
    baseWarnings: [AskQueryWarning] = [],
    progress: AskQueryProgressHandler
  ) throws -> AskQueryPage {
    guard offset <= candidates.count else {
      throw AskQueryFailure(code: .invalidCursor, queryID: query.queryID, field: "cursor")
    }

    let remainingRecordBudget = budget.maximumTotalRecords - records
    guard remainingRecordBudget > 0 else {
      throw AskQueryFailure(code: .budgetExceeded, queryID: query.queryID, field: "records")
    }
    let pageLimit = min(limit, remainingRecordBudget)
    let selected = Array(candidates.dropFirst(offset).prefix(pageLimit))
    var warnings = baseWarnings
    if pageLimit < limit { warnings.append(.resultBudgetReached) }

    var items: [AskQueryItem] = []
    for candidate in selected {
      var evidence: [AskQueryEvidence] = []
      for passage in candidate.passages {
        let remainingPassages = budget.maximumEvidencePassages - evidencePassages
        let remainingCharacters = budget.maximumEvidenceCharacters - evidenceCharacters
        guard remainingPassages > 0, remainingCharacters > 0 else {
          if !warnings.contains(.evidenceBudgetReached) {
            warnings.append(.evidenceBudgetReached)
          }
          break
        }
        let excerpt = bounded(passage.1, to: min(800, remainingCharacters))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { continue }
        evidenceSequence += 1
        let anchoredSource = AskSourceReference(
          kind: candidate.source.kind,
          entityID: candidate.source.entityID,
          revision: candidate.source.revision,
          anchor: passage.0
        )
        evidence.append(
          AskQueryEvidence(
            id: "E\(evidenceSequence)",
            source: anchoredSource,
            anchor: passage.0,
            excerpt: excerpt
          ))
        evidencePassages += 1
        evidenceCharacters += excerpt.count
      }
      guard !evidence.isEmpty else { break }
      items.append(
        AskQueryItem(
          source: candidate.source,
          title: candidate.title,
          status: candidate.status,
          dueAt: candidate.dueAt,
          startsAt: candidate.startsAt,
          endsAt: candidate.endsAt,
          updatedAt: candidate.updatedAt,
          isStarred: candidate.isStarred,
          isAllDay: candidate.isAllDay,
          collectionName: candidate.collectionName,
          evidence: evidence
        ))
    }

    calls += 1
    callsByDomain[query.domain, default: 0] += 1
    pagesByDomain[query.domain, default: 0] += 1
    records += items.count

    let consumedCandidates = offset + items.count
    let hasMore = consumedCandidates < candidates.count
    let canContinue =
      hasMore
      && calls < budget.maximumCalls
      && callsByDomain[query.domain, default: 0] < budget.maximumCallsPerDomain
      && pagesByDomain[query.domain, default: 0] < budget.maximumPagesPerDomain
      && records < budget.maximumTotalRecords
      && evidencePassages < budget.maximumEvidencePassages
      && evidenceCharacters < budget.maximumEvidenceCharacters
    let cursor = canContinue ? try encodedCursor(offset: consumedCandidates, for: query) : nil
    if hasMore && cursor == nil && !warnings.contains(.resultBudgetReached) {
      warnings.append(.resultBudgetReached)
    }

    if let domain = catalog.domains.first(where: { $0.domain == query.domain }) {
      if domain.freshness == .stale { warnings.append(.staleSource) }
      if domain.coverage.isTruncated { warnings.append(.truncatedSource) }
    }
    warnings = Array(Set(warnings)).sorted { $0.rawValue < $1.rawValue }
    let completeness: AskQueryCompleteness = warnings.isEmpty ? .complete : .partial
    let page = AskQueryPage(
      queryID: query.queryID,
      snapshotID: catalog.snapshotID,
      domain: query.domain,
      completeness: completeness,
      observedAt: temporalContext.contextAsOf,
      totalMatched: candidates.count,
      items: items,
      hasMore: hasMore,
      nextCursor: cursor,
      warnings: warnings,
      budgetUsage: currentUsage()
    )
    progress(
      nextProgress(
        query,
        phase: .pageProduced,
        returnedCount: items.count,
        totalMatched: candidates.count,
        isTruncated: hasMore
      ))
    progress(
      nextProgress(
        query,
        phase: .completed,
        returnedCount: items.count,
        totalMatched: candidates.count,
        isTruncated: hasMore
      ))
    return page
  }

  private func ensureBudgetAvailable(for query: AskReadQuery) throws {
    guard calls < budget.maximumCalls else {
      throw AskQueryFailure(code: .budgetExceeded, queryID: query.queryID, field: "calls")
    }
    guard callsByDomain[query.domain, default: 0] < budget.maximumCallsPerDomain else {
      throw AskQueryFailure(
        code: .budgetExceeded, queryID: query.queryID, field: "callsPerDomain")
    }
    guard pagesByDomain[query.domain, default: 0] < budget.maximumPagesPerDomain else {
      throw AskQueryFailure(
        code: .budgetExceeded, queryID: query.queryID, field: "pagesPerDomain")
    }
  }

  private func currentUsage() -> AskQueryBudgetUsage {
    let domains = AskSourceKind.allCases.compactMap { domain -> AskQueryDomainUsage? in
      let domainCalls = callsByDomain[domain, default: 0]
      let domainPages = pagesByDomain[domain, default: 0]
      guard domainCalls > 0 || domainPages > 0 else { return nil }
      return AskQueryDomainUsage(domain: domain, calls: domainCalls, pages: domainPages)
    }
    return AskQueryBudgetUsage(
      calls: calls,
      records: records,
      evidencePassages: evidencePassages,
      evidenceCharacters: evidenceCharacters,
      domains: domains
    )
  }

  private func nextProgress(
    _ query: AskReadQuery,
    phase: AskQueryProgressPhase,
    returnedCount: Int = 0,
    totalMatched: Int? = nil,
    isTruncated: Bool = false
  ) -> AskQueryProgress {
    progressSequence += 1
    return AskQueryProgress(
      sequence: progressSequence,
      queryID: query.queryID,
      domain: query.domain,
      phase: phase,
      returnedCount: returnedCount,
      totalMatched: totalMatched,
      isTruncated: isTruncated,
      observedAt: temporalContext.contextAsOf
    )
  }

  // MARK: Cursor binding

  private struct Cursor: Codable {
    var version: Int
    var snapshotID: String
    var domain: AskSourceKind
    var fingerprint: String
    var offset: Int
  }

  private func encodedCursor(offset: Int, for query: AskReadQuery) throws -> String {
    let cursor = Cursor(
      version: AskDataCatalog.protocolVersion,
      snapshotID: catalog.snapshotID,
      domain: query.domain,
      fingerprint: try fingerprint(query),
      offset: offset
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(cursor).base64EncodedString()
  }

  private func decodedOffset(_ raw: String?, for query: AskReadQuery) throws -> Int {
    guard let raw else { return 0 }
    guard let data = Data(base64Encoded: raw),
      let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
      cursor.version == AskDataCatalog.protocolVersion,
      cursor.snapshotID == catalog.snapshotID,
      cursor.domain == query.domain,
      cursor.fingerprint == (try? fingerprint(query)),
      cursor.offset >= 0
    else {
      throw AskQueryFailure(code: .invalidCursor, queryID: query.queryID, field: "cursor")
    }
    return cursor.offset
  }

  private func fingerprint(_ query: AskReadQuery) throws -> String {
    let withoutCursor: AskReadQuery
    switch query {
    case .todo(var value):
      value.cursor = nil
      withoutCursor = .todo(value)
    case .calendar(var value):
      value.cursor = nil
      withoutCursor = .calendar(value)
    case .note(var value):
      value.cursor = nil
      withoutCursor = .note(value)
    case .meeting(var value):
      value.cursor = nil
      withoutCursor = .meeting(value)
    case .codex(var value):
      value.cursor = nil
      withoutCursor = .codex(value)
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(withoutCursor)
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }
}

// MARK: - Private deterministic helpers

private struct Candidate {
  var source: AskSourceReference
  var title: String
  var status: AskKnowledgeStatus?
  var dueAt: Date?
  var startsAt: Date?
  var endsAt: Date?
  var updatedAt: Date
  var isStarred: Bool?
  var isAllDay: Bool?
  var collectionName: String?
  var passages: [(String, String)]
}

private struct MeetingRecord {
  var meeting: SyncedMeetingSession
  var summary: String?
  var transcript: String?

  var isReadable: Bool { summary != nil || transcript != nil }
  var occurrenceDate: Date { meeting.endedAt ?? meeting.startedAt }
}

private struct CodexRecord {
  var thread: SyncedCodexThread
  var visibleOutputs: [SyncedCodexOutputExcerpt]
}

private func meetingRecord(_ meeting: SyncedMeetingSession, note: SyncedNote?) -> MeetingRecord {
  let noteContent = note.map { MeetingNoteContent(markdown: $0.body) }
  let segmentTranscript = meeting.transcriptSegments?
    .compactMap { $0.text.askV2NonEmpty }
    .joined(separator: "\n")
    .askV2NonEmpty
  let transcript = segmentTranscript ?? noteContent?.transcript.askV2NonEmpty
  let summary =
    noteContent?.summary?.askV2NonEmpty
    ?? (segmentTranscript != nil ? note?.body.askV2NonEmpty : nil)
  return MeetingRecord(
    meeting: meeting,
    summary: summary,
    transcript: transcript
  )
}

private func meetingState(_ state: SyncedMeetingState) -> AskMeetingStateFilter {
  switch state {
  case .recording: .recording
  case .completed: .completed
  case .failed: .failed
  }
}

private func meetingStatus(_ state: SyncedMeetingState) -> AskKnowledgeStatus {
  switch state {
  case .recording: .recording
  case .completed: .completed
  case .failed: .failed
  }
}

private func codexState(_ state: SyncedCodexState) -> AskCodexStateFilter {
  switch state {
  case .running: .running
  case .waitingForInput: .waitingForInput
  case .needsApproval: .needsApproval
  case .completed: .completed
  case .failed: .failed
  }
}

private func codexStatus(_ state: SyncedCodexState) -> AskKnowledgeStatus {
  switch state {
  case .running: .running
  case .waitingForInput: .waitingForInput
  case .needsApproval: .needsApproval
  case .completed: .completed
  case .failed: .failed
  }
}

private func codexMode(_ mode: SyncedThreadMode) -> AskCodexModeFilter {
  switch mode {
  case .plan: .plan
  case .goal: .goal
  case .voice: .voice
  }
}

private func uniqueVisibleOutputs(
  _ outputs: [SyncedCodexOutputExcerpt]
) -> [SyncedCodexOutputExcerpt] {
  var newestByID: [String: SyncedCodexOutputExcerpt] = [:]
  for output in outputs {
    if let current = newestByID[output.id], current.occurredAt >= output.occurredAt { continue }
    newestByID[output.id] = output
  }
  return newestByID.values.sorted {
    if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
    return $0.id < $1.id
  }
}

private func codexRelevance(_ query: String?, record: CodexRecord) -> Int {
  relevance(
    query,
    title: record.thread.title,
    body: [
      record.thread.projectName,
      record.thread.activity,
      record.visibleOutputs.map(\.text).joined(separator: "\n"),
    ]
  )
}

private func normalized(_ value: String) -> String {
  value
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    .lowercased()
}

private func normalizedSet(_ values: [String]) -> Set<String> {
  Set(values.map(normalized).filter { !$0.isEmpty })
}

private func textMatches(_ query: String?, in values: [String?]) -> Bool {
  guard let query = query?.askV2NonEmpty else { return true }
  let terms = normalized(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
  let haystack = normalized(values.compactMap { $0 }.joined(separator: " "))
  return terms.allSatisfy { haystack.contains($0) }
}

private func relevance(_ query: String?, title: String, body: [String?]) -> Int {
  guard let query = query?.askV2NonEmpty else { return 0 }
  let normalizedQuery = normalized(query)
  let normalizedTitle = normalized(title)
  let terms = normalizedQuery.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
  var score = normalizedTitle == normalizedQuery ? 100 : 0
  if normalizedTitle.contains(normalizedQuery) { score += 40 }
  let bodyText = normalized(body.compactMap { $0 }.joined(separator: " "))
  for term in terms {
    if normalizedTitle.contains(term) { score += 10 }
    if bodyText.contains(term) { score += 3 }
  }
  return score
}

private func todoAttention(
  _ todo: SyncedTodo,
  today: Date,
  tomorrow: Date,
  nextWeek: Date
) -> Int {
  guard !todo.isCompleted else { return 0 }
  if let due = todo.dueDate, due < today { return 400 }
  if let due = todo.dueDate, due >= today, due < tomorrow { return 300 }
  if todo.isStarred { return 200 }
  if let due = todo.dueDate, due >= tomorrow, due < nextWeek { return 100 }
  return 0
}

private func compareAscending<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
  if lhs < rhs { return .orderedAscending }
  if lhs > rhs { return .orderedDescending }
  return .orderedSame
}

private func compareDescending<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
  compareAscending(rhs, lhs)
}

private func compareOptionalDatesAscending(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
  switch (lhs, rhs) {
  case (.some(let lhs), .some(let rhs)): compareAscending(lhs, rhs)
  case (.some, .none): .orderedAscending
  case (.none, .some): .orderedDescending
  case (.none, .none): .orderedSame
  }
}

private func compareOptionalDatesDescending(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
  switch (lhs, rhs) {
  case (.some(let lhs), .some(let rhs)): compareDescending(lhs, rhs)
  case (.some, .none): .orderedAscending
  case (.none, .some): .orderedDescending
  case (.none, .none): .orderedSame
  }
}

private func joined(_ values: [String?]) -> String {
  values.compactMap { $0?.askV2NonEmpty }.joined(separator: "\n")
}

private func bounded(_ value: String, to maximum: Int) -> String {
  guard maximum > 0 else { return "" }
  if value.count <= maximum { return value }
  return String(value.prefix(maximum))
}

private func passageChunks(
  _ value: String,
  prefix: String,
  maximum: Int
) -> [(String, String)] {
  let paragraphs =
    value
    .replacingOccurrences(of: "\r\n", with: "\n")
    .components(separatedBy: "\n\n")
    .compactMap(\.askV2NonEmpty)
  var chunks: [(String, String)] = []
  for paragraph in paragraphs {
    guard chunks.count < maximum else { break }
    chunks.append(("\(prefix):\(chunks.count)", bounded(paragraph, to: 800)))
  }
  if chunks.isEmpty, let value = value.askV2NonEmpty {
    chunks.append(("\(prefix):0", bounded(value, to: 800)))
  }
  return chunks
}

extension String {
  fileprivate var askV2NonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
