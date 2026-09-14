import Foundation

/// The display name of a track's channel count, and the hover text that says
/// what Bòcan does with it (ADR-091 slice 4).
///
/// The layouts a listener knows by name get the name; anything else is a
/// count. Get Info and the track panel share this so the two rows never
/// drift apart.
enum ChannelLayoutLabel {
    /// "Mono", "Stereo", "5.1", "7.1", or "N channels".
    static func text(for count: Int) -> String {
        switch count {
        case 1:
            L10n.string("Mono")

        case 2:
            L10n.string("Stereo")

        case 6:
            L10n.string("5.1")

        case 8:
            L10n.string("7.1")

        default:
            L10n.string("\(count) channels")
        }
    }

    /// Hover text for a channels row. A surround mix is played folded to
    /// stereo, and neither decoder renders Dolby Atmos objects; the row says
    /// so rather than implying otherwise.
    static func help(for count: Int) -> String {
        if count > 2 {
            return L10n.string("This surround mix plays folded to stereo. Dolby Atmos objects are not rendered.")
        }
        return L10n.string("The number of audio channels in the file.")
    }
}
