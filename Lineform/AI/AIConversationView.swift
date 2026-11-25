import LineformCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The AI conversation, drawn the same way in the Mac's right-side drawer and the iPhone's sheet
/// (one file, compiled into both apps; the reference is the approved prompt-words mockup, v11).
///
/// - Start: the session note above the quick actions, centred. Typing fades both; once anything is
///   sent they are gone for this conversation.
/// - The thread: the writer's grey bubble (pointed bottom-right), the AI's bubble (pointed
///   bottom-left; white with a soft shadow in light themes, a lighter grey with no shadow in dark).
///   A suggestion shows only the new text; versions step with "v2 ‹ ›" pinned to its bottom edge.
/// - Accept / Reject / Try Again: three equal pills just above the input, only for a pending
///   suggestion.
/// - The input: a rounded box with a soft shadow, "Ask Lineform…", the send button inside it.
///   Curated words get a dotted underline at once (solid once applied).
/// - The options card: inside the drawer, just above the input, never a popover. While it is up
///   everything else dims, greys, blurs progressively toward the bottom and stops responding;
///   Apply, ✕ or Esc are the only ways out.
struct AIConversationView: View {
    @ObservedObject var conversation: AIConversation
    let style: AIConversationStyle
    /// The Mac's drawer has a close button; the iPhone's sheet closes by dragging down.
    var onClose: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inputHeight: CGFloat = 0
    @State private var focusToken = 0

    private var metrics: AIConversationMetrics { .current }
    private var isChoosing: Bool { conversation.card != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if let onClose {
                    HStack {
                        Spacer()
                        AIIconButton(systemImage: "xmark", label: AIConversationPresentation.closeTitle,
                                     side: metrics.closeSide, style: style, action: onClose)
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 10)
                }
                content
                bottomArea
            }
            .modifier(AIChoosingBackdrop(isChoosing: isChoosing, reduceMotion: reduceMotion))

            if isChoosing {
                AIProgressiveBlur()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if let card = conversation.card {
                AIOptionsCard(card: card, initialSelection: conversation.cardSelection, style: style,
                              onApply: { selection in withMotion { conversation.applyCard(selection) } },
                              onCancel: { withMotion { conversation.cancelCard() } })
                    .padding(.horizontal, metrics.cardInset)
                    .padding(.bottom, inputHeight + 4)
                    .transition(EditorMotionPolicy.fadeAndMoveTransition(y: 6, reduceMotion: reduceMotion))
                    .zIndex(2)
            }
        }
        .font(.system(size: metrics.bodySize))
        .foregroundStyle(style.ink)
        .background(style.surface)
        .animation(EditorMotionPolicy.animation(.easeInOut(duration: 0.25), reduceMotion: reduceMotion), value: isChoosing)
        .animation(EditorMotionPolicy.animation(.easeInOut(duration: 0.25), reduceMotion: reduceMotion), value: conversation.hasStarted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AIConversationPresentation.conversationLabel)
    }

    private func withMotion(_ body: () -> Void) {
        if reduceMotion { body() } else { withAnimation(.easeInOut(duration: 0.25), body) }
    }

    // MARK: - Start or thread

    @ViewBuilder
    private var content: some View {
        if conversation.hasStarted {
            AIThreadView(conversation: conversation, style: style)
                .transition(.opacity)
        } else {
            startGroup
                .transition(.opacity)
        }
    }

    private var startGroup: some View {
        let typing = !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: metrics.startSpacing) {
            Spacer(minLength: 12)
            Text(AIConversationPresentation.startNote)
                .font(.system(size: metrics.noteSize))
                .foregroundStyle(style.secondaryInk)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: metrics.noteWidth)
                .opacity(typing ? 0 : 1)
            VStack(spacing: 6) {
                ForEach(AIConversation.quickActions, id: \.self) { action in
                    AIQuickActionButton(title: action.title, style: style) {
                        conversation.runQuickAction(action)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(AIConversationPresentation.quickActionsLabel)
            .opacity(typing ? 0 : 1)
            .allowsHitTesting(!typing)
            .accessibilityHidden(typing)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, metrics.sidePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(EditorMotionPolicy.animation(.easeOut(duration: 0.2), reduceMotion: reduceMotion), value: typing)
    }

    // MARK: - Pills and input

    private var bottomArea: some View {
        VStack(spacing: 8) {
            if let pending = conversation.pendingSuggestion {
                HStack(spacing: 6) {
                    AIPillButton(title: AIConversationPresentation.acceptTitle, isPrimary: true, style: style) {
                        withMotion { conversation.accept() }
                    }
                    AIPillButton(title: AIConversationPresentation.rejectTitle, isPrimary: false, style: style) {
                        withMotion { conversation.reject() }
                    }
                    AIPillButton(title: AIConversationPresentation.tryAgainTitle, isPrimary: false, style: style) {
                        conversation.tryAgain()
                    }
                }
                .disabled(pending.suggestion.isRetrying)
                .transition(.opacity)
            }
            AIInputBox(conversation: conversation, style: style)
        }
        .padding(.horizontal, metrics.inputInset)
        .padding(.top, 8)
        .padding(.bottom, metrics.inputBottom)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: AIInputHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(AIInputHeightKey.self) { inputHeight = $0 }
        .animation(EditorMotionPolicy.animation(.easeInOut(duration: 0.22), reduceMotion: reduceMotion),
                   value: conversation.pendingSuggestion?.id)
    }
}

private struct AIInputHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Style and metrics

/// The colours the conversation draws with, from the theme (the drawer follows the page).
struct AIConversationStyle {
    let surface: Color
    let page: Color
    let ink: Color
    let secondaryInk: Color
    let isDark: Bool

    /// Lineform blue (the Apply and send buttons, the underlines).
    var blue: Color { isDark ? Color(red: 0.357, green: 0.553, blue: 0.937) : Color(red: 0.184, green: 0.42, blue: 0.871) }
    var underline: Color { isDark ? Color(red: 0.56, green: 0.70, blue: 1.0) : blue }
    var field: Color { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.045) }
    var fieldHover: Color { isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.08) }
    var line: Color { isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.11) }
    var writerBubble: Color { isDark ? Color(red: 0.18, green: 0.227, blue: 0.322) : field }
    var aiBubble: Color { isDark ? Color.white.opacity(0.075) : page }
    var aiShadow: Color { isDark ? .clear : Color.black.opacity(0.07) }
    var card: Color { isDark ? Color(white: 0.23) : Color.white }
    var cardLine: Color { isDark ? Color(white: 0.34) : Color(red: 0.855, green: 0.863, blue: 0.878) }
    var chip: Color { card }
    var chipOn: Color { isDark ? Color(white: 0.9) : Color(white: 0.12) }
    var chipOnInk: Color { isDark ? Color(white: 0.1) : .white }
}

