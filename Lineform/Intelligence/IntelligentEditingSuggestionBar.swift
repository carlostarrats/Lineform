import SwiftUI

struct IntelligentEditingSuggestionBar: View {
    let suggestion: IntelligentEditingSuggestion
    @Binding var currentChangeIndex: Int
    var navigateToChange: (MarkdownDiff.Change) -> Void
    var retry: () -> Void
    var accept: () -> Void
    var reject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.action.title)
                    .font(.callout.weight(.semibold))
                Text(suggestion.diff.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                moveChange(by: -1)
            } label: {
                Label("Previous Change", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .disabled(suggestion.diff.changes.isEmpty)
            .help("Previous Change")

            Text(changePositionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 72)
                .accessibilityLabel(changePositionAccessibilityLabel)

            Button {
                moveChange(by: 1)
            } label: {
                Label("Next Change", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .disabled(suggestion.diff.changes.isEmpty)
            .help("Next Change")

            Divider()
                .frame(height: 18)

            Button {
                retry()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .help("Try Again")

            Button("Reject", action: reject)
                .keyboardShortcut(.cancelAction)

            Button("Accept", action: accept)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lineform suggestion")
    }

    private var changePositionText: String {
        guard !suggestion.diff.changes.isEmpty else {
            return "0 of 0"
        }
        return "\(currentChangeIndex + 1) of \(suggestion.diff.changes.count)"
    }

    private var changePositionAccessibilityLabel: String {
        guard !suggestion.diff.changes.isEmpty else {
            return "No changed lines"
        }
        return "Changed line \(currentChangeIndex + 1) of \(suggestion.diff.changes.count)"
    }

    private func moveChange(by offset: Int) {
        guard !suggestion.diff.changes.isEmpty else {
            return
        }

        let nextIndex = min(max(currentChangeIndex + offset, 0), suggestion.diff.changes.count - 1)
        currentChangeIndex = nextIndex
        navigateToChange(suggestion.diff.changes[nextIndex])
    }
}

enum IntelligentEditingReviewControls {
    static let buttonTitles = ["Try Again", "Reject", "Accept"]
}

enum IntelligentEditingOptionsPresentation {
    enum Mode: Equatable {
        case anchoredPopover
        case expandedReview
    }

    static let previewLineLimit: Int? = nil
    static let compactPreviewFontSize: CGFloat = 16
    static let expandedPreviewFontSize: CGFloat = 17
    static let optionChipSize: CGFloat = 36
    static let optionChipCornerRadius: CGFloat = 10
    static let compactMaximumWidth: CGFloat = 560
    static let expandedMaximumWidth: CGFloat = 900
    static let compactEstimatedHeight: CGFloat = 286
    static let expandedEstimatedHeight: CGFloat = 520
    static let usesNestedPreviewCard = true
    static let usesSingleVisibleSuggestion = true
    static let truncatesCompactSuggestions = false
    static let regenerateSystemImage = "arrow.clockwise"
    static let loadingSkeletonMinimumRows = 4
    static let loadingSkeletonCompactColumns = 12
    static let loadingSkeletonExpandedColumns = 16
    static let showsLoadingSkeleton = true

    static func presentation(for replacementText: String) -> Mode {
        let wordCount = replacementText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace || $0.isNewline }
            .count

        return wordCount >= 180 || replacementText.count > 1_200 ? .expandedReview : .anchoredPopover
    }
}

struct IntelligentEditingOptionsPanel: View {
    let suggestions: [IntelligentEditingSuggestion]
    @Binding var selectedIndex: Int
    var loadingActionTitle: String?
    var loadingPreviewText = ""
    var maximumBodyHeight: CGFloat?
    var retry: () -> Void
    var accept: () -> Void
    var reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(panelTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: IntelligentEditingOptionsPresentation.optionChipSize, height: IntelligentEditingOptionsPresentation.optionChipSize)
                } else if suggestions.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(suggestions.indices, id: \.self) { index in
                            IntelligentEditingOptionChip(
                                number: index + 1,
                                isSelected: selectedIndex == index
                            ) {
                                selectedIndex = index
                            }
                        }
                    }
                }
            }

            suggestionBody

            HStack(spacing: 10) {
                Spacer()

                IntelligentEditingActionButton(
                    title: "Regenerate",
                    systemImage: IntelligentEditingOptionsPresentation.regenerateSystemImage,
                    style: .secondary,
                    isDisabled: isLoading,
                    action: retry
                )
                    .help("Try Again")

                IntelligentEditingActionButton(title: "Reject", style: .secondary, isDisabled: isLoading, action: reject)
                    .keyboardShortcut(.cancelAction)

                IntelligentEditingActionButton(title: "Accept", style: .primary, isDisabled: isLoading, action: accept)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(presentationMode == .expandedReview ? 16 : 14)
        .frame(maxWidth: maximumWidth)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.28))
        }
        .shadow(color: .black.opacity(presentationMode == .expandedReview ? 0.18 : 0.12), radius: presentationMode == .expandedReview ? 28 : 18, y: presentationMode == .expandedReview ? 14 : 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isLoading ? "\(panelTitle) is generating" : "Lineform options")
    }

    @ViewBuilder
    private var suggestionBody: some View {
        if isLoading {
            loadingSkeletonBody
        } else if presentationMode == .expandedReview {
            ScrollView {
                Text(previewText)
                    .font(.system(size: IntelligentEditingOptionsPresentation.expandedPreviewFontSize))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 6)
            }
            .frame(maxHeight: maximumBodyHeight ?? 380)
        } else {
            Text(previewText)
                .font(.system(size: IntelligentEditingOptionsPresentation.compactPreviewFontSize))
                .foregroundStyle(.primary)
                .lineLimit(IntelligentEditingOptionsPresentation.previewLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var loadingSkeletonBody: some View {
        LazyVGrid(columns: skeletonGridColumns, alignment: .leading, spacing: 7) {
            ForEach(0..<loadingSkeletonCellCount, id: \.self) { cellIndex in
                let row = cellIndex / loadingSkeletonColumnCount
                let column = cellIndex % loadingSkeletonColumnCount

                if shouldDrawSkeletonBlock(row: row, column: column) {
                    IntelligentEditingSkeletonBlock(delay: skeletonDelay(row: row, column: column))
                } else {
                    Color.clear
                        .frame(height: 10)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: presentationMode == .expandedReview ? maximumBodyHeight ?? 380 : nil, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var isLoading: Bool {
        loadingActionTitle != nil
    }

    private var panelTitle: String {
        loadingActionTitle ?? activeSuggestion?.action.title ?? "Lineform"
    }

    private var activeSuggestion: IntelligentEditingSuggestion? {
        guard !suggestions.isEmpty else {
            return nil
        }
        return suggestions[min(max(selectedIndex, 0), suggestions.count - 1)]
    }

    private var previewText: String {
        activeSuggestion?.replacementText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var presentationMode: IntelligentEditingOptionsPresentation.Mode {
        IntelligentEditingOptionsPresentation.presentation(for: isLoading ? loadingPreviewText : previewText)
    }

    private var maximumWidth: CGFloat {
        presentationMode == .expandedReview ? IntelligentEditingOptionsPresentation.expandedMaximumWidth : IntelligentEditingOptionsPresentation.compactMaximumWidth
    }

    private var loadingSkeletonRowCount: Int {
        let estimatedRows = max(IntelligentEditingOptionsPresentation.loadingSkeletonMinimumRows, loadingPreviewText.count / 96)
        let maximumRows = presentationMode == .expandedReview ? 11 : 6
        return min(maximumRows, estimatedRows)
    }

    private var loadingSkeletonColumnCount: Int {
        presentationMode == .expandedReview
            ? IntelligentEditingOptionsPresentation.loadingSkeletonExpandedColumns
            : IntelligentEditingOptionsPresentation.loadingSkeletonCompactColumns
    }

    private var loadingSkeletonCellCount: Int {
        loadingSkeletonRowCount * loadingSkeletonColumnCount
    }

    private var skeletonGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 18, maximum: 42), spacing: 7),
            count: loadingSkeletonColumnCount
        )
    }

    private func shouldDrawSkeletonBlock(row: Int, column: Int) -> Bool {
        (row + column) % 7 != 0 && (row * 3 + column) % 11 != 0
    }

    private func skeletonDelay(row: Int, column: Int) -> TimeInterval {
        Double(column) * 0.055 + Double((row * 2) % 5) * 0.018
    }
}

private struct IntelligentEditingSkeletonBlock: View {
    let delay: TimeInterval
    @State private var isLit = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(isLit ? 0.18 : 0.055))
            .frame(height: 10)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.easeInOut(duration: 0.78).repeatForever(autoreverses: true)) {
                        isLit = true
                    }
                }
            }
    }
}

