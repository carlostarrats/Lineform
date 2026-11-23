import LineformCore
import SwiftUI

/// The selection row (spec §5.5): a floating card at the bottom of the page that scrolls sideways,
/// in the spec's order. Heading and List open menus; every other formatting button runs its
/// command at once. It sits at the bottom, so it never fights the system edit menu, which floats at
/// the selection; it never changes that menu either.
struct SelectionRow: View {
    @ObservedObject var controller: SelectionController
    var profile: ReadingProfile

    static let height: CGFloat = 48

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = Color(uiColor: theme.textColor)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(controller.items, id: \.self) { item in
                    button(for: item, ink: ink)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: Self.height)
        .foregroundStyle(ink)
        .floatingCardChrome(theme: theme, cornerRadius: Self.height / 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection.row")
    }

    @ViewBuilder
    private func button(for item: SelectionRowItem, ink: Color) -> some View {
        let title = item.title(aiName: controller.model.aiName)
        switch item {
        case .heading:
            Menu {
                Section {
                    Button(String(localized: "Title")) { controller.setHeading(1) }
                    Button(String(localized: "Section")) { controller.setHeading(2) }
                }
                Section {
                    Button(String(localized: "Heading 3")) { controller.setHeading(3) }
                    Button(String(localized: "Heading 4")) { controller.setHeading(4) }
                    Button(String(localized: "Heading 5")) { controller.setHeading(5) }
                    Button(String(localized: "Heading 6")) { controller.setHeading(6) }
                }
                Section {
                    Button(String(localized: "Body")) { controller.setHeading(nil) }
                }
            } label: {
                icon(item, title: title, showsChevron: true)
            }
            .accessibilityLabel(title)
        case .list:
            Menu {
                Button(String(localized: "Bulleted List")) { controller.applyList(ordered: false) }
                Button(String(localized: "Numbered List")) { controller.applyList(ordered: true) }
            } label: {
                icon(item, title: title, showsChevron: true)
            }
            .accessibilityLabel(title)
        default:
            Button {
                controller.perform(item)
            } label: {
                if item.systemImage == nil || item == .askAI {
                    textLabel(item, title: title)
                } else {
                    icon(item, title: title, showsChevron: false)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
        }
    }

    private func icon(_ item: SelectionRowItem, title: String, showsChevron: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: item.systemImage ?? "questionmark")
                .font(.system(size: 16, weight: .medium))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.6)
            }
        }
        .frame(minWidth: 40, minHeight: 40)
        .contentShape(Rectangle())
    }

    private func textLabel(_ item: SelectionRowItem, title: String) -> some View {
        HStack(spacing: 5) {
            if let symbol = item.systemImage {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
            }
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
    }
}

/// Everything the selection puts at the bottom of the page: the AI's card (`AIReviewCardsView`),
/// then the row or the comment field. It ignores the keyboard's safe area and places itself from the keyboard's frame
/// (`SelectionRowPlacement`), so it sits just above the keyboard, or above the home indicator.
/// Transitions are `LineformDesign.Motion.standard` through `EditorMotionPolicy` (a plain fade
/// under Reduce Motion).
struct SelectionBottomChrome: View {
    @ObservedObject var controller: SelectionController
    @ObservedObject private var keyboard: SelectionKeyboardTracker
    var profile: ReadingProfile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(controller: SelectionController, profile: ReadingProfile) {
        self.controller = controller
        _keyboard = ObservedObject(wrappedValue: controller.keyboard)
        self.profile = profile
    }

    private var transition: AnyTransition {
        EditorMotionPolicy.fadeAndMoveTransition(y: 24, reduceMotion: reduceMotion)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                if controller.aiState != .idle {
                    AIReviewCardsView(controller: controller, profile: profile)
                        .padding(.horizontal, 8)
                        .transition(transition)
                }
                switch controller.phase {
                case .hidden:
                    EmptyView()
                case .row:
                    SelectionRow(controller: controller, profile: profile)
                        .padding(.horizontal, MarkdownEditor.chromeMargin)
                        .transition(transition)
                case .comment:
                    CommentField(controller: controller, profile: profile)
                        .padding(.horizontal, 8)
                        .transition(transition)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, SelectionRowPlacement.bottomPadding(
                keyboardOverlap: keyboard.overlap, safeAreaBottom: proxy.safeAreaInsets.bottom
            ))
        }
        .ignoresSafeArea(.keyboard)
        .onPreferenceChange(AIReviewCardTopKey.self) { [controller] top in
            MainActor.assumeIsolated { controller.aiCardTopInWindow = top }
        }
        .animation(
            EditorMotionPolicy.animation(.easeOut(duration: LineformDesign.Motion.standard), reduceMotion: reduceMotion),
            value: controller.phase
        )
        .animation(EditorMotionPolicy.animation(.easeOut(duration: 0.2), reduceMotion: reduceMotion), value: controller.aiStatus)
        .animation(EditorMotionPolicy.animation(.easeOut(duration: LineformDesign.Motion.standard), reduceMotion: reduceMotion),
                   value: controller.aiState == .idle)
    }
}

extension View {
    /// The floating-card chrome of the Menu and Aa buttons: the page colour, the hairline and the
    /// soft shadow (`LineformDesign.FloatingCard`).
    func floatingCardChrome(theme: Theme, cornerRadius: CGFloat) -> some View {
        let isDark = theme.usesDarkChrome
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(Color(uiColor: theme.backgroundColor)))
            .overlay(
                shape.strokeBorder(
                    isDark
                        ? Color.white.opacity(LineformDesign.FloatingCard.hairlineOpacityDark)
                        : Color.black.opacity(LineformDesign.FloatingCard.hairlineOpacityLight),
                    lineWidth: LineformDesign.FloatingCard.hairlineWidth
                )
            )
            .clipShape(shape)
            .shadow(
                color: .black.opacity(
                    isDark ? LineformDesign.FloatingCard.shadowOpacityDark : LineformDesign.FloatingCard.shadowOpacityLight
                ),
                radius: LineformDesign.FloatingCard.shadowRadius,
                x: LineformDesign.FloatingCard.shadowOffset.width,
                y: LineformDesign.FloatingCard.shadowOffset.height
            )
    }
}
