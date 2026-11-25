import Combine
import LineformCore
import SwiftUI
import UIKit

/// The format row (spec §5.5; the owner's chosen mockup, option 1 "Native bar, done right",
/// `Lineform-mobile/docs/mockups/format-row-options.html`, its `.b1` CSS, 2026-11-24): a
/// full-width bar docked DIRECTLY on top of the software keyboard, in the keyboard's own colour,
/// 50 pt tall, scrolling sideways, with a 1 pt hairline along its bottom edge.
///
/// It is the editor's `inputAccessoryView` (`FormatBarAccessoryView`, a `.keyboard` `UIInputView`),
/// so UIKit keeps it on the keyboard through every keyboard motion, the interactive swipe-down
/// included. Its height is 50 pt while the row shows (`SelectionController.phase == .row`) and 0
/// otherwise. With a hardware keyboard UIKit puts it above the home indicator.
///
/// The look, value for value from the mockup: 8 pt side padding, 4 pt between items. Every command
/// is its own light chip (36 pt tall, 8 pt corners, white at 55% on the light keyboard and 12% on
/// the dark one, 12 pt side padding, 15 pt text), so the commands never run together. Ask
/// (sparkle and "Ask" in Lineform blue, semibold, no chip; only while an AI is connected), then a
/// 1 × 24 pt divider (18% ink), then Heading ›, B, I (serif italic), S (struck), Code, List, Link,
/// Quote, Image, Table, Reformat Table (a table row only), Replace With… and Another Word (a
/// selection only), and Check Spelling last. Without an AI the row starts with Heading. Heading
/// opens its levels in place: a ‹ back button (no chip), then Title, Section, Heading 3,
/// Heading 4, Body as the same chips. Whenever the row appears afresh, or turns between a caret's
/// and a selection's row, it starts scrolled to its leading edge; a command that only changes its
/// buttons leaves it where it is.
///
/// Accessibility:
/// - **Text size.** The row is chrome of a fixed height, like a toolbar: its text stops growing at
///   `maximumDynamicTypeSize` and, as in the system's bars, every item shows the Large Content
///   Viewer at the accessibility sizes (touch and hold).
/// - **Targets.** Each chip draws 36 pt tall but its button is at least 44 × 44 pt: the button
///   is laid out at the chip's size and overflows it evenly (`ChipTargetLayout`), so the row looks
///   as drawn.
/// - **VoiceOver and Voice Control.** Each item's label names the command ("Insert Table", "Ask
///   Claude"); its input labels include the word on the key ("Table", "Ask"). The first time the
///   row appears in a session (with VoiceOver on), a low-priority announcement says so.
struct SelectionRow: View {
    @ObservedObject var controller: SelectionController
    var profile: ReadingProfile

    /// The mockup's `.b1` bar: 50 pt, 8 pt side padding, 4 pt between items.
    static let height: CGFloat = 50
    static let horizontalPadding: CGFloat = 8
    static let itemSpacing: CGFloat = 4
    /// The mockup's `.t` chip: 36 pt tall, 8 pt corners, 12 pt side padding, 15 pt text.
    static let itemDrawnHeight: CGFloat = 36
    static let chipCornerRadius: CGFloat = 8
    static let chipHorizontalPadding: CGFloat = 12
    static let fontSize: CGFloat = 15
    /// The chip's fill: white at 55% (light keyboard) or 12% (dark keyboard).
    static let chipOpacityLight: CGFloat = 0.55
    static let chipOpacityDark: CGFloat = 0.12
    /// The divider after Ask: 1 × 24 pt, ink at 18%, 4 pt either side (plus the item spacing).
    static let dividerSize = CGSize(width: 1, height: 24)
    static let dividerOpacity: CGFloat = 0.18
    /// The least each item's target is, whatever its chip draws.
    static let itemTargetSide: CGFloat = 44
    /// The row's text grows to here and no further; past it the Large Content Viewer takes over.
    static let maximumDynamicTypeSize: DynamicTypeSize = .xxxLarge

    /// The heading levels the row offers: the approved mockup's five, Title, Section, Heading 3,
    /// Heading 4 and Body (`format-row-options.html`, option 1). Heading 5 and 6 stay on a
    /// hardware keyboard's ⌘5 and ⌘6.
    static var rowHeadingLevels: [(level: Int?, title: String)] {
        SelectionController.headingLevels.filter { entry in
            guard let level = entry.level else { return true }
            return level <= 4
        }
    }

