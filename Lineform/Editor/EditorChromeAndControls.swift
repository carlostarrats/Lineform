import SwiftUI

struct EditorAuxiliaryPresentation: Equatable {
    enum Kind: Equatable {
        case nativeInspector
        case trailingDrawer
    }

    var kind: Kind
    var presenter: EditorAuxiliaryPresenter
    var accessibilityLabel: String
    var minimumWidth: CGFloat?
    var idealWidth: CGFloat?
    var maximumWidth: CGFloat?
    var transitionStyle: EditorAuxiliaryTransitionStyle
    var animationDuration: Double?

    static let readingExperience = EditorAuxiliaryPresentation(
        kind: .nativeInspector,
        presenter: .systemInspector,
        accessibilityLabel: String(localized: "Reading Experience Inspector"),
        minimumWidth: 280,
        idealWidth: 320,
        maximumWidth: 380,
        transitionStyle: .systemInspector,
        animationDuration: nil
    )
}

enum EditorAuxiliaryPresenter: Equatable {
    case systemInspector
    case customLayout
}

enum EditorAuxiliaryTransitionStyle: Equatable {
    case instant
    case systemInspector
    case slideAndFade
}

/// Shared visual language for Lineform's in-window "Muse-style" modal — the Settings
/// modal (`SettingsModal`): a light, theme-independent card with a title +
/// circular-close header, presented over a dimming scrim (`MuseModalScrim`).
/// Centralizing the chrome here keeps the modal's look stable and reusable.
enum MuseModalChrome {
    /// Theme-independent light-card palette (the card reads the same in dark mode).
    static let backgroundWhiteComponent: CGFloat = 0.98
    static let textRedComponent: CGFloat = 0.12
    static let secondaryTextOpacity: CGFloat = 0.74

    /// Card fill, straight from the Paper design: a vertical wash, light at the top falling
    /// to a barely-there step darker at the bottom. Values are the design's hex stops —
    /// do not "round" them, the whole effect lives in a ~10-value range.
    static let cardGradientTop = Color(red: 1.0, green: 1.0, blue: 1.0)             // #FFFFFF
    static let cardGradientBottom = Color(red: 0.945, green: 0.945, blue: 0.945)    // #F1F1F1
    static let cardGradientTopDark = Color(red: 0.192, green: 0.192, blue: 0.192)   // #313131
    static let cardGradientBottomDark = Color(red: 0.125, green: 0.125, blue: 0.125) // #202020

    /// Modal text. These mirror `OutlineSidebarView`'s components so the modal's dark text
    /// matches the rest of the dark chrome rather than inventing a second scale.
    static let darkPrimaryTextWhiteComponent: CGFloat = 0.90
    static let darkSecondaryTextWhiteComponent: CGFloat = 0.68

    /// 1pt stroke. This is ⌘K's outline, not the Paper card's `#F1F7FF` — the two modals
    /// must carry the SAME outline, and the cool white all but vanished against the field.
    static let cardStrokeColor = Color.black.opacity(0.08)
    /// ⌘K's dark-chrome counterpart, so the shared card can serve both appearances.
    static let cardStrokeColorDark = Color.white.opacity(0.14)

    /// Circular close-button fill: invisible at rest, a faint tint on hover.
    static let closeRestingFillOpacity = 0.0
    static let closeHoverFillOpacity = 0.08

    /// Card geometry + entrance motion (shared so both modals animate identically).
    static let cornerRadius: CGFloat = 20
    static let animationDuration = 0.24
    static let entranceYOffset: CGFloat = 10

    static var backgroundColor: Color {
        Color(nsColor: NSColor(calibratedWhite: backgroundWhiteComponent, alpha: 1))
    }

