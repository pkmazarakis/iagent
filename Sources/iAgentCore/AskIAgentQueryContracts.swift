import CryptoKit
import Foundation

// MARK: - Runtime catalog

/// The locale and calendar assumptions frozen for one Ask iAgent research turn.
/// Relative time is always resolved from this value, never from an autoupdating global calendar.
public struct AskTemporalContext: Codable, Equatable, Sendable {
  public var contextAsOf: Date
  public var timeZoneIdentifier: String
  public var localeIdentifier: String
  public var calendarIdentifier: String
  public var firstWeekday: Int

  public init(
    contextAsOf: Date,
    timeZoneIdentifier: String,
    localeIdentifier: String,
    calendarIdentifier: String = "gregorian",
    firstWeekday: Int = 2
  ) {
    self.contextAsOf = contextAsOf
    self.timeZoneIdentifier = timeZoneIdentifier
    self.localeIdentifier = localeIdentifier
    self.calendarIdentifier = calendarIdentifier
    self.firstWeekday = firstWeekday
  }

  public func calendar() throws -> Calendar {
    guard let timeZone = TimeZone(identifier: timeZoneIdentifier),
      (1...7).contains(firstWeekday)
    else {
      throw AskQueryFailure(code: .invalidTemporalContext, field: "temporalContext")
    }

    let identifier: Calendar.Identifier
    switch calendarIdentifier.lowercased() {
    case "gregorian": identifier = .gregorian
    case "iso8601": identifier = .iso8601
    case "buddhist": identifier = .buddhist
    case "chinese": identifier = .chinese
    case "coptic": identifier = .coptic
    case "ethiopic-amete-mihret": identifier = .ethiopicAmeteMihret
    case "ethiopic-amete-alem": identifier = .ethiopicAmeteAlem
    case "hebrew": identifier = .hebrew
    case "indian": identifier = .indian
    case "islamic": identifier = .islamic
    case "islamic-civil": identifier = .islamicCivil
    case "japanese": identifier = .japanese
    case "persian": identifier = .persian
    case "republic-of-china": identifier = .republicOfChina
    default:
      throw AskQueryFailure(code: .invalidTemporalContext, field: "calendarIdentifier")
    }

    var calendar = Calendar(identifier: identifier)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: localeIdentifier)
    calendar.firstWeekday = firstWeekday
    return calendar
  }
}

public enum AskCatalogAvailability: String, Codable, CaseIterable, Sendable {
  case available
  case partial
  case unavailable
}

public enum AskCatalogAvailabilityReason: String, Codable, CaseIterable, Sendable {
  case none
  case accessDenied
  case offline
  case notSynced
  case notLoaded
  case unknown
}

public enum AskCatalogFreshness: String, Codable, CaseIterable, Sendable {
  case current
  case stale
  case unknown
}

/// A content-free description of the time range represented by one domain.
public struct AskCatalogCoverage: Codable, Equatable, Sendable {
  public var start: Date?
  public var end: Date?
  public var isCompleteWithinRange: Bool
  public var isTruncated: Bool

  public init(
    start: Date? = nil,
    end: Date? = nil,
    isCompleteWithinRange: Bool = true,
    isTruncated: Bool = false
  ) {
    self.start = start
    self.end = end
    self.isCompleteWithinRange = isCompleteWithinRange
    self.isTruncated = isTruncated
  }
}

/// Runtime catalog metadata intentionally contains no titles, excerpts, notes, or record identifiers.
public struct AskDomainCatalogEntry: Codable, Equatable, Sendable {
  public var domain: AskSourceKind
  public var availability: AskCatalogAvailability
  public var availabilityReason: AskCatalogAvailabilityReason
  public var recordCount: Int
  public var observedAt: Date
  public var lastSuccessfulReadAt: Date?
  public var freshness: AskCatalogFreshness
  public var coverage: AskCatalogCoverage

  public init(
    domain: AskSourceKind,
    availability: AskCatalogAvailability,
    availabilityReason: AskCatalogAvailabilityReason = .none,
    recordCount: Int,
    observedAt: Date,
    lastSuccessfulReadAt: Date? = nil,
    freshness: AskCatalogFreshness,
    coverage: AskCatalogCoverage = AskCatalogCoverage()
  ) {
    self.domain = domain
    self.availability = availability
    self.availabilityReason = availabilityReason
    self.recordCount = max(0, recordCount)
    self.observedAt = observedAt
    self.lastSuccessfulReadAt = lastSuccessfulReadAt
    self.freshness = freshness
    self.coverage = coverage
  }
}

/// The only eager context required by the V2 research harness.
public struct AskDataCatalog: Codable, Equatable, Sendable {
  public static let protocolVersion = 2

  public var version: Int
  public var snapshotID: String
  public var temporalContext: AskTemporalContext
  public var domains: [AskDomainCatalogEntry]

  public init(
    version: Int = Self.protocolVersion,
    snapshotID: String,
    temporalContext: AskTemporalContext,
    domains: [AskDomainCatalogEntry]
  ) {
    self.version = version
    self.snapshotID = snapshotID
    self.temporalContext = temporalContext
    self.domains = domains.sorted { $0.domain.rawValue < $1.domain.rawValue }
  }
}

// MARK: - Typed queries

public enum AskQueryTemporalField: String, Codable, CaseIterable, Sendable {
  case due
  case completed
  case created
  case updated
  case occurrence
  case visibleOutput
}

public enum AskQueryTemporalPreset: String, Codable, CaseIterable, Sendable {
  case any
  case past
  case today
  case tomorrow
  case yesterday
  case thisWeek
  case next7Days
  case last7Days
  case last30Days
  case absolute
}

public struct AskQueryTimeFilter: Codable, Equatable, Sendable {
  public var field: AskQueryTemporalField
  public var preset: AskQueryTemporalPreset
  public var start: Date?
  public var end: Date?

  public init(
    field: AskQueryTemporalField,
    preset: AskQueryTemporalPreset = .any,
    start: Date? = nil,
    end: Date? = nil
  ) {
    self.field = field
    self.preset = preset
    self.start = start
    self.end = end
  }