    /// What a fresh start of the row is keyed on: a new value rebuilds the scroll view at its
    /// leading edge. Only a fresh show, a switch between the caret's and a selection's row
    /// (`SelectionController.rowGeneration`) or the heading levels coming and going count; a
    /// command that only changes the buttons (Check Spelling, Link, Table) leaves the row where it
    /// is, so the next tap lands on the same button.
    private struct Contents: Hashable {
        var generation: Int
        var showsHeadingLevels: Bool
    }

    private static let leadingEdge = "selection.row.leading"

    var body: some View {
        let theme = Theme.theme(for: profile)
        let isDark = theme.usesDarkChrome
        // The row sits on the keyboard (system-coloured): the mockup's ink (#1F1F1F) on the light
        // keyboard, white on the dark one; Ask keeps Lineform blue.
        let inks = PhoneInk(theme: theme, userInterfaceStyle: isDark ? .dark : .light)
        let blue = inks.color(.lineformBlue)
        let ink = isDark ? Color.white : Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255)
        let contents = Contents(generation: controller.rowGeneration, showsHeadingLevels: controller.showsHeadingLevels)
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.itemSpacing) {
                    if controller.showsHeadingLevels {
                        headingLevels(isDark: isDark)
                    } else {
                        ForEach(controller.items, id: \.self) { item in
                            if item == .heading, controller.items.first == .askAI {
                                divider(isDark: isDark)
                            }
                            button(for: item, blue: blue, isDark: isDark)
                                .accessibilityShowsLargeContentViewer {
                                    if let symbol = item.largeContentSymbol { Image(systemName: symbol) }
                                    Text(item.title(aiName: controller.model.aiName))
                                }
                        }
                    }
                }
                .padding(.horizontal, Self.horizontalPadding)
                .frame(maxHeight: .infinity)
                .id(Self.leadingEdge)
            }
            // Only the first offset: as a size anchor it would pull the row back to its start
            // whenever a command adds or drops a button.
            .defaultScrollAnchor(.leading, for: .initialOffset)
            // A new set of items (or the heading levels) is a fresh scroll view, at its start.
            .id(contents)
            .onAppear { scrollToStart(scroller) }
            .onChange(of: contents) { _, _ in scrollToStart(scroller) }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            // The mockup's `border-bottom: 1px solid rgba(0,0,0,.08)`.
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .buttonStyle(FormatChipStyle())
        .foregroundStyle(ink)
        .environment(\.colorScheme, isDark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Format"))
        .accessibilityIdentifier("selection.row")
        .onAppear { Self.announceAppearance() }
    }

    /// Puts the row's leading edge at the bar's leading edge, now and once layout has settled.
    private func scrollToStart(_ scroller: ScrollViewProxy) {
        scroller.scrollTo(Self.leadingEdge, anchor: .leading)
        Task { @MainActor in scroller.scrollTo(Self.leadingEdge, anchor: .leading) }
    }

    /// The thin divider after Ask.
    private func divider(isDark: Bool) -> some View {
        Rectangle()
            .fill(isDark ? Color.white.opacity(Self.dividerOpacity) : Color.black.opacity(Self.dividerOpacity))
            .frame(width: Self.dividerSize.width, height: Self.dividerSize.height)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
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

    /// Heading's second row, in place of the buttons: ‹ back (no chip, the mockup's 36 pt
    /// `.back`), then the levels as chips. A level applies (one undo step) and the buttons come back.
    @ViewBuilder
    private func headingLevels(isDark: Bool) -> some View {
        let back = String(localized: "Back")
        ChipTargetLayout {
            Button {
                controller.showHeadingLevels(false)
            } label: {
                Image(systemName: "chevron.left")
                    // The mockup's 16 pt back glyph (an 8 pt tall chevron) in a 36 pt square.
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: Self.itemDrawnHeight, height: Self.itemDrawnHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityLabel(back)
        .accessibilityShowsLargeContentViewer {
            Image(systemName: "chevron.left")
            Text(back)
        }
        ForEach(Self.rowHeadingLevels, id: \.title) { entry in
            ChipTargetLayout {
                Button {
                    controller.setHeading(entry.level)
                } label: {
                    chip(isDark: isDark) { word(entry.title) }
                }
            }
            .accessibilityShowsLargeContentViewer { Text(entry.title) }
        }
    }

    @ViewBuilder
    private func button(for item: SelectionRowItem, blue: Color, isDark: Bool) -> some View {
        let title = item.title(aiName: controller.model.aiName)
        ChipTargetLayout {
            switch item {
            case .list:
                Menu {
                    Button(String(localized: "Bulleted List")) { controller.applyList(ordered: false) }
                    Button(String(localized: "Numbered List")) { controller.applyList(ordered: true) }
                } label: {
                    chip(isDark: isDark) { label(for: item, blue: blue) }
                }
                .menuStyle(.button)
            case .image:
                // Add a picture without pasting: Photos (no library permission: the system picker)
                // or Files, both through the paste path.
                Menu {
                    Button(String(localized: "Photos"), systemImage: "photo.on.rectangle") { controller.pickImage(from: .photos) }
                    Button(String(localized: "Files"), systemImage: "folder") { controller.pickImage(from: .files) }
                } label: {
                    chip(isDark: isDark) { label(for: item, blue: blue) }
                }
                .menuStyle(.button)
            case .askAI:
                // Ask has no chip (the mockup's `.t.ask`: transparent, 6 pt on its leading side).
                Button {
                    controller.perform(item)
                } label: {
                    chip(isDark: isDark, filled: false, leading: 6) { label(for: item, blue: blue) }
                }
            default:
                Button {
                    controller.perform(item)
                } label: {
                    chip(isDark: isDark) { label(for: item, blue: blue) }
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityInputLabels([Text(title), Text(item.keyText)])
    }

    /// One chip: 36 pt tall, 12 pt side padding, on an 8 pt rounded fill. The flexible frame
    /// around it takes the larger target `ChipTargetLayout` proposes, the chip centred in it.
    private func chip<Content: View>(isDark: Bool, filled: Bool = true, leading: CGFloat = chipHorizontalPadding,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.leading, leading)
            .padding(.trailing, Self.chipHorizontalPadding)
            .frame(minHeight: Self.itemDrawnHeight)
            .background {
                if filled {
                    RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(isDark ? Self.chipOpacityDark : Self.chipOpacityLight))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    /// The chip's face, as in the mockup: Ask with its sparkle in blue, Heading with a small
    /// chevron, B bold, I serif italic, S struck, the rest as words.
    @ViewBuilder
    private func label(for item: SelectionRowItem, blue: Color) -> some View {
        switch item {
        case .askAI:
            HStack(spacing: 5) {
                // The mockup's 15 pt sparkle box holds a 9 pt star.
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 15, height: 15)
                word(SelectionRowItem.askShortTitle, weight: .semibold)
            }
            .foregroundStyle(blue)
        case .heading:
            HStack(spacing: 5) {
                word(item.keyText)
                // The mockup's 11 pt chevron box.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 11, height: 11)
            }
        case .bold:
            word("B", weight: .bold)
        case .italic:
            Text(verbatim: "I")
                .font(.system(.subheadline, design: .serif).italic())
                .dynamicTypeSize(...Self.maximumDynamicTypeSize)
        case .strikethrough:
            Text(verbatim: "S")
                .font(.subheadline)
                .strikethrough()
                .dynamicTypeSize(...Self.maximumDynamicTypeSize)
        default:
            word(item.keyText)
        }
    }

    private func word(_ text: String, weight: Font.Weight = .regular) -> some View {
        Text(verbatim: text)
            .font(.subheadline.weight(weight))
            .lineLimit(1)
            .fixedSize()
            // Only the text is capped: the Large Content Viewer outside it still sees the
            // writer's own text size.
            .dynamicTypeSize(...Self.maximumDynamicTypeSize)
    }
}

/// Lays its one subview (an item's button) out at the size its chip draws, so the row's spacing
/// is the mockup's, but gives the button at least `SelectionRow.itemTargetSide` square, centred on
/// the chip: the target overflows the chip evenly and never moves it.
private struct ChipTargetLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(.unspecified) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let drawn = subview.sizeThatFits(.unspecified)
        let side = SelectionRow.itemTargetSide
        subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                      proposal: ProposedViewSize(width: max(drawn.width, side), height: max(drawn.height, side)))
    }
}

/// A chip of the format row while pressed: dimmed, as the system's bar buttons do.
private struct FormatChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
    }
}

