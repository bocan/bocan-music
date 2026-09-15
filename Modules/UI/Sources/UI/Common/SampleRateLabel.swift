import Foundation

/// The display text for a sample rate, shared by every surface that shows
/// one (#524): Get Info, the track panel, the songs table and the radio
/// station sheet.
///
/// Whole kilohertz drop the decimal: "48 kHz", "96 kHz". Anything else keeps
/// one: "44.1 kHz", "88.2 kHz", "352.8 kHz". Both forms resolve through the
/// catalog, so a surface that builds the text itself cannot quietly skip
/// localization the way the tag editor's own formatter did.
enum SampleRateLabel {
    static func text(for hertz: Int) -> String {
        if hertz.isMultiple(of: 1000) {
            return L10n.string("\(hertz / 1000) kHz")
        }
        return L10n.string("\(String(format: "%.1f", Double(hertz) / 1000)) kHz")
    }
}
