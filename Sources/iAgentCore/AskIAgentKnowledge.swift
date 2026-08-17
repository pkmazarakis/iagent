import Foundation

/// The user-owned data domains that Ask iAgent is allowed to read.
public enum AskSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
  case todo
  case calendar
  case note
  case meeting
  case codex
}

/// A stable reference back to an iAgent entity and, optionally, a precise excerpt.
public struct AskSourceReference: Codable, Hashable, Sendable {
  public var kind: AskSourceKind
  public var entityID: String
  public var revision: Date
  public var anchor: String?

  public init(
    kind: AskSourceKind,
    entityID: String,
    revision: Date,
    anchor: String? = nil
  ) {
    self.kind = kind
    self.entityID = entityID
    self.revision = revision
    self.anchor = anchor
  }

  public var stableID: String {
    ([kind.rawValue, entityID] + (anchor.map { [$0] } ?? [])).joined(separator: ":")
  }
}

public struct AskDateRange: Codable, Equatable, Sendable {
  /// Inclusive lower bound.
  public var start: Date
  /// Exclusive upper bound.
  public var end: Date

  public init(start: Date, end: Date) {
    self.start = start
    self.end = max(start, end)
  }

  public func contains(_ date: Date) -> Bool {
    date >= start && date < end
  }

  public func intersects(_ other: AskDateRange) -> Bool {
    start < other.end && other.start < end
  }
}

public enum AskKnowledgeStatus: String, Codable, Hashable, Sendable {
  case open
  case completed
  case scheduled
  case recording
  case running
  case waitingForInput
  case needsApproval
  case failed
}

/// Structured fields are kept out of model-generated prose so dates and statuses can be filtered exactly.
public struct AskKnowledgeFacets: Codable, Equatable, Sendable {
  public var status: AskKnowledgeStatus?
  public var isStarred: Bool
  public var dueDate: Date?
  public var temporalRange: AskDateRange?

  public init(
    status: AskKnowledgeStatus? = nil,
    isStarred: Bool = false,
    dueDate: Date? = nil,
    temporalRange: AskDateRange? = nil
  ) {
    self.status = status
    self.isStarred = isStarred
    self.dueDate = dueDate
    self.temporalRange = temporalRange
  }
}

public struct AskKnowledgeDocument: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var source: AskSourceReference
  public var title: String
  public var text: String
  public var updatedAt: Date
  public var facets: AskKnowledgeFacets
  public var metadata: [String: String]

  public init(
    id: String,
    source: AskSourceReference,
    title: String,
    text: String,
    updatedAt: Date,
    facets: AskKnowledgeFacets = AskKnowledgeFacets(),
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.source = source
    self.title = title
    self.text = text
    self.updatedAt = updatedAt
    self.facets = facets
    self.metadata = metadata
  }
}

public struct AskKnowledgeChunk: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var documentID: String
  public var source: AskSourceReference
  public var title: String
  public var text: String
  public var updatedAt: Date
  public var facets: AskKnowledgeFacets
  public var metadata: [String: String]

  public init(
    id: String,
    documentID: String,
    source: AskSourceReference,
    title: String,
    text: String,
    updatedAt: Date,
    facets: AskKnowledgeFacets = AskKnowledgeFacets(),
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.documentID = documentID
    self.source = source
    self.title = title
    self.text = text
    self.updatedAt = updatedAt
    self.facets = facets
    self.metadata = metadata
  }
}

/// A value-semantic, per-turn view of user data. Changes arriving during a turn belong to the next turn.
public struct AskDataSnapshot: Sendable, Equatable {
  public var data: IAgentDataSnapshot
  public var contextAsOf: Date
  /// Exact, source-owned capture bounds for domains whose backing API was queried over a finite
  /// range. An override remains meaningful when the capture returned zero records; deriving
  /// coverage from record extrema would otherwise turn an authoritative empty result into an
  /// unknown range.
  public var coverageOverrides: [AskSourceKind: AskCatalogCoverage]

  public init(
    data: IAgentDataSnapshot,
    contextAsOf: Date = Date(),
    coverageOverrides: [AskSourceKind: AskCatalogCoverage] = [:]
  ) {
    self.data = data
    self.contextAsOf = contextAsOf
    self.coverageOverrides = coverageOverrides
  }
}

public struct AskKnowledgeCorpus: Codable, Equatable, Sendable {
  public var contextAsOf: Date
  public var documents: [AskKnowledgeDocument]
  public var chunks: [AskKnowledgeChunk]

  public init(
    contextAsOf: Date,
    documents: [AskKnowledgeDocument],
    chunks: [AskKnowledgeChunk]
  ) {
    self.contextAsOf = contextAsOf
    self.documents = documents
    self.chunks = chunks
  }

  public init(snapshot: AskDataSnapshot, maximumChunkCharacters: Int = 900) {
    self = AskKnowledgeNormalizer.normalize(
      snapshot: snapshot,
      maximumChunkCharacters: maximumChunkCharacters
    )
  }
}

public enum AskStatusFilter: String, Codable, CaseIterable, Hashable, Sendable {
  case open
  case completed
  case overdue
  case starred
  case active
  case failed
  case priority
}

/// The high-level job a question asks Ask iAgent to perform. Intent is resolved before lexical
/// terms so phrases such as "tasks I need to complete" are treated as outstanding work rather
/// than completed history.
public enum AskResearchIntent: String, Codable, Equatable, Sendable {
  case lookup
  case dailyOverview
  case dailyPlanning
  case explanation
  case actionableWork
  case completedWork
  case recentUpdates
  case priorities
  case schedule
  case meetingRecall
}

/// Selects which authoritative timestamp a source-specific search uses.
public enum AskTemporalField: String, Codable, Equatable, Sendable {
  case relevant
  case occurrence
  case due
  case updated
}

public struct AskQueryPlan: Codable, Equatable, Sendable {
  public var originalQuery: String
  /// Empty means every source is eligible.
  public var sourceKinds: Set<AskSourceKind>
  public var terms: [String]
  public var dateRange: AskDateRange?
  public var temporalField: AskTemporalField
  public var statusFilters: Set<AskStatusFilter>
  public var requestsExactCount: Bool

  public init(
    originalQuery: String,
    sourceKinds: Set<AskSourceKind> = [],
    terms: [String] = [],
    dateRange: AskDateRange? = nil,
    temporalField: AskTemporalField = .relevant,
    statusFilters: Set<AskStatusFilter> = [],
    requestsExactCount: Bool = false
  ) {
    self.originalQuery = originalQuery
    self.sourceKinds = sourceKinds
    self.terms = terms
    self.dateRange = dateRange
    self.temporalField = temporalField
    self.statusFilters = statusFilters
    self.requestsExactCount = requestsExactCount
  }
}

/// One fast, independently executable search over a single iAgent data domain.
public struct AskResearchQuery: Codable, Equatable, Identifiable, Sendable {
  public enum Selection: String, Codable, Equatable, Sendable {
    /// Rank chunks by lexical relevance plus source-aware recency.
    case relevance
    /// Choose the newest completed record with readable content by occurrence time, then keep its
    /// summary and transcript together. This is intentionally document-first rather than chunk-first.
    case latestCompletedOccurrence
  }

  public var id: String
  public var reason: String
  public var plan: AskQueryPlan
  public var resultLimit: Int
  public var weight: Double
  public var selection: Selection
  public var maximumDocuments: Int?
  public var maximumChunksPerDocument: Int?

  public init(
    id: String,
    reason: String,
    plan: AskQueryPlan,
    resultLimit: Int = 3,
    weight: Double = 1,
    selection: Selection = .relevance,
    maximumDocuments: Int? = nil,
    maximumChunksPerDocument: Int? = nil
  ) {
    self.id = id
    self.reason = reason
    self.plan = plan
    self.resultLimit = max(1, resultLimit)
    self.weight = max(0.1, weight)
    self.selection = selection
    self.maximumDocuments = maximumDocuments.map { max(1, $0) }
    self.maximumChunksPerDocument = maximumChunksPerDocument.map { max(1, $0) }
  }
}

/// The complete local research plan for one turn. Searches are deliberately source-specific so a
/// high-scoring domain cannot starve the other domains the question requires.
public struct AskResearchPlan: Codable, Equatable, Sendable {
  public var originalQuery: String
  public var resolvedQuery: String
  public var intent: AskResearchIntent
  public var searches: [AskResearchQuery]
  public var requestsExactCount: Bool

  public init(
    originalQuery: String,
    resolvedQuery: String,
    intent: AskResearchIntent,
    searches: [AskResearchQuery],
    requestsExactCount: Bool = false
  ) {
    self.originalQuery = originalQuery
    self.resolvedQuery = resolvedQuery
    self.intent = intent
    self.searches = searches
    self.requestsExactCount = requestsExactCount
  }

  public var searchedSourceKinds: Set<AskSourceKind> {
    Set(searches.flatMap(\.plan.sourceKinds))
  }
}

public struct AskSearchCoverage: Codable, Equatable, Sendable {
  public var queryID: String
  public var sourceKind: AskSourceKind
  public var reason: String
  public var totalMatches: Int
  public var returnedMatches: Int

  public init(
    queryID: String,
    sourceKind: AskSourceKind,
    reason: String,
    totalMatches: Int,
    returnedMatches: Int
  ) {
    self.queryID = queryID
    self.sourceKind = sourceKind
    self.reason = reason
    self.totalMatches = totalMatches
    self.returnedMatches = returnedMatches
  }
}

/// A privacy-safe, display-ready observation from one deterministic local search. It exposes
/// record identity and title only so clients can explain what was scanned without exposing model
/// reasoning, excerpts, or hidden relevance scores.
public struct AskSearchProgressItem: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

public struct AskSearchProgress: Codable, Equatable, Sendable {
  public var queryID: String
  public var sourceKind: AskSourceKind
  public var items: [AskSearchProgressItem]

  public init(
    queryID: String,
    sourceKind: AskSourceKind,
    items: [AskSearchProgressItem]
  ) {
    self.queryID = queryID
    self.sourceKind = sourceKind
    self.items = items
  }

  public var totalMatches: Int { items.count }
}

public struct AskResearchResult: Codable, Equatable, Sendable {
  public var plan: AskResearchPlan
  public var contextAsOf: Date
  public var evidence: [AskEvidence]
  public var coverage: [AskSearchCoverage]
  public var searchProgress: [AskSearchProgress]

  public init(
    plan: AskResearchPlan,
    contextAsOf: Date,
    evidence: [AskEvidence],
    coverage: [AskSearchCoverage],
    searchProgress: [AskSearchProgress] = []
  ) {
    self.plan = plan
    self.contextAsOf = contextAsOf
    self.evidence = evidence
    self.coverage = coverage
    self.searchProgress = searchProgress
  }

  /// Coalesces the planner's source-specific query batches into the exact source-operation order
  /// shown to the user. Multiple queries against one source (for example overdue, due-today, and
  /// starred to-dos) remain one observable read with de-duplicated record titles.
  public var groupedSearchProgress: [AskSearchProgress] {
    var sourceOrder: [AskSourceKind] = []
    var seenItemIDs: [AskSourceKind: Set<String>] = [:]
    var itemsBySource: [AskSourceKind: [AskSearchProgressItem]] = [:]

    for observation in searchProgress {
      let kind = observation.sourceKind
      if seenItemIDs[kind] == nil {
        sourceOrder.append(kind)
        seenItemIDs[kind] = []
      }
      for item in observation.items where seenItemIDs[kind, default: []].insert(item.id).inserted {
        itemsBySource[kind, default: []].append(item)
      }
    }

    return sourceOrder.map { kind in
      AskSearchProgress(
        queryID: "grouped-\(kind.rawValue)",
        sourceKind: kind,
        items: itemsBySource[kind, default: []]
      )
    }
  }