    /// The card's fill. `backgroundColor` stays as the flat token for any surface that
    /// needs a solid match; the CARD itself uses this wash.
    static func backgroundGradient(usesDarkChrome: Bool) -> LinearGradient {
        LinearGradient(
            colors: usesDarkChrome
                ? [cardGradientTopDark, cardGradientBottomDark]
                : [cardGradientTop, cardGradientBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// THREADED, never read from `@Environment(\.colorScheme)`. A nested modal control that
    /// reads the environment renders invisible text after a tab/inspector transition — the
    /// same failure the sidebar is documented against in `docs/architecture/files-sidebar.md`.
    static func primaryTextColor(usesDarkChrome: Bool) -> Color {
        if usesDarkChrome {
            return Color(nsColor: NSColor(calibratedWhite: darkPrimaryTextWhiteComponent, alpha: 1))
        }
        return Color(nsColor: NSColor(calibratedRed: textRedComponent, green: textRedComponent, blue: textRedComponent, alpha: 1))
    }

    static func secondaryTextColor(usesDarkChrome: Bool) -> Color {
        if usesDarkChrome {
            return Color(nsColor: NSColor(calibratedWhite: darkSecondaryTextWhiteComponent, alpha: 1))
        }
        return primaryTextColor(usesDarkChrome: false).opacity(secondaryTextOpacity)
    }
}

/// The shared header row for a Muse modal: a semibold title on the left and a
/// circular, Esc-bound close button on the right (invisible until hovered).
struct MuseModalHeader: View {
    var title: String
    var usesDarkChrome = false
    var dismiss: () -> Void
    @State private var isCloseHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome))

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome).opacity(isCloseHovered ? MuseModalChrome.closeHoverFillOpacity : MuseModalChrome.closeRestingFillOpacity))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .contentShape(Circle())
            .help("Close")
            .onHover { hovering in
                isCloseHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isCloseHovered)
        }
        // The card's `modalArrowCursor` is an `onContinuousHover`, and that stream stops
        // arriving over the close button — an AppKit-backed control swallows the mouse-moved
        // events — leaving the editor's I-beam standing on the one thing you click. This layer
        // tracks GEOMETRICALLY, so it keeps asserting the arrow over the button.
        // Deliberately scoped to the header, not the whole card: ⌘K's search field shares
        // MuseModalCard and must keep its I-beam.
        .background(CursorRectView(cursor: .arrow))
    }
}

/// The card container shared by EVERY Muse modal (Settings, ⌘K): inner padding, a
/// caller-sized width, the gradient background, rounded clip + hairline stroke, drop
/// shadow, and a pinned color scheme.
///
/// ⌘K used to hand-roll a copy of this recipe, which is exactly how the two modals drifted
/// apart. Both go through here now — a modal that needs different chrome should add a
/// parameter, not a second copy.
private struct MuseModalCard: ViewModifier {
    var width: CGFloat
    var accessibilityLabel: String
    /// ⌘K supplies its own per-section padding (search field, divider, list), so it opts out.
    var padding: CGFloat
    /// ⌘K tracks the theme; Settings is always light.
    var usesDarkChrome: Bool

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(width: width, alignment: .leading)
            .background(MuseModalChrome.backgroundGradient(usesDarkChrome: usesDarkChrome))
            .clipShape(RoundedRectangle(cornerRadius: MuseModalChrome.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MuseModalChrome.cornerRadius, style: .continuous)
                    .stroke(
                        usesDarkChrome ? MuseModalChrome.cardStrokeColorDark : MuseModalChrome.cardStrokeColor,
                        lineWidth: 1
                    )
            }
            // Much softer than the pre-design 0.16/28/14: the field is light now, so a heavy
            // shadow reads as dirt under the card rather than lift.
            .shadow(color: Color.black.opacity(0.07), radius: 18, x: 0, y: 8)
            .environment(\.colorScheme, usesDarkChrome ? .dark : .light)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
    }
}

extension View {
    func museModalCard(
        width: CGFloat,
        accessibilityLabel: String,
        padding: CGFloat = 24,
        usesDarkChrome: Bool = false
    ) -> some View {
        modifier(
            MuseModalCard(
                width: width,
                accessibilityLabel: accessibilityLabel,
                padding: padding,
                usesDarkChrome: usesDarkChrome
            )
        )
    }
}

/// The dimming, tap-to-dismiss scrim behind a Muse-style modal (Settings). Shared
/// chrome — the modal card is layered above it by `museModalLayer`.
struct MuseModalScrim: View {
    /// The scrim is a light ATMOSPHERIC FIELD, per the Paper design: a cool-white wash with
    /// two crossing diagonal grays, laid at `fieldOpacity` over a blur of the page. The
    /// blur is what makes the remaining 10% read as depth instead of as show-through
    /// clutter — drop it and the field looks merely dirty.
    static let scrimTransitionStyle = EditorAuxiliaryTransitionStyle.instant

    /// Mostly solid: the document survives only as a faint ghost.
    static let fieldOpacity: CGFloat = 0.90

    /// Base wash: light at the top settling into the faintest tint at the bottom (dark:
    /// near-black settling darker still).
    static let fieldGradientTop = Color(red: 1.0, green: 1.0, blue: 1.0)            // #FFFFFF
    static let fieldGradientBottom = Color(red: 0.945, green: 0.969, blue: 1.0)     // #F1F7FF
    static let fieldGradientTopDark = Color(red: 0.192, green: 0.188, blue: 0.188)  // #313030
    static let fieldGradientBottomDark = Color(red: 0.071, green: 0.071, blue: 0.071) // #121212

