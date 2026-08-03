//
//  UnderlineExtension.swift
//  MarkdownEngine
//
//  Optional raw-HTML-compatible underline span for visual editors.
//

import AppKit
import Foundation

public struct UnderlineExtension: MarkdownExtension {
    public static let identifier = "underline"

    public init() {}

    public var id: String { Self.identifier }

    public var inline: InlineSyntax? {
        InlineSyntax(
            open: "<u>",
            close: "</u>",
            rejectsOpenerRun: false,
            abortsOnMismatchedCloserPrefix: false
        )
    }

    public func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: theme.bodyText,
        ]
    }

    public func html(childrenHTML: String) -> String {
        "<u>\(childrenHTML)</u>"
    }
}