  public func resolvedRange(in context: AskTemporalContext) throws -> AskDateRange? {
    if preset == .any { return nil }
    if preset == .absolute {
      guard let start, let end, start < end else {
        throw AskQueryFailure(code: .invalidTemporalRange, field: "time")
      }
      return AskDateRange(start: start, end: end)
    }

    let calendar = try context.calendar()
    let today = calendar.startOfDay(for: context.contextAsOf)
    func day(_ offset: Int) throws -> Date {
      guard let value = calendar.date(byAdding: .day, value: offset, to: today) else {
        throw AskQueryFailure(code: .invalidTemporalRange, field: "time")
      }
      return value
    }

    switch preset {
    case .any, .absolute:
      return nil
    case .past:
      return AskDateRange(start: .distantPast, end: context.contextAsOf)
    case .today:
      return AskDateRange(start: today, end: try day(1))
    case .tomorrow:
      return AskDateRange(start: try day(1), end: try day(2))
    case .yesterday:
      return AskDateRange(start: try day(-1), end: today)
    case .thisWeek:
      guard let interval = calendar.dateInterval(of: .weekOfYear, for: context.contextAsOf) else {
        throw AskQueryFailure(code: .invalidTemporalRange, field: "time")
      }
      return AskDateRange(start: interval.start, end: interval.end)
    case .next7Days:
      return AskDateRange(start: today, end: try day(7))
    case .last7Days:
      return AskDateRange(start: try day(-6), end: try day(1))
    case .last30Days:
      return AskDateRange(start: try day(-29), end: try day(1))
    }
  }
}

public enum AskTodoStateFilter: String, Codable, CaseIterable, Sendable {
  case open
  case completed
}

public enum AskTodoDueFilter: String, Codable, CaseIterable, Sendable {
  case any
  case hasDueDate
  case noDueDate
  case overdue
  case dueInWindow
}

public enum AskTodoSort: String, Codable, CaseIterable, Sendable {
  case relevanceDesc
  case attentionDesc
  case dueAsc
  case updatedDesc
  case createdDesc
  case completedDesc
}

public enum AskTodoContent: String, Codable, CaseIterable, Sendable {
  case metadata
  case preview
  case full
}

public struct AskTodoQuery: Codable, Equatable, Sendable {
  public var queryID: String
  public var text: String?
  public var recordIDs: [String]
  public var states: [AskTodoStateFilter]
  public var starred: Bool?
  public var due: AskTodoDueFilter
  public var listNames: [String]
  public var time: AskQueryTimeFilter
  public var sort: AskTodoSort
  public var content: AskTodoContent
  public var limit: Int
  public var cursor: String?

  public init(
    queryID: String,
    text: String? = nil,
    recordIDs: [String] = [],
    states: [AskTodoStateFilter] = [],
    starred: Bool? = nil,
    due: AskTodoDueFilter = .any,
    listNames: [String] = [],
    time: AskQueryTimeFilter = AskQueryTimeFilter(field: .updated),
    sort: AskTodoSort = .relevanceDesc,
    content: AskTodoContent = .preview,
    limit: Int = 10,
    cursor: String? = nil
  ) {
    self.queryID = queryID
    self.text = text
    self.recordIDs = recordIDs
    self.states = states
    self.starred = starred
    self.due = due
    self.listNames = listNames
    self.time = time
    self.sort = sort
    self.content = content
    self.limit = limit
    self.cursor = cursor
  }

  private enum CodingKeys: String, CodingKey {
    case queryID = "query_id"
    case text
    case recordIDs = "record_ids"
    case states
    case starred
    case due
    case listNames = "list_names"
    case time
    case sort
    case content
    case limit
    case cursor
  }
}

public enum AskCalendarSort: String, Codable, CaseIterable, Sendable {
  case relevanceDesc
  case startAsc
  case startDesc
  case updatedDesc
}

public enum AskCalendarContent: String, Codable, CaseIterable, Sendable {
  case metadata
  case details
}

public struct AskCalendarQuery: Codable, Equatable, Sendable {
  public var queryID: String
  public var text: String?
  public var recordIDs: [String]
  public var calendarTitles: [String]
  public var allDay: Bool?
  public var time: AskQueryTimeFilter
  public var sort: AskCalendarSort
  public var content: AskCalendarContent
  public var limit: Int
  public var cursor: String?

  public init(
    queryID: String,
    text: String? = nil,
    recordIDs: [String] = [],
    calendarTitles: [String] = [],
    allDay: Bool? = nil,
    time: AskQueryTimeFilter = AskQueryTimeFilter(field: .occurrence),
    sort: AskCalendarSort = .startAsc,
    content: AskCalendarContent = .details,
    limit: Int = 10,
    cursor: String? = nil
  ) {
    self.queryID = queryID
    self.text = text
    self.recordIDs = recordIDs
    self.calendarTitles = calendarTitles
    self.allDay = allDay
    self.time = time
    self.sort = sort
    self.content = content
    self.limit = limit
    self.cursor = cursor
  }

  private enum CodingKeys: String, CodingKey {
    case queryID = "query_id"
    case text
    case recordIDs = "record_ids"
    case calendarTitles = "calendar_titles"
    case allDay = "all_day"
    case time
    case sort
    case content
    case limit
    case cursor
  }
}

public enum AskNoteSort: String, Codable, CaseIterable, Sendable {
  case relevanceDesc
  case updatedDesc
  case createdDesc
}

public enum AskNoteContent: String, Codable, CaseIterable, Sendable {
  case metadata
  case preview
  case full
}

public struct AskNoteQuery: Codable, Equatable, Sendable {
  public var queryID: String
  public var text: String?
  public var recordIDs: [String]
  public var time: AskQueryTimeFilter
  public var sort: AskNoteSort
  public var content: AskNoteContent
  public var limit: Int
  public var cursor: String?

