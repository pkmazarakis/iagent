import Foundation

struct LocalTodo: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
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

    init(rootURL: URL) {
        fileURL = rootURL.appendingPathComponent("todos.json")
        listFileURL = rootURL.appendingPathComponent("todo-lists.json")
    }

    func load() throws -> [LocalTodo] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([LocalTodo].self, from: data)
    }

    func save(_ todos: [LocalTodo]) throws {
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
        let data = try Data(contentsOf: listFileURL)
        return try JSONDecoder().decode([String].self, from: data)
    }

    func saveListNames(_ listNames: [String]) throws {
        try FileManager.default.createDirectory(
            at: listFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(listNames)
        try data.write(to: listFileURL, options: .atomic)
    }
}
