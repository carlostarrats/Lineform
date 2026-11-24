import Combine
import LineformCore
import SwiftUI
import UIKit

/// The format row (spec §5.5; the owner's mockup "A · Native row", `selection.html`, 2026-11-24):
/// a full-width bar docked DIRECTLY on top of the software keyboard, in the keyboard's own
/// colour, 48 pt tall, scrolling sideways. No capsule, no rounded pill, no shadow, no gap.
///
/// It is the editor's `inputAccessoryView` (`FormatBarAccessoryView`, a `.keyboard` `UIInputView`),
/// so UIKit keeps it on the keyboard through every keyboard motion, the interactive swipe-down
/// included, and draws it in the keyboard's colour in light and dark. Its height is 48 pt while
/// the row shows (`SelectionController.phase == .row`) and 0 otherwise. With a hardware keyboard
/// UIKit puts it above the home indicator, where a selection's row always sat.
///
/// Contents, in order: Ask (sparkle, Lineform blue; only while an AI is connected) and a thin
/// separator; Heading ›; B, I, S; Code, List, Link, Quote; Image, Table, Reformat Table (a table
/// row only), Replace With… and Another Word (a selection only); Check Spelling last (the one
/// whole-document spelling pass, `checkDocumentNow`). Heading opens its levels in place (‹ back);
/// List and Image open a menu; every other button runs its command at once (one undo step).
///
/// Accessibility:
/// - **Text size.** The row is chrome of a fixed height, like a toolbar: its text stops growing at
///   `maximumDynamicTypeSize` and, as in the system's bars, every item shows the Large Content
///   Viewer at the accessibility sizes (touch and hold).
/// - **Targets.** Each item draws 36 pt tall (the mockup's key) but is a 44 pt target: the extra
///   is taken back with negative padding, so the row looks as drawn.
/// - **VoiceOver and Voice Control.** Each item's label names the command ("Insert Table", "Ask
///   Claude"); its input labels include the word on the key ("Table", "Ask"). The first time the
///   row appears in a session (with VoiceOver on), a low-priority announcement says so.
struct SelectionRow: View {
    @ObservedObject var controller: SelectionController
    var profile: ReadingProfile

    static let height: CGFloat = 48
    /// What each item draws (the mockup's 36 pt key; at least 40 pt wide), and the target it is.
    static let itemDrawnHeight: CGFloat = 36
    static let itemDrawnSide: CGFloat = 40
    static let itemTargetSide: CGFloat = 44
    /// The row's text grows to here and no further; past it the Large Content Viewer takes over.
    static let maximumDynamicTypeSize: DynamicTypeSize = .xxxLarge