  public init(
    queryID: String,
    text: String? = nil,
    recordIDs: [String] = [],
    time: AskQueryTimeFilter = AskQueryTimeFilter(field: .updated),
    sort: AskNoteSort = .relevanceDesc,
    content: AskNoteContent = .preview,
    limit: Int = 10,
    cursor: String? = nil
  ) {
    self.queryID = queryID
    self.text = text
    self.recordIDs = recordIDs
    self.time = time
    self.sort = sort
    self.content = content
    self.limit = limit
    self.cursor = cursor
  }

  private enum CodingKeys: String, CodingKey {
    case queryID = "query_id"
    case text
    case recordIDs = "record_ids"
    case time
    case sort
    case content
    case limit
    case cursor
  }
}

public enum AskMeetingStateFilter: String, Codable, CaseIterable, Sendable {
  case recording
  case completed
  case failed
}

public enum AskMeetingSort: String, Codable, CaseIterable, Sendable {
  case relevanceDesc
  case occurrenceDesc
  case occurrenceAsc
  case updatedDesc
}

public enum AskMeetingContent: String, Codable, CaseIterable, Sendable {
  case metadata
  case summary
  case summaryAndTranscriptPassages
}

public struct AskMeetingQuery: Codable, Equatable, Sendable {
  public var queryID: String
  public var text: String?
  public var recordIDs: [String]
  public var states: [AskMeetingStateFilter]
  public var hasReadableContent: Bool?
  public var time: AskQueryTimeFilter
  public var sort: AskMeetingSort
  public var content: AskMeetingContent
  public var limit: Int
  public var cursor: String?

  public init(
    queryID: String,
    text: String? = nil,
    recordIDs: [String] = [],
    states: [AskMeetingStateFilter] = [],
    hasReadableContent: Bool? = nil,
    time: AskQueryTimeFilter = AskQueryTimeFilter(field: .occurrence),
    sort: AskMeetingSort = .relevanceDesc,
    content: AskMeetingContent = .summary,
    limit: Int = 10,
    cursor: String? = nil
  ) {
    self.queryID = queryID
    self.text = text
    self.recordIDs = recordIDs
    self.states = states
    self.hasReadableContent = hasReadableContent
    self.time = time
    self.sort = sort
    self.content = content
    self.limit = limit
    self.cursor = cursor
  }

  public static func latestCompletedReadable(queryID: String) -> AskMeetingQuery {
    AskMeetingQuery(
      queryID: queryID,
      states: [.completed],
      hasReadableContent: true,
      time: AskQueryTimeFilter(field: .occurrence, preset: .past),
      sort: .occurrenceDesc,
      content: .summaryAndTranscriptPassages,
      limit: 1
    )
  }

  private enum CodingKeys: String, CodingKey {
    case queryID = "query_id"
    case text
    case recordIDs = "record_ids"
    case states
    case hasReadableContent = "has_readable_content"
    case time
    case sort
    case content
    case limit
    case cursor
  }
}

public enum AskCodexStateFilter: String, Codable, CaseIterable, Sendable {
  case running
  case waitingForInput
  case needsApproval
  case completed
  case failed
}

public enum AskCodexModeFilter: String, Codable, CaseIterable, Sendable {
  case plan
  case goal
  case voice
}

public enum AskCodexSort: String, Codable, CaseIterable, Sendable {
  case relevanceDesc
  case updatedDesc
  case createdDesc
}

public enum AskCodexContent: String, Codable, CaseIterable, Sendable {
  case metadata
  case activity
  case visibleOutputs
}

public struct AskCodexQuery: Codable, Equatable, Sendable {
  public var queryID: String
  public var text: String?
  public var recordIDs: [String]
  public var states: [AskCodexStateFilter]
  public var modes: [AskCodexModeFilter]
  public var projectNames: [String]
  public var time: AskQueryTimeFilter
  public var sort: AskCodexSort
  public var content: AskCodexContent
  public var limit: Int
  public var cursor: String?

  public init(
    queryID: String,
    text: String? = nil,
    recordIDs: [String] = [],
    states: [AskCodexStateFilter] = [],
    modes: [AskCodexModeFilter] = [],
    projectNames: [String] = [],
    time: AskQueryTimeFilter = AskQueryTimeFilter(field: .updated),
    sort: AskCodexSort = .relevanceDesc,
    content: AskCodexContent = .activity,
    limit: Int = 10,
    cursor: String? = nil
  ) {
    self.queryID = queryID
    self.text = text
    self.recordIDs = recordIDs
    self.states = states
    self.modes = modes
    self.projectNames = projectNames
    self.time = time
    self.sort = sort
    self.content = content
    self.limit = limit
    self.cursor = cursor
  }

  private enum CodingKeys: String, CodingKey {
    case queryID = "query_id"
    case text
    case recordIDs = "record_ids"
    case states
    case modes
    case projectNames = "project_names"
    case time
    case sort
    case content
    case limit
    case cursor
  }
}

public enum AskReadQuery: Codable, Equatable, Sendable {
  case todo(AskTodoQuery)
  case calendar(AskCalendarQuery)
  case note(AskNoteQuery)
  case meeting(AskMeetingQuery)
  case codex(AskCodexQuery)

  public var domain: AskSourceKind {
    switch self {
    case .todo: .todo
    case .calendar: .calendar
    case .note: .note
    case .meeting: .meeting
    case .codex: .codex
    }
  }

  public var queryID: String {
    switch self {
    case .todo(let value): value.queryID
    case .calendar(let value): value.queryID
    case .note(let value): value.queryID
    case .meeting(let value): value.queryID
    case .codex(let value): value.queryID
    }
  }