struct AIConversationMetrics {
    let bodySize: CGFloat
    let noteSize: CGFloat
    let noteWidth: CGFloat
    let startSpacing: CGFloat
    let sidePadding: CGFloat
    let quickSize: CGFloat
    let quickPadding: CGFloat
    let pillSize: CGFloat
    let pillPadding: CGFloat
    let inputSize: CGFloat
    let inputMinHeight: CGFloat
    let inputMaxHeight: CGFloat
    let inputInset: CGFloat
    let inputBottom: CGFloat
    let sendSide: CGFloat
    let chipSize: CGFloat
    let chipPaddingV: CGFloat
    let chipPaddingH: CGFloat
    let applyHeight: CGFloat
    let applyFullWidth: Bool
    let closeSide: CGFloat
    let versionButtonSide: CGFloat
    let cardInset: CGFloat
    /// The smallest tappable height (44 pt on iPhone).
    let minimumTarget: CGFloat

    #if os(macOS)
    static let current = AIConversationMetrics(
        bodySize: 13, noteSize: 11.5, noteWidth: 240, startSpacing: 14, sidePadding: 14, quickSize: 13,
        quickPadding: 9, pillSize: 12, pillPadding: 6, inputSize: 13, inputMinHeight: 62, inputMaxHeight: 180,
        inputInset: 10, inputBottom: 10, sendSide: 28, chipSize: 12.5, chipPaddingV: 6, chipPaddingH: 12,
        applyHeight: 30, applyFullWidth: false, closeSide: 24, versionButtonSide: 18, cardInset: 10, minimumTarget: 0)
    #else
    static let current = AIConversationMetrics(
        bodySize: 15, noteSize: 13, noteWidth: 280, startSpacing: 18, sidePadding: 16, quickSize: 15,
        quickPadding: 12, pillSize: 14, pillPadding: 10, inputSize: 16, inputMinHeight: 64, inputMaxHeight: 160,
        inputInset: 12, inputBottom: 12, sendSide: 32, chipSize: 14, chipPaddingV: 9, chipPaddingH: 14,
        applyHeight: 44, applyFullWidth: true, closeSide: 36, versionButtonSide: 28, cardInset: 10, minimumTarget: 44)
    #endif
}

// MARK: - The dimmed, blurred backdrop while the options card is up

private struct AIChoosingBackdrop: ViewModifier {
    let isChoosing: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .grayscale(isChoosing ? 1 : 0)
            .opacity(isChoosing ? 0.45 : 1)
            .allowsHitTesting(!isChoosing)
            .accessibilityHidden(isChoosing)
    }
}

