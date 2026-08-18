import AppKit
import MarkdownEngine
import SwiftUI

enum NoteEditorFormatting {
    private static let bold = Notification.Name("iagent.note-editor.bold")
    private static let italic = Notification.Name("iagent.note-editor.italic")
    private static let underline = Notification.Name("iagent.note-editor.underline")
    private static let heading = Notification.Name("iagent.note-editor.heading")
    private static let highlight = Notification.Name("iagent.note-editor.highlight")
    private static let strikethrough = Notification.Name("iagent.note-editor.strikethrough")
    private static let inlineCode = Notification.Name("iagent.note-editor.inline-code")
    private static let blockquote = Notification.Name("iagent.note-editor.blockquote")
    private static let unorderedList = Notification.Name("iagent.note-editor.unordered-list")
    private static let orderedList = Notification.Name("iagent.note-editor.ordered-list")
    private static let taskList = Notification.Name("iagent.note-editor.task-list")
    private static let link = Notification.Name("iagent.note-editor.link")
    private static let linkEditor = Notification.Name("iagent.note-editor.link-editor")
    private static let codeBlock = Notification.Name("iagent.note-editor.code-block")
    private static let horizontalRule = Notification.Name("iagent.note-editor.horizontal-rule")
    private static let image = Notification.Name("iagent.note-editor.image")
    private static let findQuery = Notification.Name("iagent.note-editor.find-query")
    private static let findResults = Notification.Name("iagent.note-editor.find-results")
    private static let findClear = Notification.Name("iagent.note-editor.find-clear")
    private static let replaceCurrent = Notification.Name("iagent.note-editor.replace-current")
    private static let replaceAll = Notification.Name("iagent.note-editor.replace-all")

    static let bus = MarkdownEditorBus(
        applyBoldRequest: bold,
        applyItalicRequest: italic,
        applyUnderlineRequest: underline,
        applyHeadingRequest: heading,
        applyHighlightRequest: highlight,
        applyStrikethroughRequest: strikethrough,
        applyInlineCodeRequest: inlineCode,
        applyBlockquoteRequest: blockquote,
        applyUnorderedListRequest: unorderedList,
        applyOrderedListRequest: orderedList,
        applyTaskListRequest: taskList,
        applyLinkRequest: link,
        applyCodeBlockRequest: codeBlock,
        applyHorizontalRuleRequest: horizontalRule,
        applyImageRequest: image,
        findClearHighlights: findClear,
        findQuery: findQuery,
        findResults: findResults,
        replaceCurrent: replaceCurrent,
        replaceAll: replaceAll
    )

    static func applyBold() { post(bold) }
    static func applyItalic() { post(italic) }
    static func applyUnderline() { post(underline) }
    static func applyHeading(_ level: Int) { post(heading, userInfo: ["level": level]) }
    static func applyHighlight() { post(highlight) }
    static func applyStrikethrough() { post(strikethrough) }
    static func applyInlineCode() { post(inlineCode) }
    static func applyBlockquote() { post(blockquote) }
    static func applyUnorderedList() { post(unorderedList) }
    static func applyOrderedList() { post(orderedList) }
    static func applyTaskList() { post(taskList) }
    static func applyLink(url: String) { post(link, userInfo: ["url": url]) }
    static func requestLinkEditor() { post(linkEditor) }
    static func applyCodeBlock() { post(codeBlock) }
    static func applyHorizontalRule() { post(horizontalRule) }
    static func applyImage(url: String) { post(image, userInfo: ["url": url]) }

    static func search(_ query: String, currentIndex: Int) {
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        post(findQuery, userInfo: ["query": query, "currentIndex": currentIndex])
    }

    static func clearSearch() { post(findClear) }

    static func replaceCurrent(query: String, replacement: String, currentIndex: Int) {
        post(
            replaceCurrent,
            userInfo: [
                "query": query,
                "replacement": replacement,
                "currentIndex": currentIndex,
            ]
        )
    }

    static func replaceAll(query: String, replacement: String) {
        post(replaceAll, userInfo: ["query": query, "replacement": replacement])
    }

