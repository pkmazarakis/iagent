//
//  ContextMenu.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 20.06.25.
//
//  Right-click menu with toggleable Markdown formatting actions.
//
//  Two rules here, both learned from silent data loss (25.07.26):
//
//  1. Never publish the binding. `didChangeText()` already enqueues the STORAGE
//     form; a handler enqueueing `self.text = tv.string` lands second on the
//     same queue and wins — and `tv.string` is the DISPLAY form, where every
//     `|UUID` has been moved out of the text into metadata.
//  2. Never rewrite retained text. Rebuilding a span from `tv.string` and
//     writing it back destroys `.wikiLinkID` on anything inside it, which is the
//     only copy of a link's UUID once its metadata range shifts. Use
//     `replacePreservingAttributes` or edit only the characters that change.
//

import Cocoa
import SwiftUI

extension NativeTextViewWrapper.Coordinator {
    // The engine ships no built-in menu (API-only). It hands the default NSMenu + the
    // current selection to the embedder's onBuildContextMenu hook, which returns the menu
    // to show. The didMarkdown* actions below stay so embedders can drive them via the bus.
    public func textView(_ textView: NSTextView,
                         menu: NSMenu,
                         for event: NSEvent,
                         at charIndex: Int) -> NSMenu? {
        // Drop the system rich-text "Font" submenu (Bold/Italic/Show Colors…). Those apply
        // NSFont traits/colors that do nothing in a markdown editor (the engine owns styling),
        // so showing them would mislead. Identified by its font-panel action (locale-independent),
        // with a title fallback.
        if let fontIndex = menu.items.firstIndex(where: { item in
            if item.title == "Font" { return true }
            return item.submenu?.items.contains { $0.action == Selector("orderFrontFontPanel:") } ?? false
        }) {
            menu.removeItem(at: fontIndex)
        }
        guard let build = onBuildContextMenu else { return menu }
        return build(menu, textView.selectedRange())
    }