/// Clear at the top, blurrier toward the bottom, over everything behind the options card: four
/// stacked bands of the system's backdrop blur, each faded in further down (the mockup's four
/// `backdrop-filter` bands, 0.8 → 7.2 pt). A backdrop blur, not a layer effect: the thread's
/// scroll view and the input's text view are platform views, which a layer effect cannot draw.
struct AIProgressiveBlur: View {
    private static let bands: [(material: Material, from: CGFloat, to: CGFloat)] = [
        (.ultraThinMaterial, 0.10, 0.45),
        (.ultraThinMaterial, 0.30, 0.60),
        (.thinMaterial, 0.45, 0.80),
        (.regularMaterial, 0.60, 0.95),
    ]

    var body: some View {
        ZStack {
            ForEach(Self.bands.indices, id: \.self) { index in
                let band = Self.bands[index]
                Rectangle()
                    .fill(band.material)
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: band.from),
                        .init(color: .black, location: band.to),
                    ], startPoint: .top, endPoint: .bottom))
                    .opacity(0.4)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

private struct AIQuickActionButton: View {
    let title: String
    let style: AIConversationStyle
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let metrics = AIConversationMetrics.current
        Button(action: action) {
            Text(title)
                .font(.system(size: metrics.quickSize))
                .frame(maxWidth: .infinity)
                .padding(.vertical, metrics.quickPadding)
                .padding(.horizontal, 12)
                .frame(minHeight: metrics.minimumTarget)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(AIFillButtonStyle(fill: style.field, hoverFill: style.blue, ink: style.ink, hoverInk: .white,
                                       isHovering: isHovering, cornerRadius: 10,
                                       glassTint: nil, hoverGlassTint: style.blue))
        .onHover { isHovering = $0 }
    }
}

struct AIPillButton: View {
    let title: String
    let isPrimary: Bool
    let style: AIConversationStyle
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let metrics = AIConversationMetrics.current
        Button(action: action) {
            Text(title)
                .font(.system(size: metrics.pillSize, weight: isPrimary ? .medium : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, metrics.pillPadding)
                .frame(minHeight: metrics.minimumTarget)
                .contentShape(Capsule())
        }
        .buttonStyle(AIFillButtonStyle(fill: isPrimary ? style.blue : style.field,
                                       hoverFill: isPrimary ? style.blue.opacity(0.9) : style.fieldHover,
                                       ink: isPrimary ? .white : style.ink, hoverInk: isPrimary ? .white : style.ink,
                                       isHovering: isHovering, cornerRadius: 999,
                                       glassTint: isPrimary ? style.blue : nil,
                                       hoverGlassTint: isPrimary ? style.blue.opacity(0.9) : style.fieldHover))
        .onHover { isHovering = $0 }
    }
}

/// A filled button with a hover fill (Mac) and a pressed dim (both). On iOS 26 / macOS 26 it is
/// Liquid Glass, tinted where the fill was a colour (Lineform blue); before, the drawn fill.
struct AIFillButtonStyle: ButtonStyle {
    let fill: Color
    let hoverFill: Color
    let ink: Color
    let hoverInk: Color
    let isHovering: Bool
    let cornerRadius: CGFloat
    /// The glass's tint at rest and while hovered or pressed (nil: untinted glass).
    var glassTint: Color? = nil
    var hoverGlassTint: Color? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let hot = isHovering || configuration.isPressed
        configuration.label
            .foregroundStyle(hot ? hoverInk : ink)
            .modifier(AIGlassControl(cornerRadius: cornerRadius, fill: hot ? hoverFill : fill,
                                     glassTint: hot ? hoverGlassTint : glassTint))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .animation(.easeOut(duration: LineformDesign.Motion.hover), value: hot)
    }
}

/// A control's surface: Liquid Glass on iOS 26 / macOS 26 (the Mac's deployment target is
/// macOS 14), the drawn fill before. Material only: the shape and size are the control's own.
private struct AIGlassControl: ViewModifier {
    let cornerRadius: CGFloat
    let fill: Color
    let glassTint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, iOS 26, *) {
            content.glassEffect(.regular.tint(glassTint), in: shape)
        } else {
            content.background(shape.fill(fill))
        }
    }
}

/// A floating surface (the input, the options card): Liquid Glass on iOS 26 / macOS 26; before,
/// the drawn fill, hairline and shadow.
private struct AIGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let fill: Color
    let line: Color
    let shadow: Color
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, iOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(line))
                .shadow(color: shadow, radius: shadowRadius, y: shadowY)
        }
    }
}