    static var findResultsPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: findResults)
    }

    static var linkEditorRequests: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: linkEditor)
    }

    private static func post(
        _ name: Notification.Name,
        userInfo: [AnyHashable: Any]? = nil
    ) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }
}

struct MarkdownNoteEditor: View {
    @Binding var text: String
    let documentID: String
    let rawSourceMode: Bool
    let placeholder: String
    var accessibilityLabel = "Note body"
    var accessibilityIdentifier = "note-markdown-editor"

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            fontName: NSFont.systemFont(ofSize: 12).fontName,
            fontSize: 12,
            documentId: documentID,
            onBuildContextMenu: { menu, _ in
                NoteEditorContextMenu.build(menu)
            },
            placeholder: NSAttributedString(
                string: placeholder,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.25),
                ]
            )
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var configuration: MarkdownEditorConfiguration {
        let theme = MarkdownEditorTheme(
            bodyText: NSColor.white.withAlphaComponent(0.78),
            mutedText: NSColor.white.withAlphaComponent(0.36),
            disabledText: NSColor.white.withAlphaComponent(0.24),
            headingMarker: NSColor(
                calibratedRed: 0.941,
                green: 0.78,
                blue: 0.4,
                alpha: 0.62
            ),
            link: NSColor(
                calibratedRed: 0.416,
                green: 0.718,
                blue: 1,
                alpha: 0.9
            ),
            incompleteLink: NSColor(
                calibratedRed: 0.416,
                green: 0.718,
                blue: 1,
                alpha: 0.62
            ),
            findMatchHighlight: NSColor(
                calibratedRed: 0.941,
                green: 0.78,
                blue: 0.4,
                alpha: 0.34
            ),
            findCurrentMatchHighlight: NSColor(
                calibratedRed: 0.941,
                green: 0.78,
                blue: 0.4,
                alpha: 0.62
            ),
            latexLightModeText: .black,
            latexDarkModeText: .white,
            strikethroughColor: NSColor.white.withAlphaComponent(0.5),
            highlightColor: NSColor(
                calibratedRed: 0.941,
                green: 0.78,
                blue: 0.4,
                alpha: 0.24
            )
        )

        return MarkdownEditorConfiguration(
            theme: theme,
            services: MarkdownEditorServices(bus: NoteEditorFormatting.bus),
            markers: MarkerStyle(revealsActiveMarkers: false),
            lists: ListStyle(
                helpersEnabled: !rawSourceMode,
                autoClosePairsEnabled: !rawSourceMode,
                indentPerLevel: 24,
                maximumNestingLevel: 6,
                extraLineHeight: 1
            ),
            taskCheckbox: TaskCheckboxStyle(
                uncheckedSymbolName: "square",
                checkedSymbolName: "checkmark.square.fill"
            ),
            headings: HeadingStyle(
                fontMultipliers: [1.65, 1.4, 1.2, 1.08, 1, 0.92],
                topSpacingEm: [0.22, 0.2, 0.18, 0.14, 0.1, 0.08]
            ),
            blockquote: BlockquoteStyle(extraLineHeight: 1),
            link: LinkStyle(activeLinkAlpha: 0.84, incompleteLinkAlpha: 0.68),
            paragraph: ParagraphStyle(spacingFactor: 0.24, lineHeightExtraSpacing: 2),
            overscroll: OverscrollPolicy(
                percent: 0.28,
                maxPoints: 180,
                minPoints: 22,
                activationStartFraction: 0.2,
                activationRangeFraction: 0.8
            ),
            scrollers: .vertical,
            textInsets: TextInsets(horizontal: 6, vertical: 8),
            spellChecking: .default,
            rawSourceMode: rawSourceMode,
            extensions: [
                StrikethroughExtension(),
                HighlightExtension(),
                UnderlineExtension(),
            ]
        )
    }
}

