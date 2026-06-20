import Foundation
import Persistence

// MARK: - OPMLWriter

/// Writes subscribed podcasts as an OPML 2.0 subscription list.
///
/// Manual string building (mirroring `XSPFWriter`), emitting a flat `<body>` of
/// `type="rss"` outlines. The head `<title>` is fixed app-owned metadata, kept
/// English for round-trip stability, not localized UI chrome.
public enum OPMLWriter {
    /// Serializes `podcasts` to OPML 2.0. `now` is injected for a deterministic
    /// `dateCreated` in tests.
    public static func write(_ podcasts: [Podcast], now: Date = Date()) -> String {
        var out = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        out += #"<opml version="2.0">"# + "\n"
        out += "  <head>\n"
        out += "    <title>Bocan Podcast Subscriptions</title>\n"
        out += "    <dateCreated>\(Self.rfc822.string(from: now))</dateCreated>\n"
        out += "  </head>\n"
        out += "  <body>\n"
        for podcast in podcasts {
            let title = self.escape(podcast.title)
            var line = #"    <outline type="rss" text="\#(title)" title="\#(title)" xmlUrl="\#(self.escape(podcast.feedURL))""#
            if let link = podcast.link, !link.isEmpty {
                line += #" htmlUrl="\#(self.escape(link))""#
            }
            line += "/>\n"
            out += line
        }
        out += "  </body>\n"
        out += "</opml>\n"
        return out
    }

    /// RFC 822 date for `dateCreated`, pinned to `en_US_POSIX` + GMT so a
    /// non-Gregorian device locale cannot drift the year (Library convention).
    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&apos;")
            default: out.append(character)
            }
        }
        return out
    }
}