    /// Paper's warm counterpart to the cool default, and Calm's cool-green one. Both carry the
    /// SAME relative luminance as `fieldGradientBottom` (~0.966) and the same tint magnitude —
    /// only the hue moves, so the field never reads lighter or heavier when the theme changes.
    /// The tops step off pure white by roughly a quarter of the bottom's deviation: enough to
    /// carry the hue through the whole field, not enough to read as a color.
    ///
    /// These stops are the BASE wash, and only about 58% of their chroma survives to the
    /// screen: the two neutral diagonals composite to `0.64 × base`, then the whole field is
    /// laid at `fieldOpacity` 0.90 over the blurred page. So the separation between channels
    /// has to be authored WIDE. Calm's first pass put green only 3/255 above blue, which
    /// arrived on screen as ~1.7/255 — measurably not-blue, visibly nothing. Green now leads
    /// blue by 8, and red trails blue, so the tint reads as a cool mint rather than as gray.
    static let fieldGradientTopPaper = Color(red: 0.996, green: 0.992, blue: 0.980)  // #FEFDFA
    static let fieldGradientBottomPaper = Color(red: 0.984, green: 0.965, blue: 0.929) // #FBF6ED
    static let fieldGradientTopCalm = Color(red: 0.980, green: 0.996, blue: 0.988)  // #FAFEFC
    static let fieldGradientBottomCalm = Color(red: 0.925, green: 0.980, blue: 0.949) // #ECFAF2

    /// Which light-field hue a theme wears. Dark themes ignore this entirely — their field
    /// stays the near-black pair above.
    static func fieldGradientColors(for themeID: ThemeID, usesDarkChrome: Bool) -> [Color] {
        guard !usesDarkChrome else {
            return [fieldGradientTopDark, fieldGradientBottomDark]
        }

        switch themeID {
        case .paper:
            return [fieldGradientTopPaper, fieldGradientBottomPaper]
        case .calm:
            return [fieldGradientTopCalm, fieldGradientBottomCalm]
        case .system, .quiet, .night:
            return [fieldGradientTop, fieldGradientBottom]
        }
    }

    /// The two diagonal washes laid across the base, crossing each other. They are what
    /// keep the field from looking like a flat vertical ramp — the soft corner shading in
    /// the design comes entirely from their overlap.
    static let diagonalWashTop = Color(red: 0.957, green: 0.957, blue: 0.957)       // #F4F4F4
    static let diagonalWashBottom = Color(red: 0.835, green: 0.835, blue: 0.835)    // #D5D5D5
    static let diagonalWashTopDark = Color(red: 0.173, green: 0.173, blue: 0.173)   // #2C2C2C
    static let diagonalWashBottomDark = Color(red: 0.071, green: 0.071, blue: 0.071) // #121212
    static let diagonalWashOpacity: CGFloat = 0.20

    static func diagonalWash(startPoint: UnitPoint, endPoint: UnitPoint, usesDarkChrome: Bool) -> some View {
        LinearGradient(
            colors: usesDarkChrome
                ? [diagonalWashTopDark, diagonalWashBottomDark]
                : [diagonalWashTop, diagonalWashBottom],
            startPoint: startPoint,
            endPoint: endPoint
        )
        .opacity(diagonalWashOpacity)
        .allowsHitTesting(false)
    }

    /// THREADED from the theme by the presenting container, never read from the
    /// environment — see `MuseModalChrome.primaryTextColor(usesDarkChrome:)`.
    var usesDarkChrome = false
    /// Selects the light field's hue so the scrim sits with the reader theme rather than
    /// against it. Threaded alongside `usesDarkChrome`, for the same reason.
    var themeID: ThemeID = .system
    var dismiss: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: Self.fieldGradientColors(for: themeID, usesDarkChrome: usesDarkChrome),
                startPoint: .top,
                endPoint: .bottom
            )
            .overlay {
                Self.diagonalWash(startPoint: .topLeading, endPoint: .bottomTrailing, usesDarkChrome: usesDarkChrome)
            }
            .overlay {
                Self.diagonalWash(startPoint: .bottomLeading, endPoint: .topTrailing, usesDarkChrome: usesDarkChrome)
            }
            .opacity(Self.fieldOpacity)
            .background(MuseModalBackdropBlur(usesDarkChrome: usesDarkChrome))
            .contentShape(Rectangle())
            .onTapGesture {
                dismiss()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The editor's I-beam gets "stuck" when the modal covers the window (nothing over the
        // scrim resets it). Actively reassert the arrow as the pointer moves across the scrim.
        .modalArrowCursor()
    }
}

/// The within-window frost behind a Muse modal's dim: blurs the editor content the modal
/// covers, so the card reads as glass over the document rather than a panel on a gray field.
///
/// The within-window blur under the modal field. AppKit rather than SwiftUI's
/// `.ultraThinMaterial` so `withinWindow` blending is explicit (SwiftUI picks it
/// heuristically) and the appearance is PINNED — a dark reader theme must not flip the
/// blur's tint under a field that is always light.
struct MuseModalBackdropBlur: NSViewRepresentable {
    var usesDarkChrome = false

