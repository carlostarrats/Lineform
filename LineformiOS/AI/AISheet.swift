import LineformCore
import SwiftUI
import UIKit

/// The iPhone's AI card (owner, 2026-11-26, `Lineform-mobile/docs/mockups/popover-and-split.html`):
/// the Mac drawer's conversation (`AIConversationView`) in the lower card of a split. Ask opens
/// it; the page becomes the top card, the chat the bottom one, on a black seam, and the two melt
/// apart only while they move (`AISplit`). The grabber is the only control: drag it up to a full
/// sheet, down to close. There is no ✕ and no title. It cannot close while a request runs or a
/// suggestion waits for Accept or Reject (those live only here: closing then would leave the
/// read-only review with no way out). The conversation lives in `SelectionController.conversation`,
/// so closing keeps it until another document replaces this one. Thumb-sized targets
/// (`AIConversationMetrics`).
///
/// The card draws on its own surface, never the page (owner review 4, the approved prompt-words
/// mockup's `--chrome`): #FDFDFD on a light theme, #262626 on a dark one. The AI's bubble keeps the
/// page colour, so it reads as a card on the surface. Every ink is measured on both (`Inks`).
struct AISheetView: View {
    @ObservedObject var conversation: AIConversation
    let profile: ReadingProfile
    /// The writer is typing to the AI: the choices go and the box is the tall one.
    var isTyping = false
    /// The input area's height, for the card's height while typing.
    var onInputAreaHeight: (CGFloat) -> Void = { _ in }

    /// The surface on a light theme: the mockup's `--chrome` (#FDFDFD).
    static let lightSurface = UIColor(red: 0xFD / 255, green: 0xFD / 255, blue: 0xFD / 255, alpha: 1)
    /// The surface on a dark theme: the mockup's Quiet `--chrome` (#262626), a step apart from
    /// every dark page (Quiet's #303030 above it, Night's and the high-contrast black below).
    static let darkSurface = UIColor(red: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1)

    static func surface(for theme: Theme) -> UIColor {
        theme.usesDarkChrome ? darkSurface : lightSurface
    }

    /// A request is running or a suggestion waits for a decision: the card cannot be closed.
    static func locksDismissal(_ conversation: AIConversation) -> Bool {
        conversation.isWorking || conversation.pendingSuggestion != nil
    }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let inks = Inks(theme: theme)
        AIConversationView(
            conversation: conversation,
            style: AIConversationStyle(surface: Color(uiColor: inks.surface), page: Color(uiColor: inks.page),
                                       ink: Color(uiColor: inks.primary), secondaryInk: Color(uiColor: inks.secondary),
                                       isDark: theme.usesDarkChrome),
            onClose: nil,
            phoneLayout: AIPhoneLayout(isTyping: isTyping, onInputAreaHeight: onInputAreaHeight)
        )
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
    }
}

// MARK: - The split

