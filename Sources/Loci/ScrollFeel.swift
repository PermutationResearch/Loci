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
        DispatchQueue.main.async { [weak self] in
            self?.configureScrollView()
        }
    }

    private func configureScrollView() {
        guard let scrollView = enclosingScrollView else {
            scheduleConfiguration()
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