/// The format row's home: the editor's input accessory view, so it moves with the keyboard, the
/// interactive swipe-down included. 50 pt tall while the row shows, 0 otherwise (nothing is drawn,
/// and the keyboard's frame is the keyboard's alone).
///
/// iOS 26's keyboard is a floating panel with rounded top corners, and a `.keyboard` input view
/// no longer draws the keyboard's colour. So the bar draws its own Liquid Glass (iOS 26, in the
/// theme's light or dark), sits at the accessory's top edge (above the home indicator with a
/// hardware keyboard), and its glass runs on under the keyboard's top edge, filling the corners
/// the keyboard rounds off: the bar and the keyboard read as one block, as in the mockup.
final class FormatBarAccessoryView: UIInputView {
    /// The reading profile the row draws for (`SelectionController.showRowNow` sets it).
    final class Style: ObservableObject {
        @Published var profile: ReadingProfile = .original
    }

    /// How far the glass runs on under the keyboard's top edge (past its rounded corners).
    static let fillOverlap: CGFloat = 44

    let style = Style()
    private weak var controller: SelectionController?
    private let host: UIHostingController<FormatBarContent>
    private let fill = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private var phaseObservation: AnyCancellable?
    private var styleObservation: AnyCancellable?
    /// The row shows: the view is `SelectionRow.height` tall.
    private(set) var isShowing = false

