import SwiftUI

/// Safari-style tab bar (user-directed, 2026-07-17): tabs are EQUAL-WIDTH and always
/// fill the bar edge to edge (no left-packed pills, no horizontal scrolling); the active
/// tab is a capsule with a hairline outline; inactive tabs are flat with a thin vertical
/// separator between adjacent inactive tabs (never beside the active capsule, matching
/// Safari); titles centered. Deliberately FLAT fills — no translucency/material ("liquid
/// glass" is Safari's look, not this app's).
struct TabBarView: View {
    @ObservedObject var tabStore: EditorTabStore
    @ObservedObject var documentSaveStatus: DocumentSaveStatus
    let usesDarkChrome: Bool
    let onSelectTab: (UUID) -> Void
    let onCloseTab: (UUID) -> Void

    @State private var hoveredTabID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabStore.tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    separator(beforeTabAt: index)
                }
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, Self.pillVerticalInset)
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        .background(
            Color(nsColor: Self.barBackgroundColor(usesDarkChrome: usesDarkChrome))
        )
        .overlay(
            Rectangle()
                .fill(Color(nsColor: Self.bottomBorderColor(usesDarkChrome: usesDarkChrome)))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    static let barHeight: CGFloat = 32
    static let pillVerticalInset: CGFloat = 4

    /// Safari hides the separator on both sides of the active capsule (and under the
    /// hovered tab's fill); it only divides two flat, resting tabs.
    @ViewBuilder
    private func separator(beforeTabAt index: Int) -> some View {
        let leadingTab = tabStore.tabs[index - 1]
        let trailingTab = tabStore.tabs[index]
        let touchesSelection = leadingTab.id == tabStore.selectedTabID
            || trailingTab.id == tabStore.selectedTabID
        let touchesHover = leadingTab.id == hoveredTabID || trailingTab.id == hoveredTabID
        Rectangle()
            .fill(Color(nsColor: Self.separatorColor(usesDarkChrome: usesDarkChrome)))
            .frame(width: 1)
            .padding(.vertical, 5)
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
        // Close affordance on the pointer's tab (and the active one), Safari-style; a
        // lone tab never shows one.
        let showsClose = tabStore.tabCount > 1 && (isSelected || isHovered)

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
                        usesDarkChrome: usesDarkChrome
                    )))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                Color(nsColor: Self.activeStrokeColor(usesDarkChrome: usesDarkChrome)),
                                lineWidth: 1
                            )
                            .opacity(isSelected ? 1 : 0)
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(tab.title))
            .accessibilityValue(isSelected ? Text("selected") : Text(""))

            // Centered title cluster, Safari-style.
            HStack(spacing: 6) {
                if isDirty {
                    Circle()
                        .fill(Color(nsColor: Self.dirtyDotColor(usesDarkChrome: usesDarkChrome)))
                        .frame(width: 6, height: 6)
                        .allowsHitTesting(false)
                }

                Text(tab.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color(nsColor: Self.textColor(
                        isSelected: isSelected,
                        usesDarkChrome: usesDarkChrome
                    )))
                    // Text still consumes hits at its own bounds even with no gesture
                    // attached, which silently blocks the selection Button stacked behind
                    // it. Let clicks fall through to the Button underneath.
                    .allowsHitTesting(false)

                if showsClose {
                    closeButton(for: tab.id, isSelected: isSelected)
                }
            }
            .padding(.horizontal, 14)
        }
        // Equal-width distribution: every tab takes the same share of the full bar.
        .frame(maxWidth: .infinity)
        .frame(height: Self.barHeight - Self.pillVerticalInset * 2)
        .onHover { hovering in
            hoveredTabID = hovering ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
        }
    }

    @ViewBuilder
    private func closeButton(for tabID: UUID, isSelected: Bool) -> some View {
        Button {
            onCloseTab(tabID)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(nsColor: Self.closeButtonColor(
                    isSelected: isSelected,
                    usesDarkChrome: usesDarkChrome
                )))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close tab")
    }

    static func barBackgroundColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)
    }

    static func tabBackgroundColor(isSelected: Bool, isHovered: Bool, usesDarkChrome: Bool) -> NSColor {
        if isSelected {
            return usesDarkChrome
                ? NSColor(calibratedWhite: 0.26, alpha: 1)
                : NSColor(calibratedWhite: 1.0, alpha: 1)
        }
        if isHovered {
            return usesDarkChrome
                ? NSColor(calibratedWhite: 0.22, alpha: 1)
                : NSColor(calibratedWhite: 0.92, alpha: 1)
        }
        return .clear
    }

    /// The active capsule's hairline outline — the Safari cue that reads "current tab"
    /// without any translucency.
    static func activeStrokeColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor.white.withAlphaComponent(0.25)
            : NSColor.black.withAlphaComponent(0.12)
    }

    static func textColor(isSelected: Bool, usesDarkChrome: Bool) -> NSColor {
        if isSelected {
            return usesDarkChrome
                ? NSColor(calibratedWhite: 0.95, alpha: 1)
                : NSColor(calibratedWhite: 0.0, alpha: 1)
        }
        return usesDarkChrome
            ? NSColor(calibratedWhite: 0.70, alpha: 1)
            : NSColor(calibratedWhite: 0.40, alpha: 1)
    }

    static func dirtyDotColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor(calibratedWhite: 0.75, alpha: 1)
            : NSColor(calibratedWhite: 0.30, alpha: 1)
    }

    static func closeButtonColor(isSelected: Bool, usesDarkChrome: Bool) -> NSColor {
        if isSelected {
            return usesDarkChrome
                ? NSColor(calibratedWhite: 0.65, alpha: 1)
                : NSColor(calibratedWhite: 0.40, alpha: 1)
        }
        return usesDarkChrome
            ? NSColor(calibratedWhite: 0.50, alpha: 1)
            : NSColor(calibratedWhite: 0.55, alpha: 1)
    }

    static func separatorColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.12)
    }

    static func bottomBorderColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor.black.withAlphaComponent(0.30)
            : NSColor.black.withAlphaComponent(0.15)
    }
}