struct MarkdownFormattingToolbar: View {
    let rawSourceMode: Bool
    let showFind: () -> Void
    let toggleSourceMode: () -> Void
    var openLibrary: (() -> Void)? = nil
    var accessibilityPrefix = "note"
    @State private var showingLinkEditor = false
    @State private var linkURL = ""
    @State private var showingImageEditor = false
    @State private var imageURL = ""
    @FocusState private var linkFieldFocused: Bool
    @FocusState private var imageFieldFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            formattingButton("bold", help: "Bold (Command-B)", id: "\(accessibilityPrefix)-format-bold") {
                NoteEditorFormatting.applyBold()
            }
            formattingButton("italic", help: "Italic (Command-I)", id: "\(accessibilityPrefix)-format-italic") {
                NoteEditorFormatting.applyItalic()
            }
            formattingButton("underline", help: "Underline (Command-U)", id: "\(accessibilityPrefix)-format-underline") {
                NoteEditorFormatting.applyUnderline()
            }
            formattingButton("strikethrough", help: "Strikethrough (Command-Shift-X)", id: "\(accessibilityPrefix)-format-strike") {
                NoteEditorFormatting.applyStrikethrough()
            }

            toolbarDivider

            MarkdownToolbarButton(
                symbol: "link",
                help: "Link (Command-K)",
                accessibilityID: "\(accessibilityPrefix)-format-link"
            ) {
                showingLinkEditor = true
            }
            .popover(isPresented: $showingLinkEditor, arrowEdge: .bottom) {
                linkEditor
            }

            formattingButton("list.number", help: "Numbered list (Command-Shift-7)", id: "\(accessibilityPrefix)-format-numbered") {
                NoteEditorFormatting.applyOrderedList()
            }
            formattingButton("list.bullet", help: "Bulleted list (Command-Shift-8)", id: "\(accessibilityPrefix)-format-bulleted") {
                NoteEditorFormatting.applyUnorderedList()
            }

            toolbarDivider

            formattingButton("text.quote", help: "Block quote", id: "\(accessibilityPrefix)-format-quote") {
                NoteEditorFormatting.applyBlockquote()
            }
            formattingButton(
                "chevron.left.forwardslash.chevron.right",
                help: "Inline code",
                id: "\(accessibilityPrefix)-format-inline-code"
            ) {
                NoteEditorFormatting.applyInlineCode()
            }
            formattingButton("curlybraces.square", help: "Code block", id: "\(accessibilityPrefix)-format-code-block") {
                NoteEditorFormatting.applyCodeBlock()
            }
            formattingButton("checklist", help: "Checklist", id: "\(accessibilityPrefix)-format-checklist") {
                NoteEditorFormatting.applyTaskList()
            }

            MarkdownFormattingMenu(
                rawSourceMode: rawSourceMode,
                showFind: showFind,
                showImageEditor: {
                    showingImageEditor = true
                },
                toggleSourceMode: toggleSourceMode,
                accessibilityPrefix: accessibilityPrefix
            )

            Spacer(minLength: 12)

            if let openLibrary {
                MarkdownToolbarButton(
                    symbol: "folder",
                    help: "Open iAgent Library",
                    accessibilityID: "\(accessibilityPrefix)-open-library",
                    action: openLibrary
                )
            }
        }
        .onReceive(NoteEditorFormatting.linkEditorRequests) { _ in
            showingLinkEditor = true
        }
        .popover(isPresented: $showingImageEditor, arrowEdge: .bottom) {
            imageEditor
        }
    }

    private func formattingButton(
        _ symbol: String,
        help: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        MarkdownToolbarButton(
            symbol: symbol,
            help: help,
            accessibilityID: id,
            action: action
        )
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 4)
    }

    private var linkEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add link")
                .font(.system(size: 12, weight: .semibold))

            TextField("https://", text: $linkURL)
                .textFieldStyle(.roundedBorder)
                .focused($linkFieldFocused)
                .onSubmit(applyLink)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") {
                    showingLinkEditor = false
                    linkURL = ""
                }
                Button("Add", action: applyLink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(linkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear {
            linkFieldFocused = true
        }
    }

    private func applyLink() {
        let url = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        NoteEditorFormatting.applyLink(url: url)
        linkURL = ""
        showingLinkEditor = false
    }

    private var imageEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add image")
                .font(.system(size: 12, weight: .semibold))

            TextField("https://", text: $imageURL)
                .textFieldStyle(.roundedBorder)
                .focused($imageFieldFocused)
                .onSubmit(applyImage)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") {
                    showingImageEditor = false
                    imageURL = ""
                }
                Button("Add", action: applyImage)
                    .keyboardShortcut(.defaultAction)
                    .disabled(imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear {
            imageFieldFocused = true
        }
    }

    private func applyImage() {
        let url = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        NoteEditorFormatting.applyImage(url: url)
        imageURL = ""
        showingImageEditor = false
    }
}

