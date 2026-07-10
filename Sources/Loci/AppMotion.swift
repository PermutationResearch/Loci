import AppKit
import SwiftUI

enum AppMotion {
    static var instant: Animation { motion(.easeOut(duration: 0.055)) }
    static var quick: Animation { motion(.spring(response: 0.14, dampingFraction: 0.92)) }
    static var snappy: Animation { motion(.spring(response: 0.18, dampingFraction: 0.90)) }
    static var smooth: Animation { motion(.spring(response: 0.22, dampingFraction: 0.88)) }
    static var selection: Animation { motion(.spring(response: 0.16, dampingFraction: 0.86)) }
    static var hero: Animation { motion(.spring(response: 0.26, dampingFraction: 0.87, blendDuration: 0.02)) }
    static var closeHero: Animation { motion(.spring(response: 0.16, dampingFraction: 0.94, blendDuration: 0.01)) }
    static var reveal: Animation { motion(.spring(response: 0.30, dampingFraction: 0.84)) }
    static var chromeReveal: Animation { motion(.spring(response: 0.18, dampingFraction: 0.92)) }
    static var panel: Animation { motion(.spring(response: 0.34, dampingFraction: 0.86)) }
    static var toast: Animation { motion(.spring(response: 0.32, dampingFraction: 0.82)) }
    static var hover: Animation { motion(.spring(response: 0.16, dampingFraction: 0.90)) }

    static var previewTransition: AnyTransition {
        .opacity
    }

    static var bottomToastTransition: AnyTransition {
        .move(edge: .bottom).combined(with: .opacity)
    }

    static var trailingPanelTransition: AnyTransition {
        .move(edge: .trailing).combined(with: .opacity)
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static func motion(_ animation: Animation) -> Animation {
        reduceMotion ? .easeOut(duration: 0.01) : animation
    }
}
