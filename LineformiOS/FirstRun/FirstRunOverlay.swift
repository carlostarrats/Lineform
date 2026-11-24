import SwiftUI
import UIKit

/// First run, over the already-loaded blank document. Nothing moves on by itself:
///
/// 1. **Welcome.** The Mac's wordmark writes itself slowly, centred, over the intro's shader with
///    its colour turned up (`FirstRunLineView`). Once it is written, the tagline and Get Started
///    fade in below it.
/// 2. **Points.** Get Started shrinks the wordmark and glides it to the top
///    (`FirstRunTiming.shrinkSeconds`, ease-in-out) while the shader quietens; the four points
///    arrive one after another, then Start Writing.
/// 3. Start Writing finishes (`FirstRunFlow`: the completed flag, then `onFinish`), which opens the
///    blank document ready to type.
///
/// Each button also answers Return on a hardware keyboard while it is on screen. It always draws
/// on the intro's paper, in a fixed light look (status bar included), whatever the reading theme.
/// Under Reduce Motion every movement becomes a crossfade (the web page itself shows the finished
/// wordmark at once).
struct FirstRunOverlay: View {
    @State private var flow: FirstRunFlow
    /// The wordmark sits small at the top (the points screen).
    @State private var wordmarkAtTop = false
    /// The wordmark's opacity: only Reduce Motion's crossfade changes it.
    @State private var wordmarkOpacity = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 44

    /// The intro's `--paper`, and the overlay's inks.
    static let paper = Color(red: 0xF7 / 255, green: 0xF6 / 255, blue: 0xF0 / 255)
    static let ink = Color(red: 0x14 / 255, green: 0x13 / 255, blue: 0x10 / 255)
    /// The points' body text: 6.3:1 on the paper.
    static let secondaryInk = Color(red: 0x5C / 255, green: 0x5A / 255, blue: 0x54 / 255)
    /// Lineform blue, Start Writing's fill (4.9:1 under white text).
    static let lineformBlue = Color(red: 0x2F / 255, green: 0x6B / 255, blue: 0xDE / 255)

    init(defaults: UserDefaults = .standard, onFinish: @escaping () -> Void) {
        _flow = State(initialValue: FirstRunFlow(defaults: defaults, onFinish: onFinish))
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = FirstRunLayout(size: proxy.size, safeArea: proxy.safeAreaInsets)
            ZStack(alignment: .top) {
                Self.paper.ignoresSafeArea()
                FirstRunLineView(
                    isQuiet: flow.stage != .welcome,
                    onWritten: { revealGetStarted() }
                )
                .ignoresSafeArea()
                // Shrunk to the top, the page's edges would cut the colour field off in a hard
                // line: feather them as it shrinks.
                .mask {
                    ZStack {
                        Rectangle().opacity(wordmarkAtTop ? 0 : 1)
                        Self.featheredEdges.opacity(wordmarkAtTop ? 1 : 0)
                    }
                    .ignoresSafeArea()
                }
                .scaleEffect(wordmarkAtTop ? FirstRunLayout.topScale : 1)
                .offset(y: wordmarkAtTop ? layout.topOffset : 0)
                .opacity(wordmarkOpacity)
                .accessibilityHidden(true)

                wordmarkElement(layout)
                welcome(layout)
                points(layout)
            }
        }
        .foregroundStyle(Self.ink)
        .environment(\.colorScheme, .light)
        // Dark status bar text on the paper, also when the system is in Dark Mode. Only while
        // first run is on screen: the preference goes away with the overlay.
        .preferredColorScheme(.light)
        .accessibilityElement(children: .contain)
        // VoiceOver stays on first run; the document underneath is not reachable until it ends.
        .accessibilityAddTraits(.isModal)
        .onAppear {
            // A VoiceOver user gets Get Started at once rather than waiting out the write-on.
            if UIAccessibility.isVoiceOverRunning { revealGetStarted() }
        }
        .task {
            // The page never said the wordmark is written: show Get Started anyway.
            try? await Task.sleep(for: FirstRunTiming.getStartedCap)
            guard !Task.isCancelled else { return }
            revealGetStarted()
        }
    }

    /// Opaque in the middle, clear at the edges: wide fades top and bottom, narrow ones at the
    /// sides (the wordmark runs to 11 % of the width from each side).
    private static var featheredEdges: some View {
        LinearGradient(
            stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                    .init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
            startPoint: .top, endPoint: .bottom
        )
        .mask {
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                        .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    // MARK: - Wordmark

    /// The wordmark for VoiceOver: the web view is hidden from it, so this stands in its place.
    private func wordmarkElement(_ layout: FirstRunLayout) -> some View {
        let scale = wordmarkAtTop ? FirstRunLayout.topScale : 1
        return Rectangle()
            .fill(.clear)
            .frame(width: layout.wordmarkSize.width * scale, height: layout.wordmarkSize.height * scale)
            .accessibilityElement()
            .accessibilityLabel(Text(String(localized: "Welcome to Lineform")))
            .accessibilityAddTraits(.isHeader)
            .position(x: layout.size.width / 2, y: wordmarkAtTop ? layout.topWordmarkCenterY : layout.centerY)
            .allowsHitTesting(false)
    }

    // MARK: - Welcome

    /// The tagline and Get Started: only once the wordmark is written, and only on the welcome
    /// (absent rather than transparent, so VoiceOver never finds a button that is not there).
    @ViewBuilder
    private func welcome(_ layout: FirstRunLayout) -> some View {
        if flow.stage == .welcome {
            let written = flow.isWordmarkWritten
            VStack(spacing: 0) {
                Color.clear.frame(height: layout.centerY + layout.wordmarkSize.height / 2 + 16)
                if written {
                    Text(FirstRunCopy.tagline)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .transition(.opacity.animation(fade(0.8, delay: 0.15)))
                }
                Spacer(minLength: 24)
                if written {
                    Button(action: getStarted) {
                        HStack(spacing: 10) {
                            Text(FirstRunCopy.getStarted)
                            Image(systemName: "arrow.right")
                                .accessibilityHidden(true)
                        }
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 30)
                        .frame(minHeight: 52)
                        .background(Capsule().fill(Self.ink))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .transition(arrival(rise: 8).animation(fade(0.7)))
                }
            }
            .padding(.bottom, 56)
            .frame(width: layout.size.width, height: layout.size.height)
            .transition(.opacity.animation(fade(0.3)))
        }
    }

    // MARK: - Points

    @ViewBuilder
    private func points(_ layout: FirstRunLayout) -> some View {
        if flow.stage != .welcome {
            FirstRunPointsView(
                reduceMotion: reduceMotion,
                arrival: { rise, delay in arrival(rise: rise).animation(fade(0.6, delay: delay)) },
                onStartWriting: { startWriting() }
            )
            .padding(.top, layout.pointsTop)
            .frame(width: layout.size.width, height: layout.size.height)
        }
    }

    /// How a piece arrives: a fade and a small rise, or only the fade under Reduce Motion.
    private func arrival(rise: CGFloat) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: rise))
    }

    // MARK: - Actions

    private func revealGetStarted() {
        guard flow.stage == .welcome, !flow.isWordmarkWritten else { return }
        flow.wordmarkDidFinishWriting()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    /// The wordmark shrinks and glides to the top (a crossfade under Reduce Motion) while the
    /// welcome fades out and the points arrive.
    private func getStarted() {
        guard flow.advance(from: .welcome) else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                wordmarkOpacity = 0
            } completion: {
                var jump = Transaction()
                jump.disablesAnimations = true
                withTransaction(jump) { wordmarkAtTop = true }
                withAnimation(.easeIn(duration: 0.35)) { wordmarkOpacity = 1 }
            }
        } else {
            withAnimation(.easeInOut(duration: FirstRunTiming.shrinkSeconds)) {
                wordmarkAtTop = true
            }
        }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func startWriting() {
        flow.advance(from: .points)
    }

    /// A fade, with the movement it carries; the same fade under Reduce Motion (the callers drop
    /// the movement there), just quicker.
    private func fade(_ duration: Double, delay: Double = 0) -> Animation {
        reduceMotion
            ? .easeOut(duration: min(duration, 0.4)).delay(delay * 0.6)
            : .easeOut(duration: duration).delay(delay)
    }
}

