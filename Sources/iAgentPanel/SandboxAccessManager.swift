import AppKit
import Foundation
import Security

enum SandboxMessagesAccessError: LocalizedError {
  case invalidMessagesDirectory
  case securityScopeUnavailable
  case bookmarkCreationFailed

  var errorDescription: String? {
    switch self {
    case .invalidMessagesDirectory:
      "Choose the Messages folder that contains chat.db."
    case .securityScopeUnavailable:
      "iAgent could not retain read-only access to the selected Messages folder."
    case .bookmarkCreationFailed:
      "iAgent could not save access to the selected Messages folder."
    }
  }
}

@MainActor
final class SandboxAccessManager {
  static let shared = SandboxAccessManager()

  private enum Key {
    static let library = "sandbox.bookmark.iagent-library.v1"
    static let codex = "sandbox.bookmark.codex-home.v1"
    static let messages = "sandbox.bookmark.messages-directory.v1"
  }

  private(set) var libraryURL: URL?
  private(set) var codexHomeURL: URL?
  private(set) var messagesDirectoryURL: URL?
  private var accessedURLs: [URL] = []

  var authorizedMessagesDatabaseURL: URL? {
    messagesDirectoryURL?.appendingPathComponent("chat.db", isDirectory: false)
  }

  var isSandboxed: Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    return SecTaskCopyValueForEntitlement(
      task,
      "com.apple.security.app-sandbox" as CFString,
      nil
    ) as? Bool == true
  }

  func prepareForLaunch(defaults: UserDefaults = .standard) {
    guard isSandboxed else { return }
    libraryURL = restoreBookmark(forKey: Key.library, defaults: defaults)
    codexHomeURL = restoreBookmark(forKey: Key.codex, defaults: defaults)
    if MacMessageProviderFactory.localAccessIsEnabled(preferences: defaults) {
      _ = restoreMessagesAccessIfEnabled(defaults: defaults)
    }

    if libraryURL == nil {
      libraryURL = requestFolder(
        title: "Choose your iAgent Library",
        message: "Select the “iAgent Library” folder so iAgent can read and save notes and todos.",
        suggested: FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Documents/iAgent Library", isDirectory: true),
        key: Key.library,
        defaults: defaults
      )
    }
    if codexHomeURL == nil {
      codexHomeURL = requestFolder(
        title: "Choose your Codex data folder",
        message: "Select the hidden “.codex” folder. Press Command-Shift-Period if hidden files are not visible.",
        suggested: FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".codex", isDirectory: true),
        key: Key.codex,
        defaults: defaults
      )
    }
    if let libraryURL {
      setenv("IAGENT_LIBRARY_HOME", libraryURL.path, 1)
    }
    if let codexHomeURL {
      setenv("CODEX_HOME", codexHomeURL.path, 1)
    }
  }

  /// Restores Messages access without showing UI. Callers may invoke this at
  /// launch; it intentionally does nothing until the user has opted in.
  @discardableResult
  func restoreMessagesAccessIfEnabled(
    defaults: UserDefaults = .standard
  ) -> URL? {
    guard isSandboxed,
      MacMessageProviderFactory.localAccessIsEnabled(preferences: defaults)
    else { return nil }
    if let authorizedMessagesDatabaseURL {
      return authorizedMessagesDatabaseURL
    }
    guard let directoryURL = restoreBookmark(
      forKey: Key.messages,
      defaults: defaults,
      readOnly: true
    ) else { return nil }
    do {
      let databaseURL = try Self.validatedMessagesDatabaseURL(in: directoryURL)
      messagesDirectoryURL = directoryURL
      return databaseURL
    } catch {
      stopHoldingAccess(to: directoryURL)
      defaults.removeObject(forKey: Key.messages)
      return nil
    }
  }

  /// Presents the folder picker for an explicit Connect Messages or recovery
  /// action. A nil result means the user cancelled.
  func requestMessagesDirectoryAccess(
    defaults: UserDefaults = .standard
  ) throws -> URL? {
    guard isSandboxed else { return nil }
    let panel = NSOpenPanel()
    panel.title = "Choose your Messages folder"
    panel.message =
      "Select the Messages folder in your Library so iAgent can read its local history."
    panel.prompt = "Allow Read Access"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Messages", isDirectory: true)
    guard panel.runModal() == .OK, let directoryURL = panel.url else { return nil }
    guard beginHoldingAccess(to: directoryURL) else {
      throw SandboxMessagesAccessError.securityScopeUnavailable
    }
    do {
      let databaseURL = try Self.validatedMessagesDatabaseURL(in: directoryURL)
      let data = try directoryURL.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      if let previous = messagesDirectoryURL,
        previous.standardizedFileURL != directoryURL.standardizedFileURL
      {
        stopHoldingAccess(to: previous)
      }
      defaults.set(data, forKey: Key.messages)
      messagesDirectoryURL = directoryURL
      return databaseURL
    } catch let error as SandboxMessagesAccessError {
      stopHoldingAccess(to: directoryURL)
      throw error
    } catch {
      stopHoldingAccess(to: directoryURL)
      throw SandboxMessagesAccessError.bookmarkCreationFailed
    }
  }

  nonisolated static func validatedMessagesDatabaseURL(
    in directoryURL: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    let directory = directoryURL.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard directory.lastPathComponent.caseInsensitiveCompare("Messages") == .orderedSame,
      fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw SandboxMessagesAccessError.invalidMessagesDirectory
    }
    let databaseURL = directory.appendingPathComponent("chat.db", isDirectory: false)
    var databaseIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: databaseURL.path, isDirectory: &databaseIsDirectory),
      !databaseIsDirectory.boolValue
    else {
      throw SandboxMessagesAccessError.invalidMessagesDirectory
    }
    return databaseURL
  }

  private func restoreBookmark(
    forKey key: String,
    defaults: UserDefaults,
    readOnly: Bool = false
  ) -> URL? {
    guard let data = defaults.data(forKey: key) else { return nil }
    var stale = false
    guard let url = try? URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    ), beginHoldingAccess(to: url) else {
      defaults.removeObject(forKey: key)
      return nil
    }
    if stale {
      saveBookmark(url, key: key, defaults: defaults, readOnly: readOnly)
    }
    return url
  }

  private func requestFolder(
    title: String,
    message: String,
    suggested: URL,
    key: String,
    defaults: UserDefaults
  ) -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.message = message
    panel.prompt = "Allow Access"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = suggested
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    guard beginHoldingAccess(to: url) else { return nil }
    saveBookmark(url, key: key, defaults: defaults)
    return url
  }

  private func saveBookmark(
    _ url: URL,
    key: String,
    defaults: UserDefaults,
    readOnly: Bool = false
  ) {
    var options: URL.BookmarkCreationOptions = [.withSecurityScope]
    if readOnly {
      options.insert(.securityScopeAllowOnlyReadAccess)
    }
    guard let data = try? url.bookmarkData(
      options: options,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    ) else { return }
    defaults.set(data, forKey: key)
  }

  private func beginHoldingAccess(to url: URL) -> Bool {
    guard url.startAccessingSecurityScopedResource() else { return false }
    if accessedURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
      url.stopAccessingSecurityScopedResource()
    } else {
      accessedURLs.append(url)
    }
    return true
  }

  private func stopHoldingAccess(to url: URL) {
    guard let index = accessedURLs.firstIndex(where: {
      $0.standardizedFileURL == url.standardizedFileURL
    }) else { return }
    accessedURLs[index].stopAccessingSecurityScopedResource()
    accessedURLs.remove(at: index)
  }
}
