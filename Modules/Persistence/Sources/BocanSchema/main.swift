import Foundation
import Persistence

// Writes a freshly migrated, empty Bòcan library to the path given as the
// first argument, so `make data-dictionary` can document the schema every
// migration produces without depending on anyone's live library (#420).

let arguments = CommandLine.arguments

guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: bocan-schema <output.sqlite>\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])

try? FileManager.default.removeItem(at: outputURL)

do {
    _ = try await Database(location: .custom(outputURL))
    print("migrated schema written to \(outputURL.path)")
} catch {
    FileHandle.standardError.write(Data("bocan-schema: \(error)\n".utf8))
    exit(1)
}