  /// Collapses query-level coverage to one row per source. This is the bounded coverage contract
  /// sent to language models and relays; it cannot exceed the five known iAgent source domains.
  /// Distinct progress item IDs preserve the exact union when several filters searched one source.
  public var groupedCoverage: [AskSearchCoverage] {
    var sourceOrder: [AskSourceKind] = []
    var reasonsBySource: [AskSourceKind: [String]] = [:]
    var queryMaximumBySource: [AskSourceKind: Int] = [:]
    var matchedIDsBySource: [AskSourceKind: Set<String>] = [:]

    for item in coverage {
      if reasonsBySource[item.sourceKind] == nil { sourceOrder.append(item.sourceKind) }
      if !item.reason.isEmpty,
        !reasonsBySource[item.sourceKind, default: []].contains(item.reason)
      {
        reasonsBySource[item.sourceKind, default: []].append(item.reason)
      }
      queryMaximumBySource[item.sourceKind] = max(
        queryMaximumBySource[item.sourceKind, default: 0],
        item.totalMatches
      )
    }
    for observation in searchProgress {
      for item in observation.items {
        matchedIDsBySource[observation.sourceKind, default: []].insert(item.id)
      }
    }

    let returnedIDsBySource = Dictionary(grouping: evidence, by: { $0.chunk.source.kind })
      .mapValues { Set($0.map(\.chunk.documentID)).count }
    return sourceOrder.map { kind in
      AskSearchCoverage(
        queryID: "grouped-\(kind.rawValue)",
        sourceKind: kind,
        reason: reasonsBySource[kind, default: []].joined(separator: "; "),
        totalMatches: max(
          queryMaximumBySource[kind, default: 0],
          matchedIDsBySource[kind, default: []].count
        ),
        returnedMatches: returnedIDsBySource[kind, default: 0]
      )
    }
  }
}

public enum AskQueryPlanner {
  public static func plan(
    _ query: String,
    referenceDate: Date = Date(),
    calendar suppliedCalendar: Calendar = .current
  ) -> AskQueryPlan {
    var calendar = suppliedCalendar
    if calendar.timeZone.identifier.isEmpty {
      calendar.timeZone = .current
    }

    let normalized = query.askNormalized
    let tokens = AskLexical.tokenize(normalized)
    let tokenSet = Set(tokens)
    var sourceKinds = Set<AskSourceKind>()

    let explicitlyCodex = !tokenSet.isDisjoint(with: ["codex", "thread", "threads"])
    let explicitlyTodo = !tokenSet.isDisjoint(with: ["todo", "todos", "checklist"])
    let genericTask = !tokenSet.isDisjoint(with: ["task", "tasks"])
    if explicitlyTodo || (genericTask && !explicitlyCodex) {
      sourceKinds.insert(.todo)
    }
    if !tokenSet.isDisjoint(with: ["note", "notes", "document", "documents"]) {
      sourceKinds.insert(.note)
    }
    if explicitlyCodex {
      sourceKinds.insert(.codex)
    }

    let hasMeetingNoteIntent =
      normalized.contains("meeting note")
      || normalized.contains("meeting notes")
    let hasRecordedMeetingIntent =
      hasMeetingNoteIntent
      || !tokenSet.isDisjoint(with: [
        "action-items", "conversation", "decide", "decided", "decision", "decisions", "discuss",
        "discussed", "mentioned", "recording", "recordings", "said", "summaries", "summary",
        "summarise", "summarize", "talked", "transcript", "transcripts",
      ]) || (tokenSet.contains("action") && tokenSet.contains("items"))
    if hasRecordedMeetingIntent {
      sourceKinds.insert(.meeting)
    }
    if hasMeetingNoteIntent {
      sourceKinds.remove(.note)
    }

    let hasMeetingWord = !tokenSet.isDisjoint(with: ["meeting", "meetings"])
    if !tokenSet.isDisjoint(with: [
      "calendar", "calendars", "event", "events", "schedule", "appointment",
    ]) || normalized.contains("free time") || tokenSet.contains("availability")
      || (hasMeetingWord && !hasRecordedMeetingIntent)
    {
      sourceKinds.insert(.calendar)
    }

    var statusFilters = Set<AskStatusFilter>()
    let asksForActionableWork =
      normalized.contains("need to complete")
      || normalized.contains("need to finish")
      || normalized.contains("need to do")
      || normalized.contains("needs my attention")
      || normalized.contains("need my attention")
      || normalized.contains("needs attention")
      || normalized.contains("need attention")
      || normalized.contains("left to do")
      || tokenSet.contains("outstanding")
    let asksForCompletedHistory =
      normalized.contains("completed tasks")
      || normalized.contains("completed todos")
      || normalized.contains("tasks i completed")
      || normalized.contains("todos i completed")
      || normalized.contains("did i complete")
      || normalized.contains("have i completed")
      || normalized.contains("i finished")

    if asksForActionableWork {
      statusFilters.insert(.open)
    } else if asksForCompletedHistory
      || !tokenSet.isDisjoint(with: ["completed", "done", "finished"])
    {
      statusFilters.insert(.completed)
    } else if !tokenSet.isDisjoint(with: ["open", "incomplete", "pending", "unfinished"]) {
      statusFilters.insert(.open)
    }
    if !tokenSet.isDisjoint(with: ["overdue", "late"]) {
      statusFilters.insert(.overdue)
    }
    if !tokenSet.isDisjoint(with: ["starred", "favorite", "favourite"]) {
      statusFilters.insert(.starred)
    }
    if !tokenSet.isDisjoint(with: ["active", "running", "live"])
      || normalized.contains("waiting for me")
      || normalized.contains("needs approval")
      || normalized.contains("need approval")
    {
      statusFilters.insert(.active)
    }
    if !tokenSet.isDisjoint(with: ["failed", "failure", "error", "errors"]) {
      statusFilters.insert(.failed)
    }
    if !tokenSet.isDisjoint(with: ["urgent", "priority", "priorities", "focus"]) {
      statusFilters.insert(.priority)
    }

    let dateRange = parsedDateRange(
      normalized,
      tokenSet: tokenSet,
      referenceDate: referenceDate,
      calendar: calendar
    )
    let ignored = AskLexical.stopWords
      .union(AskLexical.sourceWords)
      .union(AskLexical.filterWords)
      .union(AskLexical.dateWords)
      .union(AskLexical.intentWords)
    let terms = tokens.filter { token in
      !ignored.contains(token) && !token.allSatisfy(\.isNumber)
    }.uniqued()

    let temporalField: AskTemporalField
    if sourceKinds == [.calendar] || sourceKinds == [.meeting] {
      temporalField = .occurrence
    } else if sourceKinds == [.todo] {
      temporalField = .due
    } else {
      temporalField = .relevant
    }

    return AskQueryPlan(
      originalQuery: query,
      sourceKinds: sourceKinds,
      terms: terms,
      dateRange: dateRange,
      temporalField: temporalField,
      statusFilters: statusFilters,
      requestsExactCount: normalized.contains("how many")
        || normalized.contains("number of")
        || tokenSet.contains("count")
    )
  }

  private static func parsedDateRange(
    _ normalized: String,
    tokenSet: Set<String>,
    referenceDate: Date,
    calendar: Calendar
  ) -> AskDateRange? {
    let today = calendar.startOfDay(for: referenceDate)
    func addingDays(_ count: Int, to date: Date) -> Date {
      calendar.date(byAdding: .day, value: count, to: date) ?? date
    }

    if normalized.contains("tomorrow") {
      let start = addingDays(1, to: today)
      return AskDateRange(start: start, end: addingDays(1, to: start))
    }
    if normalized.contains("yesterday") {
      let start = addingDays(-1, to: today)
      return AskDateRange(start: start, end: today)
    }
    if normalized.contains("today") || normalized.contains("this morning")
      || normalized.contains("this afternoon") || normalized.contains("tonight")
    {
      return AskDateRange(start: today, end: addingDays(1, to: today))
    }

    if let count = capturedDayCount(in: normalized, prefix: "last")
      ?? capturedDayCount(in: normalized, prefix: "past")
    {
      return AskDateRange(
        start: addingDays(-(max(1, count) - 1), to: today), end: addingDays(1, to: today))
    }
    if let count = capturedDayCount(in: normalized, prefix: "next") {
      return AskDateRange(start: today, end: addingDays(max(1, count), to: today))
    }

    if normalized.contains("this week"),
      let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate)
    {
      return AskDateRange(start: interval.start, end: interval.end)
    }
    if normalized.contains("next week"),
      let current = calendar.dateInterval(of: .weekOfYear, for: referenceDate),
      let start = calendar.date(byAdding: .weekOfYear, value: 1, to: current.start),
      let end = calendar.date(byAdding: .weekOfYear, value: 1, to: current.end)
    {
      return AskDateRange(start: start, end: end)
    }
    if normalized.contains("last week"),
      let current = calendar.dateInterval(of: .weekOfYear, for: referenceDate),
      let start = calendar.date(byAdding: .weekOfYear, value: -1, to: current.start)
    {
      return AskDateRange(start: start, end: current.start)
    }

    // "Upcoming" is intentionally bounded so a broad query cannot flood the model context.
    if tokenSet.contains("upcoming") {
      return AskDateRange(start: today, end: addingDays(30, to: today))
    }
    if tokenSet.contains("recent") || tokenSet.contains("recently") {
      return AskDateRange(start: addingDays(-29, to: today), end: addingDays(1, to: today))
    }
    return nil
  }

  private static func capturedDayCount(in text: String, prefix: String) -> Int? {
    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: prefix))\\s+(\\d{1,3})\\s+days?\\b"
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: text,
        range: NSRange(text.startIndex..., in: text)
      ),
      let range = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return Int(text[range]).map { min($0, 365) }
  }
}