    /// Returns the smallest bold or boldItalic token that fully contains the selection, or nil when the selection isn't enclosed by emphasis with a bold trait.
    func enclosingBoldToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { token in
            (token.kind == .bold || token.kind == .boldItalic) && tokenEncloses(token, selection: selection)
        }
    }

    /// Returns the smallest italic or boldItalic token that fully contains the selection, or nil when the selection isn't enclosed by emphasis with an italic trait.
    func enclosingItalicToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { token in
            (token.kind == .italic || token.kind == .boldItalic) && tokenEncloses(token, selection: selection)
        }
    }

    func isSelectionBold(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingBoldToken(for: range, in: nsText as String) != nil
    }

    func isSelectionItalic(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingItalicToken(for: range, in: nsText as String) != nil
    }

    /// Returns the smallest highlight token that fully contains the selection, or nil.
    /// Highlight is extension-supplied; without a registered `HighlightExtension`
    /// no such token exists and the toggle only wraps/unwraps literal `==`.
    func enclosingHighlightToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        enclosingToken(of: .extensionSpan(HighlightExtension.identifier), for: selection, in: text)
    }

    func isSelectionHighlight(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingHighlightToken(for: range, in: nsText as String) != nil
    }

    /// Strikethrough is extension-supplied; without a registered
    /// `StrikethroughExtension` no such token exists and the toggle only
    /// wraps/unwraps literal `~~`.
    func isSelectionStrikethrough(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingToken(of: .extensionSpan(StrikethroughExtension.identifier), for: range, in: nsText as String) != nil
    }

    func isSelectionUnderline(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingToken(of: .extensionSpan(UnderlineExtension.identifier), for: range, in: nsText as String) != nil
    }

    func isSelectionInlineCode(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingToken(of: .inlineCode, for: range, in: nsText as String) != nil
    }

    /// Returns the smallest token of `kind` that fully contains the selection, or nil.
    private func enclosingToken(of kind: MarkdownTokenKind, for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { $0.kind == kind && tokenEncloses($0, selection: selection) }
    }

    /// Expands the given text location outward to the nearest alphanumeric
    /// + underscore word boundaries. Returns nil when no word characters
    /// are adjacent to the location.
    private func wordRange(at location: Int, in nsText: NSString) -> NSRange? {
        guard location >= 0, location <= nsText.length else { return nil }
        let charSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        var start = location
        while start > 0 {
            let ch = nsText.character(at: start - 1)
            guard let scalar = Unicode.Scalar(ch), charSet.contains(scalar) else { break }
            start -= 1
        }
        var end = location
        while end < nsText.length {
            let ch = nsText.character(at: end)
            guard let scalar = Unicode.Scalar(ch), charSet.contains(scalar) else { break }
            end += 1
        }
        let length = end - start
        return length > 0 ? NSRange(location: start, length: length) : nil
    }

    private func tokenEncloses(_ token: MarkdownToken, selection: NSRange) -> Bool {
        return selection.location >= token.range.location
            && NSMaxRange(selection) <= NSMaxRange(token.range)
    }

    /// Replace `range` with `newText`, carrying the attributes of `retained`
    /// onto its new home at `newOffset` within `newText`.
    ///
    /// `retained` is a subrange of the CURRENT storage whose characters survive
    /// verbatim. See the file header for why a plain replacement is unsafe.
    /// Returns false when the text view refused the edit, so callers can skip
    /// their selection update.
    @discardableResult
    private func replacePreservingAttributes(
        in range: NSRange,
        with newText: String,
        retaining retained: NSRange,
        at newOffset: Int
    ) -> Bool {
        guard let tv = textView, let storage = tv.textStorage else { return false }
        guard tv.shouldChangeText(in: range, replacementString: newText) else { return false }

        let replacement = NSMutableAttributedString(string: newText, attributes: tv.typingAttributes)
        let carried = storage.attributedSubstring(from: retained)
        let target = NSRange(location: newOffset, length: carried.length)
        // Defensive: a caller that miscomputes the offset would corrupt the
        // document rather than merely lose styling, so fall back to the plain
        // replacement instead of trapping on a bad range.
        if NSMaxRange(target) <= replacement.length {
            replacement.replaceCharacters(in: target, with: carried)
        }
        storage.replaceCharacters(in: range, with: replacement)
        tv.didChangeText()
        return true
    }

    private func unwrapToken(_ token: MarkdownToken, leftReplacement: String, rightReplacement: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let content = nsText.substring(with: token.contentRange)
        let newText = leftReplacement + content + rightReplacement
        guard replacePreservingAttributes(
            in: token.range,
            with: newText,
            retaining: token.contentRange,
            at: (leftReplacement as NSString).length
        ) else { return }
        let newSelectionLocation = token.range.location + (leftReplacement as NSString).length
        tv.setSelectedRange(NSRange(
            location: newSelectionLocation,
            length: (content as NSString).length
        ))
    }

    func isSelectionHeading(level: Int, in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLine.hasPrefix(String(repeating: "#", count: level) + " ")
    }

    func isSelectionList(in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        return line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            || line.hasPrefix("\t• ") || line.hasPrefix("1. ")
    }

    func isSelectionBlockquote(in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        return line.hasPrefix("> ")
    }

    private func applyHeading(level: Int) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let lineRange = nsText.lineRange(for: range)
        let originalLine = nsText.substring(with: lineRange)
        let rawLine = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
        var content = rawLine
        while content.hasPrefix("#") { content.removeFirst() }
        content = content.trimmingCharacters(in: .whitespaces)
        let prefix = String(repeating: "#", count: level) + " "
        // lineRange(for:) includes the trailing line terminator; preserve it so
        // applying a heading to a non-final line doesn't swallow the newline and
        // merge the line with the next one (mirrors applyList's suffix handling).
        let suffix = originalLine.hasSuffix("\n") ? "\n" : ""
        let newLine = prefix + content + suffix
        // `content` is a verbatim slice of the line — locate it so its styling,
        // and any wiki link inside it, survives the rewrite.
        let contentRange = (originalLine as NSString).range(of: content)
        let retained = contentRange.location == NSNotFound
            ? NSRange(location: lineRange.location, length: 0)
            : NSRange(location: lineRange.location + contentRange.location, length: contentRange.length)
        guard replacePreservingAttributes(
            in: lineRange,
            with: newLine,
            retaining: retained,
            at: (prefix as NSString).length
        ) else { return }
        let newSel = NSRange(
            location: lineRange.location + (prefix as NSString).length,
            length: (content as NSString).length
        )
        tv.setSelectedRange(newSel)
    }

    @objc func didMarkdownHeading(_ sender: NSMenuItem) {
        applyHeading(level: sender.tag)
    }

    private func applyList(prefix: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let selection = tv.selectedRange()
        // NSRange's upper bound is exclusive. A selection ending at the start
        // of the following line must not format that following line.
        let lineProbe = selection.length > 0
            ? NSRange(location: selection.location, length: selection.length - 1)
            : selection
        let paragraphRange = nsText.lineRange(for: lineProbe)
        let targetPattern = prefix == "1. "
            ? #"^([ \t]*)\d+[.)][ \t]+"#
            : #"^([ \t]*)[-*+•][ \t]+"#
        let targetRegex = try! NSRegularExpression(pattern: targetPattern)
        let anyListRegex = try! NSRegularExpression(
            pattern: #"^([ \t]*)(?:[-*+•]|\d+[.)])[ \t]+"#
        )

        struct PrefixEdit {
            let range: NSRange
            let replacement: String
        }

        var lines: [(range: NSRange, text: NSString)] = []
        var location = paragraphRange.location
        let end = NSMaxRange(paragraphRange)
        while location < end {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            lines.append((lineRange, nsText.substring(with: lineRange) as NSString))
            let next = NSMaxRange(lineRange)
            guard next > location else { break }
            location = next
        }
        if lines.isEmpty {
            lines.append((paragraphRange, nsText.substring(with: paragraphRange) as NSString))
        }

        let meaningfulLines = lines.filter {
            ($0.text as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        // A caret on an empty line creates an empty list row. Blank separator
        // lines inside a multiline selection remain untouched.
        let targetLines = selection.length == 0 ? lines : meaningfulLines
        guard !targetLines.isEmpty else { return }
        let removesList = targetLines.allSatisfy { line in
            targetRegex.firstMatch(
                in: line.text as String,
                range: NSRange(location: 0, length: line.text.length)
            ) != nil
        }

        var edits: [PrefixEdit] = []
        for line in targetLines {
            let localRange = NSRange(location: 0, length: line.text.length)
            if removesList,
               let existing = targetRegex.firstMatch(in: line.text as String, range: localRange)
            {
                let indentation = line.text.substring(with: existing.range(at: 1))
                edits.append(PrefixEdit(
                    range: NSRange(
                        location: line.range.location + existing.range.location,
                        length: existing.range.length
                    ),
                    replacement: indentation
                ))
                continue
            }

            if let existing = anyListRegex.firstMatch(in: line.text as String, range: localRange) {
                let indentation = line.text.substring(with: existing.range(at: 1))
                edits.append(PrefixEdit(
                    range: NSRange(
                        location: line.range.location + existing.range.location,
                        length: existing.range.length
                    ),
                    replacement: indentation + prefix
                ))
                continue
            }

            let indentation = line.text.range(of: #"^[ \t]*"#, options: .regularExpression)
            let indentationLength = indentation.location == NSNotFound ? 0 : indentation.length
            edits.append(PrefixEdit(
                range: NSRange(location: line.range.location + indentationLength, length: 0),
                replacement: prefix
            ))
        }

        guard !edits.isEmpty else { return }
        guard let storage = tv.textStorage else { return }
        let replacement = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: paragraphRange)
        )
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            let localRange = NSRange(
                location: edit.range.location - paragraphRange.location,
                length: edit.range.length
            )
            replacement.replaceCharacters(
                in: localRange,
                with: NSAttributedString(string: edit.replacement, attributes: tv.typingAttributes)
            )
        }

        tv.undoManager?.beginUndoGrouping()
        defer {
            tv.undoManager?.endUndoGrouping()
            let type = prefix == "1. " ? "Numbered List" : "Bulleted List"
            tv.undoManager?.setActionName(removesList ? "Remove \(type)" : type)
        }

        // Publish this as one attributed edit. Multiple prefix mutations followed
        // by one didChangeText event leave the storage/display bridge with only
        // the final sub-edit's range and can corrupt the Markdown writeback.
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard tv.shouldChangeText(in: paragraphRange, replacementString: replacement.string) else {
            return
        }
        storage.replaceCharacters(in: paragraphRange, with: replacement)
        pendingListStructureEdit = true
        tv.didChangeText()

        let ascendingEdits = edits.sorted { $0.range.location < $1.range.location }
        func mappedPosition(_ originalPosition: Int) -> Int {
            var delta = 0
            for edit in ascendingEdits {
                let oldStart = edit.range.location
                let oldEnd = NSMaxRange(edit.range)
                let replacementLength = (edit.replacement as NSString).length

                if originalPosition < oldStart { break }
                if edit.range.length > 0, originalPosition < oldEnd {
                    return oldStart + delta + replacementLength
                }
                delta += replacementLength - edit.range.length
            }
            return originalPosition + delta
        }

        let mappedStart = mappedPosition(selection.location)
        let mappedEnd = mappedPosition(NSMaxRange(selection))
        tv.setSelectedRange(NSRange(
            location: mappedStart,
            length: max(0, mappedEnd - mappedStart)
        ))
    }

    @objc func didMarkdownUnorderedList(_ sender: Any?) {
        applyList(prefix: "- ")
    }

    @objc func didMarkdownOrderedList(_ sender: Any?) {
        applyList(prefix: "1. ")
    }

    /// Toggles the selected paragraphs between ordinary bullets and task rows.
    /// Prefixes are edited in place so attributed content and link metadata are
    /// never rebuilt or discarded.
    @objc func didMarkdownTaskList(_ sender: Any?) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let selection = tv.selectedRange()
        // NSRange's upper bound is exclusive. If a multiline selection ends at
        // column zero, do not unexpectedly transform the following line.
        let lineProbe = selection.length > 0
            ? NSRange(location: selection.location, length: selection.length - 1)
            : selection
        let paragraphRange = nsText.lineRange(for: lineProbe)
        let taskRegex = try! NSRegularExpression(
            pattern: #"^([ \t]*)(?:[-*+•]|\d+[.)])[ \t]+\[[ xX]\](?:[ \t]+)?"#
        )
        let listRegex = try! NSRegularExpression(
            pattern: #"^([ \t]*)(?:[-*+•]|\d+[.)])[ \t]+"#
        )

        struct PrefixEdit {
            let range: NSRange
            let replacement: String
        }

        var lines: [(range: NSRange, text: NSString)] = []
        var location = paragraphRange.location
        let end = NSMaxRange(paragraphRange)
        while location < end {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            lines.append((lineRange, nsText.substring(with: lineRange) as NSString))
            let next = NSMaxRange(lineRange)
            guard next > location else { break }
            location = next
        }
        if lines.isEmpty {
            lines.append((paragraphRange, nsText.substring(with: paragraphRange) as NSString))
        }

        let meaningful = lines.filter {
            ($0.text as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        // A caret on an empty line should create a usable empty checklist row;
        // blank separator lines inside a multiline selection stay untouched.
        let targetLines = selection.length == 0 ? lines : meaningful
        let allTasks = !targetLines.isEmpty && targetLines.allSatisfy { line in
            taskRegex.firstMatch(
                in: line.text as String,
                range: NSRange(location: 0, length: line.text.length)
            ) != nil
        }

        var edits: [PrefixEdit] = []
        for line in targetLines {
            let localRange = NSRange(location: 0, length: line.text.length)
            if let task = taskRegex.firstMatch(in: line.text as String, range: localRange) {
                if allTasks {
                    let indent = line.text.substring(with: task.range(at: 1))
                    edits.append(PrefixEdit(
                        range: NSRange(
                            location: line.range.location + task.range.location,
                            length: task.range.length
                        ),
                        replacement: indent + "- "
                    ))
                }
                continue
            }

            if let list = listRegex.firstMatch(in: line.text as String, range: localRange) {
                let indent = line.text.substring(with: list.range(at: 1))
                edits.append(PrefixEdit(
                    range: NSRange(
                        location: line.range.location + list.range.location,
                        length: list.range.length
                    ),
                    replacement: indent + "- [ ] "
                ))
                continue
            }

            let indentation = line.text.range(of: #"^[ \t]*"#, options: .regularExpression)
            let indentLength = indentation.location == NSNotFound ? 0 : indentation.length
            edits.append(PrefixEdit(
                range: NSRange(location: line.range.location + indentLength, length: 0),
                replacement: "- [ ] "
            ))
        }

        guard !edits.isEmpty else { return }
        var appliedEdits: [PrefixEdit] = []
        tv.undoManager?.beginUndoGrouping()
        defer {
            tv.undoManager?.endUndoGrouping()
            tv.undoManager?.setActionName(allTasks ? "Remove Checklist" : "Checklist")
        }
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard tv.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { continue }
            tv.replaceCharacters(in: edit.range, with: edit.replacement)
            appliedEdits.append(edit)
        }
        guard !appliedEdits.isEmpty else { return }
        pendingListStructureEdit = true
        tv.didChangeText()

        // Keep the user's caret/selection attached to the same content after
        // each prefix rewrite. Positions inside a replaced prefix move to the
        // end of the new prefix; positions after it shift by the UTF-16 delta.
        let ascendingEdits = appliedEdits.sorted { $0.range.location < $1.range.location }
        func mappedPosition(_ originalPosition: Int) -> Int {
            var delta = 0
            for edit in ascendingEdits {
                let oldStart = edit.range.location
                let oldEnd = NSMaxRange(edit.range)
                let replacementLength = (edit.replacement as NSString).length

                if originalPosition < oldStart {
                    break
                }
                if edit.range.length > 0, originalPosition < oldEnd {
                    return oldStart + delta + replacementLength
                }
                delta += replacementLength - edit.range.length
            }
            return originalPosition + delta
        }

        let mappedStart = mappedPosition(selection.location)
        let mappedEnd = mappedPosition(NSMaxRange(selection))
        tv.setSelectedRange(NSRange(
            location: mappedStart,
            length: max(0, mappedEnd - mappedStart)
        ))
    }

    @objc func didMarkdownBold(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingBoldToken(for: range, in: tv.string) {
            // Toggle off: bold → plain, boldItalic → italic.
            let (left, right) = token.kind == .boldItalic ? ("*", "*") : ("", "")
            unwrapToken(token, leftReplacement: left, rightReplacement: right)
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "**", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("**")
            return
        }

        wrapSelection(with: "**")
    }

    @objc func didMarkdownItalic(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingItalicToken(for: range, in: tv.string) {
            // Toggle off: italic → plain, boldItalic → bold.
            let (left, right) = token.kind == .boldItalic ? ("**", "**") : ("", "")
            unwrapToken(token, leftReplacement: left, rightReplacement: right)
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "*", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("*")
            return
        }

        wrapSelection(with: "*")
    }

    @objc func didMarkdownUnderline(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingToken(of: .extensionSpan(UnderlineExtension.identifier), for: range, in: tv.string) {
            unwrapToken(token, leftReplacement: "", rightReplacement: "")
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, open: "<u>", close: "</u>", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers(open: "<u>", close: "</u>")
            return
        }

        let nsText = tv.string as NSString
        if nsText.rangeOfCharacter(from: .newlines, options: [], range: range).location != NSNotFound {
            wrapMultilineSelection(range, open: "<u>", close: "</u>")
            return
        }

        wrapSelection(open: "<u>", close: "</u>")
    }

    @objc func didMarkdownHighlight(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingHighlightToken(for: range, in: tv.string) {
            unwrapToken(token, leftReplacement: "", rightReplacement: "")
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("==")
            return
        }

        wrapSelection(with: "==")
    }

    @objc func didMarkdownStrikethrough(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingToken(of: .extensionSpan(StrikethroughExtension.identifier), for: range, in: tv.string) {
            unwrapToken(token, leftReplacement: "", rightReplacement: "")
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "~~", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("~~")
            return
        }

        wrapSelection(with: "~~")
    }

    @objc func didMarkdownInlineCode(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingToken(of: .inlineCode, for: range, in: tv.string) {
            unwrapToken(token, leftReplacement: "", rightReplacement: "")
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "`", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("`")
            return
        }

        wrapSelection(with: "`")
    }

    /// Toggles the `> ` prefix by editing only the prefix, leaving every
    /// attribute on the rest of the line untouched. It used to replace the whole
    /// line to add two characters, which is how it stripped wiki-link UUIDs.
    @objc func didMarkdownBlockquote(_ sender: Any?) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let lineRange = nsText.lineRange(for: range)
        let originalLine = nsText.substring(with: lineRange)

        if originalLine.hasPrefix("> ") {
            let prefixRange = NSRange(location: lineRange.location, length: 2)
            if tv.shouldChangeText(in: prefixRange, replacementString: "") {
                tv.replaceCharacters(in: prefixRange, with: "")
                tv.didChangeText()
                let newLoc = max(lineRange.location, range.location - 2)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            }
        } else {
            let insertRange = NSRange(location: lineRange.location, length: 0)
            if tv.shouldChangeText(in: insertRange, replacementString: "> ") {
                tv.replaceCharacters(in: insertRange, with: "> ")
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location + 2, length: range.length))
            }
        }
    }

    @objc func didMarkdownLink(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let url = (sender as? NSNotification)?.userInfo?["url"] as? String ?? ""

        if range.length > 0 {
            let nsText = tv.string as NSString
            let selected = nsText.substring(with: range)
            let newText = "[\(selected)](\(url))"
            // The selected text becomes the link label and survives verbatim.
            guard replacePreservingAttributes(
                in: range,
                with: newText,
                retaining: range,
                at: 1 // past the opening "["
            ) else { return }
            tv.setSelectedRange(NSRange(
                location: range.location + (newText as NSString).length,
                length: 0
            ))
        } else {
            insertEmptyMarkers(open: "[", close: "](\(url))")
        }
    }

    @objc func didMarkdownCodeBlock(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let nsText = tv.string as NSString
        let lineRange = nsText.lineRange(for: range)
        let prefix = range.location > lineRange.location ? "\n" : ""
        let insertion = "\(prefix)```\n\n```\n"
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            let cursorLoc = range.location + (prefix as NSString).length + 4
            tv.setSelectedRange(NSRange(location: cursorLoc, length: 0))
        }
    }

    @objc func didMarkdownHorizontalRule(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let nsText = tv.string as NSString
        let lineRange = nsText.lineRange(for: range)
        let prefix = range.location > lineRange.location ? "\n" : ""
        let insertion = "\(prefix)---\n"
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            let cursorLoc = range.location + (insertion as NSString).length
            tv.setSelectedRange(NSRange(location: cursorLoc, length: 0))
        }
    }

    @objc func didMarkdownImage(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let url = (sender as? NSNotification)?.userInfo?["url"] as? String ?? ""
        let insertion = "![](\(url))"
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(
                location: range.location + (insertion as NSString).length,
                length: 0
            ))
        }
    }

    /// Wraps the range with markers while preserving the cursor's relative
    /// offset within the original text. For example `wo|rd` with `**`
    /// becomes `**wo|rd**`.
    private func wrapWordRange(_ range: NSRange, with marker: String, cursorOffset: Int) {
        wrapWordRange(range, open: marker, close: marker, cursorOffset: cursorOffset)
    }

    private func wrapWordRange(
        _ range: NSRange,
        open: String,
        close: String,
        cursorOffset: Int
    ) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let original = nsText.substring(with: range)
        let newText = open + original + close
        guard replacePreservingAttributes(
            in: range,
            with: newText,
            retaining: range,
            at: (open as NSString).length
        ) else { return }
        tv.setSelectedRange(NSRange(
            location: range.location + (open as NSString).length + cursorOffset,
            length: 0
        ))
    }

    private func insertEmptyMarkers(_ marker: String) {
        insertEmptyMarkers(open: marker, close: marker)
    }

    private func insertEmptyMarkers(open: String, close: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let format = PendingInlineFormat(open: open, close: close)
        if pendingInlineFormatLocation != range.location {
            pendingInlineFormats.removeAll()
        }
        pendingInlineFormatLocation = range.location
        if let index = pendingInlineFormats.firstIndex(of: format) {
            pendingInlineFormats.remove(at: index)
        } else {
            pendingInlineFormats.append(format)
        }
        if pendingInlineFormats.isEmpty {
            pendingInlineFormatLocation = nil
        }
    }

    private func wrapSelection(with marker: String) {
        wrapSelection(open: marker, close: marker)
    }

    /// Inline extensions are deliberately single-line. Wrap each selected
    /// physical line independently so a rich-text underline selection across
    /// paragraphs never falls back to visible literal tags.
    private func wrapMultilineSelection(
        _ selection: NSRange,
        open: String,
        close: String
    ) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let probe = NSRange(
            location: selection.location,
            length: max(0, selection.length - 1)
        )
        let coveredLines = nsText.lineRange(for: probe)
        let whitespace = CharacterSet.whitespacesAndNewlines as NSCharacterSet

        var cores: [NSRange] = []
        var location = coveredLines.location
        while location < NSMaxRange(coveredLines) {
            let line = nsText.lineRange(for: NSRange(location: location, length: 0))
            var core = NSIntersectionRange(line, selection)
            while core.length > 0,
                  whitespace.characterIsMember(nsText.character(at: core.location)) {
                core.location += 1
                core.length -= 1
            }
            while core.length > 0,
                  whitespace.characterIsMember(nsText.character(at: NSMaxRange(core) - 1)) {
                core.length -= 1
            }
            if core.length > 0 { cores.append(core) }
            let next = NSMaxRange(line)
            guard next > location else { break }
            location = next
        }

        guard !cores.isEmpty else { return }
        var insertedLength = 0
        tv.undoManager?.beginUndoGrouping()
        defer {
            tv.undoManager?.endUndoGrouping()
            tv.undoManager?.setActionName("Underline")
        }
        for core in cores.reversed() {
            let closeRange = NSRange(location: NSMaxRange(core), length: 0)
            let openRange = NSRange(location: core.location, length: 0)
            guard tv.shouldChangeText(in: closeRange, replacementString: close),
                  tv.shouldChangeText(in: openRange, replacementString: open)
            else {
                continue
            }
            tv.replaceCharacters(in: closeRange, with: close)
            tv.replaceCharacters(in: openRange, with: open)
            insertedLength += (open as NSString).length + (close as NSString).length
        }
        guard insertedLength > 0 else { return }
        tv.didChangeText()
        tv.setSelectedRange(NSRange(
            location: selection.location,
            length: selection.length + insertedLength
        ))
    }

    private func wrapSelection(open: String, close: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let original = nsText.substring(with: range)
        guard original.contains(where: { !$0.isWhitespace }) else { return }
        let leadingWS = original.prefix { $0.isWhitespace }.count
        let trailingWS = original.reversed().prefix { $0.isWhitespace }.count
        let coreStart = original.index(original.startIndex, offsetBy: leadingWS)
        let coreEnd = original.index(original.endIndex, offsetBy: -trailingWS)
        let core = coreStart <= coreEnd ? String(original[coreStart..<coreEnd]) : ""
        let leading = String(original[..<coreStart])
        let trailing = String(original[coreEnd...])
        let newText = leading + open + core + close + trailing
        // Only the markers are new; `core` is the user's text and keeps its
        // attributes, including a wiki link's UUID if the selection spans one.
        let coreOldRange = NSRange(location: range.location + (leading as NSString).length,
                                   length: (core as NSString).length)
        guard replacePreservingAttributes(
            in: range,
            with: newText,
            retaining: coreOldRange,
            at: (leading as NSString).length + (open as NSString).length
        ) else { return }
        let newRange = NSRange(
            location: range.location
                + (leading as NSString).length
                + (open as NSString).length,
            length: (core as NSString).length
        )
        tv.setSelectedRange(newRange)
    }
}

// Menu Item Validation (checkmark state) removed together with the built-in menu —
// engine ships no UI. Expose the isSelection* checks as a query API if embedders
// need menu state.
