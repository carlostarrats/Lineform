import AppKit
import SwiftUI

@MainActor
final class LineformAppDelegate: NSObject, NSApplicationDelegate {
    private let firstLaunchIntroPresenter = FirstLaunchIntroPresenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        firstLaunchIntroPresenter.showIfNeeded()
    }
}

@MainActor
final class FirstLaunchIntroPresenter {
    private enum Defaults {
        static let completedKey = "LineformFirstLaunchIntroCompleted"
        static let alwaysShowKey = "LineformAlwaysShowFirstLaunchIntro"
    }

    private var window: NSWindow?

    func showIfNeeded() {
        let defaults = UserDefaults.standard
        let environmentForcesIntro = ProcessInfo.processInfo.environment["LINEFORM_SHOW_FIRST_LAUNCH_INTRO"] == "1"
        let defaultsForceIntro = defaults.bool(forKey: Defaults.alwaysShowKey)
        guard environmentForcesIntro || defaultsForceIntro || !defaults.bool(forKey: Defaults.completedKey) else {
            return
        }

        show()
    }

    private func show() {
        guard window == nil, let screen = NSScreen.main else {
            return
        }

        let overlay = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        overlay.backgroundColor = .clear
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.hasShadow = false
        overlay.isMovable = false
        overlay.isOpaque = false
        overlay.level = .floating
        overlay.titleVisibility = .hidden

        let hostingView = NSHostingView(rootView: FirstLaunchIntroOverlayView { [weak self] in
            self?.dismiss()
        })
        hostingView.frame = screen.frame
        overlay.contentView = hostingView
        overlay.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = overlay
    }

    private func dismiss() {
        UserDefaults.standard.set(true, forKey: Defaults.completedKey)
        guard let window else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                window.orderOut(nil)
                self?.window = nil
            }
        }
    }
}

struct FirstLaunchIntroOverlayView: View {
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var writeProgress = 0.0
    @State private var finalInk = 0.0
    @State private var effects = 0.0

    var body: some View {
        ZStack {
            DesktopGlassWash()
                .ignoresSafeArea()

            LineformIntroGlyphField()
                .opacity(0.24 * effects)
                .blur(radius: 0.8)

            VStack(spacing: 24) {
                ZStack {
                    LineformWordmarkImage()
                        .opacity(0.22 * effects)
                        .blur(radius: 18)
                        .offset(x: 10, y: 20)

                    LineformWordmarkImage()
                        .opacity(finalInk)
                        .shadow(color: .white.opacity(0.45), radius: 0, x: 0, y: 1)

                    LineformWordmarkImage()
                        .opacity(max(0, 1 - finalInk))
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: max(1, 920 * writeProgress))
                                .blur(radius: 18)
                        }
                        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 12)
                }
                .frame(width: 920, height: 368)
                .overlay(alignment: .trailing) {
                    Text("Simple markdown editing")
                        .font(.system(size: 30, weight: .regular, design: .default))
                        .foregroundStyle(.black.opacity(0.86))
                        .offset(x: -30, y: 112)
                        .opacity(writeProgress)
                }

                Button(action: dismiss) {
                    HStack(spacing: 18) {
                        Text("Get Started")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 28, weight: .medium))
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.92))
                    .frame(minWidth: 214, minHeight: 62)
                    .padding(.horizontal, 18)
                    .background {
                        Capsule()
                            .fill(.white.opacity(0.86))
                            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 14)
                    }
                }
                .buttonStyle(.plain)
                .opacity(finalInk)
                .offset(y: finalInk < 1 ? 10 : 0)
            }
            .offset(y: -26)
        }
        .onAppear(perform: runIntro)
    }

    private func runIntro() {
        if reduceMotion {
            writeProgress = 1
            finalInk = 1
            effects = 1
            return
        }

        withAnimation(.easeOut(duration: 0.7)) {
            effects = 1
        }
        withAnimation(.easeInOut(duration: 1.0)) {
            writeProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.3)) {
                finalInk = 1
            }
        }
    }
}

private struct DesktopGlassWash: View {
    var body: some View {
        Color.clear
    }
}

private struct LineformWordmarkImage: View {
    var body: some View {
        if let image = NSImage(named: "LineformWordmark") {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Text("Lineform")
                .font(.custom("Snell Roundhand", size: 190))
                .foregroundStyle(.black)
                .minimumScaleFactor(0.6)
        }
    }
}

private struct LineformIntroGlyphField: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                ghost(width: 420, x: width * 0.17, y: height * 0.22, rotation: -19, opacity: 0.32)
                ghost(width: 520, x: width * 0.28, y: height * 0.72, rotation: 17, opacity: 0.2)
                ghost(width: 480, x: width * 0.72, y: height * 0.26, rotation: 11, opacity: 0.26)
                ghost(width: 560, x: width * 0.82, y: height * 0.78, rotation: -13, opacity: 0.18)
            }
        }
        .allowsHitTesting(false)
    }

    private func ghost(width: CGFloat, x: CGFloat, y: CGFloat, rotation: Double, opacity: Double) -> some View {
        LineformWordmarkImage()
            .frame(width: width)
            .foregroundStyle(.black)
            .opacity(opacity)
            .rotationEffect(.degrees(rotation))
            .position(x: x, y: y)
    }
}
