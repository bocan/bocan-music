/// Marker for the kind of change that triggered a database observation update.
public enum ChangeEvent: Sendable {
    /// The initial value, emitted synchronously when observation starts.
    case initial

    /// A subsequent value caused by a database write.
    case change
}