  private enum CodingKeys: String, CodingKey { case domain, arguments }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let domain = try container.decode(AskSourceKind.self, forKey: .domain)
    let arguments = try container.superDecoder(forKey: .arguments)
    switch domain {
    case .todo: self = .todo(try AskTodoQuery(from: arguments))
    case .calendar: self = .calendar(try AskCalendarQuery(from: arguments))
    case .note: self = .note(try AskNoteQuery(from: arguments))
    case .meeting: self = .meeting(try AskMeetingQuery(from: arguments))
    case .codex: self = .codex(try AskCodexQuery(from: arguments))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(domain, forKey: .domain)
    let arguments = container.superEncoder(forKey: .arguments)
    switch self {
    case .todo(let value): try value.encode(to: arguments)
    case .calendar(let value): try value.encode(to: arguments)
    case .note(let value): try value.encode(to: arguments)
    case .meeting(let value): try value.encode(to: arguments)
    case .codex(let value): try value.encode(to: arguments)
    }
  }
}

// MARK: - Results, budgets, progress, and errors

public struct AskQueryBudget: Codable, Equatable, Sendable {
  public var maximumCalls: Int
  public var maximumCallsPerDomain: Int
  public var maximumPagesPerDomain: Int
  public var maximumRecordsPerPage: Int
  public var maximumTotalRecords: Int
  public var maximumEvidencePassages: Int
  public var maximumEvidenceCharacters: Int

  public init(
    maximumCalls: Int = 8,
    maximumCallsPerDomain: Int = 2,
    maximumPagesPerDomain: Int = 2,
    maximumRecordsPerPage: Int = 10,
    maximumTotalRecords: Int = 40,
    maximumEvidencePassages: Int = 20,
    maximumEvidenceCharacters: Int = 20_000
  ) {
    self.maximumCalls = maximumCalls
    self.maximumCallsPerDomain = maximumCallsPerDomain
    self.maximumPagesPerDomain = maximumPagesPerDomain
    self.maximumRecordsPerPage = maximumRecordsPerPage
    self.maximumTotalRecords = maximumTotalRecords
    self.maximumEvidencePassages = maximumEvidencePassages
    self.maximumEvidenceCharacters = maximumEvidenceCharacters
  }

  public func validate() throws {
    guard maximumCalls > 0,
      maximumCallsPerDomain > 0,
      maximumPagesPerDomain > 0,
      maximumRecordsPerPage > 0,
      maximumTotalRecords > 0,
      maximumEvidencePassages > 0,
      maximumEvidenceCharacters > 0
    else {
      throw AskQueryFailure(code: .invalidBudget, field: "budget")
    }
  }
}

public struct AskQueryDomainUsage: Codable, Equatable, Sendable {
  public var domain: AskSourceKind
  public var calls: Int
  public var pages: Int

  public init(domain: AskSourceKind, calls: Int, pages: Int) {
    self.domain = domain
    self.calls = calls
    self.pages = pages
  }
}

public struct AskQueryBudgetUsage: Codable, Equatable, Sendable {
  public var calls: Int
  public var records: Int
  public var evidencePassages: Int
  public var evidenceCharacters: Int
  public var domains: [AskQueryDomainUsage]

  public init(
    calls: Int = 0,
    records: Int = 0,
    evidencePassages: Int = 0,
    evidenceCharacters: Int = 0,
    domains: [AskQueryDomainUsage] = []
  ) {
    self.calls = calls
    self.records = records
    self.evidencePassages = evidencePassages
    self.evidenceCharacters = evidenceCharacters
    self.domains = domains
  }
}

public enum AskQueryCompleteness: String, Codable, CaseIterable, Sendable {
  case complete
  case partial
  case unavailable
}

public enum AskQueryWarning: String, Codable, CaseIterable, Sendable {
  case staleSource
  case truncatedSource
  case resultBudgetReached
  case evidenceBudgetReached
  case legacyDueSemantics
  case outOfCoverage
}

public struct AskQueryEvidence: Codable, Equatable, Sendable {
  public var id: String
  public var source: AskSourceReference
  public var anchor: String
  public var excerpt: String

  public init(id: String, source: AskSourceReference, anchor: String, excerpt: String) {
    self.id = id
    self.source = source
    self.anchor = anchor
    self.excerpt = excerpt
  }
}

public struct AskQueryItem: Codable, Equatable, Sendable {
  public var source: AskSourceReference
  public var title: String
  public var status: AskKnowledgeStatus?
  public var dueAt: Date?
  public var startsAt: Date?
  public var endsAt: Date?
  public var updatedAt: Date
  public var isStarred: Bool?
  public var isAllDay: Bool?
  public var collectionName: String?
  public var evidence: [AskQueryEvidence]

  public init(
    source: AskSourceReference,
    title: String,
    status: AskKnowledgeStatus? = nil,
    dueAt: Date? = nil,
    startsAt: Date? = nil,
    endsAt: Date? = nil,
    updatedAt: Date,
    isStarred: Bool? = nil,
    isAllDay: Bool? = nil,
    collectionName: String? = nil,
    evidence: [AskQueryEvidence]
  ) {
    self.source = source
    self.title = title
    self.status = status
    self.dueAt = dueAt
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.updatedAt = updatedAt
    self.isStarred = isStarred
    self.isAllDay = isAllDay
    self.collectionName = collectionName
    self.evidence = evidence
  }
}

public struct AskQueryPage: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var queryID: String
  public var snapshotID: String
  public var domain: AskSourceKind
  public var completeness: AskQueryCompleteness
  public var observedAt: Date
  public var totalMatched: Int?
  public var returnedCount: Int
  public var items: [AskQueryItem]
  public var hasMore: Bool
  public var nextCursor: String?
  public var warnings: [AskQueryWarning]
  public var budgetUsage: AskQueryBudgetUsage

  public init(
    protocolVersion: Int = AskDataCatalog.protocolVersion,
    queryID: String,
    snapshotID: String,
    domain: AskSourceKind,
    completeness: AskQueryCompleteness,
    observedAt: Date,
    totalMatched: Int?,
    items: [AskQueryItem],
    hasMore: Bool,
    nextCursor: String?,
    warnings: [AskQueryWarning] = [],
    budgetUsage: AskQueryBudgetUsage
  ) {
    self.protocolVersion = protocolVersion
    self.queryID = queryID
    self.snapshotID = snapshotID
    self.domain = domain
    self.completeness = completeness
    self.observedAt = observedAt
    self.totalMatched = totalMatched
    returnedCount = items.count
    self.items = items
    self.hasMore = hasMore
    self.nextCursor = nextCursor
    self.warnings = warnings
    self.budgetUsage = budgetUsage
  }
}