/// The split's numbers: the mockup's, at its defaults.
enum AISplitMetrics {
    /// The card's inset from the screen's sides and bottom (the seam around it).
    static let inset: CGFloat = 6
    /// The seam between the page and the card once they have pulled apart.
    static let gap: CGFloat = 16
    /// The cards' corner radius.
    static let radius: CGFloat = 34
    /// The sheet's top, from the top of the screen.
    static let sheetTop: CGFloat = 58
    /// The card's height when it starts and ends (behind the keyboard or off the bottom).
    static let pill: CGFloat = 44
    /// The grabber strip; shorter while typing, when the input area's own 8 pt top padding makes
    /// the box sit 14 pt under the card's top, as it does at its sides and above the keyboard.
    static let head: CGFloat = 30
    static let typingHead: CGFloat = 6
    /// While typing in a conversation, this much of its end stays in view above the box, with the
    /// same 14 pt between them as around the box.
    static let typingTalk: CGFloat = 150 + 14
    /// How much of the screen the page keeps in the split.
    static let pageShare: CGFloat = 0.52
    /// The seam (owner's pick, 2026-11-26: black in every theme). The darker grey the owner also
    /// liked is kept as the fallback: #D9DADD on a light theme, #141414 on a dark one.
    static let seam = Color.black
    static let fallbackSeamLight = UIColor(red: 0xD9 / 255, green: 0xDA / 255, blue: 0xDD / 255, alpha: 1)
    static let fallbackSeamDark = UIColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1)

    static func split(screenHeight: CGFloat) -> CGFloat { (screenHeight * (1 - pageShare)).rounded() }
    static func sheet(screenHeight: CGFloat) -> CGFloat { screenHeight - sheetTop - inset }

    /// The card's height while typing: the grabber strip, the end of the conversation (when there
    /// is one), the input area, and the keyboard less the card's own inset, never above the sheet.
    static func typing(inputArea: CGFloat, keyboard: CGFloat, hasTalk: Bool, screenHeight: CGFloat) -> CGFloat {
        let height = typingHead + (hasTalk ? typingTalk : 0) + inputArea + max(0, keyboard - inset)
        return min(height, sheet(screenHeight: screenHeight))
    }

    /// The closest rest to `projected` for a drag released there: closed, split or sheet.
    static func snap(_ projected: CGFloat, screenHeight: CGFloat) -> CGFloat {
        [pill, split(screenHeight: screenHeight), sheet(screenHeight: screenHeight)]
            .min { abs($0 - projected) < abs($1 - projected) } ?? pill
    }

    /// The card's motion (the mockup's spring: about a third of a second, barely any bounce).
    static func motion(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 2 * .pi / (320).squareRoot(), dampingFraction: 0.81)
    }

    static func smooth(_ t: CGFloat) -> CGFloat {
        let e = min(max(t, 0), 1)
        return e * e * (3 - 2 * e)
    }

    /// How far the card has opened, 0 (closed) to 1 (its full height), eased.
    static func opened(_ height: CGFloat) -> CGFloat { smooth((height - pill) / 180) }

    /// How far it has gone from the split towards the sheet, eased.
    static func sheetness(_ height: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let split = split(screenHeight: screenHeight)
        return smooth((height - split) / max(1, sheet(screenHeight: screenHeight) - split))
    }
}

/// The document screen as the split's top card and the AI card under it. `SelectionController.
/// isShowingAISheet` opens and closes it; the card's height follows the grabber, the keyboard
/// while the writer types to the AI, and the rests (split, sheet). The page itself is never
/// resized (it is only scaled, and its corners covered, never clipped: a clip breaks the
/// editor's safe-area inset), so its text never re-lays out.
struct AISplit: ViewModifier {
    @ObservedObject var selection: SelectionController
    @ObservedObject var conversation: AIConversation
    let profile: ReadingProfile
    let reduceMotion: Bool

    /// The card's height (0: none).
    @State private var height: CGFloat = 0
    /// Where it rests when the writer is not typing: the split or the sheet.
    @State private var rest: CGFloat = 0
    @State private var screen = CGSize(width: 402, height: 874)
    @State private var outsets = EdgeInsets()
    /// The keyboard's overlap with the bottom of the screen.
    @State private var keyboard: CGFloat = 0
    @State private var inputArea: CGFloat = 0
    @State private var dragStart: CGFloat?
    /// The page had the keyboard when Ask opened the card: it gets it back when the card closes.
    @State private var editorHadKeyboard = false

    private var isTyping: Bool {
        selection.isShowingAISheet && keyboard > 0 && selection.editor?.isFirstResponder != true
    }

