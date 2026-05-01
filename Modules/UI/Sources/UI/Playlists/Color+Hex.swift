import AppKit
import SwiftUI

// MARK: - Color(hex:)

extension Color {
    /// Creates a colour from a "#RRGGBB" or "RRGGBB" hex string.  Returns
    /// `nil` on malformed input.
    init?(hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else {
            return nil
        }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }

    /// Converts this colour to a `"#RRGGBB"` hex string via the sRGB colour space.
    ///
    /// Returns `nil` if the colour cannot be represented in sRGB (e.g. wide-gamut
    /// Display P3 values that fall outside the 0–1 sRGB range).
    func toHex() -> String? {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        ns.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}