public enum AskQueryProgressPhase: String, Codable, CaseIterable, Sendable {
  case validated
  case executing
  case pageProduced
  case completed
  case failed
}

/// User-visible progress is derived from validated executor activity, never model reasoning.
public struct AskQueryProgress: Codable, Equatable, Sendable {
  public var sequence: Int
  public var queryID: String
  public var domain: AskSourceKind
  public var phase: AskQueryProgressPhase
  public var returnedCount: Int
  public var totalMatched: Int?
  public var isTruncated: Bool
  public var observedAt: Date

  public init(
    sequence: Int,
    queryID: String,
    domain: AskSourceKind,
    phase: AskQueryProgressPhase,
    returnedCount: Int = 0,
    totalMatched: Int? = nil,
    isTruncated: Bool = false,
    observedAt: Date
  ) {
    self.sequence = sequence
    self.queryID = queryID
    self.domain = domain
    self.phase = phase
    self.returnedCount = returnedCount
    self.totalMatched = totalMatched
    self.isTruncated = isTruncated
    self.observedAt = observedAt
  }
}

public enum AskQueryErrorCode: String, Codable, CaseIterable, Sendable {
  case invalidQuery
  case invalidTemporalContext
  case invalidTemporalRange
  case unsupportedTemporalField
  case invalidCursor
  case invalidBudget
  case budgetExceeded
  case cancelled
  case unavailable
  case outOfCoverage
  case unsupportedDomain
}

public struct AskQueryFailure: Error, Codable, Equatable, Sendable {
  public var code: AskQueryErrorCode
  public var queryID: String?
  public var field: String?

  public init(code: AskQueryErrorCode, queryID: String? = nil, field: String? = nil) {
    self.code = code
    self.queryID = queryID
    self.field = field
  }
}

// MARK: - Strict JSON tool schemas

/// A small JSON-Schema algebra that emits strict objects by construction.
public indirect enum AskStrictJSONSchema: Codable, Equatable, Sendable {
  case object(description: String?, properties: [String: AskStrictJSONSchema])
  case array(description: String?, items: AskStrictJSONSchema, maxItems: Int?)
  case string(description: String?, values: [String]?, nullable: Bool, maxLength: Int?)
  case integer(description: String?, minimum: Int?, maximum: Int?)
  case boolean(description: String?, nullable: Bool)

  private enum CodingKeys: String, CodingKey {
    case type
    case description
    case properties
    case required
    case additionalProperties
    case items
    case maxItems
    case enumValues = "enum"
    case maxLength
    case minimum
    case maximum
  }

  private enum SchemaType: Equatable, Sendable {
    case scalar(String)
    case union([String])
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type: SchemaType
    if let scalar = try? container.decode(String.self, forKey: .type) {
      type = .scalar(scalar)
    } else {
      type = .union(try container.decode([String].self, forKey: .type))
    }
    let description = try container.decodeIfPresent(String.self, forKey: .description)

    switch type {
    case .scalar("object"):
      let properties = try container.decode(
        [String: AskStrictJSONSchema].self, forKey: .properties)
      let required = try container.decode([String].self, forKey: .required)
      let additional = try container.decode(Bool.self, forKey: .additionalProperties)
      guard Set(required) == Set(properties.keys), additional == false else {
        throw DecodingError.dataCorruptedError(
          forKey: .required, in: container, debugDescription: "Object schema is not strict")
      }
      self = .object(description: description, properties: properties)
    case .scalar("array"):
      self = .array(
        description: description,
        items: try container.decode(AskStrictJSONSchema.self, forKey: .items),
        maxItems: try container.decodeIfPresent(Int.self, forKey: .maxItems)
      )
    case .scalar("string"):
      self = .string(
        description: description,
        values: try container.decodeIfPresent([String].self, forKey: .enumValues),
        nullable: false,
        maxLength: try container.decodeIfPresent(Int.self, forKey: .maxLength)
      )
    case .scalar("integer"):
      self = .integer(
        description: description,
        minimum: try container.decodeIfPresent(Int.self, forKey: .minimum),
        maximum: try container.decodeIfPresent(Int.self, forKey: .maximum)
      )
    case .scalar("boolean"):
      self = .boolean(description: description, nullable: false)
    case .union(let values) where Set(values) == Set(["string", "null"]):
      self = .string(
        description: description,
        values: try container.decodeIfPresent([String].self, forKey: .enumValues),
        nullable: true,
        maxLength: try container.decodeIfPresent(Int.self, forKey: .maxLength)
      )
    case .union(let values) where Set(values) == Set(["boolean", "null"]):
      self = .boolean(description: description, nullable: true)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: container, debugDescription: "Unsupported strict schema type")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .object(let description, let properties):
      try container.encode("object", forKey: .type)
      try container.encodeIfPresent(description, forKey: .description)
      try container.encode(properties, forKey: .properties)
      try container.encode(properties.keys.sorted(), forKey: .required)
      try container.encode(false, forKey: .additionalProperties)
    case .array(let description, let items, let maxItems):
      try container.encode("array", forKey: .type)
      try container.encodeIfPresent(description, forKey: .description)
      try container.encode(items, forKey: .items)
      try container.encodeIfPresent(maxItems, forKey: .maxItems)
    case .string(let description, let values, let nullable, let maxLength):
      if nullable {
        try container.encode(["string", "null"], forKey: .type)
      } else {
        try container.encode("string", forKey: .type)
      }
      try container.encodeIfPresent(description, forKey: .description)
      try container.encodeIfPresent(values, forKey: .enumValues)
      try container.encodeIfPresent(maxLength, forKey: .maxLength)
    case .integer(let description, let minimum, let maximum):
      try container.encode("integer", forKey: .type)
      try container.encodeIfPresent(description, forKey: .description)
      try container.encodeIfPresent(minimum, forKey: .minimum)
      try container.encodeIfPresent(maximum, forKey: .maximum)
    case .boolean(let description, let nullable):
      if nullable {
        try container.encode(["boolean", "null"], forKey: .type)
      } else {
        try container.encode("boolean", forKey: .type)
      }
      try container.encodeIfPresent(description, forKey: .description)
    }
  }
}

