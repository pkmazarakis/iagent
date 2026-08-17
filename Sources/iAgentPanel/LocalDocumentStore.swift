import Darwin
import Foundation

enum LocalDocumentKind: String, Sendable {
  case note = "Notes"
  case page = "Pages"

  var singularLabel: String {
    switch self {
    case .note: "note"
    case .page: "page"
    }
  }
}

struct LocalDocument: Identifiable, Sendable, Equatable {
  let id: String
  let kind: LocalDocumentKind
  let title: String
  let body: String
  let createdAt: Date
  let updatedAt: Date
  let fileURL: URL
}

struct LocalDocumentStore: Sendable {
  // UF_DATALESS is defined by Darwin as 0x40000000 but is not imported by Swift.
  static let datalessFileFlag: UInt32 = 0x40000000

  let rootURL: URL

  init(rootURL: URL? = nil) {
    if let rootURL {
      self.rootURL = rootURL
      return
    }

    if let override = ProcessInfo.processInfo.environment["IAGENT_LIBRARY_HOME"],
       !override.isEmpty
    {
      self.rootURL = URL(fileURLWithPath: override, isDirectory: true)
      return
    }

    self.rootURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Documents", isDirectory: true)
      .appendingPathComponent("iAgent Library", isDirectory: true)
  }

  func save(
    kind: LocalDocumentKind,
    title suppliedTitle: String,
    body suppliedBody: String
  ) throws -> LocalDocument {
    let body = suppliedBody
    let title = normalizedTitle(suppliedTitle, body: body, kind: kind)
    let now = Date()
    let directory = rootURL.appendingPathComponent(kind.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    let filename = "\(timestamp(now))-\(slug(title))-\(UUID().uuidString.prefix(6)).md"
    let fileURL = directory.appendingPathComponent(filename)
    try markdown(title: title, body: body)
      .write(to: fileURL, atomically: true, encoding: .utf8)

    return LocalDocument(
      id: documentID(for: fileURL),
      kind: kind,
      title: title,
      body: body,
      createdAt: now,
      updatedAt: now,
      fileURL: fileURL
    )
  }

  func update(
    _ document: LocalDocument,
    title suppliedTitle: String,
    body suppliedBody: String
  ) throws -> LocalDocument {
    let body = suppliedBody
    let title = normalizedTitle(suppliedTitle, body: body, kind: document.kind)
    let directory = document.fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try markdown(title: title, body: body)
      .write(to: document.fileURL, atomically: true, encoding: .utf8)

    return LocalDocument(
      id: document.id,
      kind: document.kind,
      title: title,
      body: body,
      createdAt: document.createdAt,
      updatedAt: Date(),
      fileURL: document.fileURL
    )
  }

  func documents(kind: LocalDocumentKind) throws -> [LocalDocument] {
    let directory = folderURL(for: kind)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: directory.path) else { return [] }

    let keys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .creationDateKey,
      .contentModificationDateKey,
    ]
    let fileURLs = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    )

    return try fileURLs.compactMap { fileURL in
      guard fileURL.pathExtension.lowercased() == "md" else { return nil }
      let values = try fileURL.resourceValues(forKeys: keys)
      guard values.isRegularFile == true else { return nil }
      guard isMaterializedFile(at: fileURL) else { return nil }
      let source = try String(contentsOf: fileURL, encoding: .utf8)
      let parsed = parseMarkdown(
        source,
        fallbackTitle: fileURL.deletingPathExtension().lastPathComponent
      )
      let createdAt = values.creationDate ?? values.contentModificationDate ?? .distantPast
      let updatedAt = values.contentModificationDate ?? createdAt
      return LocalDocument(
        id: documentID(for: fileURL),
        kind: kind,
        title: parsed.title,
        body: parsed.body,
        createdAt: createdAt,
        updatedAt: updatedAt,
        fileURL: fileURL
      )
    }
    .sorted { lhs, rhs in
      if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
      return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
  }

  func folderURL(for kind: LocalDocumentKind) -> URL {
    rootURL.appendingPathComponent(kind.rawValue, isDirectory: true)
  }

  func documentCount(for kind: LocalDocumentKind) -> Int {
    (try? documents(kind: kind).count) ?? 0
  }

  static func isMaterialized(fileSystemFlags: UInt32) -> Bool {
    (fileSystemFlags & datalessFileFlag) == 0
  }

  private func isMaterializedFile(at fileURL: URL) -> Bool {
    var metadata = stat()
    let readMetadata = fileURL.withUnsafeFileSystemRepresentation { path in
      guard let path else { return false }
      return lstat(path, &metadata) == 0
    }
    guard readMetadata else {
      // Preserve the existing error reporting path when metadata itself is unavailable.
      return true
    }
    return Self.isMaterialized(fileSystemFlags: metadata.st_flags)
  }

  private func normalizedTitle(
    _ suppliedTitle: String,
    body: String,
    kind: LocalDocumentKind
  ) -> String {
    let supplied = suppliedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !supplied.isEmpty {
      return concise(supplied, limit: 80)
    }

    let firstLine = body
      .components(separatedBy: .newlines)
      .lazy
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first(where: { !$0.isEmpty }) ?? ""
    if !firstLine.isEmpty {
      return concise(plainTextTitle(firstLine), limit: 56)
    }
    return "Untitled \(kind.singularLabel)"
  }

  private func plainTextTitle(_ markdownLine: String) -> String {
    let withoutBlockMarker = markdownLine.replacingOccurrences(
      of: #"^\s{0,3}(?:#{1,6}\s+|>\s+|(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s*)?)"#,
      with: "",
      options: .regularExpression
    )
    let withoutInlineMarkers = withoutBlockMarker.replacingOccurrences(
      of: #"[`*_~]+"#,
      with: "",
      options: .regularExpression
    )
    let title = withoutInlineMarkers.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? markdownLine : title
  }

  private func markdown(title: String, body: String) -> String {
    guard !body.isEmpty else { return "# \(title)\n" }
    return "# \(title)\n\n\(body)\(body.hasSuffix("\n") ? "" : "\n")"
  }

  private func parseMarkdown(
    _ source: String,
    fallbackTitle: String
  ) -> (title: String, body: String) {
    var lines = source
      .replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    let firstLine = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
    let title: String
    if firstLine.hasPrefix("# ") {
      title = String(firstLine.dropFirst(2))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      lines.removeFirst()
      while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
        lines.removeFirst()
      }
    } else {
      title = fallbackTitle
    }

    while lines.last?.isEmpty == true {
      lines.removeLast()
    }
    return (title.isEmpty ? fallbackTitle : title, lines.joined(separator: "\n"))
  }

  private func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: date)
  }

  private func documentID(for fileURL: URL) -> String {
    fileURL.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private func slug(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let pieces = value.lowercased().unicodeScalars.map { scalar -> Character in
      allowed.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let collapsed = String(pieces)
      .split(separator: "-", omittingEmptySubsequences: true)
      .prefix(8)
      .joined(separator: "-")
    return collapsed.isEmpty ? "untitled" : collapsed
  }

  private func concise(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    let end = value.index(value.startIndex, offsetBy: limit)
    return String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