    /// Passes clicks through to the SwiftUI field above, which owns tap-to-dismiss.
    final class PassthroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Context-free so the configuration is assertable without a live SwiftUI update pass.
    static func makeBackdropView(usesDarkChrome: Bool) -> NSVisualEffectView {
        let view = PassthroughEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: appearanceName(usesDarkChrome: usesDarkChrome))
        return view
    }

    /// Matches the FIELD above it, not the window: a light blur under the dark field would
    /// glow through the 10% the field doesn't cover.
    static func appearanceName(usesDarkChrome: Bool) -> NSAppearance.Name {
        usesDarkChrome ? .darkAqua : .aqua
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        Self.makeBackdropView(usesDarkChrome: usesDarkChrome)
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // Re-assert after an appearance change; AppKit resets a pinned appearance when the
        // effective appearance flips under it (same failure mode as the window chrome).
        nsView.appearance = NSAppearance(named: Self.appearanceName(usesDarkChrome: usesDarkChrome))
    }
}

extension View {
    /// Actively sets the arrow cursor while the pointer moves within this view. Used on modal
    /// surfaces (scrim + card) so the editor's I-beam doesn't linger over them.
    func modalArrowCursor() -> some View {
        onContinuousHover { phase in
            if case .active = phase {
                NSCursor.arrow.set()
            }
        }
    }
}

/// The toolbar's principal mode control, self-adapting to window width: the wide segmented
/// control normally, the compact labeled menu below
/// `EditorToolbarCompactPresentation.compactModeControlThreshold`. The width observation and the
/// compact flag live HERE, in this small view, so a threshold crossing re-renders only this
/// control — putting that state on `EditorContainerView` re-rendered the whole editor mid-drag,
/// which visibly disturbed the editor's scroll anchoring.
struct EditorModePrincipalControl: View {
    @Binding var selection: EditorDisplayMode
    var windowNumber: Int?
    var usesDarkChrome = false
    var reduceMotion = false
    /// When set, the compact menu also carries a "Reading Experience" row — at compact widths the
    /// separate Aa toolbar button is hidden entirely (EditorReadingExperienceToolbarButton), so
    /// the native "»" overflow can only ever contain ONE uniform native menu item.
    var openReadingExperience: (() -> Void)?

    @State private var usesCompactControl = false

    var body: some View {
        Group {
            if usesCompactControl {
                EditorModeCompactMenu(
                    selection: $selection,
                    usesDarkChrome: usesDarkChrome,
                    openReadingExperience: openReadingExperience
                )
            } else {
                EditorModeSegmentedControl(
                    selection: $selection,
                    usesDarkChrome: usesDarkChrome,
                    reduceMotion: reduceMotion
                )
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: windowNumber) { _, _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard (notification.object as? NSWindow)?.windowNumber == windowNumber else {
                return
            }
            refresh()
        }
    }

    private func refresh() {
        guard
            let windowNumber,
            let window = NSApp.windows.first(where: { $0.windowNumber == windowNumber })
        else {
            return
        }

        let compact = EditorToolbarCompactPresentation.usesCompactModeControl(windowWidth: window.frame.width)
        // Write state only on a threshold crossing, never per resize tick.
        if compact != usesCompactControl {
            usesCompactControl = compact
        }
    }
}

/// The Aa (Reading Experience) toolbar button, hidden at compact widths — its action lives in the
/// compact mode menu there instead, so no bare icon can ever land in the "»" overflow popover.
struct EditorReadingExperienceToolbarButton<Content: View>: View {
    var windowNumber: Int?
    @ViewBuilder var content: () -> Content

    @State private var isCompact = false

    var body: some View {
        Group {
            if !isCompact {
                content()
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: windowNumber) { _, _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard (notification.object as? NSWindow)?.windowNumber == windowNumber else {
                return
            }
            refresh()
        }
    }

    private func refresh() {
        guard
            let windowNumber,
            let window = NSApp.windows.first(where: { $0.windowNumber == windowNumber })
        else {
            return
        }

        let compact = EditorToolbarCompactPresentation.usesCompactModeControl(windowWidth: window.frame.width)
        if compact != isCompact {
            isCompact = compact
        }
    }
}

/// The narrow-window stand-in for `EditorModeSegmentedControl`: a compact labeled menu showing
/// the current mode with a native pulldown of all three, so the toolbar never overflows our
/// custom control into the clipped "»" popover.
struct EditorModeCompactMenu: View {
    @Binding var selection: EditorDisplayMode
    var usesDarkChrome = false
    var openReadingExperience: (() -> Void)?