public struct AskStrictReadToolSchema: Codable, Equatable, Sendable {
  public var type: String
  public var name: String
  public var description: String
  public var strict: Bool
  public var parameters: AskStrictJSONSchema

  public init(name: String, description: String, parameters: AskStrictJSONSchema) {
    type = "function"
    self.name = name
    self.description = description
    strict = true
    self.parameters = parameters
  }
}

public enum AskReadToolSchemas {
  /// Increment whenever a tool name, description, or strict argument schema changes.
  public static let schemaVersion = 1

  public static let all: [AskStrictReadToolSchema] = [
    todo, calendar, note, meeting, codex,
  ]

  /// The only read tools an external reasoning model may request.
  public static let allowedNames: [String] = all.map(\.name)

  /// A stable SHA-256 identity for the ordered, strict read-tool contract.
  public static let schemaDigest: String = {
    struct Manifest: Encodable {
      let schemaVersion: Int
      let tools: [AskStrictReadToolSchema]

      private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case tools
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data =
      (try? encoder.encode(Manifest(schemaVersion: schemaVersion, tools: all))) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }()

  public static let todo = AskStrictReadToolSchema(
    name: "query_todos",
    description: "Read bounded todo metadata or content from the pinned iAgent snapshot.",
    parameters: object(
      commonProperties().merging([
        "states": enumArray(AskTodoStateFilter.allCases),
        "starred": .boolean(description: "Exact starred filter, or null for any.", nullable: true),
        "due": enumString(AskTodoDueFilter.allCases),
        "list_names": stringArray(maxItems: 10),
        "sort": enumString(AskTodoSort.allCases),
        "content": enumString(AskTodoContent.allCases),
      ]) { _, right in right }))

  public static let calendar = AskStrictReadToolSchema(
    name: "query_calendar",
    description: "Read bounded calendar occurrences from the pinned calendar capture.",
    parameters: object(
      commonProperties().merging([
        "calendar_titles": stringArray(maxItems: 10),
        "all_day": .boolean(description: "Exact all-day filter, or null for any.", nullable: true),
        "sort": enumString(AskCalendarSort.allCases),
        "content": enumString(AskCalendarContent.allCases),
      ]) { _, right in right }))

  public static let note = AskStrictReadToolSchema(
    name: "query_notes",
    description: "Read bounded standalone note metadata or passages.",
    parameters: object(
      commonProperties().merging([
        "sort": enumString(AskNoteSort.allCases),
        "content": enumString(AskNoteContent.allCases),
      ]) { _, right in right }))

  public static let meeting = AskStrictReadToolSchema(
    name: "query_meetings",
    description: "Read bounded meeting metadata, summaries, or transcript passages.",
    parameters: object(
      commonProperties().merging([
        "states": enumArray(AskMeetingStateFilter.allCases),
        "has_readable_content": .boolean(
          description: "Require or exclude readable meeting content, or null for any.",
          nullable: true),
        "sort": enumString(AskMeetingSort.allCases),
        "content": enumString(AskMeetingContent.allCases),
      ]) { _, right in right }))

  public static let codex = AskStrictReadToolSchema(
    name: "query_codex",
    description: "Read bounded safe Codex task metadata, activity, or visible outputs.",
    parameters: object(
      commonProperties().merging([
        "states": enumArray(AskCodexStateFilter.allCases),
        "modes": enumArray(AskCodexModeFilter.allCases),
        "project_names": stringArray(maxItems: 10),
        "sort": enumString(AskCodexSort.allCases),
        "content": enumString(AskCodexContent.allCases),
      ]) { _, right in right }))

  private static func commonProperties() -> [String: AskStrictJSONSchema] {
    [
      "query_id": .string(
        description: "Unique identifier for this query within the turn.",
        values: nil, nullable: false, maxLength: 64),
      "text": .string(
        description: "Optional bounded lexical subject; null means no text filter.",
        values: nil, nullable: true, maxLength: 300),
      "record_ids": stringArray(maxItems: 10),
      "time": object([
        "field": enumString(AskQueryTemporalField.allCases),
        "preset": enumString(AskQueryTemporalPreset.allCases),
        "start": .string(
          description: "Inclusive RFC 3339 bound for absolute ranges.",
          values: nil, nullable: true, maxLength: 40),
        "end": .string(
          description: "Exclusive RFC 3339 bound for absolute ranges.",
          values: nil, nullable: true, maxLength: 40),
      ]),
      "limit": .integer(description: "Maximum records in this page.", minimum: 1, maximum: 10),
      "cursor": .string(
        description: "Opaque snapshot-bound page cursor, or null for the first page.",
        values: nil, nullable: true, maxLength: 1_024),
    ]
  }

  private static func object(_ properties: [String: AskStrictJSONSchema]) -> AskStrictJSONSchema {
    .object(description: nil, properties: properties)
  }

  private static func stringArray(maxItems: Int) -> AskStrictJSONSchema {
    .array(
      description: nil,
      items: .string(description: nil, values: nil, nullable: false, maxLength: 240),
      maxItems: maxItems
    )
  }

  private static func enumString<T: RawRepresentable>(_ values: [T]) -> AskStrictJSONSchema
  where T.RawValue == String {
    .string(
      description: nil,
      values: values.map(\.rawValue),
      nullable: false,
      maxLength: nil
    )
  }

  private static func enumArray<T: RawRepresentable>(_ values: [T]) -> AskStrictJSONSchema
  where T.RawValue == String {
    .array(description: nil, items: enumString(values), maxItems: values.count)
  }
}

// MARK: - External read-tool boundary

public enum AskReadToolCallErrorCode: String, Codable, CaseIterable, Sendable {
  case unsupportedTool
  case payloadTooLarge
  case malformedArguments
  case missingArgument
  case unexpectedArgument
  case invalidArgument
}

/// A fail-closed error returned before an external tool call reaches the local query executor.
public struct AskReadToolCallFailure: Error, Codable, Equatable, Sendable {
  public var code: AskReadToolCallErrorCode
  public var toolName: String
  public var field: String?