struct AIIconButton: View {
    let systemImage: String
    let label: String
    let side: CGFloat
    let style: AIConversationStyle
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: side * 0.42, weight: .semibold))
                .foregroundStyle(isHovering ? style.ink : style.secondaryInk)
                .frame(width: side, height: side)
                .background(Circle().fill(isHovering ? style.field : Color.clear))
                // Drawn at `side`, tapped at least at the platform's minimum.
                .frame(width: max(side, AIConversationMetrics.current.minimumTarget),
                       height: max(side, AIConversationMetrics.current.minimumTarget))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}

/// Tapped at least at the platform's minimum (44 pt on iPhone), whatever is drawn.
private struct AIMinimumTarget: ViewModifier {
    func body(content: Content) -> some View {
        let minimum = AIConversationMetrics.current.minimumTarget
        content
            .frame(minWidth: minimum, minHeight: minimum)
            .contentShape(Rectangle())
    }
}

// MARK: - The thread

private struct AIThreadView: View {
    @ObservedObject var conversation: AIConversation
    let style: AIConversationStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let metrics = AIConversationMetrics.current
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(conversation.messages) { message in
                        AIMessageRow(message: message, conversation: conversation, style: style)
                            .id(message.id)
                            .transition(.opacity)
                    }
                    if conversation.isWorking {
                        AIWorkingBubble(style: style)
                            .id("working")
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, metrics.sidePadding)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: conversation.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: conversation.isWorking) { _, _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
            .animation(EditorMotionPolicy.animation(.easeInOut(duration: 0.22), reduceMotion: reduceMotion),
                       value: conversation.messages.map(\.id))
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: AnyHashable? = conversation.isWorking ? AnyHashable("working") : conversation.messages.last.map { AnyHashable($0.id) }
        guard let target else { return }
        if reduceMotion { proxy.scrollTo(target, anchor: .bottom) } else {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .bottom) }
        }
    }
}

/// A bubble's shape: 16 pt corners with the pointed one (4 pt) at the speaker's bottom side.
private struct AIBubbleShape: Shape {
    let isWriter: Bool

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
            topLeading: 16, bottomLeading: isWriter ? 16 : 4, bottomTrailing: isWriter ? 4 : 16, topTrailing: 16),
            style: .continuous).path(in: rect)
    }
}

private struct AIMessageRow: View {
    let message: AIConversation.Message
    @ObservedObject var conversation: AIConversation
    let style: AIConversationStyle

    var body: some View {
        switch message.content {
        case .request(let text):
            HStack {
                Spacer(minLength: 32)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(AIBubbleShape(isWriter: true).fill(style.writerBubble))
            }
        case .answer(let text):
            aiBubble { Text(text).textSelection(.enabled) }
        case .notice(let text):
            aiBubble { Text(text).foregroundStyle(style.secondaryInk) }
        case .suggestion(let suggestion):
            HStack {
                AISuggestionBubble(messageID: message.id, suggestion: suggestion, conversation: conversation, style: style)
                Spacer(minLength: 24)
            }
        }
    }

    private func aiBubble<Body: View>(@ViewBuilder _ body: () -> Body) -> some View {
        HStack {
            body()
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(AIBubbleShape(isWriter: false).fill(style.aiBubble)
                    .shadow(color: style.aiShadow, radius: 7, y: 2))
            Spacer(minLength: 24)
        }
    }
}

/// A suggested replacement: only the new text. Every change of text (Try Again, ‹ ›, a blank)
/// glides the bubble's height to the new size while the text dips to 18 % and comes back.
private struct AISuggestionBubble: View {
    let messageID: UUID
    let suggestion: AIConversation.Suggestion
    @ObservedObject var conversation: AIConversation
    let style: AIConversationStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textOpacity: Double = 1

    private var version: AIReviewVersion { suggestion.current }
    /// What identifies the text on screen: a version step or a filled blank changes it.
    private var textKey: String { "\(suggestion.index)|\(version.displayText)" }

