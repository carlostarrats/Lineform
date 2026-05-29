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
            .intelligentEditingPointingHandCursor(isEnabled: !suggestion.diff.changes.isEmpty)

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
            .intelligentEditingPointingHandCursor(isEnabled: !suggestion.diff.changes.isEmpty)

            Divider()
                .frame(height: 18)

            Button {
                retry()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .help("Try Again")
            .intelligentEditingPointingHandCursor()

            Button("Reject", action: reject)
                .keyboardShortcut(.cancelAction)
                .intelligentEditingPointingHandCursor()

            Button("Accept", action: accept)
                .keyboardShortcut(.defaultAction)
                .intelligentEditingPointingHandCursor()
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
    static let usesPointingHandCursor = true
    static let usesAppKitCursorRect = true
    static let reassertsPointingHandCursorWhileHovered = true
    static let cursorRectFillsControlBounds = true
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
    static let loadingSkeletonMinimumRows = 9
    static let loadingSkeletonCompactColumns = 20
    static let loadingSkeletonExpandedColumns = 24
    static let loadingSkeletonBlockHeight: CGFloat = 10
    static let loadingSkeletonSpacing: CGFloat = 7
    static let loadingAnswerSurfaceMinimumHeight: CGFloat = 188
    static let showsLoadingSkeleton = true
    static let controlsUsePointingHandCursor = true
    static let controlsUseAppKitCursorRect = true
    static let controlsReassertPointingHandCursorWhileHovered = true
    static let controlCursorRectFillsControlBounds = true

    static func answerSurfaceBackgroundColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance
            ? NSColor(srgbRed: 0x24 / 255.0, green: 0x24 / 255.0, blue: 0x24 / 255.0, alpha: 1)
            : .controlBackgroundColor
    }

    static func isVisible(isPreparingSuggestion _: Bool, hasSuggestions: Bool) -> Bool {
        hasSuggestions
    }

    static func presentation(for replacementText: String) -> Mode {
        let wordCount = replacementText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace || $0.isNewline }
            .count

        return wordCount >= 180 || replacementText.count > 1_200 ? .expandedReview : .anchoredPopover
    }
}

struct IntelligentEditingOptionsPanel: View {
    @Environment(\.colorScheme) private var colorScheme

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
                    IntelligentEditingLoadingSpinnerSlot()
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

