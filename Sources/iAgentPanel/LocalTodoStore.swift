import Foundation
import Darwin

enum LocalTodoStoreError: LocalizedError, Equatable {
    case contentUnavailable(fileName: String)
    case unreadable(fileName: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .contentUnavailable(fileName):
            "\(fileName) is stored in iCloud and has not downloaded yet. iAgent will retry without publishing an empty list."
        case let .unreadable(fileName, reason):
            "Could not read \(fileName): \(reason)"
        }
    }
}

struct LocalTodo: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    var notes: String?
    var isCompleted: Bool
    var isStarred: Bool
    var dueDate: Date?
    var listName: String?
    var completedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        title: String,
        notes: String? = nil,
        isCompleted: Bool,
        isStarred: Bool = false,
        dueDate: Date? = nil,
        listName: String? = nil,
        completedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.isStarred = isStarred
        self.dueDate = dueDate
        self.listName = listName
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case notes
        case isCompleted
        case isStarred
        case dueDate
        case listName
        case completedAt
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        isCompleted = try container.decode(Bool.self, forKey: .isCompleted)
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        listName = try container.decodeIfPresent(String.self, forKey: .listName)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encode(isStarred, forKey: .isStarred)
        try container.encodeIfPresent(dueDate, forKey: .dueDate)
        try container.encodeIfPresent(listName, forKey: .listName)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    func createdRelativeText(referenceDate: Date = Date()) -> String {
        let elapsed = max(0, referenceDate.timeIntervalSince(createdAt))

        if elapsed < 60 * 60 {
            return "\(Int(elapsed / 60))m"
        }
        if elapsed < 24 * 60 * 60 {
            return "\(Int(elapsed / (60 * 60)))h"
        }
        if elapsed < 30 * 24 * 60 * 60 {
            return "\(Int(elapsed / (24 * 60 * 60)))d"
        }
        return "\(max(1, Int(elapsed / (30 * 24 * 60 * 60))))mon"
    }
}

struct LocalTodoStore: Sendable {
    let fileURL: URL
    let listFileURL: URL
    private let requiresDownload: @Sendable (URL) -> Bool

    init(
        rootURL: URL,
        requiresDownload: (@Sendable (URL) -> Bool)? = nil
    ) {
        fileURL = rootURL.appendingPathComponent("todos.json")
        listFileURL = rootURL.appendingPathComponent("todo-lists.json")
        self.requiresDownload = requiresDownload ?? Self.isDatalessFile
    }

    func load() throws -> [LocalTodo] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decode([LocalTodo].self, from: fileURL)
    }

    func save(_ todos: [LocalTodo]) throws {
        try requireMaterializedIfPresent(fileURL)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(todos)
        try data.write(to: fileURL, options: .atomic)
    }

    func loadListNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: listFileURL.path) else { return [] }
        return try decode([String].self, from: listFileURL)
    }

    func saveListNames(_ listNames: [String]) throws {
        try requireMaterializedIfPresent(listFileURL)
        try FileManager.default.createDirectory(
            at: listFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(listNames)
        try data.write(to: listFileURL, options: .atomic)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from fileURL: URL) throws -> Value {
        try requireMaterializedIfPresent(fileURL)
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(type, from: data)
        } catch let error as LocalTodoStoreError {
            throw error
        } catch {
            throw LocalTodoStoreError.unreadable(
                fileName: fileURL.lastPathComponent,
                reason: error.localizedDescription
            )
        }
    }

    private func requireMaterializedIfPresent(_ fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              requiresDownload(fileURL)
        else { return }

        if FileManager.default.isUbiquitousItem(at: fileURL) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        }
        throw LocalTodoStoreError.contentUnavailable(fileName: fileURL.lastPathComponent)
    }

    private static func isDatalessFile(_ fileURL: URL) -> Bool {
        var fileStatus = stat()
        guard Darwin.lstat(fileURL.path, &fileStatus) == 0 else { return false }
        let userDatalessFlag = UInt32(0x4000_0000)
        return fileStatus.st_flags & userDatalessFlag != 0
    }
}