private struct MarkdownToolbarButton: View {
    let symbol: String
    let help: String
    let accessibilityID: String
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(hovered ? 0.84 : 0.58))
                .frame(width: 28, height: 28)
                .background(
                    .white.opacity(hovered || focused ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.white.opacity(focused ? 0.18 : 0), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(MarkdownToolbarPressStyle())
        .focused($focused)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(accessibilityID)
    }
}

private struct MarkdownToolbarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.56 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct MarkdownFormattingMenu: View {
    let rawSourceMode: Bool
    let showFind: () -> Void
    let showImageEditor: () -> Void
    let toggleSourceMode: () -> Void
    var accessibilityPrefix = "note"
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Menu {
            Button("Highlight") { NoteEditorFormatting.applyHighlight() }

            Menu("Heading") {
                Button("Heading 1") { NoteEditorFormatting.applyHeading(1) }
                Button("Heading 2") { NoteEditorFormatting.applyHeading(2) }
                Button("Heading 3") { NoteEditorFormatting.applyHeading(3) }
            }

            Divider()

            Button("Image", action: showImageEditor)
            Button("Horizontal rule") { NoteEditorFormatting.applyHorizontalRule() }

            Divider()

            Button("Find and replace", action: showFind)
            Button(
                rawSourceMode ? "Use live formatting" : "Show Markdown source",
                action: toggleSourceMode
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .frame(width: 28, height: 28)
                .background(
                    .white.opacity(hovered || focused ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.white.opacity(focused ? 0.18 : 0), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(MarkdownToolbarPressStyle())
        .focused($focused)
        .onHover { hovered = $0 }
        .help("More formatting tools")
        .accessibilityLabel("More formatting tools")
        .accessibilityIdentifier("\(accessibilityPrefix)-format-more")
    }
}

struct MarkdownNoteFindBar: View {
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var replacement = ""
    @State private var resultCount = 0
    @State private var currentIndex = 0
    @FocusState private var queryFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            searchField("Find", text: $query)
                .focused($queryFocused)
                .onSubmit { move(by: 1) }

            Text(resultLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.34))
                .frame(width: 42, alignment: .trailing)

            compactButton("chevron.up", help: "Previous match") { move(by: -1) }
            compactButton("chevron.down", help: "Next match") { move(by: 1) }

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1, height: 16)

            searchField("Replace", text: $replacement)
            textButton("Replace") { replaceOne() }
            textButton("All") { replaceEveryMatch() }

            compactButton("xmark", help: "Close find and replace") {
                isPresented = false
            }
        }
        .padding(.horizontal, PanelPageLayout.contentInset)
        .frame(height: 34)
        .background(.white.opacity(0.025))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.065)).frame(height: 1)
        }
        .onAppear {
            queryFocused = true
        }
        .onChange(of: query) { _, newValue in
            currentIndex = 0
            NoteEditorFormatting.search(newValue, currentIndex: currentIndex)
        }
        .onReceive(NoteEditorFormatting.findResultsPublisher) { notification in
            resultCount = notification.userInfo?["count"] as? Int ?? 0
            if resultCount == 0 {
                currentIndex = 0
            } else {
                currentIndex = min(currentIndex, resultCount - 1)
            }
        }
        .onDisappear {
            NoteEditorFormatting.clearSearch()
        }
    }

    private var resultLabel: String {
        guard !query.isEmpty else { return "" }
        guard resultCount > 0 else { return "0 / 0" }
        return "\(currentIndex + 1) / \(resultCount)"
    }

    private func searchField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 8)
            .frame(width: 156, height: 22)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            }
    }

    private func compactButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.52))
            .frame(height: 20)
    }

    private func move(by offset: Int) {
        guard !query.isEmpty, resultCount > 0 else { return }
        currentIndex = (currentIndex + offset + resultCount) % resultCount
        NoteEditorFormatting.search(query, currentIndex: currentIndex)
    }

    private func replaceOne() {
        guard !query.isEmpty, resultCount > 0 else { return }
        NoteEditorFormatting.replaceCurrent(
            query: query,
            replacement: replacement,
            currentIndex: currentIndex
        )
    }

    private func replaceEveryMatch() {
        guard !query.isEmpty, resultCount > 0 else { return }
        NoteEditorFormatting.replaceAll(query: query, replacement: replacement)
    }
}

