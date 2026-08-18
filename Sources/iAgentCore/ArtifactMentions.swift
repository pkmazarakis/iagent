import Foundation

/// A portable reference to an iAgent artifact. Editors keep the readable title
/// in their text and serialize the destination as an iAgent deep link.
public enum ArtifactMentionKind: String, Codable, CaseIterable, Sendable {
  case todo
  case note
  case calendarEvent
  case codexThread

  public var displayName: String {
    switch self {
    case .todo: "To-do"
    case .note: "Note"
    case .calendarEvent: "Calendar event"
    case .codexThread: "Codex task"
    }
  }

  public var systemImage: String {
    switch self {
    case .todo: "checkmark.square"
    case .note: "note.text"
    case .calendarEvent: "calendar"
    case .codexThread: "sparkles"
    }
  }
}

public struct ArtifactMention: Identifiable, Codable, Equatable, Sendable {
  public let kind: ArtifactMentionKind
  public let artifactID: String
  public let title: String
  public let subtitle: String?
  public let updatedAt: Date

  public init(
    kind: ArtifactMentionKind,
    artifactID: String,
    title: String,
    subtitle: String? = nil,
    updatedAt: Date = .distantPast
  ) {
    self.kind = kind
    self.artifactID = artifactID
    self.title = title
    self.subtitle = subtitle
    self.updatedAt = updatedAt
  }

  public var id: String { "\(kind.rawValue):\(artifactID)" }

  /// Resolves to the artifact itself, rather than only its containing section.
  public var url: URL? {
    switch kind {
    case .todo:
      guard let id = UUID(uuidString: artifactID) else { return nil }
      return IAgentDeepLink.todo(id).url
    case .note:
      if let id = UUID(uuidString: artifactID) {
        return IAgentDeepLink.note(id).url
      }
      guard IAgentDeepLink.isSafeRelativeDocumentPath(artifactID) else { return nil }
      return IAgentDeepLink.notePath(artifactID).url
    case .calendarEvent:
      guard Self.isUsableOpaqueIdentifier(artifactID) else { return nil }
      return IAgentDeepLink.calendarEvent(artifactID).url
    case .codexThread:
      guard IAgentDeepLink.isSafeOpaqueIdentifier(artifactID) else { return nil }
      return IAgentDeepLink.codexThread(artifactID).url
    }
  }

  public var markdown: String {
    guard let url else { return title }
    return "[\(Self.markdownLabel(title))](\(url.absoluteString))"
  }

  private static func markdownLabel(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
      .replacingOccurrences(of: "*", with: "\\*")
      .replacingOccurrences(of: "_", with: "\\_")
      .replacingOccurrences(of: "`", with: "\\`")
      .replacingOccurrences(of: "~", with: "\\~")
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
  }

  static func isUsableOpaqueIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 512
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

public struct ArtifactMentionQuery: Equatable, Sendable {
  public let range: Range<String.Index>
  public let text: String

  /// Finds the unfinished `@query` immediately before the insertion point.
  /// Requiring a token boundary prevents addresses such as `name@example.com`
  /// from opening the picker.
  public init?(input: String, cursor: String.Index? = nil) {
    let end = cursor ?? input.endIndex
    guard end >= input.startIndex, end <= input.endIndex else { return nil }
    let prefix = input[..<end]
    guard let at = prefix.lastIndex(of: "@") else { return nil }

    if at != input.startIndex {
      let previous = input[input.index(before: at)]
      guard previous.isWhitespace || "([{>\n".contains(previous) else { return nil }
    }

    let start = input.index(after: at)
    let value = input[start..<end]
    guard value.count <= 80,
          !value.contains(where: \.isNewline),
          !value.contains("@"),
          !value.contains("\t"),
          !value.contains("  "),
          !value.contains(where: { ",;!?".contains($0) })
    else { return nil }

    range = at..<end
    text = String(value)
  }

  public func replacing(
    in input: inout String,
    with mention: ArtifactMention,
    markdown: Bool
  ) {
    input.replaceSubrange(range, with: markdown ? mention.markdown : mention.title)
  }
}

public struct ArtifactMentionSection: Identifiable, Equatable, Sendable {
  public let kind: ArtifactMentionKind
  public let items: [ArtifactMention]

  public init(kind: ArtifactMentionKind, items: [ArtifactMention]) {
    self.kind = kind
    self.items = items
  }

  public var id: ArtifactMentionKind { kind }
}

public enum ArtifactMentionCatalog {
  public static func make(
    snapshot: IAgentDataSnapshot,
    calendarEvents: [SyncedCalendarEvent] = []
  ) -> [ArtifactMention] {
    let todos = snapshot.todos.compactMap { todo -> ArtifactMention? in
      guard todo.deletedAt == nil, let title = normalizedTitle(todo.title) else { return nil }
      return ArtifactMention(
        kind: .todo,
        artifactID: todo.id.uuidString,
        title: title,
        subtitle: todo.isCompleted ? "Completed" : normalizedSubtitle(todo.listName),
        updatedAt: todo.updatedAt
      )
    }

    let notes = snapshot.notes.compactMap { note -> ArtifactMention? in
      guard note.deletedAt == nil, let title = normalizedTitle(note.title) else { return nil }
      let artifactID = note.relativeFilePath.flatMap {
        IAgentDeepLink.isSafeRelativeDocumentPath($0) ? $0 : nil
      } ?? note.id.uuidString
      return ArtifactMention(
        kind: .note,
        artifactID: artifactID,
        title: title,
        subtitle: note.kind == .meeting ? "Meeting note" : "Note",
        updatedAt: note.updatedAt
      )
    }

    let events = deduplicatedEvents(
      synced: snapshot.calendarEvents,
      supplemental: calendarEvents
    ).compactMap { routed -> ArtifactMention? in
      let event = routed.event
      guard let title = normalizedTitle(event.title)
      else { return nil }
      return ArtifactMention(
        kind: .calendarEvent,
        artifactID: routed.artifactID,
        title: title,
        subtitle: event.startDate.formatted(date: .abbreviated, time: .shortened),
        updatedAt: event.updatedAt
      )
    }

    let threads = snapshot.codexThreads.compactMap { thread -> ArtifactMention? in
      guard thread.deletedAt == nil,
            IAgentDeepLink.isSafeOpaqueIdentifier(thread.id),
            let title = normalizedTitle(thread.title)
      else { return nil }
      return ArtifactMention(
        kind: .codexThread,
        artifactID: thread.id,
        title: title,
        subtitle: normalizedSubtitle(thread.projectName) ?? "Codex",
        updatedAt: thread.updatedAt
      )
    }

    var unique: [String: ArtifactMention] = [:]
    for item in todos + notes + events + threads {
      if let current = unique[item.id], current.updatedAt >= item.updatedAt { continue }
      unique[item.id] = item
    }

    return unique.values.sorted(by: orderedBefore)
  }

  /// Matches all supplied artifacts by default. Callers that render sections
  /// should apply their limit per section so one large kind cannot starve the
  /// kinds that follow it.
  public static func matching(
    _ query: String,
    in mentions: [ArtifactMention],
    limit: Int? = nil
  ) -> [ArtifactMention] {
    let foldedQuery = folded(query).trimmingCharacters(in: .whitespacesAndNewlines)
    let terms = foldedQuery.split(whereSeparator: \.isWhitespace).map(String.init)

    let ranked = mentions.enumerated().compactMap { index, mention -> RankedMention? in
      let title = folded(mention.title)
      let subtitle = folded(mention.subtitle ?? "")
      let kind = folded(mention.kind.displayName)
      let haystack = [title, subtitle, kind].joined(separator: " ")
      guard terms.allSatisfy(haystack.contains) else { return nil }

      let rank: Int
      if foldedQuery.isEmpty { rank = 0 }
      else if title == foldedQuery { rank = 0 }
      else if title.hasPrefix(foldedQuery) { rank = 1 }
      else if title.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(foldedQuery) }) {
        rank = 2
      } else if title.contains(foldedQuery) { rank = 3 }
      else { rank = 4 }
      return RankedMention(mention: mention, rank: rank, originalIndex: index)
    }
    .sorted {
      if $0.rank != $1.rank { return $0.rank < $1.rank }
      return $0.originalIndex < $1.originalIndex
    }
    .map(\.mention)

    guard let limit else { return ranked }
    return Array(ranked.prefix(max(0, limit)))
  }

  public static func sections(
    matching query: String,
    in mentions: [ArtifactMention],
    itemsPerSection: Int = 3
  ) -> [ArtifactMentionSection] {
    guard itemsPerSection > 0 else { return [] }
    let matches = matching(query, in: mentions)
    return ArtifactMentionKind.allCases.compactMap { kind in
      let items = Array(matches.lazy.filter { $0.kind == kind }.prefix(itemsPerSection))
      return items.isEmpty ? nil : ArtifactMentionSection(kind: kind, items: items)
    }
  }

  private struct RankedMention {
    let mention: ArtifactMention
    let rank: Int
    let originalIndex: Int
  }

  private static func folded(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  private static func normalizedTitle(_ value: String) -> String? {
    let normalized = value
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func normalizedSubtitle(_ value: String?) -> String? {
    guard let value else { return nil }
    return normalizedTitle(value)
  }

  private struct RoutedCalendarEvent {
    var event: SyncedCalendarEvent
    let artifactID: String
  }

  private static func deduplicatedEvents(
    synced: [SyncedCalendarEvent],
    supplemental: [SyncedCalendarEvent]
  ) -> [RoutedCalendarEvent] {
    var result: [RoutedCalendarEvent] = []

    for event in synced where event.deletedAt == nil
      && ArtifactMention.isUsableOpaqueIdentifier(event.id) {
      if let index = result.firstIndex(where: { $0.event.isSameOccurrence(as: event) }) {
        if event.updatedAt > result[index].event.updatedAt {
          result[index] = RoutedCalendarEvent(event: event, artifactID: event.id)
        }
      } else {
        result.append(RoutedCalendarEvent(event: event, artifactID: event.id))
      }
    }

    for event in supplemental where event.deletedAt == nil
      && ArtifactMention.isUsableOpaqueIdentifier(event.id) {
      if let index = result.firstIndex(where: { $0.event.isSameOccurrence(as: event) }) {
        if event.updatedAt > result[index].event.updatedAt {
          // Keep the synced route identity even when EventKit has fresher copy.
          result[index].event = event
        }
      } else {
        result.append(RoutedCalendarEvent(event: event, artifactID: event.id))
      }
    }
    return result
  }

  private static func orderedBefore(_ lhs: ArtifactMention, _ rhs: ArtifactMention) -> Bool {
    let leftKind = ArtifactMentionKind.allCases.firstIndex(of: lhs.kind) ?? .max
    let rightKind = ArtifactMentionKind.allCases.firstIndex(of: rhs.kind) ?? .max
    if leftKind != rightKind { return leftKind < rightKind }
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
    if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
    return lhs.id < rhs.id
  }
}