    var body: some View {
        let metrics = AIConversationMetrics.current
        VStack(alignment: .leading, spacing: 8) {
            Text(version.displayText)
                .textSelection(.enabled)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(textOpacity * (suggestion.isRetrying ? 0.45 : 1))
            if suggestion.isPending, let assumption = version.assumptions.first {
                assumptionLine(assumption)
                    .opacity(textOpacity)
            }
            if suggestion.versions.count > 1 {
                HStack(spacing: 1) {
                    Text(AIConversationPresentation.versionLabel(suggestion.versionNumber))
                        .monospacedDigit()
                        .padding(.trailing, 4)
                    AIVersionButton(systemImage: "chevron.left", label: AIConversationPresentation.previousVersionTitle,
                                    side: metrics.versionButtonSide, style: style,
                                    isEnabled: suggestion.index > 0 && !suggestion.isRetrying) {
                        conversation.showVersion(suggestion.index - 1, of: messageID)
                    }
                    AIVersionButton(systemImage: "chevron.right", label: AIConversationPresentation.nextVersionTitle,
                                    side: metrics.versionButtonSide, style: style,
                                    isEnabled: suggestion.index < suggestion.versions.count - 1 && !suggestion.isRetrying) {
                        conversation.showVersion(suggestion.index + 1, of: messageID)
                    }
                }
                .font(.system(size: metrics.noteSize))
                .foregroundStyle(style.secondaryInk)
                .accessibilityElement(children: .contain)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(AIBubbleShape(isWriter: false).fill(style.aiBubble).shadow(color: style.aiShadow, radius: 7, y: 2))
        .animation(EditorMotionPolicy.animation(.easeInOut(duration: 0.32), reduceMotion: reduceMotion), value: textKey)
        .onChange(of: textKey) { _, _ in
            guard !reduceMotion else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { textOpacity = 0.18 }
            withAnimation(.easeOut(duration: 0.3)) { textOpacity = 1 }
        }
    }

    /// "I assumed you'll share it [by Friday]." — the blank opens the options card.
    private func assumptionLine(_ assumption: AIAssumption) -> some View {
        let parts = assumption.lineParts
        var line = AttributedString(parts.before)
        var blank = AttributedString(assumption.phrase)
        blank.underlineStyle = Text.LineStyle(pattern: .dash, color: style.underline)
        blank.foregroundColor = style.ink
        blank.link = URL(string: "lineform-blank://0")
        line.append(blank)
        line.append(AttributedString(parts.after))
        return Text(line)
            .font(.system(size: AIConversationMetrics.current.pillSize + 0.5))
            .foregroundStyle(style.secondaryInk)
            .tint(style.ink)
            .environment(\.openURL, OpenURLAction { _ in
                conversation.openBlank(assumption, in: messageID)
                return .handled
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(assumption.line)
            .accessibilityHint(AIConversationPresentation.blankHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { conversation.openBlank(assumption, in: messageID) }
    }
}

private struct AIVersionButton: View {
    let systemImage: String
    let label: String
    let side: CGFloat
    let style: AIConversationStyle
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: side * 0.55, weight: .semibold))
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering && isEnabled ? style.field : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering && isEnabled ? style.ink : style.secondaryInk)
        .opacity(isEnabled ? 1 : 0.3)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}

/// The AI is working: three soft dots (a still "Working…" under Reduce Motion).
private struct AIWorkingBubble: View {
    let style: AIConversationStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            Group {
                if reduceMotion {
                    Text(AIConversationPresentation.workingLabel).foregroundStyle(style.secondaryInk)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let time = context.date.timeIntervalSinceReferenceDate
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { index in
                                Circle()
                                    .fill(style.secondaryInk)
                                    .frame(width: 6, height: 6)
                                    .opacity(0.3 + 0.7 * max(0, sin((time * 4) - Double(index) * 0.7)))
                            }
                        }
                        .frame(height: 16)
                    }
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(AIBubbleShape(isWriter: false).fill(style.aiBubble).shadow(color: style.aiShadow, radius: 7, y: 2))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AIConversationPresentation.workingLabel)
            Spacer()
        }
    }
}

// MARK: - The input

private struct AIInputBox: View {
    @ObservedObject var conversation: AIConversation
    let style: AIConversationStyle
    @State private var height: CGFloat = AIConversationMetrics.current.inputMinHeight

    var body: some View {
        let metrics = AIConversationMetrics.current
        let canSend = conversation.canSend
        ZStack(alignment: .bottomTrailing) {
            AIPromptTextView(conversation: conversation, style: style, height: $height)
                .frame(height: min(max(height, metrics.inputMinHeight), metrics.inputMaxHeight))
                .overlay(alignment: .topLeading) {
                    if conversation.draft.isEmpty {
                        Text(AIConversationPresentation.placeholder)
                            .font(.system(size: metrics.inputSize))
                            .foregroundStyle(style.secondaryInk)
                            .padding(.top, AIPromptTextMetrics.inset.height)
                            .padding(.leading, AIPromptTextMetrics.inset.width + AIPromptTextMetrics.placeholderNudge)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            sendButton(canSend: canSend, side: metrics.sendSide)
                // Drawn 7 pt in from the corner, tapped at least at the platform's minimum.
                .padding(7 - max(0, metrics.minimumTarget - metrics.sendSide) / 2)
        }
        .modifier(AIGlassSurface(cornerRadius: 12, fill: style.page, line: style.line,
                                 shadow: .black.opacity(style.isDark ? 0.25 : 0.06), shadowRadius: 6, shadowY: 2))
        .accessibilityActions {
            ForEach(Array(uniqueMatches.enumerated()), id: \.offset) { _, match in
                if let word = conversation.word(for: match) {
                    Button(word.question) { conversation.openWord(match) }
                }
            }
        }
    }

    /// One accessibility action per curated word typed (the first occurrence).
    private var uniqueMatches: [AIPromptWordMatch] {
        var seen = Set<String>()
        return conversation.matches.filter { seen.insert($0.wordID).inserted }
    }

    @ViewBuilder
    private func sendButton(canSend: Bool, side: CGFloat) -> some View {
        if conversation.isWorking {
            Button { conversation.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: side * 0.36, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: side, height: side)
                    .background(Circle().fill(style.blue))
                    .modifier(AIMinimumTarget())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AIConversationPresentation.stopTitle)
        } else {
            Button { conversation.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: side * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: side, height: side)
                    .background(Circle().fill(style.blue))
                    .opacity(canSend ? 1 : 0.35)
                    .modifier(AIMinimumTarget())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(AIConversationPresentation.sendTitle)
            #if os(macOS)
            .keyboardShortcut(.return, modifiers: .command)
            #endif
        }
    }
}

// MARK: - The options card

/// The question as its heading, the chips (several for a word, one for a blank, which also takes
/// "Something else…"), Apply, and ✕. It is modal for VoiceOver; Esc cancels.
private struct AIOptionsCard: View {
    let card: AIConversation.Card
    let style: AIConversationStyle
    let onApply: ([String]) -> Void
    let onCancel: () -> Void