@MainActor
private final class NoteEditorContextMenuTarget: NSObject {
    static let shared = NoteEditorContextMenuTarget()

    @objc func bold(_: Any?) { NoteEditorFormatting.applyBold() }
    @objc func italic(_: Any?) { NoteEditorFormatting.applyItalic() }
    @objc func underline(_: Any?) { NoteEditorFormatting.applyUnderline() }
    @objc func strikethrough(_: Any?) { NoteEditorFormatting.applyStrikethrough() }
    @objc func inlineCode(_: Any?) { NoteEditorFormatting.applyInlineCode() }
    @objc func blockquote(_: Any?) { NoteEditorFormatting.applyBlockquote() }
    @objc func unorderedList(_: Any?) { NoteEditorFormatting.applyUnorderedList() }
    @objc func orderedList(_: Any?) { NoteEditorFormatting.applyOrderedList() }
    @objc func taskList(_: Any?) { NoteEditorFormatting.applyTaskList() }
    @objc func link(_: Any?) { NoteEditorFormatting.requestLinkEditor() }
    @objc func codeBlock(_: Any?) { NoteEditorFormatting.applyCodeBlock() }
}

@MainActor
private enum NoteEditorContextMenu {
    static func build(_ menu: NSMenu) -> NSMenu {
        let formatMenu = NSMenu(title: "Format")
        let target = NoteEditorContextMenuTarget.shared

        add("Bold", action: #selector(NoteEditorContextMenuTarget.bold(_:)), key: "b", to: formatMenu, target: target)
        add("Italic", action: #selector(NoteEditorContextMenuTarget.italic(_:)), key: "i", to: formatMenu, target: target)
        add("Underline", action: #selector(NoteEditorContextMenuTarget.underline(_:)), key: "u", to: formatMenu, target: target)
        add("Strikethrough", action: #selector(NoteEditorContextMenuTarget.strikethrough(_:)), to: formatMenu, target: target)
        add("Inline code", action: #selector(NoteEditorContextMenuTarget.inlineCode(_:)), to: formatMenu, target: target)
        formatMenu.addItem(.separator())
        add("Block quote", action: #selector(NoteEditorContextMenuTarget.blockquote(_:)), to: formatMenu, target: target)
        add("Bulleted list", action: #selector(NoteEditorContextMenuTarget.unorderedList(_:)), to: formatMenu, target: target)
        add("Numbered list", action: #selector(NoteEditorContextMenuTarget.orderedList(_:)), to: formatMenu, target: target)
        add("Checklist", action: #selector(NoteEditorContextMenuTarget.taskList(_:)), to: formatMenu, target: target)
        formatMenu.addItem(.separator())
        add("Link", action: #selector(NoteEditorContextMenuTarget.link(_:)), key: "k", to: formatMenu, target: target)
        add("Code block", action: #selector(NoteEditorContextMenuTarget.codeBlock(_:)), to: formatMenu, target: target)

        menu.addItem(.separator())
        let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        formatItem.submenu = formatMenu
        menu.addItem(formatItem)
        return menu
    }

    private static func add(
        _ title: String,
        action: Selector,
        key: String = "",
        to menu: NSMenu,
        target: AnyObject
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        if !key.isEmpty {
            item.keyEquivalentModifierMask = .command
        }
        menu.addItem(item)
    }
}