    func body(content: Content) -> some View {
        let theme = Theme.theme(for: profile)
        content
            .modifier(AISplitLayout(
                height: height,
                screen: screen,
                outsets: outsets,
                keyboard: isTyping ? keyboard : 0,
                isTyping: isTyping,
                pageColor: Color(uiColor: theme.backgroundColor),
                cardColor: Color(uiColor: AISheetView.surface(for: theme)),
                card: AnyView(card),
                head: AnyView(head)
            ))
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                       height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
            } action: { screen = $0 }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { outsets = $0 }
            .onChange(of: selection.isShowingAISheet) { _, showing in
                showing ? open() : close()
            }
            .onAppear { if selection.isShowingAISheet { open() } }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                keyboardChanged(to: Self.keyboardOverlap(from: note))
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardChanged(to: 0)
            }
            .onChange(of: inputArea) {
                // The box grew or shrank while typing: the card follows at once.
                if isTyping, dragStart == nil { height = typingHeight }
            }
            .onChange(of: conversation.hasStarted) {
                if isTyping, dragStart == nil { animate(to: typingHeight) }
            }
    }

    // MARK: Parts

    private var card: some View {
        AISheetView(conversation: conversation, profile: profile, isTyping: isTyping,
                    onInputAreaHeight: { inputArea = $0 })
    }

    /// The grabber strip: drag up to the sheet, down to close (or back to the split while a
    /// decision waits).
    private var head: some View {
        let theme = Theme.theme(for: profile)
        return ZStack(alignment: .top) {
            Color.clear
            Capsule()
                .fill(Color(uiColor: theme.usesDarkChrome ? UIColor(white: 1, alpha: 0.28) : UIColor(white: 0, alpha: 0.18)))
                .frame(width: 36, height: 5)
                .padding(.top, isTyping ? 5 : 9)
        }
        .frame(height: isTyping ? AISplitMetrics.typingHead : AISplitMetrics.head)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = height
                        // A drag ends typing: the keyboard goes and the card follows the finger.
                        if isTyping { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    }
                    let sheet = AISplitMetrics.sheet(screenHeight: screen.height)
                    var next = (dragStart ?? height) - value.translation.height
                    if next > sheet { next = sheet + (next - sheet) * 0.2 }
                    if next < AISplitMetrics.pill { next = AISplitMetrics.pill - (AISplitMetrics.pill - next) * 0.2 }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { height = next }
                }
                .onEnded { value in
                    dragStart = nil
                    let velocity = value.velocity.height
                    let target = AISplitMetrics.snap(height - velocity * 0.2, screenHeight: screen.height)
                    if target <= AISplitMetrics.pill {
                        if AISheetView.locksDismissal(conversation) {
                            rest = AISplitMetrics.split(screenHeight: screen.height)
                            animate(to: rest)
                        } else {
                            selection.isShowingAISheet = false
                        }
                    } else {
                        rest = target
                        animate(to: target)
                    }
                }
        )
        .accessibilityElement()
        .accessibilityLabel(String(localized: "AI conversation"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Drag up for more room or down to close"))
        .accessibilityAction(named: String(localized: "Close")) {
            if !AISheetView.locksDismissal(conversation) { selection.isShowingAISheet = false }
        }
        .accessibilityAction(named: String(localized: "More room")) {
            rest = AISplitMetrics.sheet(screenHeight: screen.height)
            animate(to: rest)
        }
    }

    // MARK: Moves

    private var typingHeight: CGFloat {
        AISplitMetrics.typing(inputArea: inputArea, keyboard: keyboard,
                              hasTalk: conversation.hasStarted, screenHeight: screen.height)
    }

    private func animate(to target: CGFloat, completion: (() -> Void)? = nil) {
        if let animation = AISplitMetrics.motion(reduceMotion: reduceMotion) {
            withAnimation(animation) { height = target } completion: { completion?() }
        } else {
            height = target
            completion?()
        }
        reportTop(for: target)
    }

    /// Ask: the keyboard goes down while the card grows into the split.
    private func open() {
        // Only the writer's Ask puts the keyboard away. A request or review that brings the card
        // back leaves the focus alone: the review overlay records whether the editor had it and
        // hands it back when the review ends.
        if selection.aiController.state == .idle {
            editorHadKeyboard = selection.editor?.isFirstResponder == true
            selection.editor?.resignFirstResponder()
        } else {
            editorHadKeyboard = false
        }
        rest = AISplitMetrics.split(screenHeight: screen.height)
        if height < AISplitMetrics.pill {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { height = AISplitMetrics.pill }
        }
        animate(to: rest)
    }

    private func close() {
        if isTyping { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        // Opened from the format row: the keyboard (and the row) come back as the card goes.
        // Taking the focus scrolls to the caret (after a review, at the change's end): the page
        // stays where the writer left it.
        if editorHadKeyboard, let editor = selection.editor, editor.window != nil {
            let restored = editor.contentOffset
            editor.becomeFirstResponder()
            AIReviewOverlay.holdOffset(restored, of: editor)
        }
        editorHadKeyboard = false
        animate(to: AISplitMetrics.pill) {
            guard !selection.isShowingAISheet else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { height = 0 }
        }
        selection.aiCardTopInWindow = .infinity
    }

    private func keyboardChanged(to overlap: CGFloat) {
        guard overlap != keyboard else { return }
        keyboard = overlap
        guard selection.isShowingAISheet, dragStart == nil else { return }
        if selection.editor?.isFirstResponder == true {
            // The page took the keyboard: the card makes way, unless a decision waits in it.
            if overlap > 0, !AISheetView.locksDismissal(conversation) { selection.isShowingAISheet = false }
            return
        }
        // Typing to the AI: the card sinks onto the keyboard; done typing, it goes back to rest.
        animate(to: overlap > 0 ? typingHeight : rest)
    }

    /// The review overlay keeps the current change above the card's top.
    private func reportTop(for target: CGFloat) {
        selection.aiCardTopInWindow = selection.isShowingAISheet && target > AISplitMetrics.pill
            ? screen.height - AISplitMetrics.inset - target
            : .infinity
    }

    /// The keyboard's overlap with the bottom of the key window, from a frame notification.
    static func keyboardOverlap(from note: Notification) -> CGFloat {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow)
        else { return 0 }
        return max(0, window.bounds.maxY - window.convert(frame, from: window.screen.coordinateSpace).minY)
    }
}

