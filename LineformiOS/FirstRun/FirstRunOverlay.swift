import SwiftUI
import UIKit

/// First run, over the already-loaded blank document: the Mac's line animation, "What to expect"
/// (which fades in and out), then the points and Start Writing. A tap or swipe skips ahead;
/// Return (hardware keyboard) and the VoiceOver "Continue" action do the same, so it can be left
/// without a tap. `FirstRunFlow` holds the stages, the timing and the one-time finish (the
/// completed flag, then `onFinish`).
///
/// It always draws on the intro's paper, in a fixed light look (status bar included), whatever
/// the reading theme. Under Reduce Motion every native fade is off (the web page itself shows the
/// finished line).
struct FirstRunOverlay: View {
    @State private var flow: FirstRunFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One column for the point symbols, so the lines of text start at the same edge.
    @ScaledMetric(relativeTo: .body) private var symbolColumnWidth: CGFloat = 28

    /// The intro's `--paper`, and the overlay's ink.
    static let paper = Color(red: 0xF7 / 255, green: 0xF6 / 255, blue: 0xF0 / 255)
    static let ink = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255)

    init(defaults: UserDefaults = .standard, onFinish: @escaping () -> Void) {
        _flow = State(initialValue: FirstRunFlow(defaults: defaults, onFinish: onFinish))
    }

    /// What the stage timer waits on: the stage, and for the line, whether the page has painted.
    private struct TimerKey: Hashable {
        var stage: FirstRunStage
        var lineIsReady: Bool
    }

    var body: some View {
        let stage = flow.stage
        ZStack {
            Self.paper.ignoresSafeArea()
            if stage == .line {
                FirstRunLineView(onReady: { flow.lineDidBecomeReady() })
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
            // `.done` keeps the points on screen while the document screen fades first run out.
            if stage == .points || stage == .done {
                points
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Self.ink)
        .environment(\.colorScheme, .light)
        // Dark status bar text on the paper, also when the system is in Dark Mode. Only while
        // first run is on screen: the preference goes away with the overlay.
        .preferredColorScheme(.light)
        .contentShape(Rectangle())
        .onTapGesture { userAdvance() }
        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
            // On the points, a vertical drag scrolls them (the largest text sizes); a sideways
            // swipe still skips ahead.
            let translation = value.translation
            if flow.stage == .points, abs(translation.height) >= abs(translation.width) { return }
            userAdvance()
        })
        .background {
            // Return on a hardware keyboard.
            Button(String(localized: "Continue")) { userAdvance() }
                .keyboardShortcut(.defaultAction)
                .hidden()
        }
        .accessibilityElement(children: stage == .points || stage == .done ? .contain : .ignore)
        .accessibilityLabel(stage == .line ? Text(String(localized: "Welcome to Lineform")) : Text(FirstRunCopy.heading))
        .accessibilityAction(named: Text(String(localized: "Continue"))) { userAdvance() }
        // VoiceOver stays on first run; the document underneath is not reachable until it ends.
        // On "What to expect" the single element is the heading.
        .accessibilityAddTraits(stage == .expect ? [.isModal, .isHeader] : .isModal)
        .onChange(of: stage) { _, newStage in
            switch newStage {
            case .expect: UIAccessibility.post(notification: .layoutChanged, argument: nil)
            case .points: UIAccessibility.post(notification: .screenChanged, argument: nil)
            case .line, .done: break
            }
        }
        .task(id: TimerKey(stage: stage, lineIsReady: flow.lineReadyAt != nil)) {
            guard let deadline = flow.autoAdvanceDeadline(reduceMotion: reduceMotion) else { return }
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            animated(to: stage.next) { flow.autoAdvance(from: stage) }
        }
    }

    /// The points and Start Writing, centred when they fit and scrolling when they do not (the
    /// largest Dynamic Type sizes).
    private var points: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(FirstRunCopy.pointItems.enumerated()), id: \.offset) { _, point in
                        Label {
                            Text(point.text)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: point.symbol)
                                .frame(width: symbolColumnWidth)
                                .accessibilityHidden(true)
                        }
                    }
                    Button { userAdvance() } label: {
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

    private func userAdvance() {
        animated(to: flow.stage.next) { flow.userAdvance() }
    }

    /// Runs `change` inside the fade for the stage it leads to ("What to expect" fades in over
    /// 0.4 s, the others take the cards' 0.24 s; none under Reduce Motion).
    private func animated(to next: FirstRunStage, _ change: () -> Void) {
        let duration: TimeInterval = next == .expect ? 0.4 : 0.24
        withAnimation(EditorMotionPolicy.animation(.easeOut(duration: duration), reduceMotion: reduceMotion)) {
            change()
        }
    }
}
