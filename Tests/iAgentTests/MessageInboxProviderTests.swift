import Foundation
import SQLite3
import XCTest
import iAgentCore

@testable import iAgentPanel

final class MessageInboxProviderTests: XCTestCase {
  func testProviderFactoryDoesNotProbeLocalSourceBeforeOptIn() async {
    let provider = MacMessageProviderFactory.make(
      smokeTest: false,
      preferences: isolatedPreferences(),
      environment: [:],
      arguments: []
    )

    let access = await provider.authorizationStatus()
    guard case .disabled(let message) = access else {
      return XCTFail("Expected an unconfigured source to stay disabled, got \(access)")
    }
    XCTAssertTrue(message.contains("Connect Messages"))
  }

  func testProviderFactoryUsesLocalSourceAfterPersistedOptIn() {
    let preferences = isolatedPreferences()
    MacMessageProviderFactory.setLocalAccessEnabled(true, preferences: preferences)

    let provider = MacMessageProviderFactory.make(
      smokeTest: false,
      preferences: preferences,
      environment: [:],
      arguments: []
    )

    XCTAssertTrue(provider is LocalMacMessagesProvider)
  }

  func testProviderFactoryPersistsEnableAndDisableChoice() {
    let preferences = isolatedPreferences()
    XCTAssertFalse(MacMessageProviderFactory.localAccessIsEnabled(preferences: preferences))

    MacMessageProviderFactory.setLocalAccessEnabled(true, preferences: preferences)
    XCTAssertTrue(MacMessageProviderFactory.localAccessIsEnabled(preferences: preferences))

    MacMessageProviderFactory.setLocalAccessEnabled(false, preferences: preferences)
    XCTAssertFalse(MacMessageProviderFactory.localAccessIsEnabled(preferences: preferences))
  }

  func testProviderFactoryKeepsMockSourceExplicitAndSmokeSafe() {
    let preferences = isolatedPreferences()
    MacMessageProviderFactory.setLocalAccessEnabled(true, preferences: preferences)
    let explicitMock = MacMessageProviderFactory.make(
      smokeTest: false,
      preferences: preferences,
      environment: ["IAGENT_MESSAGES_PROVIDER": "mock"],
      arguments: []
    )
    let smokeMock = MacMessageProviderFactory.make(
      smokeTest: true,
      preferences: preferences,
      environment: [:],
      arguments: []
    )

    XCTAssertTrue(explicitMock is MockMacMessagesProvider)
    XCTAssertTrue(smokeMock is MockMacMessagesProvider)
  }

  func testProviderFactoryAllowsExplicitLocalOverride() {
    let provider = MacMessageProviderFactory.make(
      smokeTest: false,
      preferences: isolatedPreferences(),
      environment: [:],
      arguments: ["--local-messages-provider"]
    )

    XCTAssertTrue(provider is LocalMacMessagesProvider)
  }

  func testProviderFactoryAllowsExplicitDisableAfterOptIn() async {
    let preferences = isolatedPreferences()
    MacMessageProviderFactory.setLocalAccessEnabled(true, preferences: preferences)
    let provider = MacMessageProviderFactory.make(
      smokeTest: false,
      preferences: preferences,
      environment: ["IAGENT_MESSAGES_PROVIDER": "disabled"],
      arguments: []
    )

    let access = await provider.authorizationStatus()
    guard case .disabled = access else {
      return XCTFail("Expected explicit disabled mode to override opt-in, got \(access)")
    }
  }

  func testProviderFactoryInjectsAuthorizedSandboxDatabaseURL() throws {
    let preferences = isolatedPreferences()
    MacMessageProviderFactory.setLocalAccessEnabled(true, preferences: preferences)
    let databaseURL = URL(fileURLWithPath: "/private/tmp/Authorized/Messages/chat.db")

    let provider = MacMessageProviderFactory.make(
      smokeTest: false,
      preferences: preferences,
      environment: [:],
      arguments: [],
      authorizedDatabaseURL: databaseURL,
      requiresSecurityScopedDatabaseURL: true
    )

    let localProvider = try XCTUnwrap(provider as? LocalMacMessagesProvider)
    XCTAssertEqual(localProvider.configuredDatabaseURL, databaseURL)
  }

  func testProviderFactoryDoesNotProbeDefaultSourceWhenSandboxBookmarkIsMissing() async {
    let preferences = isolatedPreferences()
    MacMessageProviderFactory.setLocalAccessEnabled(true, preferences: preferences)

    let provider = MacMessageProviderFactory.make(
      smokeTest: false,
      preferences: preferences,
      environment: [:],
      arguments: [],
      requiresSecurityScopedDatabaseURL: true
    )

    let access = await provider.authorizationStatus()
    guard case .disabled(let message) = access else {
      return XCTFail("Expected bookmark recovery without a source probe, got \(access)")
    }
    XCTAssertTrue(message.contains("Reconnect Messages"))
  }