/// The split drawn at one card height (animatable, so every frame is laid out from the height,
/// as the mockup's spring does): the page clipped above the card (and, towards the sheet, scaled
/// back and dimmed), the card, the black seam behind both, and the melt between them while they
/// pull apart.
private struct AISplitLayout: ViewModifier, @preconcurrency Animatable {
    var height: CGFloat
    let screen: CGSize
    let outsets: EdgeInsets
    let keyboard: CGFloat
    let isTyping: Bool
    let pageColor: Color
    let cardColor: Color
    let card: AnyView
    let head: AnyView

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        let active = height > AISplitMetrics.pill + 0.5
        let w = screen.width, h = screen.height
        let inset = AISplitMetrics.inset
        let ee = AISplitMetrics.opened(height)
        let te = AISplitMetrics.sheetness(height, screenHeight: h)
        let cardHeight = AISplitMetrics.pill + (max(AISplitMetrics.pill, height) - AISplitMetrics.pill) * ee
        let cardTop = h - inset - cardHeight
        let cardRadius = 22 + (AISplitMetrics.radius - 22) * ee
        let gap = AISplitMetrics.gap * ee
        let splitPage = h + (cardTop - gap - h) * ee
        let pageHeight = max(110, splitPage + (h - splitPage) * te)
        let scale = 1 - 0.08 * te
        let shift = 14 * te
        let bottomRadius = AISplitMetrics.radius * ee
        let topRadius = 40 * te
        let melting = active && ee > 0.001 && ee < 0.999
        // The page on screen (scaled about its frame's centre, then moved down). It is never
        // clipped — a clip moves the editor's text up under the mode switch — so everything
        // outside it is covered by the seam instead.
        let centreY = outsets.top + (h - outsets.top - outsets.bottom) / 2
        let pageRect = CGRect(x: w * (1 - scale) / 2, y: centreY * (1 - scale) + shift,
                              width: w * scale, height: pageHeight * scale)
        let screenRect = CGRect(x: -20, y: -20, width: w + 40, height: h + 40)
        let pageShape = Path(roundedRect: pageRect, cornerRadii: RectangleCornerRadii(
            topLeading: topRadius, bottomLeading: bottomRadius, bottomTrailing: bottomRadius, topTrailing: topRadius
        ), style: .continuous)
        content
            .scaleEffect(scale, anchor: .center)
            .offset(y: shift)
            .overlay {
                if active {
                    ZStack {
                        // Dimmed towards the sheet.
                        pageShape.fill(Color.black.opacity(0.28 * te))
                        // The seam: everything but the page.
                        OutsidePage(screen: screenRect, page: pageShape)
                            .fill(AISplitMetrics.seam, style: FillStyle(eoFill: true))
                        if melting {
                            SplitMelt(pageRect: CGRect(x: 0, y: -40, width: w, height: pageHeight + 40),
                                      cardRect: CGRect(x: inset, y: cardTop, width: w - 2 * inset, height: cardHeight),
                                      pageColor: pageColor, cardColor: cardColor,
                                      pageRadius: bottomRadius, cardRadius: cardRadius)
                                .mask { OutsidePage(screen: screenRect, page: pageShape).fill(style: FillStyle(eoFill: true)) }
                        }
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .overlay {
                if active {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        VStack(spacing: 0) {
                            head
                            card
                                .opacity(Double(min(max((height - AISplitMetrics.pill - 60) / 120, 0), 1)))
                            Color.clear.frame(height: max(0, keyboard - inset))
                        }
                        .frame(width: w - 2 * inset, height: cardHeight, alignment: .top)
                        .background(cardColor)
                        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                        .offset(x: inset, y: cardTop)
                    }
                    .ignoresSafeArea()
                }
            }
    }
}

/// The screen with the page cut out of it (fill with the even-odd rule).
private struct OutsidePage: Shape {
    var screen: CGRect
    var page: Path

