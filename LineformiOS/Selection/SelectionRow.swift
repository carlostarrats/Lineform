import LineformCore
import SwiftUI

/// The selection row (spec §5.5): a floating card at the bottom of the page that scrolls sideways,
/// in the spec's order. Heading opens its levels in place (‹ back); List opens a menu; every other button runs its
/// command at once. It sits at the bottom, so it never fights the system edit menu, which floats at
/// the selection; it never changes that menu either.
///
/// Accessibility:
/// - **Text size.** The row is floating chrome of a fixed height, like a toolbar: its text stops
///   growing at `maximumDynamicTypeSize` (so it never clips in the 48 pt card) and, as in the
///   system's bars, every item shows the Large Content Viewer at the accessibility sizes (touch
///   and hold).
/// - **Targets.** Each item draws 40 pt but is a 44 × 44 pt target: the extra 2 pt on each side
///   is taken back with negative padding, so the row looks as it always did.
/// - **VoiceOver.** The row rises at the bottom while focus stays on the text, so a VoiceOver user
///   would never learn it is there. The first time it appears in a session (with VoiceOver on), a
///   low-priority announcement says so: it is
///   queued behind whatever VoiceOver is reading (the selection), never interrupts it, and focus
///   is not moved — the writer may still be adjusting the selection. The items are one swipe
///   past the text, in the row's own container.
struct SelectionRow: View {
    @ObservedObject var controller: SelectionController
    var profile: ReadingProfile

    static let height: CGFloat = 48
    /// What each item draws, and the target it is.
    static let itemDrawnSide: CGFloat = 40
    static let itemTargetSide: CGFloat = 44
    /// The row's text grows to here and no further; past it the Large Content Viewer takes over.
    static let maximumDynamicTypeSize: DynamicTypeSize = .xxxLarge

    private var hitOutset: CGFloat { (Self.itemTargetSide - Self.itemDrawnSide) / 2 }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = Color(uiColor: theme.textColor)
        // The row's card draws in the page colour; its scheme follows the theme's chrome.
        let inks = PhoneInk(theme: theme, userInterfaceStyle: theme.usesDarkChrome ? .dark : .light)
        let chevron = inks.color(.chevron)
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if controller.showsHeadingLevels {
                        headingLevels
                    } else {
                        ForEach(controller.items, id: \.self) { item in
                            button(for: item, chevron: chevron, blue: inks.color(.lineformBlue))
                                .accessibilityShowsLargeContentViewer {
                                    if let symbol = item.systemImage { Image(systemName: symbol) }
                                    Text(item.title(aiName: controller.model.aiName))
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .id(controller.showsHeadingLevels)
            }
            .onChange(of: controller.showsHeadingLevels) { _, _ in
                // Each row starts at its leading edge.
                scroller.scrollTo(controller.showsHeadingLevels, anchor: .leading)
            }
        }
        .frame(height: Self.height)
        .foregroundStyle(ink)
        .floatingCardChrome(theme: theme, cornerRadius: Self.height / 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection.row")
        .onAppear { Self.announceAppearance() }
    }

    /// What VoiceOver hears when the row rises.
    static var appearanceAnnouncement: String {
        String(localized: "Formatting options available at the bottom of the screen.")
    }

    /// Whether the row has already told VoiceOver it is there in this app session. The row comes
    /// back on every settled selection; hearing the same sentence each time is noise.
    @MainActor static var didAnnounceThisSession = false

    /// Queues `appearanceAnnouncement` at low priority while VoiceOver runs, once per app session;
    /// returns whether it did. `post` is the system's announcement (replaced by the tests).
    @MainActor @discardableResult
    static func announceAppearance(
        isVoiceOverRunning: Bool = UIAccessibility.isVoiceOverRunning,
        post: @MainActor (AttributedString) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) -> Bool {
        guard isVoiceOverRunning, !didAnnounceThisSession else { return false }
        didAnnounceThisSession = true
        var announcement = AttributedString(appearanceAnnouncement)
        announcement.accessibilitySpeechAnnouncementPriority = .low
        post(announcement)
        return true
    }

    /// Heading's second row, in place of the buttons: ‹ back, then the Mac's Format ▸ Heading
    /// levels. A level applies (one undo step) and the buttons come back.
    @ViewBuilder
    private var headingLevels: some View {
        let back = String(localized: "Back")
        Button {
            controller.showHeadingLevels(false)
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .medium))
                .frame(minWidth: Self.itemDrawnSide, minHeight: Self.itemDrawnSide)
                .padding(hitOutset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-hitOutset)
        .accessibilityLabel(back)
        .accessibilityShowsLargeContentViewer {
            Image(systemName: "chevron.left")
            Text(back)
        }
        ForEach(SelectionController.headingLevels, id: \.title) { entry in
            Button {
                controller.setHeading(entry.level)
            } label: {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .dynamicTypeSize(...Self.maximumDynamicTypeSize)
                    .padding(.horizontal, 10)
                    .frame(minHeight: Self.itemDrawnSide)
                    .padding(hitOutset)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-hitOutset)
            .accessibilityShowsLargeContentViewer { Text(entry.title) }
        }
    }

