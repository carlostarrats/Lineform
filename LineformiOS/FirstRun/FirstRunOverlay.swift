import SwiftUI

/// First run, over the already-loaded blank document: the Mac's line animation, "What to expect"
/// (which fades in and out), then the three points and Start Writing. A tap or swipe skips
/// ahead; Return (hardware keyboard) and the VoiceOver "Continue" action do the same, so it can
/// be left without a tap. Reaching `.done` marks first run completed, once, then calls `onFinish`.
///
/// It always draws on the intro's paper, in a fixed light look, whatever the reading theme.
/// Under Reduce Motion every native fade is off (the web page itself shows the finished line).
struct FirstRunOverlay: View {
    private let onFinish: () -> Void
    @State private var stage: FirstRunStage = .line
    @State private var isDismissing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One column for the point symbols, so the three lines of text start at the same edge.
    @ScaledMetric(relativeTo: .body) private var symbolColumnWidth: CGFloat = 28

    /// The intro's `--paper`, and the overlay's ink.
    static let paper = Color(red: 0xF7 / 255, green: 0xF6 / 255, blue: 0xF0 / 255)
    static let ink = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255)
    /// The point symbols, in the order of `FirstRunCopy.points`.
    static let pointSymbols = ["lock", "icloud", "doc.richtext"]

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack {
            Self.paper.ignoresSafeArea()
            if stage == .line {
                FirstRunLineView()
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            if stage == .expect {
                Text(FirstRunCopy.heading)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
            if stage == .points {
                points
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Self.ink)
        .environment(\.colorScheme, .light)
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
            // On the points, a vertical drag scrolls them (the largest text sizes); a sideways
            // swipe still skips ahead.
            let translation = value.translation
            if stage == .points, abs(translation.height) >= abs(translation.width) { return }
            advance()
        })
        .background {
            // Return on a hardware keyboard.
            Button(String(localized: "Continue")) { advance() }
                .keyboardShortcut(.defaultAction)
                .hidden()
        }
        .accessibilityElement(children: stage == .points ? .contain : .ignore)
        .accessibilityLabel(stage == .line ? Text(String(localized: "Welcome to Lineform")) : Text(FirstRunCopy.heading))
        .accessibilityAction(named: Text(String(localized: "Continue"))) { advance() }
        // VoiceOver stays on first run; the document underneath is not reachable until it ends.
        .accessibilityAddTraits(.isModal)
        .task(id: stage) {
            guard let delay = stage.autoAdvanceDelay(reduceMotion: reduceMotion) else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            advance()
        }
    }

    /// The three points and Start Writing, centred when they fit and scrolling when they do not
    /// (the largest Dynamic Type sizes).
    private var points: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(zip(Self.pointSymbols, FirstRunCopy.points)), id: \.1) { symbol, point in
                        Label {
                            Text(point)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: symbol)
                                .frame(width: symbolColumnWidth)
                                .accessibilityHidden(true)
                        }
                    }
                    Button { advance() } label: {
                        // The paper on the ink capsule: the container's ink would hide the label.
                        Text(FirstRunCopy.startWriting)
                            .foregroundStyle(Self.paper)
                    }
                        .font(.body.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .tint(Self.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// The next stage, or, from the points, the document. A second call while dismissing does
    /// nothing, so a double tap marks and finishes once.
    private func advance() {
        guard !isDismissing else { return }
        let next = stage.next
        guard next != stage else { return }
        if next == .done {
            isDismissing = true
            FirstRunGate.markCompleted()
            onFinish()
            return
        }
        withAnimation(EditorMotionPolicy.animation(.easeOut(duration: Self.stageFade(for: next)), reduceMotion: reduceMotion)) {
            stage = next
        }
    }

    /// "What to expect" fades in over 0.4 s; the other stage changes take the cards' 0.24 s.
    private static func stageFade(for stage: FirstRunStage) -> TimeInterval {
        stage == .expect ? 0.4 : 0.24
    }
}