    var body: some View {
        Menu {
            Picker("Editor mode", selection: $selection) {
                ForEach(EditorDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)

            if let openReadingExperience {
                Divider()
                Button("Reading Experience") {
                    openReadingExperience()
                }
            }
        } label: {
            // No custom font: the label must inherit the system menu/toolbar typography so the
            // "»" overflow popover renders it at the same size as every other native row.
            Text(selection.title)
                .foregroundStyle(
                    EditorToolbarTogglePresentation.offIconColor(usesDarkChrome: usesDarkChrome)
                )
        }
        .menuIndicator(.visible)
        .fixedSize()
        // EXACTLY the segmented control's total height. The toolbar derives its height from its
        // tallest item, so swapping in a shorter control mid-drag changed the toolbar height and
        // vertically snapped the ENTIRE content area (~65pt) at the compact threshold — the
        // "text jumps up when resizing" the user kept reporting after the scroll fixes landed;
        // caught on a screen recording of the real drag (2026-07-17). Same-height controls keep
        // the toolbar, and therefore the page, rock still across the swap.
        .frame(height: EditorModeSegmentedControl.segmentHeight + 6)
        .accessibilityLabel("Editor mode")
    }
}

/// Replaces `NavigationSplitView`'s automatic sidebar toggle with a themed one that sits — and
/// moves — exactly where the native item did.
///
/// The native item's ink is resolved when its window is created and NEVER re-resolves, so a window
/// created under a dark theme keeps a white glyph forever and switching to a light theme leaves
/// white-on-white. Nothing reachable fixes it in place: an explicit `colorScheme` on the toolbar,
/// pinning/un-pinning `window.appearance`, dropping the window `backgroundColor` write, dropping
/// `.toolbarBackground(.hidden)`, and removing + re-inserting the `NSToolbarItem` were each tested
/// against a reproduction and each left it frozen (patching the toolbar from AppKit does apply, but
/// SwiftUI rebuilds the toolbar and drops it again within the same runloop).
///
/// Layout is load-bearing: AppKit lays the native item out as
/// `[flexibleSpace, toggle, trackingSeparator]`. The flexible space is what pushes the glyph to the
/// sidebar's TRAILING edge, and the tracking separator is what keeps it pinned there as the sidebar
/// resizes or collapses. Declaring the spacer here reproduces BOTH — dropping it moved the glyph to
/// the traffic lights and stopped it tracking the sidebar.
///
/// Scoped to macOS 26, where the freeze occurs and where `ToolbarSpacer` exists; earlier systems
/// keep the stock item untouched. The `#available` wraps the `.toolbar` APPLICATION rather than
/// living inside the builder — an `if` inside toolbar content erases the structure SwiftUI uses to
/// resolve spacer group breaks.
struct SidebarToggleReplacement: ViewModifier {
    var isShowingSidebar: Bool
    var usesDarkChrome: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                    ToolbarItem(id: EditorSidebarToggleButton.toolbarItemIdentifier, placement: .primaryAction) {
                        EditorSidebarToggleButton(
                            isShowingSidebar: isShowingSidebar,
                            usesDarkChrome: usesDarkChrome
                        )
                    }
                }
        } else {
            content
        }
    }
}

/// The sidebar toggle itself: a native-looking glyph whose ink is THREADED from the theme, like
/// every other control in this window. `SidebarToggleReplacement` (above) explains why the stock
/// item cannot be used and documents the layout this has to reproduce.
struct EditorSidebarToggleButton: View {
    /// Read-only: the button never sets this. Toggling goes through AppKit's own action (below) so
    /// the sidebar still animates; this only picks the label/help wording.
    var isShowingSidebar: Bool
    var usesDarkChrome: Bool

    /// Stable identifier so the item keeps its place in the toolbar across rebuilds.
    static let toolbarItemIdentifier = "lineform.sidebarToggle"

    var body: some View {
        Button {
            // Send AppKit's own `toggleSidebar:` down the responder chain rather than flipping the
            // binding. Writing the binding directly changes the column visibility with NO animation
            // — the sidebar snapped open/closed instead of sliding. This is the exact action the
            // native item performed, so the motion is unchanged. The binding is still read (below)
            // for the label/help state, and updates as the split view reports its new visibility.
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        } label: {
            Image(systemName: "sidebar.left")
                .foregroundStyle(Self.inkColor(usesDarkChrome: usesDarkChrome))
        }
        .help(isShowingSidebar ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(isShowingSidebar ? "Hide Sidebar" : "Show Sidebar")
    }

    /// Matches `EditorModeSegmentedControl`'s text fill so the toggle and the Write/Read/Preview
    /// control read as the same weight in both chromes.
    static func inkColor(usesDarkChrome: Bool) -> Color {
        let component = usesDarkChrome
            ? EditorModeSegmentedControl.darkTextFillRedComponent
            : EditorModeSegmentedControl.textFillRedComponent
        return Color(
            nsColor: NSColor(calibratedRed: component, green: component, blue: component, alpha: 1)
        )
    }
}

struct EditorModeSegmentedControl: View {
    struct LiquidBridge: Equatable {
        var from: EditorDisplayMode
        var to: EditorDisplayMode
    }