    @ViewBuilder
    private func button(for item: SelectionRowItem, chevron: Color, blue: Color) -> some View {
        let title = item.title(aiName: controller.model.aiName)
        switch item {
        case .list:
            Menu {
                Button(String(localized: "Bulleted List")) { controller.applyList(ordered: false) }
                Button(String(localized: "Numbered List")) { controller.applyList(ordered: true) }
            } label: {
                icon(item, chevron: chevron, chevronSymbol: "chevron.down")
            }
            .padding(-hitOutset)
            .accessibilityLabel(title)
        case .image:
            // Add a picture without pasting: Photos (no library permission: the system picker) or
            // Files, both through the paste path.
            Menu {
                Button(String(localized: "Photos"), systemImage: "photo.on.rectangle") { controller.pickImage(from: .photos) }
                Button(String(localized: "Files"), systemImage: "folder") { controller.pickImage(from: .files) }
            } label: {
                icon(item, chevron: chevron, chevronSymbol: "chevron.down")
            }
            .padding(-hitOutset)
            .accessibilityLabel(title)
        case .askAI:
            // Ask, in Lineform blue (§21 "A · Native row"); VoiceOver hears the AI's name.
            Button {
                controller.perform(item)
            } label: {
                textLabel(item, title: SelectionRowItem.askShortTitle)
                    .foregroundStyle(blue)
            }
            .buttonStyle(.plain)
            .padding(-hitOutset)
            .accessibilityLabel(title)
        default:
            Button {
                controller.perform(item)
            } label: {
                if item.systemImage == nil {
                    textLabel(item, title: title)
                } else if item == .heading {
                    // Opens the levels in place: a drill-in chevron, never a menu.
                    icon(item, chevron: chevron, chevronSymbol: "chevron.right")
                } else {
                    icon(item, chevron: nil, chevronSymbol: nil)
                }
            }
            .buttonStyle(.plain)
            .padding(-hitOutset)
            .accessibilityLabel(title)
        }
    }

    /// A glyph (fixed size, like a toolbar's) drawn in 40 pt and padded out to a 44 pt target.
    private func icon(_ item: SelectionRowItem, chevron: Color?, chevronSymbol: String?) -> some View {
        HStack(spacing: 2) {
            Image(systemName: item.systemImage ?? "questionmark")
                .font(.system(size: 16, weight: .medium))
            if let chevron, let chevronSymbol {
                Image(systemName: chevronSymbol)
                    .font(.system(size: 9, weight: .semibold))
                    // A non-text mark, measured by `PhoneInkContrastTests` (3:1).
                    .foregroundStyle(chevron)
            }
        }
        .frame(minWidth: Self.itemDrawnSide, minHeight: Self.itemDrawnSide)
        .padding(hitOutset)
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
                // Only the text is capped: the Large Content Viewer outside it still sees the
                // writer's own text size.
                .dynamicTypeSize(...Self.maximumDynamicTypeSize)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: Self.itemDrawnSide)
        .padding(hitOutset)
        .contentShape(Rectangle())
    }
}

/// Everything the selection puts at the bottom of the page: the row or the comment field. (The
/// AI's requests, replies and decisions live in the AI sheet, `AISheetView`.) It ignores the keyboard's safe area and places itself from the keyboard's frame
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