/// Expands one conversational request into a small set of source-specific local searches. The
/// expansion is deterministic, fast, and intentionally happens before any language-model call.
public enum AskResearchPlanner {
  public static func plan(
    _ query: String,
    recentUserQueries: [String] = [],
    referenceDate: Date = Date(),
    calendar suppliedCalendar: Calendar = .current
  ) -> AskResearchPlan {
    var calendar = suppliedCalendar
    if calendar.timeZone.identifier.isEmpty {
      calendar.timeZone = .current
    }

    let resolvedQuery = resolveFollowUp(query, recentUserQueries: recentUserQueries)
    var base = AskQueryPlanner.plan(
      resolvedQuery,
      referenceDate: referenceDate,
      calendar: calendar
    )
    if resolvedQuery != query {
      let currentTurn = AskQueryPlanner.plan(
        query,
        referenceDate: referenceDate,
        calendar: calendar
      )
      if !currentTurn.sourceKinds.isEmpty {
        base.sourceKinds = currentTurn.sourceKinds
      }
      if !currentTurn.statusFilters.isEmpty {
        base.statusFilters = currentTurn.statusFilters
      }
      if let dateRange = currentTurn.dateRange {
        base.dateRange = dateRange
      }
      base.requestsExactCount = base.requestsExactCount || currentTurn.requestsExactCount
    }
    let normalized = resolvedQuery.askNormalized
    let tokens = Set(AskLexical.tokenize(normalized))
    let intent =
      isExplanationFollowUp(query)
      ? .explanation
      : intent(
        normalized: normalized,
        tokens: tokens,
        plan: base
      )
    let broadDecisionIntent = [
      AskResearchIntent.dailyOverview,
      .dailyPlanning,
      .priorities,
    ].contains(intent)
    let subjectTerms = base.terms.filter { term in
      !AskLexical.intentWords.contains(term)
        && (!broadDecisionIntent || !AskLexical.decisionFillerWords.contains(term))
    }
    var searches: [AskResearchQuery] = []

    func append(
      _ id: String,
      kind: AskSourceKind,
      reason: String,
      terms: [String] = [],
      dateRange: AskDateRange? = nil,
      temporalField: AskTemporalField = .relevant,
      statusFilters: Set<AskStatusFilter> = [],
      resultLimit: Int = 3,
      weight: Double = 1,
      selection: AskResearchQuery.Selection = .relevance,
      maximumDocuments: Int? = nil,
      maximumChunksPerDocument: Int? = nil
    ) {
      var sourcePlan = base
      sourcePlan.sourceKinds = [kind]
      sourcePlan.terms = terms
      sourcePlan.dateRange = dateRange
      sourcePlan.temporalField = temporalField
      sourcePlan.statusFilters = statusFilters
      searches.append(
        AskResearchQuery(
          id: id,
          reason: reason,
          plan: sourcePlan,
          resultLimit: resultLimit,
          weight: weight,
          selection: selection,
          maximumDocuments: maximumDocuments,
          maximumChunksPerDocument: maximumChunksPerDocument
        ))
    }

    switch intent {
    case .dailyOverview:
      let day = base.dateRange ?? dayRange(containing: referenceDate, calendar: calendar)
      append(
        "agenda-calendar",
        kind: .calendar,
        reason: "scheduled calendar events in the requested day",
        terms: subjectTerms,
        dateRange: day,
        temporalField: .occurrence,
        resultLimit: 4,
        weight: 1.35
      )
      append(
        "agenda-todos",
        kind: .todo,
        reason: "open todos that still need attention",
        terms: subjectTerms,
        statusFilters: [.open],
        resultLimit: 4,
        weight: 1.25
      )
      append(
        "agenda-codex",
        kind: .codex,
        reason: "active Codex work or work waiting for the user",
        terms: subjectTerms,
        statusFilters: [.active],
        resultLimit: 3,
        weight: 1.15
      )

    case .dailyPlanning:
      let day = base.dateRange ?? dayRange(containing: referenceDate, calendar: calendar)
      let recent = recentRange(referenceDate: referenceDate, calendar: calendar)
      // "Include my todos" names an additional required lane; it must not silently turn a broad
      // day-planning request into a todo-only search. Existing explicit scopes such as "using only
      // my calendar", "based on my calendar", and "around my calendar" remain restrictive.
      let includesNamedSources = requestsInclusivePlanningScope(normalized)
      let includes: (AskSourceKind) -> Bool = {
        base.sourceKinds.isEmpty || includesNamedSources || base.sourceKinds.contains($0)
      }
      if includes(.calendar) {
        append(
          "plan-calendar",
          kind: .calendar,
          reason: "fixed calendar commitments that shape the requested day",
          terms: subjectTerms,
          dateRange: day,
          temporalField: .occurrence,
          resultLimit: 5,
          weight: 1.45
        )
      }
      if includes(.todo) {
        append(
          "plan-overdue-todos",
          kind: .todo,
          reason: "overdue todos that should not be displaced by recently edited work",
          terms: subjectTerms,
          statusFilters: [.overdue],
          resultLimit: 2,
          weight: 1.65
        )
        append(
          "plan-due-today-todos",
          kind: .todo,
          reason: "open todos due during the requested day",
          terms: subjectTerms,
          dateRange: day,
          temporalField: .due,
          statusFilters: [.open],
          resultLimit: 2,
          weight: 1.55
        )
        append(
          "plan-starred-todos",
          kind: .todo,
          reason: "starred open todos the user marked as important",
          terms: subjectTerms,
          statusFilters: [.open, .starred],
          resultLimit: 2,
          weight: 1.45
        )
        append(
          "plan-open-todos",
          kind: .todo,
          reason: "other unfinished todos available to prioritize",
          terms: subjectTerms,
          statusFilters: [.open],
          resultLimit: 4,
          weight: 1.25
        )
      }
      if includes(.codex) {
        append(
          "plan-codex",
          kind: .codex,
          reason: "active Codex work or work waiting for the user",
          terms: subjectTerms,
          statusFilters: [.active],
          resultLimit: 4,
          weight: 1.25
        )
      }
      if includes(.meeting) {
        append(
          "plan-meeting-actions",
          kind: .meeting,
          reason: "recent meeting commitments and action items that may affect the plan",
          terms: subjectTerms.isEmpty
            ? ["action", "follow", "deadline", "owner", "next"] : subjectTerms,
          dateRange: recent,
          temporalField: .updated,
          resultLimit: 3,
          weight: 0.95
        )
      }
      if includes(.note) {
        append(
          "plan-note-actions",
          kind: .note,
          reason: "recent written commitments or planning context",
          terms: subjectTerms.isEmpty
            ? ["action", "follow", "deadline", "priority", "next"] : subjectTerms,
          dateRange: recent,
          temporalField: .updated,
          resultLimit: 2,
          weight: 0.85
        )
      }

    case .explanation:
      let kinds = base.sourceKinds.isEmpty ? AskSourceKind.allCases : sorted(base.sourceKinds)
      for kind in kinds {
        append(
          "explain-\(kind.rawValue)",
          kind: kind,
          reason: "evidence needed to explain the prior answer’s selections",
          terms: subjectTerms,
          dateRange: base.dateRange,
          temporalField: temporalField(for: kind, requested: base.temporalField),
          statusFilters: base.statusFilters,
          resultLimit: 3,
          weight: 1.2
        )
      }

    case .actionableWork:
      let explicitlyTodo = !tokens.isDisjoint(with: ["todo", "todos", "checklist"])
      let explicitlyCodex =
        tokens.contains("codex") || tokens.contains("thread")
        || tokens.contains("threads")
      if !explicitlyCodex {
        append(
          "open-todos",
          kind: .todo,
          reason: "unfinished todos",
          terms: subjectTerms,
          statusFilters: [.open],
          resultLimit: 5,
          weight: 1.4
        )
      }
      if !explicitlyTodo {
        append(
          "actionable-codex",
          kind: .codex,
          reason: "running Codex work and threads waiting for input or approval",
          terms: subjectTerms,
          statusFilters: [.active],
          resultLimit: 4,
          weight: 1.25
        )
      }

    case .completedWork:
      let kinds =
        base.sourceKinds.isEmpty ? [AskSourceKind.todo, .codex] : sorted(base.sourceKinds)
      for kind in kinds {
        append(
          "completed-\(kind.rawValue)",
          kind: kind,
          reason: "completed \(kind.rawValue) records",
          terms: subjectTerms,
          dateRange: base.dateRange,
          temporalField: base.dateRange == nil ? .relevant : .updated,
          statusFilters: [.completed],
          resultLimit: 4,
          weight: 1.2
        )
      }

    case .recentUpdates:
      let range = base.dateRange ?? recentRange(referenceDate: referenceDate, calendar: calendar)
      let kinds = base.sourceKinds.isEmpty ? AskSourceKind.allCases : sorted(base.sourceKinds)
      for kind in kinds {
        append(
          "updates-\(kind.rawValue)",
          kind: kind,
          reason: "recent \(kind.rawValue) changes related to the subject",
          terms: subjectTerms,
          dateRange: range,
          temporalField: .updated,
          resultLimit: 3,
          weight: kind == .meeting || kind == .codex ? 1.2 : 1
        )
      }

    case .priorities:
      append(
        "priority-todos",
        kind: .todo,
        reason: "starred, overdue, or near-due open todos",
        terms: subjectTerms,
        statusFilters: [.priority],
        resultLimit: 4,
        weight: 1.4
      )
      append(
        "priority-codex",
        kind: .codex,
        reason: "Codex work that is running or waiting for the user",
        terms: subjectTerms,
        statusFilters: [.active],
        resultLimit: 3,
        weight: 1.25
      )
      let upcoming = base.dateRange ?? AskDateRange(
        start: referenceDate,
        end: calendar.date(byAdding: .day, value: 1, to: referenceDate)
          ?? referenceDate.addingTimeInterval(86_400)
      )
      append(
        "priority-calendar",
        kind: .calendar,
        reason: "calendar commitments in the next 24 hours",
        terms: subjectTerms,
        dateRange: upcoming,
        temporalField: .occurrence,
        resultLimit: 3,
        weight: 1.1
      )
      append(
        "priority-open-todos",
        kind: .todo,
        reason: "other unfinished todos to consider when no item is explicitly prioritized",
        terms: subjectTerms,
        statusFilters: [.open],
        resultLimit: 4,
        weight: 0.9
      )
      let recent = recentRange(referenceDate: referenceDate, calendar: calendar)
      append(
        "priority-meeting-actions",
        kind: .meeting,
        reason: "recent meeting commitments that may determine the next priority",
        terms: subjectTerms.isEmpty
          ? ["action", "follow", "deadline", "owner", "next"] : subjectTerms,
        dateRange: recent,
        temporalField: .updated,
        resultLimit: 2,
        weight: 0.8
      )
      append(
        "priority-note-actions",
        kind: .note,
        reason: "recent written commitments that may determine the next priority",
        terms: subjectTerms.isEmpty
          ? ["action", "follow", "deadline", "priority", "next"] : subjectTerms,
        dateRange: recent,
        temporalField: .updated,
        resultLimit: 2,
        weight: 0.7
      )

    case .schedule:
      append(
        "schedule-calendar",
        kind: .calendar,
        reason: "calendar occurrences in the requested time range",
        terms: subjectTerms,
        dateRange: base.dateRange,
        temporalField: .occurrence,
        resultLimit: 6,
        weight: 1.4
      )

    case .meetingRecall:
      if requestsLatestMeeting(normalized: normalized, tokens: tokens) {
        append(
          "latest-meeting-content",
          kind: .meeting,
          reason: "the latest completed meeting with readable summary or transcript content",
          terms: subjectTerms,
          dateRange: base.dateRange,
          temporalField: .occurrence,
          resultLimit: 6,
          weight: 1.7,
          selection: .latestCompletedOccurrence,
          maximumDocuments: 1,
          maximumChunksPerDocument: 6
        )
      } else {
        append(
          "meeting-content",
          kind: .meeting,
          reason: "meeting summaries and transcript excerpts",
          terms: subjectTerms,
          dateRange: base.dateRange,
          temporalField: .occurrence,
          resultLimit: 5,
          weight: 1.35
        )
      }

    case .lookup:
      let kinds = base.sourceKinds.isEmpty ? AskSourceKind.allCases : sorted(base.sourceKinds)
      for kind in kinds {
        append(
          "lookup-\(kind.rawValue)",
          kind: kind,
          reason: "matching \(kind.rawValue) information",
          terms: subjectTerms,
          dateRange: base.dateRange,
          temporalField: temporalField(for: kind, requested: base.temporalField),
          statusFilters: base.statusFilters,
          resultLimit: 3,
          weight: 1
        )
      }
    }

    return AskResearchPlan(
      originalQuery: query,
      resolvedQuery: resolvedQuery,
      intent: intent,
      searches: deduplicated(searches),
      requestsExactCount: base.requestsExactCount
    )
  }

