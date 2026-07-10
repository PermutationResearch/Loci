import AppKit
import SwiftUI

/// Semantic color tokens backed by AppKit's adaptive system palette.
/// Mirrors `AppMotion`'s role: views should reach for these instead of ad-hoc
/// `.black.opacity(...)` literals so the palette stays consistent, meets
/// contrast minimums, and can honor Increase Contrast (and, later, dark mode)
/// from one place.
///
/// Opacity floors are chosen so text at the app's small sizes clears
/// WCAG AA against white: primary/secondary ink ≥ 4.5:1, faint ink is
/// reserved for decorative, non-essential glyphs.
enum LociColor {
    /// Primary text. ~13.6:1 on white.
    static var ink: Color { Color(nsColor: .labelColor) }
    /// Secondary text (titles' supporting lines, metadata). ~6.5:1 on white.
    static var inkSecondary: Color { Color(nsColor: .secondaryLabelColor) }
    /// Tertiary text — smallest passing tier for non-essential small text. ~4.6:1.
    static var inkTertiary: Color { Color(nsColor: .tertiaryLabelColor) }
    /// Decorative glyphs and hairline icons only; below AA for text — never
    /// use for words the user must read.
    static var inkFaint: Color { Color(nsColor: .quaternaryLabelColor) }

    /// Window and canvas surface.
    static var surface: Color { Color(nsColor: .windowBackgroundColor) }
    /// Large working planes such as the Board and Explore modes.
    static var canvas: Color { Color(nsColor: .textBackgroundColor) }
    /// Slightly recessed panels, rows, and wells.
    static var surfaceRecessed: Color { Color(nsColor: .controlBackgroundColor) }
    /// Hover/selected fills for list rows and tiles.
    static var surfaceSelected: Color { Color(nsColor: .selectedContentBackgroundColor).opacity(0.16) }

    /// Hairline separators and strokes.
    static var hairline: Color { Color(nsColor: .separatorColor) }
    /// Stronger borders (focused fields, active cards).
    static var border: Color { Color(nsColor: .gridColor) }

    /// Platform accent for the one place color should carry interaction meaning.
    static var accent: Color { Color(nsColor: .controlAccentColor) }
}

/// Semantic type scale. The app renders dense, chrome-like UI, so sizes sit
/// below the system defaults; keep every size ≥ 10pt for readability and pair
/// anything smaller than `body` with `LociColor.ink`/`inkSecondary`, never
/// `inkFaint`.
enum LociFont {
    /// Section headers and sheet titles.
    static var title: Font { .system(.headline, design: .default, weight: .semibold) }
    /// Emphasized row titles.
    static var headline: Font { .system(.subheadline, design: .default, weight: .semibold) }
    /// Default reading text.
    static var body: Font { .system(.body, design: .default, weight: .regular) }
    /// Supporting metadata under titles.
    static var caption: Font { .system(.caption, design: .default, weight: .medium) }
    /// Uppercase micro-labels (tracking recommended); the smallest permitted size.
    static var label: Font { .system(.caption2, design: .default, weight: .semibold) }
    /// Numeric badges and counts.
    static var badge: Font { .system(.caption2, design: .rounded, weight: .semibold) }
}

private struct LociScaledFontModifier: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: Font.Weight,
        design: Font.Design
    ) {
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.lociFont(size: scaledSize, weight: weight, design: design, relativeTo: .body)
    }
}

extension View {
    /// Preserves Loci's authored compact type/icon geometry while allowing the
    /// system Dynamic Type setting to scale it from an appropriate baseline.
    func lociFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> some View {
        modifier(
            LociScaledFontModifier(
                size: size,
                relativeTo: textStyle,
                weight: weight,
                design: design
            )
        )
    }
}

/// Spacing scale — multiples of 2 with the grid's common paddings named.
enum LociSpacing {
    /// Icon-to-text gaps inside a row.
    static let tight: CGFloat = 4
    /// Sibling elements inside a component.
    static let compact: CGFloat = 8
    /// Component padding (row insets, field padding).
    static let element: CGFloat = 12
    /// Between distinct components in a panel.
    static let component: CGFloat = 16
    /// Panel and sheet margins.
    static let panel: CGFloat = 20
    /// Workspace gutters.
    static let gutter: CGFloat = 28
}