private struct IntelligentEditingActionButton: View {
    enum Style {
        case primary
        case secondary
    }

    let title: String
    var systemImage: String?
    var style: Style
    var isDisabled = false
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 42, height: 32)
                } else {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 15)
                        .frame(height: 32)
                }
            }
            .foregroundStyle(foregroundStyle)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(title)
    }

    private var foregroundStyle: some ShapeStyle {
        if isDisabled {
            return AnyShapeStyle((style == .primary ? Color.white : Color.primary).opacity(0.45))
        }

        return style == .primary ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary)
    }

    private var backgroundStyle: some ShapeStyle {
        if style == .primary {
            return AnyShapeStyle(Color.accentColor.opacity(isDisabled ? 0.42 : (isHovered ? 0.88 : 1)))
        }

        return AnyShapeStyle(Color.primary.opacity(isDisabled ? 0.055 : (isHovered ? 0.14 : 0.075)))
    }
}

private struct IntelligentEditingOptionChip: View {
    let number: Int
    let isSelected: Bool
    var select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .primary.opacity(0.72))
                .frame(width: IntelligentEditingOptionsPresentation.optionChipSize, height: IntelligentEditingOptionsPresentation.optionChipSize)
                .background(
                    chipBackground,
                    in: RoundedRectangle(cornerRadius: IntelligentEditingOptionsPresentation.optionChipCornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: IntelligentEditingOptionsPresentation.optionChipCornerRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(isSelected ? 0 : 0.22))
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("Option \(number)")
    }

    private var chipBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor)
        }

        if isHovered {
            return AnyShapeStyle(Color.primary.opacity(0.14))
        }

        return AnyShapeStyle(Color.primary.opacity(0.08))
    }
}