    @State private var options: [String]
    @State private var selection: [String]
    @State private var other = ""
    @FocusState private var otherFocused: Bool

    init(card: AIConversation.Card, initialSelection: [String], style: AIConversationStyle,
         onApply: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.card = card
        self.style = style
        self.onApply = onApply
        self.onCancel = onCancel
        switch card {
        case .word(let word): _options = State(initialValue: word.refinements.map(\.label))
        case .blank(_, let assumption): _options = State(initialValue: assumption.options)
        }
        _selection = State(initialValue: initialSelection)
    }

    private var isMultiple: Bool {
        if case .word = card { return true }
        return false
    }

    var body: some View {
        let metrics = AIConversationMetrics.current
        VStack(alignment: .leading, spacing: 12) {
            Text(card.question)
                .font(.system(size: metrics.bodySize))
                .foregroundStyle(style.secondaryInk)
                .padding(.trailing, metrics.closeSide)
                .accessibilityAddTraits(.isHeader)
            AIFlowLayout(spacing: 7) {
                ForEach(options, id: \.self) { option in
                    chip(option, metrics: metrics)
                }
            }
            if !isMultiple {
                HStack(spacing: 6) {
                    TextField(AIConversationPresentation.somethingElsePlaceholder, text: $other)
                        .textFieldStyle(.plain)
                        .font(.system(size: metrics.chipSize))
                        .padding(.vertical, metrics.chipPaddingV)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.card))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(otherFocused ? style.blue : style.cardLine))
                        .focused($otherFocused)
                        .onSubmit(addTyped)
                    Button(action: addTyped) {
                        Image(systemName: "plus")
                            .font(.system(size: metrics.chipSize + 2, weight: .medium))
                            .frame(width: metrics.applyFullWidth ? 44 : 32, height: metrics.applyFullWidth ? 40 : 30)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.field))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AIConversationPresentation.addTitle)
                }
            }
            Button {
                addTyped()
                onApply(selection)
            } label: {
                Text(AIConversationPresentation.applyTitle)
                    .font(.system(size: metrics.chipSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: metrics.applyFullWidth ? .infinity : nil, minHeight: metrics.applyHeight)
                    .padding(.horizontal, 18)
                    .background(Capsule().fill(style.blue))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AIGlassSurface(cornerRadius: 16, fill: style.card, line: style.cardLine,
                                 shadow: .black.opacity(style.isDark ? 0.4 : 0.14), shadowRadius: 14, shadowY: -2))
        .overlay(alignment: .topTrailing) {
            AIIconButton(systemImage: "xmark", label: AIConversationPresentation.cancelTitle,
                         side: metrics.closeSide, style: style, action: onCancel)
                .padding(metrics.applyFullWidth ? 6 : 8)
        }
        .foregroundStyle(style.ink)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onCancel)
        #if os(macOS)
        .onExitCommand(perform: onCancel)
        #endif
    }

    private func chip(_ option: String, metrics: AIConversationMetrics) -> some View {
        let isOn = selection.contains(option)
        return Button {
            if isMultiple {
                if let index = selection.firstIndex(of: option) { selection.remove(at: index) } else { selection.append(option) }
            } else {
                selection = [option]
                other = ""
            }
        } label: {
            Text(option)
                .font(.system(size: metrics.chipSize))
                .foregroundStyle(isOn ? style.chipOnInk : style.ink)
                .padding(.vertical, metrics.chipPaddingV)
                .padding(.horizontal, metrics.chipPaddingH)
                .background(Capsule().fill(isOn ? style.chipOn : style.chip))
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : style.cardLine))
                .shadow(color: .black.opacity(isOn || style.isDark ? 0 : 0.05), radius: 1, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// + or Return: the typed option becomes a picked chip. Apply keeps it too.
    private func addTyped() {
        let typed = other.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        if !options.contains(typed) { options.append(typed) }
        selection = [typed]
        other = ""
    }
}