                IntelligentEditingActionButton(title: "Reject", style: .secondary, action: reject)
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
        if presentationMode == .expandedReview {
            answerSurface
                .frame(maxHeight: maximumBodyHeight ?? 380)
        } else {
            answerSurface
        }
    }

    private var answerSurface: some View {
        ZStack(alignment: .topLeading) {
            if isLoading {
                loadingSkeletonGrid
                    .transition(.opacity)
            } else if presentationMode == .expandedReview {
                ScrollView {
                    answerText
                        .padding(.trailing, 6)
                }
                .transition(.opacity)
            } else {
                answerText
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isLoading ? 13 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: answerSurfaceMinimumHeight, alignment: .topLeading)
        .background(
            Color(nsColor: IntelligentEditingOptionsPresentation.answerSurfaceBackgroundColor(usesDarkAppearance: colorScheme == .dark)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var answerText: some View {
        Text(previewText)
            .font(.system(size: presentationMode == .expandedReview ? IntelligentEditingOptionsPresentation.expandedPreviewFontSize : IntelligentEditingOptionsPresentation.compactPreviewFontSize))
            .foregroundStyle(.primary)
            .lineLimit(presentationMode == .expandedReview ? nil : IntelligentEditingOptionsPresentation.previewLineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingSkeletonGrid: some View {
        LazyVGrid(columns: skeletonGridColumns, alignment: .leading, spacing: IntelligentEditingOptionsPresentation.loadingSkeletonSpacing) {
            ForEach(0..<loadingSkeletonCellCount, id: \.self) { cellIndex in
                let row = cellIndex / loadingSkeletonColumnCount
                let column = cellIndex % loadingSkeletonColumnCount

                if shouldDrawSkeletonBlock(row: row, column: column, cellIndex: cellIndex) {
                    IntelligentEditingSkeletonBlock(
                        delay: skeletonDelay(row: row, column: column, cellIndex: cellIndex),
                        duration: skeletonDuration(cellIndex: cellIndex),
                        scale: skeletonScale(cellIndex: cellIndex)
                    )
                } else {
                    Color.clear
                        .frame(height: IntelligentEditingOptionsPresentation.loadingSkeletonBlockHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: answerSurfaceMinimumHeight - 26, alignment: .topLeading)
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
        let rowHeight = IntelligentEditingOptionsPresentation.loadingSkeletonBlockHeight + IntelligentEditingOptionsPresentation.loadingSkeletonSpacing
        let rowsForSurface = Int(max(2, floor((answerSurfaceMinimumHeight - 26) / rowHeight)))
        let estimatedRows = max(rowsForSurface, loadingPreviewText.count / 72)
        let maximumRows = presentationMode == .expandedReview ? 16 : 12
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

    private var answerSurfaceMinimumHeight: CGFloat {
        if isVeryShortReference {
            return 54
        }

        let lineHeight: CGFloat = presentationMode == .expandedReview ? 24 : 22
        let estimatedLines = max(3, ceil(CGFloat(max(loadingPreviewText.count, previewText.count)) / 64))
        let estimatedHeight = estimatedLines * lineHeight + 24
        let maximumHeight = presentationMode == .expandedReview ? maximumBodyHeight ?? 380 : 300
        return min(maximumHeight, max(IntelligentEditingOptionsPresentation.loadingAnswerSurfaceMinimumHeight, estimatedHeight))
    }

    private var isVeryShortPreview: Bool {
        let trimmedPreview = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isLoading && trimmedPreview.count <= 80 && !trimmedPreview.contains("\n")
    }

    private var isVeryShortReference: Bool {
        if isLoading {
            let trimmedReference = loadingPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedReference.count <= 80 && !trimmedReference.contains("\n")
        }

        return isVeryShortPreview
    }

    private func shouldDrawSkeletonBlock(row: Int, column: Int, cellIndex: Int) -> Bool {
        let preserveEdges = column == 0 || column == loadingSkeletonColumnCount - 1
        return preserveEdges || seededNoise(Double(cellIndex + 101)) >= 0.16
    }

    private func skeletonDelay(row: Int, column: Int, cellIndex: Int) -> TimeInterval {
        let secondaryNoise = seededNoise(Double(cellIndex + 101) * 3.17)
        return Double(column) * 0.045 + Double((row * 7) % 5) * 0.026 + secondaryNoise * 0.12
    }

    private func skeletonDuration(cellIndex: Int) -> TimeInterval {
        1.18 + seededNoise(Double(cellIndex) * 2.11 + 100) * 0.72
    }

    private func skeletonScale(cellIndex: Int) -> Double {
        0.82 + seededNoise(Double(cellIndex) * 4.61 + 100) * 0.18
    }

    private func seededNoise(_ seed: Double) -> Double {
        let value = sin(seed * 12.9898) * 43758.5453
        return value - floor(value)
    }
}

private struct IntelligentEditingLoadingSpinnerSlot: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(
                width: IntelligentEditingOptionsPresentation.optionChipSize,
                height: IntelligentEditingOptionsPresentation.optionChipSize
            )
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: IntelligentEditingOptionsPresentation.optionChipCornerRadius, style: .continuous))
            .accessibilityLabel("Generating")
    }
}

private struct IntelligentEditingSkeletonBlock: View {
    let delay: TimeInterval
    let duration: TimeInterval
    let scale: Double
    @State private var isLit = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(isLit ? 0.19 : 0.035))
                .blur(radius: 3.2)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(isLit ? 0.05 : 0.018),
                            Color.primary.opacity(isLit ? 0.31 : 0.07),
                            Color.primary.opacity(isLit ? 0.07 : 0.022)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .blur(radius: 1.15)
        }
            .frame(height: IntelligentEditingOptionsPresentation.loadingSkeletonBlockHeight)
            .scaleEffect(scale)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
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
        .intelligentEditingPointingHandCursor(isEnabled: !isDisabled) { hovering in
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
        .intelligentEditingPointingHandCursor { hovering in
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

private extension View {
    func intelligentEditingPointingHandCursor(
        isEnabled: Bool = true,
        onHoverChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        modifier(IntelligentEditingPointingHandCursorModifier(isEnabled: isEnabled, onHoverChanged: onHoverChanged))
    }
}

private struct IntelligentEditingPointingHandCursorModifier: ViewModifier {
    let isEnabled: Bool
    let onHoverChanged: (Bool) -> Void
    @State private var hasPushedCursor = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isEnabled {
                    CursorRectView(cursor: .pointingHand) { hovering in
                        setHovering(hovering)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                setHovering(hovering)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard isEnabled else { return }
                    reassertCursor()
                case .ended:
                    setHovering(false)
                }
            }
            .onDisappear {
                setHovering(false)
            }
    }

    private func setHovering(_ hovering: Bool) {
        guard isEnabled else {
            popCursorIfNeeded()
            onHoverChanged(false)
            return
        }

        if hovering {
            pushCursorIfNeeded()
            reassertCursor()
        } else {
            popCursorIfNeeded()
        }
        onHoverChanged(hovering)
    }

    private func pushCursorIfNeeded() {
        guard !hasPushedCursor else { return }
        NSCursor.pointingHand.push()
        hasPushedCursor = true
    }

    private func popCursorIfNeeded() {
        guard hasPushedCursor else { return }
        NSCursor.pop()
        hasPushedCursor = false
    }

    private func reassertCursor() {
        NSCursor.pointingHand.set()
        DispatchQueue.main.async {
            NSCursor.pointingHand.set()
        }
    }
}