  private static func intent(
    normalized: String,
    tokens: Set<String>,
    plan: AskQueryPlan
  ) -> AskResearchIntent {
    if plan.statusFilters.contains(.completed) { return .completedWork }
    if normalized.contains("plan my day")
      || normalized.contains("plan the day")
      || normalized.contains("plan out my day")
      || normalized.contains("help me plan")
      || normalized.contains("map out my day")
      || normalized.contains("structure my day")
      || normalized.contains("organize my day")
      || normalized.contains("organise my day")
    {
      return .dailyPlanning
    }
    if normalized.contains("top things")
      || normalized.contains("top priorities")
      || normalized.contains("most important things")
    {
      return .priorities
    }
    if normalized.contains("what should i build")
      || normalized.contains("what should i accomplish")
      || normalized.contains("what should i achieve")
      || normalized.contains("what should i work on")
      || normalized.contains("what should i get done")
    {
      return .dailyPlanning
    }
    if normalized.contains("what do i have today")
      || normalized.contains("what's on my day")
      || normalized.contains("whats on my day")
      || normalized.contains("about my day")
      || normalized.contains("my day look like")
      || normalized.contains("attention today")
      || normalized.contains("focus on today")
    {
      return .dailyOverview
    }
    if normalized.contains("need to complete")
      || normalized.contains("need to finish")
      || normalized.contains("need to do")
      || normalized.contains("needs my attention")
      || normalized.contains("need my attention")
      || normalized.contains("needs attention")
      || normalized.contains("need attention")
      || normalized.contains("left to do")
      || tokens.contains("outstanding")
      || plan.statusFilters.contains(.open)
    {
      return .actionableWork
    }
    if !tokens.isDisjoint(with: ["priority", "priorities", "urgent", "focus"]) {
      return .priorities
    }
    if normalized.contains("what should i do first") { return .priorities }
    if !tokens.isDisjoint(with: ["update", "updates", "progress", "changed", "changes"]) {
      return .recentUpdates
    }
    if plan.sourceKinds == [.meeting] { return .meetingRecall }
    if plan.sourceKinds == [.calendar] { return .schedule }
    return .lookup
  }

  private static func requestsInclusivePlanningScope(_ normalized: String) -> Bool {
    normalized.contains("include ")
      || normalized.contains("includes ")
      || normalized.contains("including ")
      || normalized.contains("along with ")
  }

  private static func resolveFollowUp(_ query: String, recentUserQueries: [String]) -> String {
    let normalized = query.askNormalized
    let tokens = Set(AskLexical.tokenize(normalized))
    let meaningfulTokens = tokens.subtracting(AskLexical.stopWords)
    let isTemporalOnly =
      !meaningfulTokens.isEmpty
      && meaningfulTokens.isSubset(of: AskLexical.dateWords)
    let isContextualWhy = isExplanationFollowUp(query)
    let referencesPriorContext =
      normalized.hasPrefix("what about")
      || normalized.hasPrefix("and ")
      || normalized.hasPrefix("which are ")
      || normalized.hasPrefix("which one")
      || normalized.hasPrefix("which of ")
      || isContextualWhy
      || isTemporalOnly
      || !tokens.isDisjoint(with: ["here", "those", "them", "these", "same"])
    guard referencesPriorContext,
      let previous =
        recentUserQueries.reversed().first(where: {
          !$0.askNormalized.isEmpty && !isContextualFollowUp($0)
        })
        ?? recentUserQueries.reversed().first(where: { !$0.askNormalized.isEmpty })
    else {
      return query
    }
    // Preserve the previous subject/source vocabulary while letting the follow-up replace temporal
    // words such as "today" with "tomorrow". Avoid synthetic labels because they would become
    // mandatory lexical search terms.
    return previous + "\n" + query
  }

  private static func requestsLatestMeeting(
    normalized: String,
    tokens: Set<String>
  ) -> Bool {
    guard !tokens.isDisjoint(with: ["meeting", "meetings"]) else { return false }
    return tokens.contains("latest")
      || tokens.contains("newest")
      || normalized.contains("most recent")
      || normalized.contains("last meeting")
  }

  private static func isContextualFollowUp(_ query: String) -> Bool {
    let normalized = query.askNormalized
    let tokens = Set(AskLexical.tokenize(normalized))
    let meaningfulTokens = tokens.subtracting(AskLexical.stopWords)
    let isTemporalOnly =
      !meaningfulTokens.isEmpty
      && meaningfulTokens.isSubset(of: AskLexical.dateWords)
    return normalized.hasPrefix("what about")
      || normalized.hasPrefix("and ")
      || normalized.hasPrefix("which are ")
      || normalized.hasPrefix("which one")
      || normalized.hasPrefix("which of ")
      || isExplanationFollowUp(query)
      || isTemporalOnly
      || !tokens.isDisjoint(with: ["here", "those", "them", "these", "same"])
  }

  private static func isExplanationFollowUp(_ query: String) -> Bool {
    let normalized = query.askNormalized
    let tokens = Set(AskLexical.tokenize(normalized))
    let meaningfulTokens = tokens.subtracting(AskLexical.stopWords)
    let referencesSelection =
      !tokens.isDisjoint(with: ["it", "this", "that", "them", "these", "those", "things"])
      || normalized.contains("the order")
      || normalized.contains("the selection")
    return (tokens.contains("why") && (meaningfulTokens.isEmpty || referencesSelection))
      || (referencesSelection
        && !tokens.isDisjoint(with: [
          "defer", "deferred", "important", "importance", "reason", "reasons",
        ]))
  }

  private static func dayRange(containing date: Date, calendar: Calendar) -> AskDateRange {
    let start = calendar.startOfDay(for: date)
    return AskDateRange(
      start: start,
      end: calendar.date(byAdding: .day, value: 1, to: start)
        ?? start.addingTimeInterval(86_400)
    )
  }

  private static func recentRange(referenceDate: Date, calendar: Calendar) -> AskDateRange {
    let end =
      calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate))
      ?? referenceDate.addingTimeInterval(86_400)
    return AskDateRange(
      start: calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: referenceDate))
        ?? referenceDate.addingTimeInterval(-13 * 86_400),
      end: end
    )
  }

  private static func temporalField(
    for kind: AskSourceKind,
    requested: AskTemporalField
  ) -> AskTemporalField {
    guard requested == .relevant else { return requested }
    switch kind {
    case .calendar, .meeting: return .occurrence
    case .todo: return .due
    case .note, .codex: return .updated
    }
  }

  private static func sorted(_ kinds: Set<AskSourceKind>) -> [AskSourceKind] {
    AskSourceKind.allCases.filter(kinds.contains)
  }

  private static func deduplicated(_ searches: [AskResearchQuery]) -> [AskResearchQuery] {
    var seen = Set<String>()
    return searches.filter { search in
      let sourceKinds = search.plan.sourceKinds
        .map(\.rawValue)
        .sorted()
        .joined(separator: ",")
      let terms = search.plan.terms.joined(separator: ",")
      let statuses = search.plan.statusFilters
        .map(\.rawValue)
        .sorted()
        .joined(separator: ",")
      let dateRange: String
      if let range = search.plan.dateRange {
        dateRange = "\(range.start.timeIntervalSince1970)-\(range.end.timeIntervalSince1970)"
      } else {
        dateRange = "none"
      }
      let maximumDocuments = search.maximumDocuments.map { String($0) } ?? "all-documents"
      let maximumChunks = search.maximumChunksPerDocument.map { String($0) } ?? "default-chunks"
      let components = [
        sourceKinds,
        terms,
        statuses,
        dateRange,
        search.plan.temporalField.rawValue,
        search.selection.rawValue,
        maximumDocuments,
        maximumChunks,
      ]
      let key = components.joined(separator: "|")
      return seen.insert(key).inserted
    }
  }
}