    static let segmentWidth: CGFloat = 78
    static let segmentHeight: CGFloat = 30
    static let selectedFillRedComponent: CGFloat = 0.86
    static let backgroundFillRedComponent: CGFloat = 1.0
    static let textFillRedComponent: CGFloat = 0.18
    static let darkSelectedFillRedComponent: CGFloat = 0.20
    static let darkBackgroundFillRedComponent: CGFloat = (LineformColors.darkControlBackground.usingColorSpace(.sRGB) ?? LineformColors.darkControlBackground).redComponent
    static let darkTextFillRedComponent: CGFloat = 0.92
    static let shadowRadius: CGFloat = 5
    static let hitAreaWidth: CGFloat = segmentWidth
    static let hitAreaHeight: CGFloat = segmentHeight
    static let dividerSlotWidth: CGFloat = 3
    static let liquidSettleDelay: TimeInterval = 0.16
    static let usesReduceMotionForLiquidBridge = true

    @Binding var selection: EditorDisplayMode
    var usesDarkChrome = false
    var reduceMotion = false

    @State private var hoveredMode: EditorDisplayMode?
    @State private var liquidBridge: LiquidBridge?
    @State private var liquidTransitionID = 0

    private let modes = EditorDisplayMode.allCases
    private let controlPadding: CGFloat = 3

    var body: some View {
        ZStack(alignment: .leading) {
            hoverPill
            selectedPill

            HStack(spacing: 0) {
                ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                    Button {
                        select(mode)
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Self.textFillColor(usesDarkChrome: usesDarkChrome))
                            .lineLimit(1)
                            .frame(width: Self.hitAreaWidth, height: Self.hitAreaHeight)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(selection == mode ? [.isSelected] : [])
                    .onHover { isHovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            hoveredMode = isHovering ? mode : nil
                        }
                    }

                    if index < modes.index(before: modes.endIndex) {
                        Rectangle()
                            .fill(Self.dividerColor(usesDarkChrome: usesDarkChrome).opacity(shouldShowDivider(after: index) ? 0.45 : 0))
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, 1)
                    }
                }
            }
        }
        .padding(controlPadding)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .fill(Self.backgroundFillColor(usesDarkChrome: usesDarkChrome).opacity(usesDarkChrome ? 0.92 : 0.82))
                }
                .overlay {
                    Capsule()
                        .stroke((usesDarkChrome ? Color.white.opacity(0.10) : Color.white.opacity(0.72)), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.035), radius: Self.shadowRadius, y: 1)
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor mode")
    }

    private var selectedPill: some View {
        Capsule()
            .fill(Self.selectedFillColor(usesDarkChrome: usesDarkChrome))
            .overlay {
                Capsule()
                    .stroke((usesDarkChrome ? Color.white.opacity(0.16) : Color.white.opacity(0.36)), lineWidth: 0.5)
            }
            .frame(width: selectedPillWidth, height: Self.segmentHeight)
            .offset(x: selectedPillOffset)
            .animation(
                EditorMotionPolicy.animation(.spring(response: 0.30, dampingFraction: 0.82), reduceMotion: reduceMotion),
                value: selection
            )
            .animation(
                EditorMotionPolicy.animation(.spring(response: 0.24, dampingFraction: 0.78), reduceMotion: reduceMotion),
                value: liquidBridge
            )
    }

    @ViewBuilder
    private var hoverPill: some View {
        if let hoveredMode, hoveredMode != selection {
            Capsule()
                .fill(Self.selectedFillColor(usesDarkChrome: usesDarkChrome).opacity(0.48))
                .frame(width: Self.segmentWidth, height: Self.segmentHeight)
                .offset(x: Self.segmentOffset(for: hoveredMode))
                .transition(.opacity)
        }
    }

    private var selectedPillWidth: CGFloat {
        if let liquidBridge {
            return Self.liquidPillWidth(from: liquidBridge.from, to: liquidBridge.to)
        }

        return Self.segmentWidth
    }

    private var selectedPillOffset: CGFloat {
        if let liquidBridge {
            return Self.liquidPillOffset(from: liquidBridge.from, to: liquidBridge.to)
        }

        return Self.segmentOffset(for: selection)
    }

    private static func selectedFillColor(usesDarkChrome: Bool) -> Color {
        let component = usesDarkChrome ? darkSelectedFillRedComponent : selectedFillRedComponent
        return Color(
            nsColor: NSColor(
                calibratedRed: component,
                green: component,
                blue: component,
                alpha: usesDarkChrome ? 0.92 : 0.74
            )
        )
    }

    private static func backgroundFillColor(usesDarkChrome: Bool) -> Color {
        let component = usesDarkChrome ? darkBackgroundFillRedComponent : backgroundFillRedComponent
        return Color(
            nsColor: NSColor(
                calibratedRed: component,
                green: component,
                blue: component,
                alpha: 1
            )
        )
    }

    private static func textFillColor(usesDarkChrome: Bool) -> Color {
        let component = usesDarkChrome ? darkTextFillRedComponent : textFillRedComponent
        return Color(
            nsColor: NSColor(
                calibratedRed: component,
                green: component,
                blue: component,
                alpha: 1
            )
        )
    }

    private static func dividerColor(usesDarkChrome: Bool) -> Color {
        usesDarkChrome ? .white : Color(nsColor: .separatorColor)
    }

    static func segmentOffset(for mode: EditorDisplayMode) -> CGFloat {
        guard let index = EditorDisplayMode.allCases.firstIndex(of: mode) else {
            return 0
        }

        return CGFloat(index) * (Self.segmentWidth + Self.dividerSlotWidth)
    }

    static func liquidPillOffset(from source: EditorDisplayMode, to destination: EditorDisplayMode) -> CGFloat {
        min(segmentOffset(for: source), segmentOffset(for: destination))
    }

    static func liquidPillWidth(from source: EditorDisplayMode, to destination: EditorDisplayMode) -> CGFloat {
        abs(segmentOffset(for: destination) - segmentOffset(for: source)) + Self.segmentWidth
    }

    private func select(_ mode: EditorDisplayMode) {
        guard mode != selection else {
            return
        }

        guard !reduceMotion else {
            liquidTransitionID += 1
            liquidBridge = nil
            selection = mode
            return
        }

        let previousSelection = selection
        liquidTransitionID += 1
        let transitionID = liquidTransitionID

        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
            liquidBridge = LiquidBridge(from: previousSelection, to: mode)
            selection = mode
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liquidSettleDelay) {
            guard transitionID == liquidTransitionID else {
                return
            }

            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                liquidBridge = nil
            }
        }
    }

    private func shouldShowDivider(after index: Int) -> Bool {
        guard index < modes.index(before: modes.endIndex) else {
            return false
        }

        let nextIndex = modes.index(after: index)
        return modes[index] != selection && modes[nextIndex] != selection
    }
}