/// The four points and Start Writing. They arrive one after another once the view is on screen
/// (`FirstRunTiming`); each is absent until it arrives, so VoiceOver meets only what is shown.
private struct FirstRunPointsView: View {
    var reduceMotion: Bool
    /// The overlay's arrival transition for a rise and a delay.
    var arrival: (CGFloat, Double) -> AnyTransition
    var onStartWriting: () -> Void

    @State private var arrived = false
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 44

    var body: some View {
        let items = FirstRunCopy.pointItems
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, point in
                        if arrived {
                            row(point)
                                .transition(arrival(12, FirstRunTiming.pointDelay(index)))
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            ZStack {
                if arrived {
                    Button(action: onStartWriting) {
                        Text(FirstRunCopy.startWriting)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Capsule().fill(FirstRunOverlay.lineformBlue))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .transition(arrival(10, FirstRunTiming.startWritingDelay(pointCount: items.count)))
                }
            }
            .frame(minHeight: 54)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .onAppear {
            withAnimation { arrived = true }
        }
    }

    private func row(_ point: FirstRunPoint) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: point.symbol)
                .font(.body.weight(.medium))
                .frame(width: iconSize, height: iconSize)
                .background(
                    RoundedRectangle(cornerRadius: iconSize * 14 / 44, style: .continuous)
                        .fill(Color.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(point.title)
                    .font(.headline)
                Text(point.text)
                    .font(.subheadline)
                    .foregroundStyle(FirstRunOverlay.secondaryInk)
                    .lineSpacing(2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where first run's pieces sit, in the overlay's safe-area coordinates. The web view fills the
/// whole screen and centres the wordmark on it at 78 % of the width (`pageAdjustmentScript`).
struct FirstRunLayout {
    /// The wordmark's size on the points screen, relative to the welcome.
    static let topScale: CGFloat = 0.5
    /// The wordmark's aspect ratio (the intro's `Lineform.svg`, 639 × 255).
    static let wordmarkAspect: CGFloat = 639 / 255
    /// Gap from the safe area's top to the small wordmark.
    static let topMargin: CGFloat = 20

    var size: CGSize
    var safeArea: EdgeInsets

    /// The welcome wordmark's size (the page draws it at 78 % of the screen width).
    var wordmarkSize: CGSize {
        let width = (size.width + safeArea.leading + safeArea.trailing) * 0.78
        return CGSize(width: width, height: width / Self.wordmarkAspect)
    }

    /// The screen's centre (where the page centres the wordmark), measured from the safe top.
    var centerY: CGFloat {
        (size.height + safeArea.top + safeArea.bottom) / 2 - safeArea.top
    }

    var topWordmarkCenterY: CGFloat {
        Self.topMargin + wordmarkSize.height * Self.topScale / 2
    }

    /// The web view's offset that brings the scaled wordmark to the top.
    var topOffset: CGFloat {
        topWordmarkCenterY - centerY
    }

    /// Where the points begin, below the small wordmark.
    var pointsTop: CGFloat {
        Self.topMargin + wordmarkSize.height * Self.topScale + 28
    }
}