    private var verticalOutset: CGFloat { (Self.itemTargetSide - Self.itemDrawnHeight) / 2 }
    private var horizontalOutset: CGFloat { (Self.itemTargetSide - Self.itemDrawnSide) / 2 }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let isDark = theme.usesDarkChrome
        // The row sits on the keyboard (system-coloured), so its ink is the system's label colour
        // for the keyboard's appearance; Ask keeps Lineform blue.
        let inks = PhoneInk(theme: theme, userInterfaceStyle: isDark ? .dark : .light)
        let blue = inks.color(.lineformBlue)
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if controller.showsHeadingLevels {
                        headingLevels
                    } else {
                        ForEach(controller.items, id: \.self) { item in
                            if item == .heading, controller.items.first == .askAI {
                                separator(isDark: isDark)
                            }
                            button(for: item, blue: blue)
                                .accessibilityShowsLargeContentViewer {
                                    if let symbol = item.largeContentSymbol { Image(systemName: symbol) }
                                    Text(item.title(aiName: controller.model.aiName))
                                }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .id(controller.showsHeadingLevels)
            }
            .onChange(of: controller.showsHeadingLevels) { _, _ in
                // Each row starts at its leading edge.
                scroller.scrollTo(controller.showsHeadingLevels, anchor: .leading)
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .buttonStyle(FormatKeyStyle(isDark: isDark))
        .foregroundStyle(Color(uiColor: .label))
        .environment(\.colorScheme, isDark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Format"))
        .accessibilityIdentifier("selection.row")
        .onAppear { Self.announceAppearance() }
    }

    /// The thin line after Ask.
    private func separator(isDark: Bool) -> some View {
        Rectangle()
            .fill(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
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

    /// Heading's second row, in place of the buttons: ‹ back, then the Mac's Format ▸ Heading
    /// levels. A level applies (one undo step) and the buttons come back.
    @ViewBuilder
    private var headingLevels: some View {
        let back = String(localized: "Back")
        Button {
            controller.showHeadingLevels(false)
        } label: {
            key {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
            }
        }
        .padding(.vertical, -verticalOutset)
        .padding(.horizontal, -horizontalOutset)
        .accessibilityLabel(back)
        .accessibilityShowsLargeContentViewer {
            Image(systemName: "chevron.left")
            Text(back)
        }
        ForEach(SelectionController.headingLevels, id: \.title) { entry in
            Button {
                controller.setHeading(entry.level)
            } label: {
                key { word(entry.title) }
            }
            .padding(.vertical, -verticalOutset)
            .padding(.horizontal, -horizontalOutset)
            .accessibilityShowsLargeContentViewer { Text(entry.title) }
        }
    }

    @ViewBuilder
    private func button(for item: SelectionRowItem, blue: Color) -> some View {
        let title = item.title(aiName: controller.model.aiName)
        Group {
            switch item {
            case .list:
                Menu {
                    Button(String(localized: "Bulleted List")) { controller.applyList(ordered: false) }
                    Button(String(localized: "Numbered List")) { controller.applyList(ordered: true) }
                } label: {
                    key { label(for: item, blue: blue) }
                }
                .menuStyle(.button)
            case .image:
                // Add a picture without pasting: Photos (no library permission: the system picker)
                // or Files, both through the paste path.
                Menu {
                    Button(String(localized: "Photos"), systemImage: "photo.on.rectangle") { controller.pickImage(from: .photos) }
                    Button(String(localized: "Files"), systemImage: "folder") { controller.pickImage(from: .files) }
                } label: {
                    key { label(for: item, blue: blue) }
                }
                .menuStyle(.button)
            default:
                Button {
                    controller.perform(item)
                } label: {
                    key { label(for: item, blue: blue) }
                }
            }
        }
        .padding(.vertical, -verticalOutset)
        .padding(.horizontal, -horizontalOutset)
        .accessibilityLabel(title)
        .accessibilityInputLabels([Text(title), Text(item.keyText)])
    }

    /// One key: drawn 36 pt tall and at least 40 wide, padded out to a 44 pt target.
    private func key<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .frame(minWidth: Self.itemDrawnSide, minHeight: Self.itemDrawnHeight)
            .contentShape(Rectangle())
            .padding(.vertical, verticalOutset)
            .padding(.horizontal, horizontalOutset)
            .contentShape(Rectangle())
    }

    /// The key's face, as in the mockup: Ask with its sparkle in blue, Heading with a small
    /// chevron, B I S drawn as their styles, Code in monospace, the rest as words.
    @ViewBuilder
    private func label(for item: SelectionRowItem, blue: Color) -> some View {
        switch item {
        case .askAI:
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .semibold))
                word(SelectionRowItem.askShortTitle, weight: .semibold)
            }
            .foregroundStyle(blue)
        case .heading:
            HStack(spacing: 6) {
                word(item.keyText)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
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
        case .code:
            Text(item.keyText)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1)
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

/// A key of the format row: no fill at rest; while pressed, the keyboard's key colour on an 8 pt
/// rounded rectangle (the mockup's `.bar button:active`).
private struct FormatKeyStyle: ButtonStyle {
    var isDark: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDark ? Color(white: 0.353) : Color.white)
                    .padding(.vertical, (SelectionRow.itemTargetSide - SelectionRow.itemDrawnHeight) / 2)
                    .padding(.horizontal, (SelectionRow.itemTargetSide - SelectionRow.itemDrawnSide) / 2)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
    }
}

/// The format row's home: the editor's input accessory view, so it moves with the keyboard, the
/// interactive swipe-down included. 48 pt tall while the row shows, 0 otherwise (nothing is drawn,
/// and the keyboard's frame is the keyboard's alone).
///
/// iOS 26's keyboard is a floating panel with rounded top corners, and a `.keyboard` input view
/// no longer draws the keyboard's colour. So the bar fills itself with that colour
/// (`keyboardColor`, sampled from the system keyboard over the page in light and dark), sits on
/// the accessory's bottom edge (UIKit leaves the accessory a little taller than asked), and its
/// fill runs on under the keyboard's top edge, filling the corners the keyboard rounds off: the
/// bar and the keyboard read as one block, as in the mockup.
final class FormatBarAccessoryView: UIInputView {
    /// The reading profile the row draws for (`SelectionController.showRowNow` sets it).
    final class Style: ObservableObject {
        @Published var profile: ReadingProfile = .original
    }

    /// The system keyboard's colour over a Lineform page (iOS 26): light #E2E4E8, dark #212122.
    static func keyboardColor(isDark: Bool) -> UIColor {
        isDark
            ? UIColor(red: 0x21 / 255, green: 0x21 / 255, blue: 0x22 / 255, alpha: 1)
            : UIColor(red: 0xE2 / 255, green: 0xE4 / 255, blue: 0xE8 / 255, alpha: 1)
    }

    /// How far the fill runs on under the keyboard's top edge (past its rounded corners).
    static let fillOverlap: CGFloat = 44

    let style = Style()
    private let host: UIHostingController<FormatBarContent>
    private let fill = UIView()
    private var phaseObservation: AnyCancellable?
    private var styleObservation: AnyCancellable?
    /// The row shows: the view is `SelectionRow.height` tall.
    private(set) var isShowing = false

    init(controller: SelectionController) {
        host = UIHostingController(rootView: FormatBarContent(controller: controller, style: style))
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 0), inputViewStyle: .default)
        allowsSelfSizing = true
        autoresizingMask = .flexibleHeight
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        clipsToBounds = false
        fill.isHidden = true
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)
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
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        fill.backgroundColor = Self.keyboardColor(isDark: Theme.theme(for: profile).usesDarkChrome)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: isShowing ? SelectionRow.height : 0)
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