struct WindowChromeReader: NSViewRepresentable {
    @Binding var windowNumber: Int?
    var usesDarkChrome: Bool
    // The theme's page color, applied as the WINDOW background. The translucent toolbar shows
    // the window background wherever no content extends beneath it — which is the tab-bar case:
    // the tab strip stops AppKit's under-titlebar scroll-view extension, so without this the nav
    // band washed to neutral (Paper's cream nav went white the moment a second tab opened).
    var pageBackground: NSColor?

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.usesDarkChrome = usesDarkChrome
        view.pageBackground = pageBackground
        view.onWindowChanged = { window in
            // Read the window number a runloop LATER: an off-screen window (before it is
            // ordered front) reports 0/-1, and the @Binding write must not happen during
            // the SwiftUI view-update phase. Deferring the read (as the old code did) lets
            // it settle to the real on-screen number and reset to nil when the view
            // detaches. The appearance itself is applied synchronously (in ChromeView) so
            // native, appearance-derived controls never paint a frame against the default
            // light appearance.
            Task { @MainActor in windowNumber = window?.windowNumber }
        }
        return view
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.usesDarkChrome = usesDarkChrome
        nsView.pageBackground = pageBackground
        nsView.applyChrome()
    }

    static func dismantleNSView(_ nsView: ChromeView, coordinator: ()) {
        // Deliberately do NOT reset the window/contentView appearance here. SwiftUI can dismantle
        // and recreate this background view during detail-hierarchy rebuilds (the tab bar
        // appearing/disappearing), and the teardown order vs. the replacement view's apply is not
        // guaranteed: clearing the appearance on dismantle either flashed the nav light for a
        // frame (cleared, then healed) or left the whole window chrome stuck light on a dark
        // theme when the clear landed last (2026-07-18, Quiet + tabs: light nav band, black
        // sidebar-toggle glyph). A window that keeps its themed appearance while briefly ownerless
        // is always correct — every live editor window re-asserts through its own ChromeView.
    }

    /// Applies the window appearance SYNCHRONOUSLY the moment it joins a window (and on
    /// later theme changes), rather than deferring it inside the Task used for the
    /// windowNumber binding. Deferring the appearance let the window render a frame with
    /// the default (light) appearance, so appearance-derived native controls — the
    /// NavigationSplitView sidebar-toggle glyph and NSColor.secondaryLabelColor in the
    /// empty-state placeholder — flashed dark-on-dark in the Quiet theme.
    final class ChromeView: NSView {
        var usesDarkChrome = false
        var pageBackground: NSColor?
        var onWindowChanged: ((NSWindow?) -> Void)?
        private weak var appliedWindow: NSWindow?
        private var appliedDarkChrome: Bool?
        private var appliedPageBackground: NSColor?
        private var appearanceObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWindowAppearance()
            applyChrome()
        }

        // The DIRECT self-heal, and the only one that covers the sidebar collapse/expand reset.
        //
        // viewDidChangeEffectiveAppearance below can NEVER fire for that drift: apply() pins
        // `window.contentView.appearance`, and this view is a descendant of the content view, so
        // it inherits the PINNED appearance — resetting `window.appearance` alone leaves this
        // view's effectiveAppearance untouched. The titlebar does NOT inherit the content view's
        // pin; it follows `window.appearance`. That asymmetry is exactly the reported symptom:
        // the nav band still looks themed (it is painted by `window.backgroundColor`, which the
        // reset does not touch) while the one native, appearance-derived control in it — the
        // NavigationSplitView sidebar-toggle glyph — turns black on a dark theme and STICKS.
        //
        // Observing `window.appearance` directly makes the heal deterministic and timing-free,
        // replacing the earlier next-tick + 0.35s re-assert pair, which merely raced the column's
        // slide animation (any reset landing after the last timer still stuck).
        //
        // Cannot loop: the observer re-applies only while drifted, and our own write re-enters
        // once with no drift left to correct.
        private func observeWindowAppearance() {
            // `MainActor.assumeIsolated` would TRAP if AppKit ever delivered this off-main; a
            // chrome touch-up is never worth a crash, so hop instead of asserting.
            appearanceObservation = window?.observe(\.appearance, options: [.new]) { [weak self] _, _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.applyChrome() }
                } else {
                    DispatchQueue.main.async { self?.applyChrome() }
                }
            }
        }

        // AppKit resets the window's explicit appearance to the default (light) aqua whenever the
        // detail hierarchy rebuilds — most notably when the tab bar appears/disappears and when the
        // reading inspector opens/closes. That reset changes this view's effectiveAppearance, so
        // observing it here re-asserts the themed appearance the instant it drifts, rather than only
        // on the next SwiftUI update (updateNSView) which those transitions do not reliably trigger.
        // Without this, a dark theme could keep a light toolbar/title bar, and — because nested
        // SwiftUI controls (the sidebar tabs, file rows) re-derive colorScheme from the window's
        // effectiveAppearance — their selected/hover colors would resolve against the wrong chrome.
        // Cannot loop: applyChrome() re-applies only while drifted; once the appearance matches the
        // theme the drift guard no longer fires.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyChrome()
        }

        func applyChrome() {
            // Apply synchronously when the window or theme changed — OR when the window's
            // appearance has drifted from what the theme wants. The drift check is load-bearing
            // for multi-tab: when the tab bar appears (1→2 tabs) the detail hierarchy rebuilds and
            // AppKit can reset the window's explicit appearance back to the default (light) aqua,
            // which on a dark theme leaves the toolbar/title bar light while the content stays
            // dark. Re-asserting only on window/theme change missed that (neither changed), so the
            // light header stuck. Re-applying on drift self-heals it and cannot loop: once applied,
            // the appearance matches and the guard no longer fires.
            if let window {
                let desiredName = EditorWindowChrome.appearanceName(usesDarkChrome: usesDarkChrome)
                let appearanceDrifted = window.appearance?.name != desiredName
                if window !== appliedWindow || appliedDarkChrome != usesDarkChrome
                    || appliedPageBackground != pageBackground || appearanceDrifted {
                    appliedWindow = window
                    appliedDarkChrome = usesDarkChrome
                    appliedPageBackground = pageBackground
                    window.animationBehavior = .none
                    EditorWindowChrome.apply(to: window, usesDarkChrome: usesDarkChrome, pageBackground: pageBackground)
                }
            }
            // Report the (possibly nil) window every time so the deferred reader converges
            // on the real number once the window is ordered and clears it on detach.
            onWindowChanged?(window)
        }
    }
}

struct EditorWindowChrome {
    static func appearanceName(usesDarkChrome: Bool) -> NSAppearance.Name {
        usesDarkChrome ? .darkAqua : .aqua
    }

    static func appearance(usesDarkChrome: Bool) -> NSAppearance? {
        NSAppearance(named: appearanceName(usesDarkChrome: usesDarkChrome))
    }

    @MainActor
    static func apply(to window: NSWindow?, usesDarkChrome: Bool, pageBackground: NSColor? = nil) {
        let resolvedAppearance = appearance(usesDarkChrome: usesDarkChrome)
        window?.appearance = resolvedAppearance
        window?.contentView?.appearance = resolvedAppearance
        // The translucent toolbar shows the WINDOW background wherever no content extends
        // beneath it. Without tabs, AppKit extends the detail's root scroll view under the
        // titlebar and the nav samples the page; with the tab strip topmost, that extension
        // stops and the band showed the default (neutral) window background instead — so
        // Paper/Calm tints vanished from the nav whenever a second tab opened. Keeping the
        // window background AT the theme page color makes the band themed in both layouts.
        if let pageBackground {
            window?.backgroundColor = pageBackground
        }
    }
}
