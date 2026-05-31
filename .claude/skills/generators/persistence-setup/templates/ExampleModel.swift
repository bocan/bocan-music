import Foundation
import SwiftData

/// Example SwiftData model.
///
/// This demonstrates common patterns for SwiftData models.
/// Replace or extend with your own models.
///
/// Usage:
/// ```swift
/// let item = Item(title: "Buy groceries")
/// item.isCompleted = true
/// ```
@Model
final class Item {
    // MARK: - Stored Properties

    /// Unique identifier for the item.
    @Attribute(.unique)
    var id: UUID

    /// The item's title.
    var title: String

    /// When the item was created.
    var createdAt: Date

    /// When the item was last modified.
    var modifiedAt: Date

    /// Whether the item is completed.
    var isCompleted: Bool

    /// Optional notes for the item.
    var notes: String?

    /// Priority level (0 = none, 1 = low, 2 = medium, 3 = high).
    var priority: Int

    // MARK: - Transient Properties (Not Persisted)

    /// UI selection state (not saved to database).
    @Transient
    var isSelected = false

    // MARK: - Relationships

    // Example: Uncomment to add a relationship to a Project model
    // @Relationship(inverse: \Project.items)
    // var project: Project?

    // Example: Tags relationship
    // @Relationship(deleteRule: .nullify)
    // var tags: [Tag] = []

    // MARK: - Initialization

    init(
        title: String,
        notes: String? = nil,
        priority: Int = 0,
        isCompleted: Bool = false
    ) {
        self.id = UUID()
        self.title = title
        self.createdAt = .now
        self.modifiedAt = .now
        self.isCompleted = isCompleted
        self.notes = notes
        self.priority = priority
    }

    // MARK: - Methods

    /// Mark the item as completed.
    func complete() {
        self.isCompleted = true
        self.modifiedAt = .now
    }

    /// Mark the item as not completed.
    func uncomplete() {
        self.isCompleted = false
        self.modifiedAt = .now
    }

    /// Toggle completion status.
    func toggleCompletion() {
        self.isCompleted.toggle()
        self.modifiedAt = .now
    }

    /// Update the title.
    func updateTitle(_ newTitle: String) {
        self.title = newTitle
        self.modifiedAt = .now
    }
}

// MARK: - Convenience Extensions

extension Item {
    /// Priority level as human-readable string.
    var priorityLabel: String {
        switch self.priority {
        case 0: "None"
        case 1: "Low"
        case 2: "Medium"
        case 3: "High"
        default: "Unknown"
        }
    }

    /// Whether this is a high-priority item.
    var isHighPriority: Bool {
        self.priority >= 3
    }
}

// MARK: - Sample Data

extension Item {
    /// Sample items for previews and testing.
    static var sampleItems: [Item] {
        [
            Item(title: "Complete project proposal", priority: 3),
            Item(title: "Review pull request", priority: 2),
            Item(title: "Update documentation", priority: 1),
            Item(title: "Schedule team meeting", notes: "Discuss Q4 goals"),
            Item(title: "Buy coffee", isCompleted: true),
        ]
    }
}
