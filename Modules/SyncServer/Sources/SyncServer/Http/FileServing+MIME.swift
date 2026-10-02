import Foundation

// MARK: - MIME types

extension FileServing {
    static func audioMIME(_ format: String) -> String {
        switch format.lowercased() {
        case "flac":
            "audio/flac"

        case "mp3", "audio/mpeg":
            "audio/mpeg"

        case "m4a", "aac", "mp4", "audio/mp4":
            "audio/mp4"

        case "ogg", "oga":
            "audio/ogg"

        case "opus":
            "audio/opus"

        case "wav":
            "audio/wav"

        case "aiff", "aif":
            "audio/aiff"

        default:
            "application/octet-stream"
        }
    }

    static func imageMIME(_ format: String?) -> String {
        switch format?.lowercased() {
        case "jpg", "jpeg":
            "image/jpeg"

        case "png":
            "image/png"

        case "gif":
            "image/gif"

        case "webp":
            "image/webp"

        default:
            "application/octet-stream"
        }
    }
}