    func path(in _: CGRect) -> Path {
        var path = Path(screen)
        path.addPath(page)
        return path
    }
}

/// The liquid between the page and the card while they pull apart: both shapes blurred together
/// and their edges sharpened again, so a neck of colour stretches across the seam and snaps. Drawn
/// only while the cards move; at rest the edges are the cards' own, clean.
private struct SplitMelt: View {
    let pageRect: CGRect
    let cardRect: CGRect
    let pageColor: Color
    let cardColor: Color
    let pageRadius: CGFloat
    let cardRadius: CGFloat

    var body: some View {
        Canvas { context, _ in
            // Applied last to first: the blur spreads both shapes, the matrix makes the alpha a
            // hard edge again (colour kept).
            var sharpen = ColorMatrix()
            sharpen.a4 = 18
            sharpen.a5 = -8
            context.addFilter(.colorMatrix(sharpen))
            context.addFilter(.blur(radius: 9))
            context.drawLayer { layer in
                layer.fill(Path(roundedRect: pageRect, cornerRadius: pageRadius, style: .continuous), with: .color(pageColor))
                layer.fill(Path(roundedRect: cardRect, cornerRadius: cardRadius, style: .continuous), with: .color(cardColor))
            }
        }
    }
}

extension AISheetView {
    /// Every ink the sheet draws text with, made readable (AA) on the sheet's surface AND on the
    /// page-coloured AI bubble. `AISheetTests` measures `entries`.
    @MainActor
    struct Inks {
        let surface: UIColor
        /// The AI's bubble: the page colour (light), or the dark bubble's wash over the surface.
        let page: UIColor
        let primary: UIColor
        let secondary: UIColor

        /// The dark bubble as it lands (`AIConversationStyle.aiBubble`: white at 7.5% over the surface).
        static let darkBubbleWhiteAlpha: CGFloat = 0.075

        init(theme: Theme) {
            let style: UIUserInterfaceStyle = theme.usesDarkChrome ? .dark : .light
            var sheet = PhoneInk(theme: theme, userInterfaceStyle: style).theme
            let page = sheet.backgroundColor
            let surface = AISheetView.surface(for: sheet)
            sheet.backgroundColor = surface
            self.surface = surface
            self.page = page
            let bubble = sheet.usesDarkChrome
                ? PhoneInk.flatten(.white, alpha: Self.darkBubbleWhiteAlpha, over: surface)
                : page
            func readable(_ base: UIColor) -> UIColor {
                let onSurface = sheet.readableInk(base, minimumRatio: PhoneInk.Role.textMinimum)
                return sheet.readableInk(onSurface, minimumRatio: PhoneInk.Role.textMinimum, on: bubble)
            }
            primary = readable(sheet.textColor)
            secondary = readable(sheet.textColor.withAlphaComponent(0.6))
            bubbleSurface = bubble
        }

        /// The bubble's colour as measured.
        let bubbleSurface: UIColor

        var entries: [PhoneInk.Entry] {
            [
                PhoneInk.Entry(name: "primary", color: primary, surface: surface, minimumRatio: PhoneInk.Role.textMinimum),
                PhoneInk.Entry(name: "secondary", color: secondary, surface: surface, minimumRatio: PhoneInk.Role.textMinimum),
                PhoneInk.Entry(name: "primaryOnBubble", color: primary, surface: bubbleSurface, minimumRatio: PhoneInk.Role.textMinimum),
                PhoneInk.Entry(name: "secondaryOnBubble", color: secondary, surface: bubbleSurface,
                               minimumRatio: PhoneInk.Role.textMinimum),
            ]
        }
    }
}
