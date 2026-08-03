import AppKit
import ApplicationServices
import Foundation

struct CodexDesktopPromptError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

@MainActor
final class CodexDesktopPromptSender {
  private let bundleIdentifier = "com.openai.codex"

  func sendPrompt(_ text: String, to threadID: String) async throws {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      throw CodexDesktopPromptError(message: "The dictated prompt is empty.")
    }
    guard let threadURL = URL(string: "codex://threads/\(threadID)") else {
      throw CodexDesktopPromptError(message: "The Codex task link is invalid.")
    }

    let trustOptions = [
      "AXTrustedCheckOptionPrompt": true,
    ] as CFDictionary
    guard AXIsProcessTrustedWithOptions(trustOptions) else {
      throw CodexDesktopPromptError(
        message: "Allow iAgent in System Settings > Privacy & Security > Accessibility, then press Enter again."
      )
    }

    guard NSWorkspace.shared.open(threadURL) else {
      throw CodexDesktopPromptError(message: "Could not open the task in Codex.")
    }

    let application = try await waitForCodexApplication()
    _ = application.activate()
    try await Task.sleep(for: .milliseconds(750))

    let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
    let composer = try await waitForComposer(in: applicationElement)
    guard AXUIElementSetAttributeValue(
      composer,
      kAXFocusedAttribute as CFString,
      kCFBooleanTrue
    ) == .success else {
      throw CodexDesktopPromptError(message: "Could not focus the Codex prompt field.")
    }

    try await pasteAndSubmit(prompt)
    try await Task.sleep(for: .milliseconds(220))

    if let remainingValue = stringAttribute(composer, kAXValueAttribute as CFString),
       remainingValue.trimmingCharacters(in: .whitespacesAndNewlines) == prompt
    {
      throw CodexDesktopPromptError(
        message: "Codex did not accept the prompt. Keep the task open and press Enter again."
      )
    }
  }

  private func waitForCodexApplication() async throws -> NSRunningApplication {
    for _ in 0..<40 {
      if let application = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleIdentifier)
        .first(where: { !$0.isTerminated })
      {
        return application
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw CodexDesktopPromptError(message: "Codex did not finish opening.")
  }

  private func waitForComposer(in application: AXUIElement) async throws -> AXUIElement {
    for _ in 0..<28 {
      if let composer = bestComposer(in: application) {
        return composer
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw CodexDesktopPromptError(
      message: "Could not find the Codex prompt field. Leave the target task visible and try again."
    )
  }

  private func bestComposer(in application: AXUIElement) -> AXUIElement? {
    var queue = [application]
    var candidates: [(score: Int, element: AXUIElement)] = []
    var visited = 0

    while !queue.isEmpty, visited < 1_200 {
      let element = queue.removeFirst()
      visited += 1
      queue.append(contentsOf: childElements(of: element))

      guard boolAttribute(element, kAXEnabledAttribute as CFString) ?? true,
            let role = stringAttribute(element, kAXRoleAttribute as CFString),
            role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String)
      else {
        continue
      }

      var settable = DarwinBoolean(false)
      guard AXUIElementIsAttributeSettable(
        element,
        kAXFocusedAttribute as CFString,
        &settable
      ) == .success, settable.boolValue else {
        continue
      }

      let context = [
        stringAttribute(element, kAXPlaceholderValueAttribute as CFString),
        stringAttribute(element, kAXDescriptionAttribute as CFString),
        stringAttribute(element, kAXTitleAttribute as CFString),
      ]
      .compactMap { $0 }
      .joined(separator: " ")
      .lowercased()

      var score = role == (kAXTextAreaRole as String) ? 100 : 20
      if ["ask", "message", "prompt", "task", "describe", "follow up"]
        .contains(where: context.contains)
      {
        score += 120
      }
      if context.contains("search") || context.contains("title") {
        score -= 90
      }
      if (stringAttribute(element, kAXValueAttribute as CFString) ?? "").isEmpty {
        score += 5
      }
      candidates.append((score, element))
    }

    return candidates.max(by: { $0.score < $1.score })?.element
  }

  private func childElements(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      kAXChildrenAttribute as CFString,
      &value
    ) == .success else {
      return []
    }
    return value as? [AXUIElement] ?? []
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
      return nil
    }
    return value as? String
  }

  private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
      return nil
    }
    return value as? Bool
  }

  private func pasteAndSubmit(_ prompt: String) async throws {
    let pasteboard = NSPasteboard.general
    let snapshot = ClipboardSnapshot(pasteboard: pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(prompt, forType: .string) else {
      throw CodexDesktopPromptError(message: "Could not prepare the dictated prompt.")
    }

    defer { snapshot.restore(to: pasteboard) }
    try postShortcut(keyCode: 0, flags: .maskCommand)
    try await Task.sleep(for: .milliseconds(35))
    try postShortcut(keyCode: 9, flags: .maskCommand)
    try await Task.sleep(for: .milliseconds(120))
    try postShortcut(keyCode: 36, flags: [])
  }

  private func postShortcut(keyCode: CGKeyCode, flags: CGEventFlags) throws {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    else {
      throw CodexDesktopPromptError(message: "Could not send a keyboard event to Codex.")
    }
    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
  }
}

@MainActor
private struct ClipboardSnapshot {
  struct Item {
    let values: [(type: NSPasteboard.PasteboardType, data: Data)]
  }

  let items: [Item]

  init(pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { pasteboardItem in
      Item(
        values: pasteboardItem.types.compactMap { type in
          pasteboardItem.data(forType: type).map { (type, $0) }
        }
      )
    }
  }

  func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let restoredItems = items.map { item in
      let pasteboardItem = NSPasteboardItem()
      for value in item.values {
        pasteboardItem.setData(value.data, forType: value.type)
      }
      return pasteboardItem
    }
    if !restoredItems.isEmpty {
      pasteboard.writeObjects(restoredItems)
    }
  }
}
