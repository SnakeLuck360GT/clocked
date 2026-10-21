import Foundation

enum AppInfo {
    static let name = "Clocked"
}

/// Where the app keeps its few small files (inside its sandbox container).
enum Storage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent("Clocked")
        // Earlier builds used other names; move the newest existing folder over once.
        for legacy in ["Lock In", "DistractionDetector"].map(base.appendingPathComponent)
        where !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: current)
        }
        return current
    }()

    static func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
}