  public init(code: AskReadToolCallErrorCode, toolName: String, field: String? = nil) {
    self.code = code
    self.toolName = toolName
    self.field = field
  }
}

/// A validated external read call with a canonical payload identity for replay protection.
public struct AskDecodedReadToolCall: Equatable, Sendable {
  public var name: String
  public var query: AskReadQuery
  public var canonicalArgumentsJSON: Data
  public var payloadDigest: String

  public init(
    name: String,
    query: AskReadQuery,
    canonicalArgumentsJSON: Data,
    payloadDigest: String
  ) {
    self.name = name
    self.query = query
    self.canonicalArgumentsJSON = canonicalArgumentsJSON
    self.payloadDigest = payloadDigest
  }
}

/// Decodes calls emitted by an external model into the same typed read queries used on device.
/// Objects are strict at both the root and nested temporal-filter level: all schema keys must be
/// present, and unknown keys are rejected before Codable decoding.
public enum AskReadToolCallDecoder {
  public static let maximumArgumentsBytes = 32_000

  public static func decode(
    name: String,
    argumentsJSON: Data
  ) throws -> AskDecodedReadToolCall {
    guard AskReadToolSchemas.allowedNames.contains(name) else {
      throw AskReadToolCallFailure(code: .unsupportedTool, toolName: name)
    }
    guard argumentsJSON.count <= maximumArgumentsBytes else {
      throw AskReadToolCallFailure(code: .payloadTooLarge, toolName: name)
    }

    let object: [String: Any]
    do {
      guard
        let value = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any]
      else {
        throw AskReadToolCallFailure(code: .malformedArguments, toolName: name)
      }
      object = value
    } catch let error as AskReadToolCallFailure {
      throw error
    } catch {
      throw AskReadToolCallFailure(code: .malformedArguments, toolName: name)
    }

    try requireExactKeys(
      in: object,
      expected: expectedKeys(for: name),
      toolName: name,
      path: nil
    )
    guard let time = object["time"] as? [String: Any] else {
      throw AskReadToolCallFailure(code: .invalidArgument, toolName: name, field: "time")
    }
    try requireExactKeys(
      in: time,
      expected: ["field", "preset", "start", "end"],
      toolName: name,
      path: "time"
    )

    let query: AskReadQuery
    do {
      let decoder = strictDecoder()
      switch name {
      case AskReadToolSchemas.todo.name:
        query = .todo(try decoder.decode(AskTodoQuery.self, from: argumentsJSON))
      case AskReadToolSchemas.calendar.name:
        query = .calendar(try decoder.decode(AskCalendarQuery.self, from: argumentsJSON))
      case AskReadToolSchemas.note.name:
        query = .note(try decoder.decode(AskNoteQuery.self, from: argumentsJSON))
      case AskReadToolSchemas.meeting.name:
        query = .meeting(try decoder.decode(AskMeetingQuery.self, from: argumentsJSON))
      case AskReadToolSchemas.codex.name:
        query = .codex(try decoder.decode(AskCodexQuery.self, from: argumentsJSON))
      default:
        throw AskReadToolCallFailure(code: .unsupportedTool, toolName: name)
      }
    } catch let error as AskReadToolCallFailure {
      throw error
    } catch let error as DecodingError {
      throw AskReadToolCallFailure(
        code: .invalidArgument,
        toolName: name,
        field: decodingPath(from: error)
      )
    } catch {
      throw AskReadToolCallFailure(code: .invalidArgument, toolName: name)
    }

    let canonicalArgumentsJSON: Data
    do {
      canonicalArgumentsJSON = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
    } catch {
      throw AskReadToolCallFailure(code: .malformedArguments, toolName: name)
    }
    let payloadDigest = SHA256.hash(
      data: Data(name.utf8) + Data([0]) + canonicalArgumentsJSON
    ).map { String(format: "%02x", $0) }.joined()

    return AskDecodedReadToolCall(
      name: name,
      query: query,
      canonicalArgumentsJSON: canonicalArgumentsJSON,
      payloadDigest: payloadDigest
    )
  }

  private static func expectedKeys(for name: String) -> Set<String> {
    let common: Set<String> = [
      "query_id", "text", "record_ids", "time", "limit", "cursor", "sort", "content",
    ]
    switch name {
    case AskReadToolSchemas.todo.name:
      return common.union(["states", "starred", "due", "list_names"])
    case AskReadToolSchemas.calendar.name:
      return common.union(["calendar_titles", "all_day"])
    case AskReadToolSchemas.note.name:
      return common
    case AskReadToolSchemas.meeting.name:
      return common.union(["states", "has_readable_content"])
    case AskReadToolSchemas.codex.name:
      return common.union(["states", "modes", "project_names"])
    default:
      return []
    }
  }

  private static func requireExactKeys(
    in object: [String: Any],
    expected: Set<String>,
    toolName: String,
    path: String?
  ) throws {
    let actual = Set(object.keys)
    if let missing = expected.subtracting(actual).sorted().first {
      throw AskReadToolCallFailure(
        code: .missingArgument,
        toolName: toolName,
        field: [path, missing].compactMap { $0 }.joined(separator: ".")
      )
    }
    if let unexpected = actual.subtracting(expected).sorted().first {
      throw AskReadToolCallFailure(
        code: .unexpectedArgument,
        toolName: toolName,
        field: [path, unexpected].compactMap { $0 }.joined(separator: ".")
      )
    }
  }