/// Chips wrap onto as many lines as they need.
private struct AIFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                let y = row.y + row.height + spacing
                rows.append(Row(indices: [index], y: y, width: size.width, height: size.height))
                continue
            }
            row.indices.append(index)
            row.width = needed
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - The text view under the input

enum AIPromptTextMetrics {
    #if os(macOS)
    static let inset = CGSize(width: 10, height: 9)
    static let placeholderNudge: CGFloat = 0
    #else
    static let inset = CGSize(width: 10, height: 10)
    static let placeholderNudge: CGFloat = 0
    #endif
    /// Room kept for the send button at the trailing edge.
    static let trailingRoom: CGFloat = 42
}

/// Applies the underlines for the curated words: dotted, solid once applied, washed while its
/// card is open. Attributes only — the input's text never changes.
@MainActor
func applyPromptWordAttributes(to storage: NSTextStorage, conversation: AIConversation, style: AIConversationStyle,
                               font: PlatformFontType, ink: PlatformColorType, underline: PlatformColorType,
                               wash: PlatformColorType) {
    let full = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.setAttributes([.font: font, .foregroundColor: ink], range: full)
    var activeID: String?
    if case .word(let word) = conversation.card { activeID = word.id }
    for match in conversation.matches where NSMaxRange(match.range) <= storage.length {
        let solid = conversation.isChosen(match.wordID)
        let pattern: NSUnderlineStyle = solid ? [.single] : [.single, .patternDot]
        storage.addAttribute(.underlineStyle, value: (pattern.union(.thick)).rawValue, range: match.range)
        storage.addAttribute(.underlineColor, value: underline, range: match.range)
        if match.wordID == activeID { storage.addAttribute(.backgroundColor, value: wash, range: match.range) }
    }
    storage.endEditing()
}

#if os(macOS)
typealias PlatformFontType = NSFont
typealias PlatformColorType = NSColor

/// An `NSTextView` for the instruction: Return sends (an input method's Return confirms its
/// candidate first), ⇧Return is a new line, and a click on a curated word opens its card.
struct AIPromptTextView: NSViewRepresentable {
    @ObservedObject var conversation: AIConversation
    let style: AIConversationStyle
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        let text = PromptNSTextView()
        text.delegate = context.coordinator
        text.coordinator = context.coordinator
        text.isRichText = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: AIPromptTextMetrics.inset.width - 5, height: AIPromptTextMetrics.inset.height)
        text.textContainer?.lineFragmentPadding = 5
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.font = .systemFont(ofSize: AIConversationMetrics.current.inputSize)
        text.setAccessibilityLabel(AIConversationPresentation.inputLabel)
        scroll.documentView = text
        context.coordinator.textView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let text = scroll.documentView as? PromptNSTextView else { return }
        // Room for the send button.
        text.textContainer?.size = NSSize(width: max(40, scroll.contentSize.width - AIPromptTextMetrics.trailingRoom),
                                          height: .greatestFiniteMagnitude)
        if text.string != conversation.draft, !text.hasMarkedText() {
            text.string = conversation.draft
        }
        text.insertionPointColor = NSColor(style.underline)
        context.coordinator.restyle()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIPromptTextView
        weak var textView: PromptNSTextView?

        init(_ parent: AIPromptTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.conversation.draft != textView.string { parent.conversation.draft = textView.string }
            restyle()
        }

        func restyle() {
            guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let selection = textView.selectedRanges
            applyPromptWordAttributes(
                to: storage, conversation: parent.conversation, style: parent.style,
                font: .systemFont(ofSize: AIConversationMetrics.current.inputSize), ink: NSColor(parent.style.ink),
                underline: NSColor(parent.style.underline), wash: NSColor(parent.style.field))
            textView.typingAttributes = [.font: NSFont.systemFont(ofSize: AIConversationMetrics.current.inputSize),
                                         .foregroundColor: NSColor(parent.style.ink)]
            textView.selectedRanges = selection
            if let manager = textView.layoutManager, let container = textView.textContainer {
                manager.ensureLayout(for: container)
                let used = manager.usedRect(for: container).height + textView.textContainerInset.height * 2
                if abs(parent.height - used) > 0.5 {
                    let binding = parent.$height
                    DispatchQueue.main.async { binding.wrappedValue = used }
                }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                parent.conversation.send()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.conversation.card != nil { parent.conversation.cancelCard(); return true }
                return false
            default:
                return false
            }
        }

        /// A click (not a drag) ON a curated word's glyphs (`point` in the text container).
        func clicked(at point: NSPoint) {
            guard let textView, let manager = textView.layoutManager, let container = textView.textContainer,
                  let match = parent.conversation.matches.first(where: { match in
                      let glyphs = manager.glyphRange(forCharacterRange: match.range, actualCharacterRange: nil)
                      return manager.boundingRect(forGlyphRange: glyphs, in: container)
                          .insetBy(dx: -2, dy: -3).contains(point)
                  }) else { return }
            parent.conversation.openWord(match)
        }
    }

    final class PromptNSTextView: NSTextView {
        weak var coordinator: Coordinator?

        override func mouseDown(with event: NSEvent) {
            let start = event.locationInWindow
            super.mouseDown(with: event) // tracks until the mouse goes up
            let end = window?.mouseLocationOutsideOfEventStream ?? start
            guard hypot(end.x - start.x, end.y - start.y) < 4, selectedRange().length == 0 else { return }
            var point = convert(start, from: nil)
            point.x -= textContainerOrigin.x
            point.y -= textContainerOrigin.y
            MainActor.assumeIsolated { coordinator?.clicked(at: point) }
        }
    }
}
#else
typealias PlatformFontType = UIFont
typealias PlatformColorType = UIColor