public enum AskKnowledgeNormalizer {
  public static func normalize(
    snapshot: AskDataSnapshot,
    maximumChunkCharacters: Int = 900,
    shouldCancel: @Sendable () -> Bool = { false }
  ) -> AskKnowledgeCorpus {
    let limit = max(120, maximumChunkCharacters)
    var documents: [AskKnowledgeDocument] = []
    var chunks: [AskKnowledgeChunk] = []
    let data = snapshot.data

    for todo in data.todos where todo.deletedAt == nil {
      guard !shouldCancel() else { break }
      let entityID = todo.id.uuidString.lowercased()
      let source = AskSourceReference(kind: .todo, entityID: entityID, revision: todo.updatedAt)
      let text = [todo.notes, todo.listName]
        .compactMap { $0?.nonEmptyAskValue }
        .joined(separator: "\n")
      let facets = AskKnowledgeFacets(
        status: todo.isCompleted ? .completed : .open,
        isStarred: todo.isStarred,
        dueDate: todo.dueDate,
        temporalRange: todo.dueDate.map { AskDateRange(start: $0, end: $0.addingTimeInterval(1)) }
      )
      var metadata = [String: String]()
      metadata["list"] = todo.listName?.nonEmptyAskValue
      metadata["completedAt"] = todo.completedAt.map(iso8601)
      metadata["createdAt"] = iso8601(todo.createdAt)
      appendDocument(
        source: source,
        title: todo.title,
        text: text,
        updatedAt: todo.updatedAt,
        facets: facets,
        metadata: metadata,
        anchorPrefix: "body",
        chunkLimit: limit,
        shouldCancel: shouldCancel,
        documents: &documents,
        chunks: &chunks
      )
    }

    let linkedMeetingNoteIDs = Set(
      data.meetings.lazy.filter { $0.deletedAt == nil }.map(\.noteID)
    )
    for note in data.notes where note.deletedAt == nil && !linkedMeetingNoteIDs.contains(note.id) {
      guard !shouldCancel() else { break }
      let kind: AskSourceKind = note.kind == .meeting ? .meeting : .note
      let entityID = note.id.uuidString.lowercased()
      let source = AskSourceReference(kind: kind, entityID: entityID, revision: note.updatedAt)
      appendDocument(
        source: source,
        title: note.title,
        text: note.body,
        updatedAt: note.updatedAt,
        metadata: [
          "createdAt": iso8601(note.createdAt),
          "sourceDeviceID": note.sourceDeviceID,
        ],
        anchorPrefix: kind == .meeting ? "summary" : "body",
        chunkLimit: limit,
        shouldCancel: shouldCancel,
        documents: &documents,
        chunks: &chunks
      )
    }

    let activeNotesByID = Dictionary(
      uniqueKeysWithValues: data.notes.lazy
        .filter { $0.deletedAt == nil }
        .map { ($0.id, $0) }
    )
    for meeting in data.meetings where meeting.deletedAt == nil {
      guard !shouldCancel() else { break }
      let entityID = meeting.id.uuidString.lowercased()
      let source = AskSourceReference(
        kind: .meeting, entityID: entityID, revision: meeting.updatedAt)
      let note = activeNotesByID[meeting.noteID]
      let noteContent = note.map { MeetingNoteContent(markdown: $0.body) }
      let transcriptSegments = meeting.transcriptSegments ?? []
      let hasSegmentedTranscript = transcriptSegments.contains {
        $0.text.nonEmptyAskValue != nil
      }
      let segmentedTranscript =
        transcriptSegments
        .compactMap { $0.text.nonEmptyAskValue }
        .joined(separator: "\n")
      let transcript =
        segmentedTranscript.nonEmptyAskValue
        ?? noteContent?.transcript.nonEmptyAskValue
      let summary =
        noteContent?.summary?.nonEmptyAskValue
        ?? (hasSegmentedTranscript ? note?.body.nonEmptyAskValue : nil)
      let body = [summary, transcript]
        .compactMap { $0 }
        .joined(separator: "\n\n")
      let end = meeting.endedAt ?? snapshot.contextAsOf
      let facets = AskKnowledgeFacets(
        status: meetingStatus(meeting.state),
        temporalRange: AskDateRange(
          start: meeting.startedAt, end: max(meeting.startedAt.addingTimeInterval(1), end))
      )
      var metadata = [
        "sourceDeviceID": meeting.sourceDeviceID,
        "startedAt": iso8601(meeting.startedAt),
        "noteID": meeting.noteID.uuidString.lowercased(),
      ]
      metadata["calendarEventID"] = meeting.calendarEventID?.nonEmptyAskValue
      metadata["endedAt"] = meeting.endedAt.map(iso8601)
      metadata["summaryGeneratedAt"] = meeting.summaryGeneratedAt.map(iso8601)
      let documentID = sourceDocumentID(source)
      documents.append(
        AskKnowledgeDocument(
          id: documentID,
          source: source,
          title: meeting.title,
          text: body,
          updatedAt: meeting.updatedAt,
          facets: facets,
          metadata: metadata.compactMapValues { $0 }
        ))

      let summaryPieces = chunkedText(
        summary ?? "",
        maximumCharacters: limit,
        shouldCancel: shouldCancel
      )
      for (index, piece) in summaryPieces.enumerated() {
        guard !shouldCancel() else { break }
        appendChunk(
          documentID: documentID,
          source: source,
          anchor: "summary:\(index)",
          title: meeting.title,
          text: piece,
          updatedAt: meeting.updatedAt,
          facets: facets,
          metadata: metadata.compactMapValues { $0 },
          chunks: &chunks
        )
      }
      if hasSegmentedTranscript {
        appendTranscriptChunks(
          transcriptSegments,
          documentID: documentID,
          source: source,
          title: meeting.title,
          updatedAt: meeting.updatedAt,
          facets: facets,
          metadata: metadata.compactMapValues { $0 },
          chunkLimit: limit,
          shouldCancel: shouldCancel,
          chunks: &chunks
        )
      } else {
        let transcriptPieces = chunkedText(
          transcript ?? "",
          maximumCharacters: limit,
          shouldCancel: shouldCancel
        )
        for (index, piece) in transcriptPieces.enumerated() {
          guard !shouldCancel() else { break }
          appendChunk(
            documentID: documentID,
            source: source,
            anchor: "transcript:note:\(index)",
            title: meeting.title,
            text: piece,
            updatedAt: meeting.updatedAt,
            facets: facets,
            metadata: metadata.compactMapValues { $0 },
            chunks: &chunks
          )
        }
      }
      if summaryPieces.isEmpty && transcript?.nonEmptyAskValue == nil {
        appendChunk(
          documentID: documentID,
          source: source,
          anchor: "metadata",
          title: meeting.title,
          text: meeting.title,
          updatedAt: meeting.updatedAt,
          facets: facets,
          metadata: metadata.compactMapValues { $0 },
          chunks: &chunks
        )
      }
    }

    for event in coalescedCalendarEvents(data.calendarEvents, shouldCancel: shouldCancel) {
      guard !shouldCancel() else { break }
      let source = AskSourceReference(
        kind: .calendar, entityID: event.id, revision: event.updatedAt)
      let text = [event.notes, event.location, Optional(event.calendarTitle)]
        .compactMap { $0?.nonEmptyAskValue }
        .joined(separator: "\n")
      var metadata = [
        "calendar": event.calendarTitle,
        "start": iso8601(event.startDate),
        "end": iso8601(event.endDate),
        "allDay": event.isAllDay ? "true" : "false",
      ]
      metadata["location"] = event.location?.nonEmptyAskValue
      metadata["sourceIdentifier"] = event.sourceIdentifier?.nonEmptyAskValue
      let facets = AskKnowledgeFacets(
        status: .scheduled,
        temporalRange: AskDateRange(
          start: event.startDate,
          end: max(event.startDate.addingTimeInterval(1), event.endDate)
        )
      )
      appendDocument(
        source: source,
        title: event.title,
        text: text,
        updatedAt: event.updatedAt,
        facets: facets,
        metadata: metadata.compactMapValues { $0 },
        anchorPrefix: "event",
        chunkLimit: limit,
        shouldCancel: shouldCancel,
        documents: &documents,
        chunks: &chunks
      )
    }

    for thread in data.codexThreads where thread.deletedAt == nil {
      guard !shouldCancel() else { break }
      let source = AskSourceReference(kind: .codex, entityID: thread.id, revision: thread.updatedAt)
      var lines = [thread.activity.nonEmptyAskValue].compactMap { $0 }
      let visibleOutputLines = (thread.visibleOutputs ?? [])
        .sorted { $0.occurredAt > $1.occurredAt }
        .compactMap { $0.text.nonEmptyAskValue }
      // `activityHistory` predates the explicit visible-output projection and may
      // contain internal reasoning. Never index it for Ask iAgent. Older records
      // still contribute their title, state, project, and current visible activity.
      lines.append(contentsOf: visibleOutputLines)
      var metadata = [
        "state": thread.state.rawValue,
        "createdAt": iso8601(thread.createdAt),
      ]
      metadata["project"] = thread.projectName?.nonEmptyAskValue
      if !thread.modes.isEmpty {
        metadata["modes"] = thread.modes.map(\.rawValue).joined(separator: ",")
      }
      appendDocument(
        source: source,
        title: thread.title,
        text: lines.uniqued().joined(separator: "\n"),
        updatedAt: thread.updatedAt,
        facets: AskKnowledgeFacets(status: codexStatus(thread.state)),
        metadata: metadata.compactMapValues { $0 },
        anchorPrefix: "activity",
        chunkLimit: limit,
        shouldCancel: shouldCancel,
        documents: &documents,
        chunks: &chunks
      )
    }

    documents.sort { $0.id < $1.id }
    chunks.sort { $0.id < $1.id }
    return AskKnowledgeCorpus(
      contextAsOf: snapshot.contextAsOf,
      documents: documents,
      chunks: chunks
    )
  }

  private static func appendDocument(
    source: AskSourceReference,
    title: String,
    text: String,
    updatedAt: Date,
    facets: AskKnowledgeFacets = AskKnowledgeFacets(),
    metadata: [String: String],
    anchorPrefix: String,
    chunkLimit: Int,
    shouldCancel: @Sendable () -> Bool,
    documents: inout [AskKnowledgeDocument],
    chunks: inout [AskKnowledgeChunk]
  ) {
    let documentID = sourceDocumentID(source)
    documents.append(
      AskKnowledgeDocument(
        id: documentID,
        source: source,
        title: title,
        text: text,
        updatedAt: updatedAt,
        facets: facets,
        metadata: metadata
      ))
    let pieces = chunkedText(
      text,
      maximumCharacters: chunkLimit,
      shouldCancel: shouldCancel
    )
    for (index, piece) in (pieces.isEmpty ? [title] : pieces).enumerated() {
      guard !shouldCancel() else { break }
      appendChunk(
        documentID: documentID,
        source: source,
        anchor: "\(anchorPrefix):\(index)",
        title: title,
        text: piece,
        updatedAt: updatedAt,
        facets: facets,
        metadata: metadata,
        chunks: &chunks
      )
    }
  }

  private static func appendChunk(
    documentID: String,
    source: AskSourceReference,
    anchor: String,
    title: String,
    text: String,
    updatedAt: Date,
    facets: AskKnowledgeFacets,
    metadata: [String: String],
    chunks: inout [AskKnowledgeChunk]
  ) {
    let anchoredSource = AskSourceReference(
      kind: source.kind,
      entityID: source.entityID,
      revision: source.revision,
      anchor: anchor
    )
    chunks.append(
      AskKnowledgeChunk(
        id: anchoredSource.stableID,
        documentID: documentID,
        source: anchoredSource,
        title: title,
        text: text,
        updatedAt: updatedAt,
        facets: facets,
        metadata: metadata
      ))
  }

  private static func appendTranscriptChunks(
    _ segments: [SyncedTranscriptSegment],
    documentID: String,
    source: AskSourceReference,
    title: String,
    updatedAt: Date,
    facets: AskKnowledgeFacets,
    metadata: [String: String],
    chunkLimit: Int,
    shouldCancel: @Sendable () -> Bool,
    chunks: inout [AskKnowledgeChunk]
  ) {
    var group: [SyncedTranscriptSegment] = []
    var characterCount = 0

    func flush() {
      guard let first = group.first else { return }
      var chunkMetadata = metadata
      chunkMetadata["startOffset"] = first.startOffset.map { String(format: "%.3f", $0) }
      chunkMetadata["endOffset"] = group.last?.endOffset.map { String(format: "%.3f", $0) }
      appendChunk(
        documentID: documentID,
        source: source,
        anchor: "transcript:\(first.id.uuidString.lowercased())",
        title: title,
        text: group.compactMap { $0.text.nonEmptyAskValue }.joined(separator: "\n"),
        updatedAt: updatedAt,
        facets: facets,
        metadata: chunkMetadata,
        chunks: &chunks
      )
      group.removeAll(keepingCapacity: true)
      characterCount = 0
    }

    for segment in segments where segment.text.nonEmptyAskValue != nil {
      guard !shouldCancel() else { break }
      let segmentCount = segment.text.count + (group.isEmpty ? 0 : 1)
      if !group.isEmpty && characterCount + segmentCount > chunkLimit {
        flush()
      }
      if segmentCount > chunkLimit {
        flush()
        for (index, piece) in chunkedText(
          segment.text,
          maximumCharacters: chunkLimit,
          shouldCancel: shouldCancel
        ).enumerated() {
          guard !shouldCancel() else { break }
          var pieceMetadata = metadata
          pieceMetadata["startOffset"] = segment.startOffset.map { String(format: "%.3f", $0) }
          pieceMetadata["endOffset"] = segment.endOffset.map { String(format: "%.3f", $0) }
          appendChunk(
            documentID: documentID,
            source: source,
            anchor: "transcript:\(segment.id.uuidString.lowercased()):\(index)",
            title: title,
            text: piece,
            updatedAt: updatedAt,
            facets: facets,
            metadata: pieceMetadata,
            chunks: &chunks
          )
        }
      } else {
        group.append(segment)
        characterCount += segmentCount
      }
    }
    flush()
  }

  private static func chunkedText(
    _ text: String,
    maximumCharacters: Int,
    shouldCancel: @Sendable () -> Bool
  ) -> [String] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }

    let paragraphs = normalized.components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .flatMap {
        splitOversized(
          $0,
          maximumCharacters: maximumCharacters,
          shouldCancel: shouldCancel
        )
      }
    var output: [String] = []
    var current = ""
    for paragraph in paragraphs {
      guard !shouldCancel() else { break }
      let candidate = current.isEmpty ? paragraph : current + "\n\n" + paragraph
      if !current.isEmpty && candidate.count > maximumCharacters {
        output.append(current)
        current = paragraph
      } else {
        current = candidate
      }
    }
    if !current.isEmpty {
      output.append(current)
    }
    return output
  }

  private static func splitOversized(
    _ text: String,
    maximumCharacters: Int,
    shouldCancel: @Sendable () -> Bool
  ) -> [String] {
    guard text.count > maximumCharacters else { return [text] }
    var pieces: [String] = []
    var current = ""
    for word in text.split(whereSeparator: \Character.isWhitespace).map(String.init) {
      guard !shouldCancel() else { break }
      let candidate = current.isEmpty ? word : current + " " + word
      if !current.isEmpty && candidate.count > maximumCharacters {
        pieces.append(current)
        current = word
      } else if word.count > maximumCharacters {
        if !current.isEmpty {
          pieces.append(current)
          current = ""
        }
        var start = word.startIndex
        while start < word.endIndex {
          guard !shouldCancel() else { break }
          let end =
            word.index(start, offsetBy: maximumCharacters, limitedBy: word.endIndex)
            ?? word.endIndex
          pieces.append(String(word[start..<end]))
          start = end
        }
      } else {
        current = candidate
      }
    }
    if !current.isEmpty {
      pieces.append(current)
    }
    return pieces
  }

  private static func coalescedCalendarEvents(
    _ events: [SyncedCalendarEvent],
    shouldCancel: @Sendable () -> Bool
  )
    -> [SyncedCalendarEvent]
  {
    let sorted = events.filter { $0.deletedAt == nil }.sorted {
      if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
      return $0.updatedAt > $1.updatedAt
    }
    var result: [SyncedCalendarEvent] = []
    for event in sorted where !result.contains(where: { $0.isSameOccurrence(as: event) }) {
      guard !shouldCancel() else { break }
      result.append(event)
    }
    return result
  }

  private static func sourceDocumentID(_ source: AskSourceReference) -> String {
    "\(source.kind.rawValue):\(source.entityID)"
  }

  private static func meetingStatus(_ state: SyncedMeetingState) -> AskKnowledgeStatus {
    switch state {
    case .recording: .recording
    case .completed: .completed
    case .failed: .failed
    }
  }

  private static func codexStatus(_ state: SyncedCodexState) -> AskKnowledgeStatus {
    switch state {
    case .running: .running
    case .waitingForInput: .waitingForInput
    case .needsApproval: .needsApproval
    case .completed: .completed
    case .failed: .failed
    }
  }

  private static func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

public struct AskEvidence: Codable, Equatable, Identifiable, Sendable {
  /// A turn-local allowlisted citation identifier such as `E1`.
  public var id: String
  public var chunk: AskKnowledgeChunk
  public var score: Double

  public init(id: String, chunk: AskKnowledgeChunk, score: Double) {
    self.id = id
    self.chunk = chunk
    self.score = score
  }
}

public struct AskEvidenceBundle: Codable, Equatable, Sendable {
  public var queryPlan: AskQueryPlan
  public var contextAsOf: Date
  public var evidence: [AskEvidence]

  public init(queryPlan: AskQueryPlan, contextAsOf: Date, evidence: [AskEvidence]) {
    self.queryPlan = queryPlan
    self.contextAsOf = contextAsOf
    self.evidence = evidence
  }

  public var citationIDs: Set<String> {
    Set(evidence.map(\.id))
  }

  public func evidence(forCitationID id: String) -> AskEvidence? {
    evidence.first { $0.id == id }
  }
}

public struct AskKnowledgeMatch: Equatable, Sendable {
  public var chunk: AskKnowledgeChunk
  public var score: Double

  public init(chunk: AskKnowledgeChunk, score: Double) {
    self.chunk = chunk
    self.score = score
  }
}

public enum AskKnowledgeSearch {
  public static func search(
    plan: AskQueryPlan,
    in corpus: AskKnowledgeCorpus,
    limit: Int = 8,
    maximumPerSourceKind: Int = 3,
    maximumPerDocument: Int = 2
  ) -> AskEvidenceBundle {
    guard limit > 0 else {
      return AskEvidenceBundle(queryPlan: plan, contextAsOf: corpus.contextAsOf, evidence: [])
    }

    let candidates = rankedMatches(plan: plan, in: corpus)

    let kindLimit = max(1, maximumPerSourceKind)
    let documentLimit = max(1, maximumPerDocument)
    var kindCounts: [AskSourceKind: Int] = [:]
    var documentCounts: [String: Int] = [:]
    var selected: [AskKnowledgeMatch] = []
    for candidate in candidates {
      guard selected.count < limit else { break }
      let kind = candidate.chunk.source.kind
      guard kindCounts[kind, default: 0] < kindLimit,
        documentCounts[candidate.chunk.documentID, default: 0] < documentLimit
      else {
        continue
      }
      selected.append(candidate)
      kindCounts[kind, default: 0] += 1
      documentCounts[candidate.chunk.documentID, default: 0] += 1
    }

    return AskEvidenceBundle(
      queryPlan: plan,
      contextAsOf: corpus.contextAsOf,
      evidence: selected.enumerated().map { index, value in
        AskEvidence(id: "E\(index + 1)", chunk: value.chunk, score: value.score)
      }
    )
  }

  /// Applies a model-proposed refinement only inside the records authorized by the deterministic
  /// first-pass scope. This prevents a refinement term from replacing the user's subject.
  public static func search(
    refinementPlan: AskQueryPlan,
    constrainedBy authorizedPlan: AskQueryPlan,
    in corpus: AskKnowledgeCorpus,
    limit: Int = 8,
    maximumPerDocument: Int = 2,
    shouldCancel: @Sendable () -> Bool = { false }
  ) -> AskEvidenceBundle {
    guard limit > 0 else {
      return AskEvidenceBundle(
        queryPlan: refinementPlan,
        contextAsOf: corpus.contextAsOf,
        evidence: []
      )
    }

    let authorizedDocumentIDs = Set(
      rankedMatches(plan: authorizedPlan, in: corpus, shouldCancel: shouldCancel)
        .map(\.chunk.documentID)
    )
    guard !authorizedDocumentIDs.isEmpty else {
      return AskEvidenceBundle(
        queryPlan: refinementPlan,
        contextAsOf: corpus.contextAsOf,
        evidence: []
      )
    }

    let documentLimit = max(1, maximumPerDocument)
    var perDocument: [String: Int] = [:]
    var selected: [AskKnowledgeMatch] = []
    for match in rankedMatches(
      plan: refinementPlan,
      in: corpus,
      shouldCancel: shouldCancel
    ) where authorizedDocumentIDs.contains(match.chunk.documentID) {
      guard !shouldCancel(), selected.count < limit else { break }
      guard perDocument[match.chunk.documentID, default: 0] < documentLimit else { continue }
      selected.append(match)
      perDocument[match.chunk.documentID, default: 0] += 1
    }

    return AskEvidenceBundle(
      queryPlan: refinementPlan,
      contextAsOf: corpus.contextAsOf,
      evidence: selected.enumerated().map { index, match in
        AskEvidence(id: "E\(index + 1)", chunk: match.chunk, score: match.score)
      }
    )
  }

  /// Returns every matching chunk in deterministic rank order before presentation limits are
  /// applied. Research fan-out uses this to preserve full match counts and fuse several searches.
  public static func rankedMatches(
    plan: AskQueryPlan,
    in corpus: AskKnowledgeCorpus,
    shouldCancel: @Sendable () -> Bool = { false }
  ) -> [AskKnowledgeMatch] {
    var matches: [AskKnowledgeMatch] = []
    for chunk in corpus.chunks {
      guard !shouldCancel() else { break }
      guard sourceMatches(chunk, plan: plan),
        dateMatches(chunk, plan: plan),
        statusMatches(chunk, plan: plan, now: corpus.contextAsOf)
      else {
        continue
      }
      let lexical = lexicalScore(chunk, terms: plan.terms, originalQuery: plan.originalQuery)
      guard plan.terms.isEmpty || lexical > 0 else { continue }
      let score =
        lexical
        + recencyScore(chunk, now: corpus.contextAsOf)
        + sourcePriorityScore(chunk, now: corpus.contextAsOf)
      matches.append(AskKnowledgeMatch(chunk: chunk, score: score))
    }
    return matches.sorted {
      if $0.score != $1.score { return $0.score > $1.score }
      if $0.chunk.updatedAt != $1.chunk.updatedAt { return $0.chunk.updatedAt > $1.chunk.updatedAt }
      return $0.chunk.id < $1.chunk.id
    }
  }

  private static func sourceMatches(_ chunk: AskKnowledgeChunk, plan: AskQueryPlan) -> Bool {
    plan.sourceKinds.isEmpty || plan.sourceKinds.contains(chunk.source.kind)
  }

  private static func dateMatches(_ chunk: AskKnowledgeChunk, plan: AskQueryPlan) -> Bool {
    guard let requested = plan.dateRange else { return true }
    if plan.statusFilters.contains(.overdue),
      let dueDate = chunk.facets.dueDate
    {
      return dueDate < requested.end
    }
    switch plan.temporalField {
    case .occurrence:
      guard let range = chunk.facets.temporalRange else { return false }
      return requested.intersects(range) || requested.contains(range.start)
    case .due:
      guard let dueDate = chunk.facets.dueDate else { return false }
      return requested.contains(dueDate)
    case .updated:
      return requested.contains(chunk.updatedAt)
    case .relevant:
      if let range = chunk.facets.temporalRange {
        return requested.intersects(range) || requested.contains(range.start)
      }
      return requested.contains(chunk.updatedAt)
    }
  }

  private static func statusMatches(
    _ chunk: AskKnowledgeChunk,
    plan: AskQueryPlan,
    now: Date
  ) -> Bool {
    plan.statusFilters.allSatisfy { filter in
      switch filter {
      case .open:
        return chunk.facets.status == .open
      case .completed:
        return chunk.facets.status == .completed
      case .overdue:
        return chunk.facets.status == .open && (chunk.facets.dueDate.map { $0 < now } ?? false)
      case .starred:
        return chunk.facets.isStarred
      case .active:
        return [.running, .waitingForInput, .needsApproval, .recording].contains(
          chunk.facets.status)
      case .failed:
        return chunk.facets.status == .failed
      case .priority:
        return isPriority(chunk, now: now)
      }
    }
  }

  private static func isPriority(_ chunk: AskKnowledgeChunk, now: Date) -> Bool {
    switch chunk.source.kind {
    case .todo:
      guard chunk.facets.status == .open else { return false }
      if chunk.facets.isStarred { return true }
      return chunk.facets.dueDate.map { $0 <= now.addingTimeInterval(3 * 86_400) } ?? false
    case .calendar:
      guard let start = chunk.facets.temporalRange?.start else { return false }
      return start >= now.addingTimeInterval(-3_600) && start <= now.addingTimeInterval(24 * 3_600)
    case .meeting:
      return chunk.facets.status == .recording
    case .codex:
      return [.running, .waitingForInput, .needsApproval].contains(chunk.facets.status)
    case .note:
      return false
    }
  }

  private static func lexicalScore(
    _ chunk: AskKnowledgeChunk,
    terms: [String],
    originalQuery: String
  ) -> Double {
    guard !terms.isEmpty else { return 0 }
    let titleTokens = AskLexical.frequencyMap(chunk.title)
    let textTokens = AskLexical.frequencyMap(chunk.text)
    let metadataTokens = AskLexical.frequencyMap(chunk.metadata.values.joined(separator: " "))
    var score = 0.0
    var matched = 0
    for term in terms {
      var termScore = 0.0
      termScore += Double(min(titleTokens[term, default: 0], 2)) * 3.0
      termScore += Double(min(textTokens[term, default: 0], 3)) * 1.0
      termScore += Double(min(metadataTokens[term, default: 0], 2)) * 0.5
      if termScore == 0 {
        if titleTokens.keys.contains(where: { $0.hasPrefix(term) || term.hasPrefix($0) }) {
          termScore += 1.25
        } else if textTokens.keys.contains(where: { $0.hasPrefix(term) || term.hasPrefix($0) }) {
          termScore += 0.5
        }
      }
      if termScore > 0 { matched += 1 }
      score += termScore
    }
    score += 2.0 * Double(matched) / Double(max(1, terms.count))

    let phrase = originalQuery.askNormalized
    if phrase.count >= 4 {
      if chunk.title.askNormalized.contains(phrase) { score += 4 }
      if chunk.text.askNormalized.contains(phrase) { score += 1.5 }
    }
    return score
  }

  private static func recencyScore(_ chunk: AskKnowledgeChunk, now: Date) -> Double {
    let ageDays = max(0, now.timeIntervalSince(chunk.updatedAt) / 86_400)
    return 0.8 * exp(-ageDays / 30)
  }

  private static func sourcePriorityScore(_ chunk: AskKnowledgeChunk, now: Date) -> Double {
    switch chunk.source.kind {
    case .todo:
      var score = chunk.facets.isStarred ? 0.55 : 0
      if let due = chunk.facets.dueDate {
        if due < now {
          // An overdue item stays important even when its due date is no longer close to now.
          score += 0.65 + 0.15 * exp(-now.timeIntervalSince(due) / (7 * 86_400))
        } else {
          score += 0.4 * exp(-due.timeIntervalSince(now) / (3 * 86_400))
        }
      }
      return score
    case .calendar:
      guard let start = chunk.facets.temporalRange?.start else { return 0 }
      return 0.25 * exp(-abs(start.timeIntervalSince(now)) / 86_400)
    case .codex:
      switch chunk.facets.status {
      case .needsApproval: return 0.6
      case .waitingForInput: return 0.5
      case .running: return 0.3
      default: return 0
      }
    case .meeting:
      return chunk.facets.status == .recording ? 0.3 : 0
    case .note:
      return 0
    }
  }
}

/// Executes every planned source query, records full-document match counts, then fuses the small
/// result sets while reserving coverage for each non-empty search.
public enum AskKnowledgeResearch {
  public static func search(
    plan: AskResearchPlan,
    in corpus: AskKnowledgeCorpus,
    limit: Int = 12,
    maximumPerSourceKind: Int = 4,
    maximumPerDocument: Int = 2,
    onSearch: @Sendable (AskSourceKind) -> Void = { _ in },
    onProgress: @Sendable (AskSearchProgress) -> Void = { _ in },
    shouldCancel: @Sendable () -> Bool = { false }
  ) -> AskResearchResult {
    guard limit > 0 else {
      return AskResearchResult(
        plan: plan,
        contextAsOf: corpus.contextAsOf,
        evidence: [],
        coverage: plan.searches.compactMap { search in
          guard let kind = search.plan.sourceKinds.first else { return nil }
          return AskSearchCoverage(
            queryID: search.id,
            sourceKind: kind,
            reason: search.reason,
            totalMatches: 0,
            returnedMatches: 0
          )
        }
      )
    }

    struct QueryBatch {
      var query: AskResearchQuery
      var matches: [AskKnowledgeMatch]
    }
    struct FusedCandidate {
      var chunk: AskKnowledgeChunk
      var score: Double
      var firstQueryIndex: Int
      var bestRank: Int
    }

    var batches: [QueryBatch] = []
    var coverage: [AskSearchCoverage] = []
    var searchProgress: [AskSearchProgress] = []
    var fused: [String: FusedCandidate] = [:]
    var observedItemsBySource: [AskSourceKind: [AskSearchProgressItem]] = [:]
    var observedItemIDsBySource: [AskSourceKind: Set<String>] = [:]
    var documentLimitOverrides: [String: Int] = [:]

    for (queryIndex, query) in plan.searches.enumerated() {
      guard !shouldCancel() else { break }
      if let kind = query.plan.sourceKinds.first {
        onSearch(kind)
      }
      let rankedMatches = AskKnowledgeSearch.rankedMatches(
        plan: query.plan,
        in: corpus,
        shouldCancel: shouldCancel
      )
      let allMatches = selectedScope(
        for: query,
        rankedMatches: rankedMatches,
        defaultMaximumPerDocument: maximumPerDocument
      )
      var observedDocumentIDs = Set<String>()
      let allObservedItems = rankedMatches.compactMap { match -> AskSearchProgressItem? in
        guard observedDocumentIDs.insert(match.chunk.documentID).inserted else { return nil }
        return AskSearchProgressItem(
          id: match.chunk.documentID,
          title: match.chunk.title
        )
      }
      let progressItems: [AskSearchProgressItem]
      if query.selection == .relevance {
        progressItems = allObservedItems
      } else {
        var selectedDocumentIDs = Set<String>()
        progressItems = allMatches.compactMap { match -> AskSearchProgressItem? in
          guard selectedDocumentIDs.insert(match.chunk.documentID).inserted else { return nil }
          return AskSearchProgressItem(id: match.chunk.documentID, title: match.chunk.title)
        }
      }
      let totalDocuments = allObservedItems.count
      let queryDocumentLimit = query.maximumChunksPerDocument ?? maximumPerDocument
      var perDocument: [String: Int] = [:]
      var selected: [AskKnowledgeMatch] = []
      for match in allMatches {
        guard !shouldCancel() else { break }
        guard selected.count < query.resultLimit else { break }
        guard perDocument[match.chunk.documentID, default: 0] < queryDocumentLimit else {
          continue
        }
        selected.append(match)
        perDocument[match.chunk.documentID, default: 0] += 1
        if let override = query.maximumChunksPerDocument {
          documentLimitOverrides[match.chunk.documentID] = max(
            documentLimitOverrides[match.chunk.documentID, default: 0], override)
        }
      }

      let kind = query.plan.sourceKinds.first ?? selected.first?.chunk.source.kind
      if let kind {
        searchProgress.append(
          AskSearchProgress(
            queryID: query.id,
            sourceKind: kind,
            items: progressItems
          ))
        coverage.append(
          AskSearchCoverage(
            queryID: query.id,
            sourceKind: kind,
            reason: query.reason,
            totalMatches: totalDocuments,
            returnedMatches: Set(selected.map(\.chunk.documentID)).count
          ))
        for item in progressItems
        where observedItemIDsBySource[kind, default: []].insert(item.id).inserted {
          observedItemsBySource[kind, default: []].append(item)
        }
        let hasLaterQueryForSource = plan.searches.dropFirst(queryIndex + 1).contains {
          $0.plan.sourceKinds.contains(kind)
        }
        if !hasLaterQueryForSource {
          onProgress(
            AskSearchProgress(
              queryID: "grouped-\(kind.rawValue)",
              sourceKind: kind,
              items: observedItemsBySource[kind, default: []]
            ))
        }
      }
      batches.append(QueryBatch(query: query, matches: selected))

      for (rank, match) in selected.enumerated() {
        guard !shouldCancel() else { break }
        // Weighted reciprocal-rank fusion makes independently scaled lexical scores comparable.
        let fusedContribution = query.weight / Double(60 + rank)
        let key = match.chunk.id
        if var existing = fused[key] {
          existing.score += fusedContribution
          existing.firstQueryIndex = min(existing.firstQueryIndex, queryIndex)
          existing.bestRank = min(existing.bestRank, rank)
          fused[key] = existing
        } else {
          fused[key] = FusedCandidate(
            chunk: match.chunk,
            score: fusedContribution + max(0, match.score) * 0.000_1,
            firstQueryIndex: queryIndex,
            bestRank: rank
          )
        }
      }
    }

    let sortedFused = fused.values.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      if lhs.firstQueryIndex != rhs.firstQueryIndex {
        return lhs.firstQueryIndex < rhs.firstQueryIndex
      }
      if lhs.bestRank != rhs.bestRank { return lhs.bestRank < rhs.bestRank }
      if lhs.chunk.updatedAt != rhs.chunk.updatedAt {
        return lhs.chunk.updatedAt > rhs.chunk.updatedAt
      }
      return lhs.chunk.id < rhs.chunk.id
    }

    let kindLimit = max(1, maximumPerSourceKind)
    let documentLimit = max(1, maximumPerDocument)
    var selected: [FusedCandidate] = []
    var selectedIDs = Set<String>()
    var kindCounts: [AskSourceKind: Int] = [:]
    var documentCounts: [String: Int] = [:]

    func canSelect(_ candidate: FusedCandidate) -> Bool {
      let allowedDocumentCount = max(
        documentLimit,
        documentLimitOverrides[candidate.chunk.documentID, default: 0]
      )
      return !selectedIDs.contains(candidate.chunk.id)
        && kindCounts[candidate.chunk.source.kind, default: 0] < kindLimit
        && documentCounts[candidate.chunk.documentID, default: 0] < allowedDocumentCount
    }

    func select(_ candidate: FusedCandidate) {
      selected.append(candidate)
      selectedIDs.insert(candidate.chunk.id)
      kindCounts[candidate.chunk.source.kind, default: 0] += 1
      documentCounts[candidate.chunk.documentID, default: 0] += 1
    }

    // Reserve one result for every non-empty planned search before globally filling the budget.
    for batch in batches where selected.count < limit {
      guard !shouldCancel() else { break }
      guard
        let candidate = batch.matches.lazy
          .compactMap({ fused[$0.chunk.id] })
          .first(where: canSelect)
      else {
        continue
      }
      select(candidate)
    }
    for candidate in sortedFused where selected.count < limit && canSelect(candidate) {
      guard !shouldCancel() else { break }
      select(candidate)
    }

    let finalChunkIDs = Set(selected.map(\.chunk.id))
    let finalCoverage = coverage.map { original in
      var resolved = original
      guard let batch = batches.first(where: { $0.query.id == original.queryID }) else {
        return resolved
      }
      resolved.returnedMatches =
        Set(
          batch.matches
            .filter { finalChunkIDs.contains($0.chunk.id) }
            .map(\.chunk.documentID)
        ).count
      return resolved
    }

    return AskResearchResult(
      plan: plan,
      contextAsOf: corpus.contextAsOf,
      evidence: selected.enumerated().map { index, candidate in
        AskEvidence(id: "E\(index + 1)", chunk: candidate.chunk, score: candidate.score)
      },
      coverage: finalCoverage,
      searchProgress: searchProgress
    )
  }

  private static func selectedScope(
    for query: AskResearchQuery,
    rankedMatches: [AskKnowledgeMatch],
    defaultMaximumPerDocument: Int
  ) -> [AskKnowledgeMatch] {
    guard query.selection == .latestCompletedOccurrence else { return rankedMatches }

    struct DocumentCandidate {
      var documentID: String
      var matches: [AskKnowledgeMatch]
      var hasReadableContent: Bool
      var isCompleted: Bool
      var occurrence: Date
      var updatedAt: Date
    }

    let grouped = Dictionary(grouping: rankedMatches, by: { $0.chunk.documentID })
    let candidates = grouped.map { documentID, matches in
      let first = matches[0].chunk
      let readable = matches.contains { match in
        let anchor = match.chunk.source.anchor ?? ""
        let text = match.chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return anchor != "metadata" && !text.isEmpty && text != match.chunk.title
      }
      return DocumentCandidate(
        documentID: documentID,
        matches: matches,
        hasReadableContent: readable,
        isCompleted: first.facets.status == .completed,
        occurrence: first.facets.temporalRange?.start ?? first.updatedAt,
        updatedAt: first.updatedAt
      )
    }
    // "Latest meeting" means the newest finished meeting the app can actually summarize. An
    // active recording or a title-only placeholder must never displace a completed readable one.
    let documents = candidates.filter { $0.isCompleted && $0.hasReadableContent }.sorted { lhs, rhs in
      if lhs.occurrence != rhs.occurrence { return lhs.occurrence > rhs.occurrence }
      if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
      return lhs.documentID < rhs.documentID
    }

    let documentLimit = query.maximumDocuments ?? 1
    let chunkLimit = query.maximumChunksPerDocument ?? max(1, defaultMaximumPerDocument)
    return documents.prefix(documentLimit).flatMap { document in
      document.matches.sorted { lhs, rhs in
        let lhsRank = meetingChunkRank(lhs.chunk)
        let rhsRank = meetingChunkRank(rhs.chunk)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.chunk.id < rhs.chunk.id
      }.prefix(chunkLimit)
    }
  }

  private static func meetingChunkRank(_ chunk: AskKnowledgeChunk) -> Int {
    let anchor = chunk.source.anchor ?? ""
    if anchor.hasPrefix("summary") { return 0 }
    if anchor.hasPrefix("transcript") { return 1 }
    return 2
  }
}

public struct AskCitationReference: Codable, Equatable, Sendable {
  public var citationID: String
  public var source: AskSourceReference
  public var retrievedAt: Date

  public init(citationID: String, source: AskSourceReference, retrievedAt: Date) {
    self.citationID = citationID
    self.source = source
    self.retrievedAt = retrievedAt
  }
}

public struct AskCitationValidation: Equatable, Sendable {
  public var accepted: [AskCitationReference]
  public var rejectedIDs: [String]

  public init(accepted: [AskCitationReference], rejectedIDs: [String]) {
    self.accepted = accepted
    self.rejectedIDs = rejectedIDs
  }
}

public struct AskGroundedClaim: Codable, Equatable, Sendable {
  public var text: String
  public var citationIDs: [String]

  public init(text: String, citationIDs: [String]) {
    self.text = text
    self.citationIDs = citationIDs
  }
}

/// A model-proposed citation before it is admitted into a user-facing grounded claim.
public struct AskGroundedSupportDraft: Equatable, Sendable {
  public var evidenceID: String
  public var excerpt: String

  public init(evidenceID: String, excerpt: String) {
    self.evidenceID = evidenceID
    self.excerpt = excerpt
  }
}

/// A model-proposed claim whose evidence IDs and exact excerpts still require turn-local QA.
public struct AskGroundedClaimDraft: Equatable, Sendable {
  public var text: String
  public var supports: [AskGroundedSupportDraft]

  public init(text: String, supports: [AskGroundedSupportDraft]) {
    self.text = text
    self.supports = supports
  }
}

public struct AskGroundingValidation: Equatable, Sendable {
  public var acceptedClaims: [AskGroundedClaim]
  public var rejectedClaims: [AskGroundedClaim]
  public var rejectedCitationIDs: [String]

  public init(
    acceptedClaims: [AskGroundedClaim],
    rejectedClaims: [AskGroundedClaim],
    rejectedCitationIDs: [String]
  ) {
    self.acceptedClaims = acceptedClaims
    self.rejectedClaims = rejectedClaims
    self.rejectedCitationIDs = rejectedCitationIDs
  }
}

public enum AskCitationValidator {
  /// Converts only turn-local evidence IDs into stable source references.
  public static func validate(
    _ requestedIDs: [String],
    against bundle: AskEvidenceBundle
  ) -> AskCitationValidation {
    var seen = Set<String>()
    var accepted: [AskCitationReference] = []
    var rejected: [String] = []
    for id in requestedIDs where seen.insert(id).inserted {
      guard let evidence = bundle.evidence(forCitationID: id) else {
        rejected.append(id)
        continue
      }
      accepted.append(
        AskCitationReference(
          citationID: id,
          source: evidence.chunk.source,
          retrievedAt: bundle.contextAsOf
        ))
    }
    return AskCitationValidation(accepted: accepted, rejectedIDs: rejected)
  }

  /// Drops claims with no valid grounding and strips fabricated IDs from otherwise grounded claims.
  public static func validate(
    claims: [AskGroundedClaim],
    against bundle: AskEvidenceBundle
  ) -> AskGroundingValidation {
    var acceptedClaims: [AskGroundedClaim] = []
    var rejectedClaims: [AskGroundedClaim] = []
    var rejectedIDs: [String] = []
    for claim in claims {
      let validation = validate(claim.citationIDs, against: bundle)
      rejectedIDs.append(contentsOf: validation.rejectedIDs)
      let validIDs = validation.accepted.map(\.citationID)
      guard !validIDs.isEmpty else {
        rejectedClaims.append(claim)
        continue
      }
      acceptedClaims.append(AskGroundedClaim(text: claim.text, citationIDs: validIDs))
    }
    return AskGroundingValidation(
      acceptedClaims: acceptedClaims,
      rejectedClaims: rejectedClaims,
      rejectedCitationIDs: rejectedIDs.uniqued()
    )
  }

  /// Fails closed unless every cited ID belongs to this turn and every proposed excerpt occurs in
  /// that exact evidence record after punctuation/case normalization. This is intentionally
  /// deterministic: it is the final gate used by remote answers after model-side source QA.
  public static func validateExactSupports(
    claims: [AskGroundedClaimDraft],
    evidenceTextByID: [String: String]
  ) -> [AskGroundedClaim] {
    claims.compactMap { claim in
      let text = claim.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, !claim.supports.isEmpty else { return nil }
      var seen = Set<String>()
      var acceptedIDs: [String] = []
      for support in claim.supports {
        guard let evidenceText = evidenceTextByID[support.evidenceID] else { return nil }
        let excerpt = normalizedSupportText(support.excerpt)
        guard excerpt.count >= 4,
          normalizedSupportText(evidenceText).contains(excerpt)
        else { return nil }
        if seen.insert(support.evidenceID).inserted {
          acceptedIDs.append(support.evidenceID)
        }
      }
      guard !acceptedIDs.isEmpty else { return nil }
      return AskGroundedClaim(text: text, citationIDs: acceptedIDs)
    }
  }

  private static func normalizedSupportText(_ value: String) -> String {
    value.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}

private enum AskLexical {
  static let stopWords: Set<String> = [
    "a", "about", "all", "am", "an", "and", "are", "around", "as", "at", "based", "be", "by",
    "can",
    "could", "did", "do", "does", "for", "from", "give", "have", "how", "i", "in", "is", "it",
    "important", "importance", "list",
    "many", "me", "my", "number", "of", "on", "please", "right", "should", "show", "some", "tell",
    "here", "that", "the", "them", "thing", "things",
    "there", "these", "those", "to", "was", "we", "were", "what", "when", "which", "who", "why",
    "only", "s", "using", "with", "would",
    "you",
  ]
  static let sourceWords: Set<String> = [
    "action", "appointment", "availability", "calendar", "calendars", "checklist", "codex",
    "conversation",
    "decide",
    "decided", "decision", "decisions", "discuss", "discussed", "document", "documents", "event",
    "events",
    "items", "meeting", "meetings", "mentioned", "note", "notes", "recording", "recordings", "said",
    "say",
    "schedule", "summaries", "summarise", "summarize", "summary", "talked", "task", "tasks",
    "thread", "threads", "todo",
    "todos",
    "transcript", "transcripts",
  ]
  static let filterWords: Set<String> = [
    "active", "biggest", "complete", "completed", "count", "current", "currently", "done", "due",
    "error",
    "errors", "failed", "failure", "favorite", "favourite", "finished", "focus", "incomplete",
    "late",
    "live", "now", "open", "overdue", "pending", "priorities", "priority", "running", "starred",
    "unfinished", "urgent",
  ]
  static let intentWords: Set<String> = [
    "attention", "because", "changed", "changes", "chosen", "defer", "deferred", "finish", "left",
    "matters", "most", "need", "needs", "order", "outstanding", "organise", "organize", "picked",
    "plan", "progress", "reason", "reasons", "selected", "structure", "update", "updates", "work",
  ]
  /// Words that describe the requested decision/output rather than the subject of a broad planning
  /// search. Requiring these to appear in stored records caused natural prompts such as "What
  /// should I build today?" to miss todos, meetings, notes, and calendar events entirely.
  static let decisionFillerWords: Set<String> = [
    "accomplish", "accomplished", "achieve", "build", "first", "five", "four", "include",
    "includes", "including", "one", "second", "six", "three", "top", "two",
  ]
  static let dateWords: Set<String> = [
    "afternoon", "day", "days", "last", "morning", "newest", "next", "past", "recent", "recently", "this",
    "today", "latest",
    "tomorrow", "tonight", "upcoming", "week", "yesterday",
  ]

  static func tokenize(_ value: String) -> [String] {
    let normalized = value.askNormalized
    var tokens = normalized
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    // Users commonly spell the noun as "to-do", "to do", or a possessive ("my to do's"). Only
    // promote the two-token form when its local grammar is noun-like so a verb phrase such as
    // "plan to do this week" does not accidentally become a todo-only source request.
    let nounDeterminers: Set<String> = [
      "a", "any", "my", "our", "some", "the", "these", "those", "your",
    ]
    for index in tokens.indices where tokens[index] == "to" {
      let next = tokens.index(after: index)
      guard next < tokens.endIndex, tokens[next] == "do" else { continue }
      let previousToken = index > tokens.startIndex ? tokens[tokens.index(before: index)] : nil
      let afterDo = tokens.index(after: next)
      let followingToken = afterDo < tokens.endIndex ? tokens[afterDo] : nil
      let hyphenated = normalized.contains("to-do")
      let nounLike = previousToken.map(nounDeterminers.contains) == true
        || followingToken.map { ["item", "items", "list", "s"].contains($0) } == true
      if hyphenated || nounLike {
        tokens.append("todo")
        break
      }
    }
    return tokens
  }

  static func frequencyMap(_ value: String) -> [String: Int] {
    Dictionary(tokenize(value).map { ($0, 1) }, uniquingKeysWith: +)
  }
}

extension String {
  fileprivate var askNormalized: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .lowercased()
  }

  fileprivate var nonEmptyAskValue: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

extension Array where Element: Hashable {
  fileprivate func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