    init(controller: SelectionController) {
        host = UIHostingController(rootView: FormatBarContent(controller: controller, style: style))
        self.controller = controller
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 0), inputViewStyle: .default)
        allowsSelfSizing = true
        autoresizingMask = .flexibleHeight
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        clipsToBounds = false
        fill.isHidden = true
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)
        // The bar's SwiftUI content must never move for the keyboard or the home indicator: a
        // hosting controller inside the keyboard's accessory otherwise gets the keyboard's (and,
        // with a hardware keyboard, the home indicator's) safe area and shifts its chips up out of
        // the bar, where they were cut off and drawn over the text (owner review, 2026-11-24).
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.isHidden = true
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: Self.fillOverlap),
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.heightAnchor.constraint(equalToConstant: SelectionRow.height),
        ])
        applyColor(for: style.profile)
        phaseObservation = controller.$phase.sink { [weak self] phase in
            MainActor.assumeIsolated { self?.setShowing(phase == .row) }
        }
        styleObservation = style.$profile.sink { [weak self] profile in
            MainActor.assumeIsolated { self?.applyColor(for: profile) }
        }
    }

    private func applyColor(for profile: ReadingProfile) {
        fill.overrideUserInterfaceStyle = Theme.theme(for: profile).usesDarkChrome ? .dark : .light
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// With a hardware keyboard UIKit puts the accessory at the very bottom of the screen, over
    /// the home indicator: the bar grows by the bottom safe area so its chips sit above it. With
    /// the software keyboard it never does: during an interactive swipe-down the accessory
    /// reaches the bottom of the screen and takes the home indicator's inset mid-gesture, and
    /// adding it there made the bar jump by 34 pt under the finger.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric,
               height: isShowing ? SelectionRow.height + hardwareKeyboardInset : 0)
    }

    /// The bottom safe area, only while no software keyboard is up (a hardware keyboard alone).
    var hardwareKeyboardInset: CGFloat {
        let software = (controller?.keyboardOverlap ?? 0) >= SelectionController.minimumSoftwareKeyboardOverlap
        return software ? 0 : safeAreaInsets.bottom
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
    }

    private func setShowing(_ shows: Bool) {
        guard shows != isShowing else { return }
        isShowing = shows
        host.view.isHidden = !shows
        fill.isHidden = !shows
        invalidateIntrinsicContentSize()
    }
}

/// The accessory's SwiftUI content: the row, for the style's profile, while it shows.
struct FormatBarContent: View {
    @ObservedObject var controller: SelectionController
    @ObservedObject var style: FormatBarAccessoryView.Style

    var body: some View {
        if controller.phase == .row {
            SelectionRow(controller: controller, profile: style.profile)
        }
    }
}

/// What the selection puts at the bottom of the page besides the format row (which rides on the
/// keyboard as its accessory): the comment field. (The AI's requests, replies and decisions live
/// in the AI sheet, `AISheetView`.) It ignores the keyboard's safe area and places itself from the keyboard's frame
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
                case .hidden, .row:
                    // The row is the keyboard's accessory (`FormatBarAccessoryView`), never here.
                    EmptyView()
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