/// A `UITextView` for the instruction: Return is a new line (Send is the button), and a tap on a
/// curated word opens its card.
struct AIPromptTextView: UIViewRepresentable {
    @ObservedObject var conversation: AIConversation
    let style: AIConversationStyle
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let text = UITextView(usingTextLayoutManager: false)
        text.delegate = context.coordinator
        text.backgroundColor = .clear
        text.font = .systemFont(ofSize: AIConversationMetrics.current.inputSize)
        text.adjustsFontForContentSizeCategory = false
        text.textContainerInset = UIEdgeInsets(top: AIPromptTextMetrics.inset.height, left: AIPromptTextMetrics.inset.width - 5,
                                               bottom: AIPromptTextMetrics.inset.height, right: AIPromptTextMetrics.trailingRoom)
        text.textContainer.lineFragmentPadding = 5
        text.accessibilityLabel = AIConversationPresentation.inputLabel
        text.smartQuotesType = .no
        text.smartDashesType = .no
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        text.addGestureRecognizer(tap)
        context.coordinator.textView = text
        return text
    }

    func updateUIView(_ text: UITextView, context: Context) {
        context.coordinator.parent = self
        if text.text != conversation.draft, text.markedTextRange == nil {
            text.text = conversation.draft
        }
        text.tintColor = UIColor(style.underline)
        // The sheet's own light or dark, never the phone's (`.default` follows the phone).
        let appearance: UIKeyboardAppearance = style.isDark ? .dark : .light
        if text.keyboardAppearance != appearance {
            text.keyboardAppearance = appearance
            if text.isFirstResponder { text.reloadInputViews() }
        }
        context.coordinator.restyle()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: AIPromptTextView
        weak var textView: UITextView?

        init(_ parent: AIPromptTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            if parent.conversation.draft != textView.text { parent.conversation.draft = textView.text }
            restyle()
        }

        func restyle() {
            guard let textView, textView.markedTextRange == nil else { return }
            let selection = textView.selectedRange
            let font = UIFont.systemFont(ofSize: AIConversationMetrics.current.inputSize)
            applyPromptWordAttributes(to: textView.textStorage, conversation: parent.conversation, style: parent.style,
                                      font: font, ink: UIColor(parent.style.ink), underline: UIColor(parent.style.underline),
                                      wash: UIColor(parent.style.field))
            textView.typingAttributes = [.font: font, .foregroundColor: UIColor(parent.style.ink)]
            textView.selectedRange = selection
            let width = textView.bounds.width > 0 ? textView.bounds.width : 300
            let used = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            if abs(parent.height - used) > 0.5 {
                let binding = parent.$height
                DispatchQueue.main.async { binding.wrappedValue = used }
            }
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let textView else { return }
            var point = recognizer.location(in: textView)
            point.x -= textView.textContainerInset.left
            point.y -= textView.textContainerInset.top
            // Only a tap ON a word's glyphs: the nearest character to a tap in empty space is the
            // last one, and a caret placed after the text must not open a card.
            let manager = textView.layoutManager
            guard let match = parent.conversation.matches.first(where: { match in
                let glyphs = manager.glyphRange(forCharacterRange: match.range, actualCharacterRange: nil)
                return manager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
                    .insetBy(dx: -2, dy: -4).contains(point)
            }) else { return }
            parent.conversation.openWord(match)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif
