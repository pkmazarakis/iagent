import Foundation

struct ThreadProjectSection: Identifiable, Equatable {
  let id: String
  let name: String
  let workspacePath: String?
  let threads: [AgentThread]
  let lastActivityAt: Date

  static func build(
    from threads: [AgentThread],
    excluding excludedThreadIDs: Set<String>
  ) -> [ThreadProjectSection] {
    struct Draft {
      var name: String
      var workspacePath: String?
      var threads: [AgentThread]
      var lastActivityAt: Date
    }

    var drafts: [String: Draft] = [:]
    for thread in threads {
      let identity = projectIdentity(for: thread)
      if var draft = drafts[identity.id] {
        draft.lastActivityAt = max(draft.lastActivityAt, thread.recencyDate)
        if !excludedThreadIDs.contains(thread.id) {
          draft.threads.append(thread)
        }
        drafts[identity.id] = draft
      } else {
        drafts[identity.id] = Draft(
          name: identity.name,
          workspacePath: identity.workspacePath,
          threads: excludedThreadIDs.contains(thread.id) ? [] : [thread],
          lastActivityAt: thread.recencyDate
        )
      }
    }

    return drafts.map { id, draft in
      ThreadProjectSection(
        id: id,
        name: draft.name,
        workspacePath: draft.workspacePath,
        threads: draft.threads.sorted { left, right in
          if left.recencyDate != right.recencyDate {
            return left.recencyDate > right.recencyDate
          }
          return left.id > right.id
        },
        lastActivityAt: draft.lastActivityAt
      )
    }
    .sorted { left, right in
      if left.lastActivityAt != right.lastActivityAt {
        return left.lastActivityAt > right.lastActivityAt
      }
      return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }
  }

  private static func projectIdentity(
    for thread: AgentThread
  ) -> (id: String, name: String, workspacePath: String?) {
    let trimmedPath = thread.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedPath.isEmpty {
      let path = URL(fileURLWithPath: trimmedPath).standardizedFileURL.path
      let fallbackName = URL(fileURLWithPath: path).lastPathComponent
      return (
        id: "workspace:\(path)",
        name: thread.projectName ?? (fallbackName.isEmpty ? "Home" : fallbackName),
        workspacePath: path
      )
    }

    if let projectName = thread.projectName, !projectName.isEmpty {
      return (
        id: "project:\(projectName.lowercased())",
        name: projectName,
        workspacePath: nil
      )
    }

    return (id: "home", name: "Home", workspacePath: nil)
  }
}

extension AgentThread {
  var recencyDate: Date {
    max(createdAt, updatedAt)
  }

  func updatedRelativeText(referenceDate: Date) -> String {
    let seconds = max(0, Int(referenceDate.timeIntervalSince(updatedAt)))
    if seconds < 10 {
      return "now"
    }
    if seconds < 60 {
      return "\(seconds)s"
    }

    let minutes = seconds / 60
    if minutes < 60 {
      return "\(minutes)m"
    }

    let hours = minutes / 60
    if hours < 24 {
      return "\(hours)h"
    }

    let days = hours / 24
    if days < 100 {
      return "\(days)d"
    }
    if days < 365 {
      return "\(days / 7)w"
    }
    return "\(min(99, days / 365))y"
  }

  static func activityFeed(from threads: [AgentThread], now: Date) -> [AgentThread] {
    let cutoff = now.addingTimeInterval(-24 * 60 * 60)
    return threads
      .filter { $0.createdAt >= cutoff || $0.updatedAt >= cutoff }
      .sorted { left, right in
        let leftPriority = left.state.activityPriority
        let rightPriority = right.state.activityPriority
        if leftPriority != rightPriority {
          return leftPriority < rightPriority
        }
        if left.recencyDate != right.recencyDate {
          return left.recencyDate > right.recencyDate
        }
        return left.id > right.id
      }
  }
}

extension AgentState {
  fileprivate var activityPriority: Int {
    switch self {
    case .running:
      0
    case .waitingForInput, .needsApproval:
      1
    case .completed, .failed:
      2
    }
  }
}

struct ProjectSectionPreferenceStore {
  private static let orderKey = "codex.project-section-order.v1"
  private static let collapsedKey = "codex.collapsed-project-sections.v1"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadOrder() -> [String] {
    defaults.stringArray(forKey: Self.orderKey) ?? []
  }

  func saveOrder(_ order: [String]) {
    defaults.set(order, forKey: Self.orderKey)
  }

  func loadCollapsedIDs() -> Set<String> {
    Set(defaults.stringArray(forKey: Self.collapsedKey) ?? [])
  }

  func saveCollapsedIDs(_ ids: Set<String>) {
    defaults.set(ids.sorted(), forKey: Self.collapsedKey)
  }

  static func appendingNewIDs(_ ids: [String], to storedOrder: [String]) -> [String] {
    var seen = Set(storedOrder)
    var result = storedOrder
    for id in ids where seen.insert(id).inserted {
      result.append(id)
    }
    return result
  }

  static func moving(_ draggedID: String, before targetID: String, in order: [String]) -> [String] {
    guard draggedID != targetID,
          let sourceIndex = order.firstIndex(of: draggedID),
          order.contains(targetID)
    else {
      return order
    }

    var result = order
    result.remove(at: sourceIndex)
    guard let targetIndex = result.firstIndex(of: targetID) else { return order }
    result.insert(draggedID, at: targetIndex)
    return result
  }

  static func moving(_ draggedID: String, over targetID: String, in order: [String]) -> [String] {
    guard draggedID != targetID,
          let sourceIndex = order.firstIndex(of: draggedID),
          let targetIndex = order.firstIndex(of: targetID)
    else {
      return order
    }

    var result = order
    let dragged = result.remove(at: sourceIndex)
    result.insert(dragged, at: min(targetIndex, result.count))
    return result
  }

  static func moving(_ draggedID: String, to insertionIndex: Int, in order: [String]) -> [String] {
    guard let sourceIndex = order.firstIndex(of: draggedID) else { return order }

    var result = order
    let dragged = result.remove(at: sourceIndex)
    result.insert(dragged, at: min(max(insertionIndex, 0), result.count))
    return result
  }
}

enum ProjectDragPlacement {
  static func insertionIndex(
    pointerY: CGFloat,
    orderedIDs: [String],
    frames: [String: CGRect],
    draggedID: String
  ) -> Int {
    orderedIDs
      .filter { $0 != draggedID }
      .reduce(into: 0) { index, projectID in
        guard let frame = frames[projectID], pointerY > frame.midY else { return }
        index += 1
      }
  }
}

enum SelectionRevealEdge: Equatable {
  case top
  case bottom

  static func required(
    for rowFrame: CGRect,
    viewportHeight: CGFloat,
    inset: CGFloat = 4
  ) -> SelectionRevealEdge? {
    if rowFrame.minY < inset {
      return .top
    }
    if rowFrame.maxY > viewportHeight - inset {
      return .bottom
    }
    return nil
  }
}