  private static func strictDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let raw = try container.decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let value = formatter.date(from: raw) { return value }
      formatter.formatOptions = [.withInternetDateTime]
      if let value = formatter.date(from: raw) { return value }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an RFC 3339 timestamp"
      )
    }
    return decoder
  }

  private static func decodingPath(from error: DecodingError) -> String? {
    let path: [CodingKey]
    switch error {
    case .dataCorrupted(let context): path = context.codingPath
    case .keyNotFound(let key, let context): path = context.codingPath + [key]
    case .typeMismatch(_, let context): path = context.codingPath
    case .valueNotFound(_, let context): path = context.codingPath
    @unknown default: return nil
    }
    let value = path.map(\.stringValue).joined(separator: ".")
    return value.isEmpty ? nil : value
  }
}

// MARK: - Deterministic validation

public enum AskQueryValidator {
  public static func validate(
    _ query: AskReadQuery,
    temporalContext: AskTemporalContext,
    budget: AskQueryBudget
  ) throws {
    try budget.validate()
    _ = try temporalContext.calendar()

    switch query {
    case .todo(let value):
      try validateCommon(
        queryID: value.queryID, text: value.text, recordIDs: value.recordIDs,
        time: value.time, limit: value.limit, cursor: value.cursor,
        allowedFields: [.due, .completed, .created, .updated], budget: budget)
      if value.due == .dueInWindow,
        value.time.field != .due || value.time.preset == .any
      {
        throw AskQueryFailure(code: .invalidQuery, queryID: value.queryID, field: "due")
      }
      try validateEnumList(
        value.states, maximum: AskTodoStateFilter.allCases.count,
        queryID: value.queryID, field: "states")
      try validateStringList(
        value.listNames, maximum: 10, queryID: value.queryID, field: "list_names")
    case .calendar(let value):
      try validateCommon(
        queryID: value.queryID, text: value.text, recordIDs: value.recordIDs,
        time: value.time, limit: value.limit, cursor: value.cursor,
        allowedFields: [.occurrence, .updated], budget: budget)
      if value.time.preset == .absolute,
        let range = try value.time.resolvedRange(in: temporalContext),
        range.end.timeIntervalSince(range.start) > 366 * 24 * 60 * 60
      {
        throw AskQueryFailure(
          code: .invalidTemporalRange, queryID: value.queryID, field: "time")
      }
      try validateStringList(
        value.calendarTitles, maximum: 10,
        queryID: value.queryID, field: "calendar_titles")
    case .note(let value):
      try validateCommon(
        queryID: value.queryID, text: value.text, recordIDs: value.recordIDs,
        time: value.time, limit: value.limit, cursor: value.cursor,
        allowedFields: [.created, .updated], budget: budget)
    case .meeting(let value):
      try validateCommon(
        queryID: value.queryID, text: value.text, recordIDs: value.recordIDs,
        time: value.time, limit: value.limit, cursor: value.cursor,
        allowedFields: [.occurrence, .updated], budget: budget)
      try validateEnumList(
        value.states, maximum: AskMeetingStateFilter.allCases.count,
        queryID: value.queryID, field: "states")
    case .codex(let value):
      try validateCommon(
        queryID: value.queryID, text: value.text, recordIDs: value.recordIDs,
        time: value.time, limit: value.limit, cursor: value.cursor,
        allowedFields: [.created, .updated, .visibleOutput], budget: budget)
      try validateEnumList(
        value.states, maximum: AskCodexStateFilter.allCases.count,
        queryID: value.queryID, field: "states")
      try validateEnumList(
        value.modes, maximum: AskCodexModeFilter.allCases.count,
        queryID: value.queryID, field: "modes")
      try validateStringList(
        value.projectNames, maximum: 10,
        queryID: value.queryID, field: "project_names")
    }
  }

  private static func validateCommon(
    queryID: String,
    text: String?,
    recordIDs: [String],
    time: AskQueryTimeFilter,
    limit: Int,
    cursor: String?,
    allowedFields: Set<AskQueryTemporalField>,
    budget: AskQueryBudget
  ) throws {
    let id = queryID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty, id.count <= 64,
      id.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace })
    else {
      throw AskQueryFailure(code: .invalidQuery, queryID: queryID, field: "query_id")
    }
    if let text {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed.count <= 300 else {
        throw AskQueryFailure(code: .invalidQuery, queryID: queryID, field: "text")
      }
    }
    guard recordIDs.count <= 10,
      recordIDs.allSatisfy({ !$0.isEmpty && $0.count <= 240 }),
      limit > 0, limit <= min(10, budget.maximumRecordsPerPage),
      (cursor?.count ?? 0) <= 1_024
    else {
      throw AskQueryFailure(code: .invalidQuery, queryID: queryID, field: "bounds")
    }
    guard allowedFields.contains(time.field) else {
      throw AskQueryFailure(
        code: .unsupportedTemporalField, queryID: queryID, field: "time.field")
    }
    if time.preset == .absolute {
      guard let start = time.start, let end = time.end, start < end else {
        throw AskQueryFailure(
          code: .invalidTemporalRange, queryID: queryID, field: "time")
      }
    } else if time.start != nil || time.end != nil {
      throw AskQueryFailure(
        code: .invalidTemporalRange, queryID: queryID, field: "time")
    }
  }

  private static func validateStringList(
    _ values: [String],
    maximum: Int,
    queryID: String,
    field: String
  ) throws {
    let normalizedValues = values.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    guard values.count <= maximum,
      normalizedValues.allSatisfy({ !$0.isEmpty && $0.count <= 240 }),
      Set(normalizedValues).count == normalizedValues.count
    else {
      throw AskQueryFailure(code: .invalidQuery, queryID: queryID, field: field)
    }
  }

  private static func validateEnumList<Value: RawRepresentable>(
    _ values: [Value],
    maximum: Int,
    queryID: String,
    field: String
  ) throws where Value.RawValue == String {
    let rawValues = values.map(\.rawValue)
    guard values.count <= maximum, Set(rawValues).count == rawValues.count else {
      throw AskQueryFailure(code: .invalidQuery, queryID: queryID, field: field)
    }
  }
}
