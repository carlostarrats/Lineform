import SwiftUI

struct TabBarView: View {
    @ObservedObject var tabStore: EditorTabStore
    @ObservedObject var documentSaveStatus: DocumentSaveStatus
    let usesDarkChrome: Bool
    let onSelectTab: (UUID) -> Void
    let onCloseTab: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(tabStore.tabs.enumerated()), id: \.element.id) { index, tab in
                    if index > 0 {
                        Rectangle()
                            .fill(Color(nsColor: Self.separatorColor(usesDarkChrome: usesDarkChrome)))
                            .frame(width: 0.5)
                            .padding(.vertical, 6)
                    }
                    tabButton(for: tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 0)
        }
        .frame(height: Self.barHeight)
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

    static let barHeight: CGFloat = 28

    @ViewBuilder
    private func tabButton(for tab: DocumentTab) -> some View {
        let isSelected = tab.id == tabStore.selectedTabID
        let isDirty = documentSaveStatus.isDirty(
            documentID: tab.document.id,
            currentText: tab.document.text
        )
        let showsClose = tabStore.tabCount > 1

        ZStack {
            // Selection tap area: covers the whole row so the close button can be a
            // sibling Button instead of nested inside another Button. A real Button
            // (rather than onTapGesture) because onTapGesture loses the gesture-priority
            // race to the enclosing horizontal ScrollView's own click/pan handling on
            // macOS, silently swallowing clicks — Button routes through AppKit's normal
            // control click handling instead and doesn't have this problem.
            Button {
                onSelectTab(tab.id)
            } label: {
                Rectangle()
                    .fill(Color(nsColor: Self.tabBackgroundColor(
                        isSelected: isSelected,
                        usesDarkChrome: usesDarkChrome
                    )))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(tab.title))
            .accessibilityValue(isSelected ? Text("selected") : Text(""))

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
                    .foregroundStyle(Color(nsColor: Self.textColor(
                        isSelected: isSelected,
                        usesDarkChrome: usesDarkChrome
                    )))
                    // Text still consumes hits at its own bounds even with no gesture
                    // attached, which silently blocks the selection Button stacked behind
                    // it (the tab title sits right where a user naturally clicks). Let
                    // clicks fall through to the Button underneath.
                    .allowsHitTesting(false)

                if showsClose {
                    closeButton(for: tab.id, isSelected: isSelected)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 0)
            .frame(height: Self.barHeight)
        }
        .frame(height: Self.barHeight)
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

    static func tabBackgroundColor(isSelected: Bool, usesDarkChrome: Bool) -> NSColor {
        if isSelected {
            return usesDarkChrome
                ? NSColor(calibratedWhite: 0.22, alpha: 1)
                : NSColor(calibratedWhite: 1.0, alpha: 1)
        }
        return .clear
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
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.10)
    }

    static func bottomBorderColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor.black.withAlphaComponent(0.30)
            : NSColor.black.withAlphaComponent(0.15)
    }
}