  func testMessagesDirectoryValidationRequiresNamedDirectoryAndChatDatabase() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("iagent-messages-bookmark-\(UUID().uuidString)", isDirectory: true)
    let messagesDirectory = root.appendingPathComponent("Messages", isDirectory: true)
    let wrongDirectory = root.appendingPathComponent("NotMessages", isDirectory: true)
    try FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: wrongDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(
      try SandboxAccessManager.validatedMessagesDatabaseURL(in: messagesDirectory)
    )
    let databaseURL = messagesDirectory.appendingPathComponent("chat.db")
    XCTAssertTrue(FileManager.default.createFile(atPath: databaseURL.path, contents: Data()))
    XCTAssertEqual(
      try SandboxAccessManager.validatedMessagesDatabaseURL(in: messagesDirectory),
      databaseURL
    )
    XCTAssertThrowsError(
      try SandboxAccessManager.validatedMessagesDatabaseURL(in: wrongDirectory)
    )
  }

  func testMockBackfillIsStableDeduplicatedAndStrictlyWindowed() async throws {
    let referenceDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let provider = MockMacMessagesProvider(referenceDate: referenceDate)

    let access = await provider.authorizationStatus()
    XCTAssertEqual(access, .authorized)

    let batch = try await provider.backfill(since: .distantPast)
    XCTAssertTrue(batch.isFullSnapshot)
    XCTAssertEqual(batch.conversations.count, 3)
    XCTAssertEqual(batch.messages.count, 10)
    XCTAssertEqual(Set(batch.conversations.map(\.id)).count, batch.conversations.count)
    XCTAssertEqual(Set(batch.messages.map(\.id)).count, batch.messages.count)
    XCTAssertFalse(batch.messages.contains { $0.id.contains("expired") })
    XCTAssertFalse(batch.messages.contains { $0.body.contains("deliberately expired") })
    XCTAssertTrue(batch.conversations.contains { $0.isGroup })
    XCTAssertTrue(
      batch.conversations.contains { conversation in
        conversation.displayName == "Maya Ortiz"
          && batch.readStates.first(where: { $0.id == conversation.id })?.readThroughMessageID
            == conversation.latestMessageID
      })
  }

  func testMockLiveStreamEmitsOneDeduplicatedUnreadIncomingDelta() async throws {
    let referenceDate = Date()
    let provider = MockMacMessagesProvider(
      referenceDate: referenceDate,
      liveUpdateDelay: .milliseconds(1)
    )
    let stream = provider.updates(
      since: MessageSyncWindow.cutoff(referenceDate: referenceDate)
    )
    var iterator = stream.makeAsyncIterator()
    let batch = try await iterator.next()

    let update = try XCTUnwrap(batch)
    XCTAssertFalse(update.isFullSnapshot)
    XCTAssertEqual(update.conversations.map(\.id), ["mock-conversation-avery"])
    XCTAssertEqual(update.messages.map(\.id), ["mock-message-avery-live-1"])
    XCTAssertEqual(update.messages.first?.isFromMe, false)
    XCTAssertNil(update.messages.first?.sourceReadAt)
    XCTAssertEqual(update.readStates.first?.readThroughMessageID, "mock-message-avery-3")
  }

  func testLocalProviderUsesExactCutoffHashedIDsAndNormalizedPhoneFallbacks() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "iagent-message-provider-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appendingPathComponent("chat.db")
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let cutoffNanoseconds = Int64(
      (cutoff.timeIntervalSinceReferenceDate * 1_000_000_000).rounded(.up)
    )
    try makeMessagesFixture(
      at: databaseURL,
      cutoffNanoseconds: cutoffNanoseconds
    )

    let provider = LocalMacMessagesProvider(
      databaseURL: databaseURL,
      pollingInterval: .milliseconds(10),
      contactNameResolver: StubContactNameResolver()
    )
    let access = await provider.authorizationStatus()
    XCTAssertEqual(access, .authorized)

    let batch = try await provider.backfill(since: cutoff)
    XCTAssertEqual(batch.conversations.count, 1)
    XCTAssertEqual(batch.messages.count, 1)
    let conversation = try XCTUnwrap(batch.conversations.first)
    let message = try XCTUnwrap(batch.messages.first)
    XCTAssertEqual(conversation.displayName, "+15551234567")
    XCTAssertEqual(conversation.participants.map(\.displayName), ["+15551234567"])
    XCTAssertEqual(message.senderDisplayName, "+15551234567")
    XCTAssertEqual(message.body, "Recent fixture body")
    XCTAssertTrue(conversation.id.hasPrefix("macmsg-conversation-"))
    XCTAssertTrue(message.id.hasPrefix("macmsg-message-"))
    XCTAssertFalse(conversation.id.contains("+15551234567"))
    XCTAssertFalse(message.id.contains("fixture-message-guid"))
    XCTAssertFalse(batch.messages.contains { $0.body == "Too old" })
  }

  func testLocalProviderResolvesOneReplyRecipientOnDemandWithoutPublishingIt() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "iagent-message-reply-resolution-test-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appendingPathComponent("chat.db")
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let cutoffNanoseconds = Int64(
      (cutoff.timeIntervalSinceReferenceDate * 1_000_000_000).rounded(.up)
    )
    try makeMessagesFixture(at: databaseURL, cutoffNanoseconds: cutoffNanoseconds)

    let provider = LocalMacMessagesProvider(
      databaseURL: databaseURL,
      contactNameResolver: StubContactNameResolver(),
      includesReplyAddresses: false
    )
    let privateSnapshot = try await provider.backfill(since: cutoff)
    let conversation = try XCTUnwrap(privateSnapshot.conversations.first)
    XCTAssertNil(conversation.participants.first?.replyAddress)

    let recipients = try await provider.replyRecipients(
      for: conversation.id,
      since: cutoff
    )
    XCTAssertEqual(recipients.count, 1)
    XCTAssertEqual(recipients.first?.address.value, "+15551234567")
    XCTAssertEqual(recipients.first?.displayName, "+15551234567")

    let stillPrivateSnapshot = try await provider.backfill(since: cutoff)
    XCTAssertNil(stillPrivateSnapshot.conversations.first?.participants.first?.replyAddress)
  }

  func testLocalProviderPrefersPhoneThenEmailForUnresolvedDirectParticipants() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "iagent-message-provider-participant-order-test-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appendingPathComponent("chat.db")
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let cutoffNanoseconds = Int64(
      (cutoff.timeIntervalSinceReferenceDate * 1_000_000_000).rounded(.up)
    )
    try makeMessagesFixture(at: databaseURL, cutoffNanoseconds: cutoffNanoseconds)
    try execute(
      """
      INSERT INTO handle VALUES (8, 'MAILTO:Avery.Chen%40Example.COM', 'iMessage');
      INSERT INTO chat_handle_join VALUES (1, 8);
      """,
      at: databaseURL
    )

    let provider = LocalMacMessagesProvider(
      databaseURL: databaseURL,
      contactNameResolver: StubContactNameResolver()
    )
    let snapshot = try await provider.backfill(since: cutoff)
    let conversation = try XCTUnwrap(snapshot.conversations.first)

    XCTAssertFalse(conversation.isGroup)
    XCTAssertEqual(conversation.displayName, "+15551234567")
    XCTAssertEqual(
      conversation.participants.map(\.displayName),
      ["+15551234567", "avery.chen@example.com"]
    )
    XCTAssertFalse(conversation.displayName.contains("Conversation"))
    XCTAssertFalse(conversation.displayName.contains("Contact"))
  }

  func testLocalProviderUsesLowercaseEmailForDisplayButPreservesReplyLocalPart() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "iagent-message-provider-email-fallback-test-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appendingPathComponent("chat.db")
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let cutoffNanoseconds = Int64(
      (cutoff.timeIntervalSinceReferenceDate * 1_000_000_000).rounded(.up)
    )
    try makeMessagesFixture(at: databaseURL, cutoffNanoseconds: cutoffNanoseconds)
    try execute(
      """
      UPDATE handle SET id = 'MAILTO:Avery.Chen%40Example.COM' WHERE ROWID = 7;
      UPDATE chat
      SET guid = 'iMessage;-;Avery.Chen@example.com',
          chat_identifier = 'Avery.Chen@example.com'
      WHERE ROWID = 1;
      """,
      at: databaseURL
    )

    let provider = LocalMacMessagesProvider(
      databaseURL: databaseURL,
      contactNameResolver: StubContactNameResolver()
    )
    let snapshot = try await provider.backfill(since: cutoff)

    XCTAssertEqual(snapshot.conversations.first?.displayName, "avery.chen@example.com")
    XCTAssertEqual(snapshot.messages.first?.senderDisplayName, "avery.chen@example.com")

    let replyEnabledProvider = LocalMacMessagesProvider(
      databaseURL: databaseURL,
      contactNameResolver: StubContactNameResolver(),
      includesReplyAddresses: true
    )
    let replyEnabled = try await replyEnabledProvider.backfill(since: cutoff)
    XCTAssertEqual(
      replyEnabled.conversations.first?.participants.first?.replyAddress,
      "Avery.Chen@example.com"
    )
  }

  func testLocalProviderResolvesContactNameTransientlyAndKeepsNamedGroupAuthoritative() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "iagent-message-provider-contact-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appendingPathComponent("chat.db")
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let cutoffNanoseconds = Int64(
      (cutoff.timeIntervalSinceReferenceDate * 1_000_000_000).rounded(.up)
    )
    try makeMessagesFixture(at: databaseURL, cutoffNanoseconds: cutoffNanoseconds)
    let resolver = StubContactNameResolver(names: ["+15551234567": "Avery Chen"])
    let provider = LocalMacMessagesProvider(
      databaseURL: databaseURL,
      contactNameResolver: resolver
    )

    let resolved = try await provider.backfill(since: cutoff)
    let conversation = try XCTUnwrap(resolved.conversations.first)
    let message = try XCTUnwrap(resolved.messages.first)
    XCTAssertEqual(conversation.displayName, "Avery Chen")
    XCTAssertEqual(conversation.participants.map(\.displayName), ["Avery Chen"])
    XCTAssertEqual(message.senderDisplayName, "Avery Chen")
    XCTAssertEqual(resolver.lookupCount(for: "+15551234567"), 1)
    XCTAssertFalse(conversation.id.contains("+15551234567"))
    XCTAssertFalse(conversation.participants.contains { $0.id.contains("+15551234567") })
    XCTAssertFalse(message.senderID?.contains("+15551234567") == true)
    XCTAssertNil(conversation.participants.first?.replyAddress)

    let replyEnabledProvider = LocalMacMessagesProvider(
      databaseURL: databaseURL,
      contactNameResolver: resolver,
      includesReplyAddresses: true
    )
    let replyEnabled = try await replyEnabledProvider.backfill(since: cutoff)
    let replyParticipant = try XCTUnwrap(replyEnabled.conversations.first?.participants.first)
    XCTAssertEqual(replyParticipant.displayName, "Avery Chen")
    XCTAssertEqual(replyParticipant.replyAddress, "+15551234567")
    XCTAssertFalse(replyParticipant.id.contains(replyParticipant.replyAddress ?? ""))

    try execute(
      "UPDATE chat SET display_name = 'Weekend Plans', style = 43 WHERE ROWID = 1",
      at: databaseURL
    )
    let namedGroup = try await provider.backfill(since: cutoff)
    XCTAssertEqual(namedGroup.conversations.first?.displayName, "Weekend Plans")
  }

  func testContactIndexNormalizesMessagesURIsEmailCaseAndPhoneCountryPrefixes() {
    var index = MessageContactNameIndex()
    index.add(
      displayName: "Avery Chen",
      phoneNumbers: ["(691) 234-5678"],
      emailAddresses: ["Avery.Chen@Example.com"]
    )

    XCTAssertEqual(
      MessageContactIdentifier.normalized("mailto:Avery.Chen%40Example.com"),
      .email("avery.chen@example.com")
    )
    XCTAssertEqual(
      MessageContactIdentifier.normalized("iMessage;-;tel:%2B30%20691%20234%205678"),
      .phone("306912345678")
    )
    XCTAssertEqual(
      MessageContactIdentifier.normalized("tel:%2B30%20691%20234%205678")?
        .privacySafeDisplayValue(source: "tel:%2B30%20691%20234%205678"),
      "+306912345678"
    )
    XCTAssertEqual(
      MessageContactIdentifier.normalized("(691) 234-5678")?
        .privacySafeDisplayValue(source: "(691) 234-5678"),
      "6912345678"
    )
    XCTAssertEqual(
      index.displayName(for: "MAILTO:AVERY.CHEN%40EXAMPLE.COM?subject=ignored"),
      "Avery Chen"
    )
    XCTAssertEqual(
      index.displayName(for: "tel:+30 691 234 5678;ext=42"),
      "Avery Chen"
    )
    XCTAssertNil(index.displayName(for: "mailto:unknown@example.com"))
  }

  func testContactIndexRejectsAmbiguousPhoneSuffixesAndRawIdentifierNames() {
    var index = MessageContactNameIndex()
    index.add(
      displayName: "Avery Chen",
      phoneNumbers: ["+1 212 555 0100"],
      emailAddresses: []
    )
    index.add(
      displayName: "Jordan Lee",
      phoneNumbers: ["+44 20 2555 0100"],
      emailAddresses: []
    )
    index.add(
      displayName: "private@example.com",
      phoneNumbers: [],
      emailAddresses: ["private@example.com"]
    )

    XCTAssertNil(index.displayName(for: "tel:55550100"))
    XCTAssertNil(index.displayName(for: "mailto:private@example.com"))
  }

  func testMessageAvatarToneSeparatesGroupsKnownDirectsAndUnresolvedHandles() {
    func conversation(displayName: String, isGroup: Bool) -> SyncedMessageConversation {
      SyncedMessageConversation(
        id: "conversation-\(displayName)-\(isGroup)",
        displayName: displayName,
        participants: [],
        isGroup: isGroup,
        latestMessageID: "message",
        latestMessageDate: .now,
        latestPreview: "Preview",
        updatedAt: .now
      )
    }

    XCTAssertEqual(
      messageAvatarTone(for: conversation(displayName: "+15551234567", isGroup: true)),
      .group
    )
    XCTAssertEqual(
      messageAvatarTone(for: conversation(displayName: "Avery Chen", isGroup: false)),
      .knownDirect
    )
    XCTAssertEqual(
      messageAvatarTone(for: conversation(displayName: "+15551234567", isGroup: false)),
      .unresolvedDirect
    )
    XCTAssertEqual(
      messageAvatarTone(for: conversation(displayName: "unknown@example.com", isGroup: false)),
      .unresolvedDirect
    )
    XCTAssertEqual(
      messageAvatarTone(for: conversation(displayName: "Contact", isGroup: false)),
      .unresolvedDirect
    )
  }

  func testMessageInboxVisualContractUsesTodoStyleSearchAndStableMetadataSlots() throws {
    XCTAssertEqual(PanelPageLayout.contentInset, 20)
    XCTAssertEqual(MessageInboxLayout.searchAccessorySize, 24)
    XCTAssertEqual(MessageInboxLayout.searchVerticalInset, 8)
    XCTAssertEqual(MessageInboxLayout.searchRowHeight, 40)
    XCTAssertEqual(MessageInboxLayout.searchFontSize, 12)
    XCTAssertEqual(PanelPageLayout.headerLeadingInset, 10)
    XCTAssertEqual(PanelPageLayout.headerItemSpacing, 8)
    XCTAssertEqual(MessageInboxLayout.metadataGap, 20)
    XCTAssertEqual(MessageInboxLayout.metadataWidth, 90)
    XCTAssertEqual(MessageInboxLayout.relativeTimeWidth, 22)

    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repositoryRoot
        .appendingPathComponent("Sources/iAgentPanel/MessageInboxViews.swift"),
      encoding: .utf8
    )
    let searchStart = try XCTUnwrap(source.range(of: "private var messageSearchRow"))
    let searchEnd = try XCTUnwrap(
      source.range(of: "private var filteredConversations", range: searchStart.upperBound..<source.endIndex)
    )
    let searchImplementation = source[searchStart.lowerBound..<searchEnd.lowerBound]
    XCTAssertTrue(searchImplementation.contains("TextField(\"Search messages\""))
    XCTAssertFalse(searchImplementation.contains("magnifyingglass"))
    XCTAssertTrue(
      searchImplementation.contains(".padding(.horizontal, PanelPageLayout.contentInset)")
    )
    XCTAssertTrue(
      searchImplementation.contains(".padding(.vertical, MessageInboxLayout.searchVerticalInset)")
    )
    XCTAssertTrue(searchImplementation.contains(".background(ExpandedPanelBackground())"))
    XCTAssertTrue(
      source.contains(
        ".frame(width: MessageInboxLayout.relativeTimeWidth, alignment: .leading)"
      )
    )
  }

  @MainActor
  func testCompactPanelWidthTracksRequestedRetinaPixelIncreasesWithoutChangingOtherPanelWidths() {
    let controller = PanelController(
      smokeTest: true,
      preferences: isolatedPreferences()
    )

    XCTAssertEqual(controller.compactSize.width, 593)
    XCTAssertEqual(controller.notchSize.width, 210)
    XCTAssertEqual(controller.expandedSize.width, 760)
  }

  func testFullDiskAccessSettingsURLTargetsModernPrivacySettingsExtension() throws {
    XCTAssertEqual(
      try XCTUnwrap(messageFullDiskAccessSettingsURL()).absoluteString,
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )
  }

  func testAttributedBodyDecoderAcceptsSecureKeyedAndStrictTypedStreamFixtures() throws {
    let keyed = try NSKeyedArchiver.archivedData(
      withRootObject: NSAttributedString(string: "Keyed Unicode body 🟢"),
      requiringSecureCoding: true
    )
    XCTAssertEqual(
      MessageAttributedBodyDecoder.decode(keyed),
      "Keyed Unicode body 🟢"
    )
    XCTAssertEqual(
      MessageAttributedBodyDecoder.decode(typedStreamFixture),
      "Synthetic fixture"
    )
  }

  func testAttributedBodyDecoderRejectsWrongRootMalformedOversizeAndAttachmentPlaceholder() throws {
    let wrongRoot = try NSKeyedArchiver.archivedData(
      withRootObject: NSString(string: "Not an attributed string"),
      requiringSecureCoding: true
    )
    XCTAssertNil(MessageAttributedBodyDecoder.decode(wrongRoot))

    var malformedTypedStream = typedStreamFixture
    let classMarker = try XCTUnwrap(
      malformedTypedStream.range(of: Data("NSAttributedString".utf8))
    )
    malformedTypedStream[classMarker.lowerBound] = UInt8(ascii: "X")
    XCTAssertNil(MessageAttributedBodyDecoder.decode(malformedTypedStream))
    XCTAssertNil(
      MessageAttributedBodyDecoder.decode(
        Data("streamtyped NSAttributedString NSString + /private/attachment/path".utf8)
      )
    )
    XCTAssertNil(
      MessageAttributedBodyDecoder.decode(
        Data(count: MessageAttributedBodyDecoder.maximumArchiveBytes + 1)
      )
    )

    let placeholder = try NSKeyedArchiver.archivedData(
      withRootObject: NSAttributedString(string: "\u{FFFC}"),
      requiringSecureCoding: true
    )
    XCTAssertNil(MessageAttributedBodyDecoder.decode(placeholder))
  }

  func testLocalProviderBodyPrecedenceAndAttachmentMetadataFallback() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "iagent-message-provider-body-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appendingPathComponent("chat.db")
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let cutoffNanoseconds = Int64(
      (cutoff.timeIntervalSinceReferenceDate * 1_000_000_000).rounded(.up)
    )
    try makeMessagesFixture(at: databaseURL, cutoffNanoseconds: cutoffNanoseconds)
    let provider = LocalMacMessagesProvider(
      databaseURL: databaseURL,
      contactNameResolver: StubContactNameResolver()
    )

    try updateRecentMessage(
      at: databaseURL,
      text: nil,
      attributedBody: typedStreamFixture,
      hasAttachments: false
    )
    let decodedSnapshot = try await provider.backfill(since: cutoff)
    XCTAssertEqual(decodedSnapshot.messages.first?.body, "Synthetic fixture")

    try updateRecentMessage(
      at: databaseURL,
      text: "Plain text wins",
      attributedBody: typedStreamFixture,
      hasAttachments: false
    )
    let plainTextSnapshot = try await provider.backfill(since: cutoff)
    XCTAssertEqual(plainTextSnapshot.messages.first?.body, "Plain text wins")

    try updateRecentMessage(
      at: databaseURL,
      text: nil,
      attributedBody: Data("/private/attachment/path".utf8),
      hasAttachments: true
    )
    let attachmentBody = try await provider.backfill(since: cutoff).messages.first?.body
    XCTAssertEqual(attachmentBody, "Attachment")
    XCTAssertFalse(attachmentBody?.contains("/private/") == true)
  }

  func testLocalProviderDerivesAwaitingReplyFromMeaningfulTextOnly() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "iagent-message-provider-awaiting-reply-test-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appendingPathComponent("chat.db")
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let cutoffNanoseconds = Int64(
      (cutoff.timeIntervalSinceReferenceDate * 1_000_000_000).rounded(.up)
    )
    try makeReplySemanticsFixture(
      at: databaseURL,
      cutoffNanoseconds: cutoffNanoseconds
    )

    let provider = LocalMacMessagesProvider(
      databaseURL: databaseURL,
      contactNameResolver: StubContactNameResolver()
    )
    let snapshot = try await provider.backfill(since: cutoff)

    func message(_ body: String) throws -> SyncedMessage {
      try XCTUnwrap(snapshot.messages.first { $0.body == body })
    }

    func conversation(containing body: String) throws -> SyncedMessageConversation {
      let message = try message(body)
      return try XCTUnwrap(snapshot.conversations.first { $0.id == message.conversationID })
    }

    let answered = try conversation(containing: "Outgoing answer")
    XCTAssertNil(answered.awaitingReplyMessageID)

    let latestInbound = try message("Latest inbound question")
    XCTAssertEqual(
      try conversation(containing: "Latest inbound question").awaitingReplyMessageID,
      latestInbound.id
    )

    let inboundBeforeNoise = try message("Inbound before non-text events")
    XCTAssertEqual(
      try conversation(containing: "System event").awaitingReplyMessageID,
      inboundBeforeNoise.id
    )
    XCTAssertNotNil(try? message("Attachment"))
    XCTAssertNotNil(try? message("Tapback event"))
    XCTAssertNotNil(try? message("Rich balloon event"))
    XCTAssertNotNil(try? message("Action event"))

    let inboundGroup = try conversation(containing: "Latest group inbound")
    XCTAssertTrue(inboundGroup.isGroup)
    XCTAssertNil(inboundGroup.awaitingReplyMessageID)

    let caption = try message("Caption on attachment")
    XCTAssertEqual(
      try conversation(containing: "Caption on attachment").awaitingReplyMessageID,
      caption.id
    )

    XCTAssertFalse(snapshot.messages.contains { $0.body == "Expired inbound" })
    XCTAssertNil(
      try conversation(containing: "Recent attachment only").awaitingReplyMessageID
    )
  }

  func testConversationDecodesLegacyPayloadWithoutAwaitingReplyMessageID() throws {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let conversation = SyncedMessageConversation(
      id: "conversation-legacy",
      displayName: "Legacy",
      participants: [],
      isGroup: false,
      latestMessageID: "message-latest",
      latestMessageDate: now,
      latestPreview: "Preview",
      awaitingReplyMessageID: "message-awaiting",
      updatedAt: now
    )
    let encoded = try JSONEncoder().encode(conversation)
    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    legacyObject.removeValue(forKey: "awaitingReplyMessageID")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

    let decoded = try JSONDecoder().decode(
      SyncedMessageConversation.self,
      from: legacyData
    )
    XCTAssertNil(decoded.awaitingReplyMessageID)
  }

  func testLocalProviderPollingSkipsUnchangedSourceAndReloadsAfterSourceOrContactChange() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "iagent-message-provider-poll-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appendingPathComponent("chat.db")
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let cutoffNanoseconds = Int64(
      (cutoff.timeIntervalSinceReferenceDate * 1_000_000_000).rounded(.up)
    )
    try makeMessagesFixture(
      at: databaseURL,
      cutoffNanoseconds: cutoffNanoseconds
    )

    let loadCount = SnapshotLoadCounter()
    let contactNameResolver = StubContactNameResolver()
    let provider = LocalMacMessagesProvider(
      databaseURL: databaseURL,
      pollingInterval: .milliseconds(5),
      snapshotLoadObserver: loadCount.increment,
      contactNameResolver: contactNameResolver
    )
    let stream = provider.updates(since: cutoff)
    var iterator = stream.makeAsyncIterator()
    let initial = try await iterator.next()
    XCTAssertEqual(initial?.isFullSnapshot, true)

    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(loadCount.value, 1)

    contactNameResolver.signalChange()
    for _ in 0..<50 where loadCount.value < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(loadCount.value, 2)

    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(10)],
      ofItemAtPath: databaseURL.path
    )
    for _ in 0..<50 where loadCount.value < 3 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(loadCount.value, 3)
  }

  func testLocalProviderReportsMissingReadableDatabaseAsFailure() async {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "iagent-message-provider-missing-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = LocalMacMessagesProvider(
      databaseURL: root.appendingPathComponent("chat.db"),
      contactNameResolver: StubContactNameResolver()
    )
    let status = await provider.authorizationStatus()
    guard case .failed(let message) = status else {
      return XCTFail("Expected a missing readable Messages source to fail, got \(status)")
    }
    XCTAssertTrue(message.contains("not found"))
  }

  private func makeMessagesFixture(
    at databaseURL: URL,
    cutoffNanoseconds: Int64
  ) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
    let opened = try XCTUnwrap(database)
    defer { sqlite3_close(opened) }

    let setup = """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        guid TEXT,
        chat_identifier TEXT,
        display_name TEXT,
        service_name TEXT,
        style INTEGER
      );
      CREATE TABLE handle (
        ROWID INTEGER PRIMARY KEY,
        id TEXT,
        service TEXT
      );
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        guid TEXT,
        text TEXT,
        attributedBody BLOB,
        cache_has_attachments INTEGER,
        handle_id INTEGER,
        is_from_me INTEGER,
        date INTEGER,
        date_read INTEGER,
        is_read INTEGER,
        service TEXT
      );
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      INSERT INTO chat VALUES (
        1,
        'iMessage;-;+15551234567',
        '+15551234567',
        '',
        'iMessage',
        45
      );
      INSERT INTO handle VALUES (7, '+15551234567', 'iMessage');
      INSERT INTO chat_handle_join VALUES (1, 7);
      INSERT INTO message VALUES (
        10,
        'fixture-message-guid-recent',
        'Recent fixture body',
        NULL,
        0,
        7,
        0,
        \(cutoffNanoseconds),
        \(cutoffNanoseconds),
        1,
        'iMessage'
      );
      INSERT INTO chat_message_join VALUES (1, 10);
      INSERT INTO message VALUES (
        11,
        'fixture-message-guid-old',
        'Too old',
        NULL,
        0,
        7,
        0,
        \(cutoffNanoseconds - 1_000_000_000),
        0,
        0,
        'iMessage'
      );
      INSERT INTO chat_message_join VALUES (1, 11);
      """
    guard sqlite3_exec(opened, setup, nil, nil, nil) == SQLITE_OK else {
      throw NSError(domain: "MessageInboxProviderTests", code: 1)
    }
  }

  private func makeReplySemanticsFixture(
    at databaseURL: URL,
    cutoffNanoseconds: Int64
  ) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
    let opened = try XCTUnwrap(database)
    defer { sqlite3_close(opened) }

    let second: Int64 = 1_000_000_000
    let setup = """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        guid TEXT,
        chat_identifier TEXT,
        display_name TEXT,
        service_name TEXT,
        style INTEGER
      );
      CREATE TABLE handle (
        ROWID INTEGER PRIMARY KEY,
        id TEXT,
        service TEXT
      );
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        guid TEXT,
        text TEXT,
        attributedBody BLOB,
        cache_has_attachments INTEGER,
        handle_id INTEGER,
        is_from_me INTEGER,
        date INTEGER,
        date_read INTEGER,
        is_read INTEGER,
        service TEXT,
        associated_message_guid TEXT,
        associated_message_type INTEGER,
        is_system_message INTEGER,
        is_service_message INTEGER,
        item_type INTEGER,
        group_action_type INTEGER,
        message_action_type INTEGER,
        balloon_bundle_id TEXT
      );
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);

      INSERT INTO handle VALUES (1, '+15550000001', 'iMessage');
      INSERT INTO handle VALUES (2, '+15550000002', 'iMessage');
      INSERT INTO handle VALUES (3, '+15550000003', 'iMessage');
      INSERT INTO handle VALUES (4, '+15550000004', 'iMessage');
      INSERT INTO handle VALUES (5, '+15550000005', 'iMessage');
      INSERT INTO handle VALUES (6, '+15550000006', 'iMessage');
      INSERT INTO handle VALUES (7, '+15550000007', 'iMessage');

      INSERT INTO chat VALUES (1, 'chat-answered', '+15550000001', '', 'iMessage', 45);
      INSERT INTO chat VALUES (2, 'chat-awaiting', '+15550000002', '', 'iMessage', 45);
      INSERT INTO chat VALUES (3, 'chat-noise', '+15550000003', '', 'iMessage', 45);
      INSERT INTO chat VALUES (4, 'chat-group', 'group-4', 'Test Group', 'iMessage', 43);
      INSERT INTO chat VALUES (5, 'chat-caption', '+15550000005', '', 'iMessage', 45);
      INSERT INTO chat VALUES (6, 'chat-expired', '+15550000006', '', 'iMessage', 45);

      INSERT INTO chat_handle_join VALUES (1, 1);
      INSERT INTO chat_handle_join VALUES (2, 2);
      INSERT INTO chat_handle_join VALUES (3, 3);
      INSERT INTO chat_handle_join VALUES (4, 4);
      INSERT INTO chat_handle_join VALUES (4, 7);
      INSERT INTO chat_handle_join VALUES (5, 5);
      INSERT INTO chat_handle_join VALUES (6, 6);

      INSERT INTO message VALUES (
        100, 'answered-in', 'Inbound answered question', NULL, 0, 1, 0,
        \(cutoffNanoseconds), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 0, ''
      );
      INSERT INTO message VALUES (
        101, 'answered-out', 'Outgoing answer', NULL, 0, 1, 1,
        \(cutoffNanoseconds + second), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 0, ''
      );
      INSERT INTO chat_message_join VALUES (1, 100);
      INSERT INTO chat_message_join VALUES (1, 101);

      INSERT INTO message VALUES (
        110, 'awaiting-out', 'Earlier outgoing text', NULL, 0, 2, 1,
        \(cutoffNanoseconds + 2 * second), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 0, ''
      );
      INSERT INTO message VALUES (
        111, 'awaiting-in', 'Latest inbound question', NULL, 0, 2, 0,
        \(cutoffNanoseconds + 3 * second), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 0, ''
      );
      INSERT INTO chat_message_join VALUES (2, 110);
      INSERT INTO chat_message_join VALUES (2, 111);

      INSERT INTO message VALUES (
        120, 'noise-in', 'Inbound before non-text events', NULL, 0, 3, 0,
        \(cutoffNanoseconds + 4 * second), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 0, ''
      );
      INSERT INTO message VALUES (
        121, 'noise-attachment', NULL, NULL, 1, 3, 0,
        \(cutoffNanoseconds + 5 * second), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 0, ''
      );
      INSERT INTO message VALUES (
        122, 'noise-system', 'System event', NULL, 0, 3, 0,
        \(cutoffNanoseconds + 6 * second), 0, 1, 'iMessage', '', 0, 1, 0, 1, 1, 0, ''
      );
      INSERT INTO message VALUES (
        123, 'noise-tapback', 'Tapback event', NULL, 0, 3, 0,
        \(cutoffNanoseconds + 7 * second), 0, 1, 'iMessage', 'p:0/noise-in', 2001, 0, 0, 0, 0, 0, ''
      );
      INSERT INTO message VALUES (
        124, 'noise-balloon', 'Rich balloon event', NULL, 0, 3, 0,
        \(cutoffNanoseconds + 8 * second), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 0, 'com.apple.messages.MSMessageExtensionBalloonPlugin:dummy'
      );
      INSERT INTO message VALUES (
        125, 'noise-action', 'Action event', NULL, 0, 3, 0,
        \(cutoffNanoseconds + 9 * second), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 1, ''
      );
      INSERT INTO chat_message_join VALUES (3, 120);
      INSERT INTO chat_message_join VALUES (3, 121);
      INSERT INTO chat_message_join VALUES (3, 122);
      INSERT INTO chat_message_join VALUES (3, 123);
      INSERT INTO chat_message_join VALUES (3, 124);
      INSERT INTO chat_message_join VALUES (3, 125);

      INSERT INTO message VALUES (
        130, 'group-out', 'Earlier group outgoing', NULL, 0, 4, 1,
        \(cutoffNanoseconds + 10 * second), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 0, ''
      );
      INSERT INTO message VALUES (
        131, 'group-in', 'Latest group inbound', NULL, 0, 4, 0,
        \(cutoffNanoseconds + 11 * second), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 0, ''
      );
      INSERT INTO chat_message_join VALUES (4, 130);
      INSERT INTO chat_message_join VALUES (4, 131);

      INSERT INTO message VALUES (
        140, 'caption-in', 'Caption on attachment', NULL, 1, 5, 0,
        \(cutoffNanoseconds + 12 * second), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 0, ''
      );
      INSERT INTO chat_message_join VALUES (5, 140);

      INSERT INTO message VALUES (
        150, 'expired-in', 'Expired inbound', NULL, 0, 6, 0,
        \(cutoffNanoseconds - 1), 0, 1, 'iMessage', '', 0, 0, 0, 0, 0, 0, ''
      );
      INSERT INTO message VALUES (
        151, 'recent-attachment', 'Recent attachment only', NULL, 0, 6, 0,
        \(cutoffNanoseconds + 13 * second), 0, 1, 'iMessage', '', 0, 1, 0, 0, 0, 0, ''
      );
      INSERT INTO chat_message_join VALUES (6, 150);
      INSERT INTO chat_message_join VALUES (6, 151);
      """
    guard sqlite3_exec(opened, setup, nil, nil, nil) == SQLITE_OK else {
      throw NSError(domain: "MessageInboxProviderTests", code: 7)
    }
  }

  private var typedStreamFixture: Data {
    Data(
      base64Encoded:
        "BAtzdHJlYW10eXBlZIHoA4QBQISEhBJOU0F0dHJpYnV0ZWRTdHJpbmcAhIQITlNPYmplY3QAhZKEhIQITlNTdHJpbmcBlIQBKxFTeW50aGV0aWMgZml4dHVyZYaEAmlJARGShISEDE5TRGljdGlvbmFyeQCUhAFpAIaG"
    )!
  }

  private func execute(_ sql: String, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
      throw NSError(domain: "MessageInboxProviderTests", code: 2)
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw NSError(domain: "MessageInboxProviderTests", code: 3)
    }
  }

  private func updateRecentMessage(
    at databaseURL: URL,
    text: String?,
    attributedBody: Data?,
    hasAttachments: Bool
  ) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
      throw NSError(domain: "MessageInboxProviderTests", code: 4)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    let sql = """
      UPDATE message
      SET text = ?, attributedBody = ?, cache_has_attachments = ?
      WHERE ROWID = 10
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
    else { throw NSError(domain: "MessageInboxProviderTests", code: 5) }
    defer { sqlite3_finalize(statement) }
    let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    if let text {
      sqlite3_bind_text(statement, 1, text, -1, sqliteTransient)
    } else {
      sqlite3_bind_null(statement, 1)
    }
    if let attributedBody {
      _ = attributedBody.withUnsafeBytes { bytes in
        sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
      }
    } else {
      sqlite3_bind_null(statement, 2)
    }
    sqlite3_bind_int(statement, 3, hasAttachments ? 1 : 0)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw NSError(domain: "MessageInboxProviderTests", code: 6)
    }
  }

  private func isolatedPreferences() -> UserDefaults {
    let suiteName = "MessageInboxProviderTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suiteName) ?? .standard
    preferences.removePersistentDomain(forName: suiteName)
    return preferences
  }
}

private final class SnapshotLoadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}

private final class StubContactNameResolver: MessageContactNameResolving, @unchecked Sendable {
  private let lock = NSLock()
  private let names: [String: String]
  private var lookupCounts: [String: Int] = [:]
  private var generation: UInt64 = 0

  init(names: [String: String] = [:]) {
    self.names = names
  }

  func requestAuthorizationIfNeeded() async {}

  var changeGeneration: UInt64 {
    lock.withLock { generation }
  }

  func displayName(for rawHandle: String) -> String? {
    lock.withLock {
      lookupCounts[rawHandle, default: 0] += 1
      return names[rawHandle]
    }
  }

  func lookupCount(for rawHandle: String) -> Int {
    lock.withLock { lookupCounts[rawHandle, default: 0] }
  }

  func signalChange() {
    lock.withLock { generation &+= 1 }
  }
}
