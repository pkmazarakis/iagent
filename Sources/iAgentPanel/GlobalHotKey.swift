import Carbon
import Foundation

final class GlobalHotKey: @unchecked Sendable {
  struct Shortcut {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String
  }

  private static let signature: OSType = 0x6941_6774
  private static let eventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotKeyID
    )
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    guard status == noErr,
          hotKeyID.signature == GlobalHotKey.signature,
          hotKeyID.id == hotKey.identifier
    else {
      return OSStatus(eventNotHandledErr)
    }

    hotKey.fire()
    return noErr
  }

  private let identifier: UInt32
  private let shortcuts: [Shortcut]
  private let action: @MainActor @Sendable () -> Void
  private var eventHandlerRef: EventHandlerRef?
  private var hotKeyRef: EventHotKeyRef?
  private(set) var registeredLabel: String?

  init(
    identifier: UInt32,
    shortcuts: [Shortcut],
    action: @escaping @MainActor @Sendable () -> Void
  ) {
    self.identifier = identifier
    self.shortcuts = shortcuts
    self.action = action
  }

  @discardableResult
  func register() -> String? {
    unregister()

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      Self.eventHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandlerRef
    )
    guard installStatus == noErr else { return nil }

    for shortcut in shortcuts {
      var reference: EventHotKeyRef?
      let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
      let status = RegisterEventHotKey(
        shortcut.keyCode,
        shortcut.modifiers,
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &reference
      )
      if status == noErr, let reference {
        hotKeyRef = reference
        registeredLabel = shortcut.label
        return shortcut.label
      }
    }

    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
      self.eventHandlerRef = nil
    }
    return nil
  }

  func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
      self.eventHandlerRef = nil
    }
    registeredLabel = nil
  }

  private func fire() {
    Task { @MainActor [action] in
      action()
    }
  }

  deinit {
    unregister()
  }
}
