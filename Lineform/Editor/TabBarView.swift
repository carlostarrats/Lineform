import SwiftUI

/// Tab bar per the user's Paper design (Surface Camera › "Tabs", Groups 762/763,
/// 2026-07-18). Safari-like behavior, flat fills (no translucency):
/// - Equal-width capsule tabs always filling the bar edge to edge.
/// - Resting inactive tabs share the bar's fill (they "blend in"), divided by short
///   hairline separators; separators never touch the selected or hovered tab.
/// - The selected tab is a lighter capsule with a soft shadow (design: 0/1/2 black 8%).
/// - Hovering an inactive tab darkens it and reveals a close × at the capsule's LEFT;
///   hovering the selected tab adds a slight tint and the same left ×. No × at rest.
struct TabBarView: View {
    @ObservedObject var tabStore: EditorTabStore
    @ObservedObject var documentSaveStatus: DocumentSaveStatus
    let usesDarkChrome: Bool
    // The theme's page color; light-chrome fills derive from it so Paper/Calm tint the
    // strip and tabs (see lightTone). Nil (tests/previews) falls back to the design greys.
    var pageBackground: NSColor?
    let onSelectTab: (UUID) -> Void
    let onCloseTab: (UUID) -> Void

    @State private var hoveredTabID: UUID?
    @State private var hoveredCloseTabID: UUID?

