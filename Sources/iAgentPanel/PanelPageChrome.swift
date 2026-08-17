import SwiftUI

enum PanelPageLayout {
    static let contentInset: CGFloat = 20
    static let headerLeadingInset: CGFloat = 10
    static let headerTrailingInset: CGFloat = 10
    static let headerItemSpacing: CGFloat = 8
    static let headerHeight: CGFloat = 36
    static let headerFlexibleSpace: CGFloat = 64
}

enum PanelPageHeaderPlacement {
    case root
    case navigation

    var leadingInset: CGFloat {
        switch self {
        case .root:
            PanelPageLayout.contentInset
        case .navigation:
            PanelPageLayout.headerLeadingInset
        }
    }
}

enum PanelPageTitleRole {
    case home
    case page
    case messages

    var font: Font {
        switch self {
        case .home:
            .system(size: 10, weight: .semibold)
        case .page, .messages:
            .system(size: 12, weight: .semibold)
        }
    }

    var color: Color {
        switch self {
        case .home:
            .white.opacity(0.56)
        case .page:
            .white.opacity(0.96)
        case .messages:
            .white.opacity(0.68)
        }
    }
}

struct PanelPageHeader<Actions: View>: View {
    let title: String
    let titleRole: PanelPageTitleRole
    let placement: PanelPageHeaderPlacement
    let onBack: (() -> Void)?
    let backHelp: String
    let focusesBackOnAppear: Bool
    let titleActsAsBackLabel: Bool
    private let actions: Actions

    @FocusState private var backButtonFocused: Bool

    init(
        title: String,
        titleRole: PanelPageTitleRole = .page,
        placement: PanelPageHeaderPlacement = .navigation,
        onBack: (() -> Void)? = nil,
        backHelp: String = "Back",
        focusesBackOnAppear: Bool = false,
        titleActsAsBackLabel: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.titleRole = titleRole
        self.placement = placement
        self.onBack = onBack
        self.backHelp = backHelp
        self.focusesBackOnAppear = focusesBackOnAppear
        self.titleActsAsBackLabel = titleActsAsBackLabel
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: PanelPageLayout.headerItemSpacing) {
            leadingContent

            Spacer(minLength: PanelPageLayout.headerFlexibleSpace)

            actions
        }
        .padding(.leading, placement.leadingInset)
        .padding(.trailing, PanelPageLayout.headerTrailingInset)
        .frame(height: PanelPageLayout.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.09))
                .frame(height: 1)
        }
        .onAppear {
            if focusesBackOnAppear, onBack != nil {
                backButtonFocused = true
            }
        }
    }

    @ViewBuilder
    private var leadingContent: some View {
        if let onBack {
            if titleActsAsBackLabel {
                Button(action: onBack) {
                    HStack(spacing: PanelPageLayout.headerItemSpacing) {
                        backIcon
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.76))
                            .frame(width: 28, height: 28)

                        titleLabel
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($backButtonFocused)
                .help(backHelp)
                .accessibilityLabel(backHelp)
            } else {
                Button(action: onBack) {
                    backIcon
                }
                .buttonStyle(HeaderIconButtonStyle(isActive: false))
                .focused($backButtonFocused)
                .help(backHelp)
                .accessibilityLabel(backHelp)

                titleLabel
            }
        } else {
            titleLabel
        }
    }

    private var backIcon: some View {
        Image(systemName: "chevron.left")
    }

    private var titleLabel: some View {
        Text(title)
            .font(titleRole.font)
            .foregroundStyle(titleRole.color)
            .lineLimit(1)
    }
}
