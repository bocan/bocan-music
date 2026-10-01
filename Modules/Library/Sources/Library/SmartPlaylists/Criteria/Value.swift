import Foundation

/// A typed value used in a smart-playlist rule.
///
/// The `Codable` implementation uses a tagged-object representation so the
/// type is preserved across serialisation round-trips.
public indirect enum Value: Sendable, Hashable {
    case text(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case duration(TimeInterval)
    /// Inclusive numeric or date range stored as two `Value` scalars.
    case range(Self, Self)
    /// Reference to a playlist by ID.
    case playlistRef(Int64)
    /// A string drawn from a fixed enumeration (e.g. file format).
    case enumeration(String)
    case null
}

// MARK: - Codable

extension Value: Codable {
    private enum Tag: String, Codable {
        case text, int, double, bool, date, duration, range, playlistRef, enumeration, null
    }

    private enum CodingKeys: String, CodingKey {
        case tag
        case text, int, double, bool, date, duration
        case low, high
        case playlistRef
        case enumeration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(Tag.self, forKey: .tag)
        switch tag {
        case .text:
            self = try .text(container.decode(String.self, forKey: .text))

        case .int:
            self = try .int(container.decode(Int64.self, forKey: .int))

        case .double:
            self = try .double(container.decode(Double.self, forKey: .double))

        case .bool:
            self = try .bool(container.decode(Bool.self, forKey: .bool))

        case .date:
            self = try .date(container.decode(Date.self, forKey: .date))

        case .duration:
            self = try .duration(container.decode(TimeInterval.self, forKey: .duration))

        case .range:
            let low = try container.decode(Value.self, forKey: .low)
            let high = try container.decode(Value.self, forKey: .high)
            self = .range(low, high)

        case .playlistRef:
            self = try .playlistRef(container.decode(Int64.self, forKey: .playlistRef))

        case .enumeration:
            self = try .enumeration(container.decode(String.self, forKey: .enumeration))

        case .null:
            self = .null
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(payload):
            try container.encode(Tag.text, forKey: .tag)
            try container.encode(payload, forKey: .text)

        case let .int(payload):
            try container.encode(Tag.int, forKey: .tag)
            try container.encode(payload, forKey: .int)

        case let .double(payload):
            try container.encode(Tag.double, forKey: .tag)
            try container.encode(payload, forKey: .double)

        case let .bool(payload):
            try container.encode(Tag.bool, forKey: .tag)
            try container.encode(payload, forKey: .bool)

        case let .date(payload):
            try container.encode(Tag.date, forKey: .tag)
            try container.encode(payload, forKey: .date)

        case let .duration(payload):
            try container.encode(Tag.duration, forKey: .tag)
            try container.encode(payload, forKey: .duration)

        case let .range(low, high):
            try container.encode(Tag.range, forKey: .tag)
            try container.encode(low, forKey: .low)
            try container.encode(high, forKey: .high)

        case let .playlistRef(payload):
            try container.encode(Tag.playlistRef, forKey: .tag)
            try container.encode(payload, forKey: .playlistRef)

        case let .enumeration(payload):
            try container.encode(Tag.enumeration, forKey: .tag)
            try container.encode(payload, forKey: .enumeration)

        case .null:
            try container.encode(Tag.null, forKey: .tag)
        }
    }
}
