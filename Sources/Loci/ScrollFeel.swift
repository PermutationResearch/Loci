import AppKit
import SwiftUI

struct LociScrollFeel: NSViewRepresentable {
    enum Profile {
        case library
        case compact
    }

    var profile: Profile = .library

    func makeNSView(context: Context) -> ScrollFeelProbeView {
        let view = ScrollFeelProbeView()
        view.profile = profile
        return view
    }

    func updateNSView(_ nsView: ScrollFeelProbeView, context: Context) {
        nsView.profile = profile
        nsView.scheduleConfiguration()
    }
}

final class ScrollFeelProbeView: NSView {
    var profile: LociScrollFeel.Profile = .library
    private weak var configuredScrollView: NSScrollView?
    private var retriesRemaining = 0

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleConfiguration()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func scheduleConfiguration() {
        retriesRemaining = 40
        DispatchQueue.main.async { [weak self] in
            self?.configureScrollView()
        }
    }

    private func configureScrollView() {
        // Detached probes get a fresh viewDidMoveToWindow when they return to
        // a hierarchy; retrying while detached would spin the main queue at
        // 100% CPU forever, so both the window guard and the retry budget are
        // load-bearing.
        guard window != nil else { return }
        guard let scrollView = enclosingScrollView else {
            guard retriesRemaining > 0 else { return }
            retriesRemaining -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.configureScrollView()
            }
            return
        }

        configuredScrollView = scrollView
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.usesPredominantAxisScrolling = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = profile == .library ? .automatic : .none
        scrollView.scrollsDynamically = true
    }
}

extension View {
    func lociScrollFeel(_ profile: LociScrollFeel.Profile = .library) -> some View {
        background {
            LociScrollFeel(profile: profile)
                .allowsHitTesting(false)
        }
    }
}