    var body: some View {
        HStack(spacing: Self.tabGap) {
            ForEach(Array(tabStore.tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    separator(beforeTabAt: index)
                }
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, Self.barHorizontalPadding)
        .padding(.vertical, Self.capsuleVerticalInset)
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        // ignoresSafeAreaEdges: [] is load-bearing: as the topmost view in the detail column,
        // a default .background(color) BLEEDS into the top safe area — under the translucent
        // toolbar — so the nav sampled this strip's grey instead of the theme page color the
        // moment a second tab appeared (pixel-verified 2026-07-18: Paper's cream nav went
        // neutral white with tabs, identical no-tab nav stayed cream). Constrained to the
        // bar's own bounds, the page-color background on editorShell's wrapper owns the
        // under-toolbar region, so the nav is identical with or without tabs.
        .background(
            Color(nsColor: Self.barBackgroundColor(usesDarkChrome: usesDarkChrome, pageBackground: pageBackground)),
            ignoresSafeAreaEdges: []
        )
    }

    // Design metrics (Paper, 1:1): bar 32, capsule 24, 4 inset, ~3 gap, 4 edge padding.
    static let barHeight: CGFloat = 32
    static let capsuleVerticalInset: CGFloat = 4
    static let tabGap: CGFloat = 3
    static let barHorizontalPadding: CGFloat = 4
    static let separatorHeight: CGFloat = 14

    /// Separators only divide two RESTING tabs — hidden beside the selected capsule and
    /// the hovered tab (both per the design's hover frame).
    @ViewBuilder
    private func separator(beforeTabAt index: Int) -> some View {
        let leadingTab = tabStore.tabs[index - 1]
        let trailingTab = tabStore.tabs[index]
        let touchesSelection = leadingTab.id == tabStore.selectedTabID
            || trailingTab.id == tabStore.selectedTabID
        let touchesHover = leadingTab.id == hoveredTabID || trailingTab.id == hoveredTabID
        Rectangle()
            .fill(Color(nsColor: Self.separatorColor(usesDarkChrome: usesDarkChrome, pageBackground: pageBackground)))
            .frame(width: 0.5, height: Self.separatorHeight)
            .opacity(touchesSelection || touchesHover ? 0 : 1)
    }

    @ViewBuilder
    private func tabButton(for tab: DocumentTab) -> some View {
        let isSelected = tab.id == tabStore.selectedTabID
        let isHovered = hoveredTabID == tab.id
        let isDirty = documentSaveStatus.isDirty(
            documentID: tab.document.id,
            currentText: tab.document.text
        )
        // The × exists only under the pointer (design: no close affordance at rest,
        // including on the selected tab) and never on a lone tab.
        let showsClose = tabStore.tabCount > 1 && isHovered

        ZStack {
            // Selection tap area: covers the whole capsule so the close button can be a
            // sibling Button instead of nested inside another Button. A real Button
            // (rather than onTapGesture) because onTapGesture can lose gesture-priority
            // races on macOS, silently swallowing clicks — Button routes through AppKit's
            // normal control click handling instead.
            Button {
                onSelectTab(tab.id)
            } label: {
                Capsule(style: .continuous)
                    .fill(Color(nsColor: Self.tabBackgroundColor(
                        isSelected: isSelected,
                        isHovered: isHovered,
                        usesDarkChrome: usesDarkChrome,
                        pageBackground: pageBackground
                    )))
                    // Design: 0/1/2 (spread 1) black 8% under the selected capsule only.
                    .shadow(
                        color: Color.black.opacity(isSelected ? 0.08 : 0),
                        radius: 1, x: 0, y: 1
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(tab.title))
            .accessibilityValue(isSelected ? Text("selected") : Text(""))

            // Centered title cluster (title is centered regardless of the left ×).
            HStack(spacing: 6) {
                if isDirty {
                    Circle()
                        .fill(Color(nsColor: Self.dirtyDotColor(usesDarkChrome: usesDarkChrome)))
                        .frame(width: 5, height: 5)
                        .allowsHitTesting(false)
                }

                Text(tab.title)
                    .font(.system(size: 10, weight: .medium))
                    .kerning(0.3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color(nsColor: Self.textColor(usesDarkChrome: usesDarkChrome)))
                    // Text still consumes hits at its own bounds even with no gesture
                    // attached, which silently blocks the selection Button stacked behind
                    // it. Let clicks fall through to the Button underneath.
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 28)

            // Close × pinned to the capsule's left edge, per the design's hover frames.
            if showsClose {
                HStack {
                    closeButton(for: tab.id)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .transition(.opacity)
            }
        }
        // Equal-width distribution: every tab takes the same share of the full bar.
        .frame(maxWidth: .infinity)
        .frame(height: Self.barHeight - Self.capsuleVerticalInset * 2)
        .onHover { hovering in
            // Same quiet transition as the Write/Read/Preview control's hover fill —
            // the capsule tint, separator fade, and × appearance all ride this animation.
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredTabID = hovering ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
            }
        }
    }

    @ViewBuilder
    private func closeButton(for tabID: UUID) -> some View {
        Button {
            onCloseTab(tabID)
        } label: {
            // The × is drawn as raw geometry, not an SF Symbol — the symbol's internal
            // bearings kept it optically off-center inside the hover circle no matter
            // how it was stacked. Two strokes in a square, centered by construction.
            Circle()
                .fill(Color(nsColor: Self.closeButtonHoverCircleColor(usesDarkChrome: usesDarkChrome)))
                .opacity(hoveredCloseTabID == tabID ? 1 : 0)
                .frame(width: 16, height: 16)
                .overlay(
                    TabCloseGlyph()
                        .stroke(
                            Color(nsColor: Self.closeButtonColor(usesDarkChrome: usesDarkChrome)),
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
                        )
                        .frame(width: 7, height: 7)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredCloseTabID = hovering ? tabID : (hoveredCloseTabID == tabID ? nil : hoveredCloseTabID)
            }
        }
        .accessibilityLabel("Close tab")
    }

    // Design values (light chrome, from the Paper file): bar #E3E3E3; inactive tabs
    // share it; hover #D3D3D3; selected #EBEBEB (+slight tint when also hovered);
    // text #4C4C4C everywhere; separator #CDCDCD; × glyph #7A7A7A. Dark chrome maps
    // the same relationships onto the app's dark bar tones.
    //
    // In light chrome the fills are derived from the theme PAGE color, not fixed greys:
    // each design grey becomes `page × (grey/255)`, so a pure-white page (Original)
    // yields exactly the designed grey while Paper's cream and Calm's cool tint carry
    // into the strip and tabs instead of reading as neutral grey on a tinted page.
    private static func lightTone(_ factor: CGFloat, page: NSColor?) -> NSColor {
        guard let rgb = page?.usingColorSpace(.sRGB) else {
            return NSColor(srgbRed: factor, green: factor, blue: factor, alpha: 1)
        }
        return NSColor(
            srgbRed: rgb.redComponent * factor,
            green: rgb.greenComponent * factor,
            blue: rgb.blueComponent * factor,
            alpha: 1
        )
    }

    static func barBackgroundColor(usesDarkChrome: Bool, pageBackground: NSColor? = nil) -> NSColor {
        usesDarkChrome
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : lightTone(0xE3 / 255, page: pageBackground)
    }

    static func tabBackgroundColor(isSelected: Bool, isHovered: Bool, usesDarkChrome: Bool, pageBackground: NSColor? = nil) -> NSColor {
        if isSelected {
            if isHovered {
                // A slight tint only — the first pass (#E6E6E6) read as too dark in QA.
                return usesDarkChrome
                    ? NSColor(calibratedWhite: 0.31, alpha: 1)
                    : lightTone(0xED / 255, page: pageBackground)
            }
            // Lightened from the design file's #EBEBEB, per QA.
            return usesDarkChrome
                ? NSColor(calibratedWhite: 0.30, alpha: 1)
                : lightTone(0xF0 / 255, page: pageBackground)
        }
        if isHovered {
            return usesDarkChrome
                ? NSColor(calibratedWhite: 0.13, alpha: 1)
                : lightTone(0xD3 / 255, page: pageBackground)
        }
        return .clear
    }

    static func textColor(usesDarkChrome: Bool) -> NSColor {
        // A step lighter than the design file's #4C4C4C, per QA.
        usesDarkChrome
            ? NSColor(calibratedWhite: 0.78, alpha: 1)
            : NSColor(srgbRed: 0x63 / 255, green: 0x63 / 255, blue: 0x63 / 255, alpha: 1)
    }

    static func dirtyDotColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor(calibratedWhite: 0.75, alpha: 1)
            : NSColor(srgbRed: 0x4C / 255, green: 0x4C / 255, blue: 0x4C / 255, alpha: 1)
    }

    static func closeButtonColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor(calibratedWhite: 0.60, alpha: 1)
            : NSColor(srgbRed: 0x7A / 255, green: 0x7A / 255, blue: 0x7A / 255, alpha: 1)
    }

    static func separatorColor(usesDarkChrome: Bool, pageBackground: NSColor? = nil) -> NSColor {
        // A step darker than the design file's #CDCDCD, per QA.
        usesDarkChrome
            ? NSColor.white.withAlphaComponent(0.24)
            : lightTone(0xBB / 255, page: pageBackground)
    }

    /// An × as exact geometry: both diagonals of the given rect.
    struct TabCloseGlyph: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            return path
        }
    }

    static func closeButtonHoverCircleColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.08)
    }
}
