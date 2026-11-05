import Foundation

struct GeneratedImage: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let date: Date
    let byteCount: Int64
}

/// The UUID PNG files are the history index, including images saved by older app versions.
struct GeneratedImages {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Generated", isDirectory: true)
    }

    func list() throws -> [GeneratedImage] {
        let files = FileManager.default
        guard files.fileExists(atPath: directory.path) else { return [] }
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys:
            [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey])
        var images: [GeneratedImage] = []
        for entry in entries {
            let name = entry.deletingPathExtension().lastPathComponent
            let values = try entry.resourceValues(forKeys:
                [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if entry.pathExtension == "png", name.hasPrefix(".pending-"),
               UUID(uuidString: String(name.dropFirst(9))) != nil {
                // A process interruption may leave an unfinished PNG, never a visible history entry.
                try files.removeItem(at: entry)
                continue
            }
            guard entry.pathExtension == "png", let id = UUID(uuidString: name) else { continue }
            // Darwin may resolve /var to /private/var during enumeration. Keep
            // the same URL spelling as save() and delete() for result matching.
            let imageURL = directory.appendingPathComponent(entry.lastPathComponent)
            images.append(GeneratedImage(id: id, url: imageURL,
                date: values.creationDate ?? values.contentModificationDate ?? .distantPast,
                byteCount: Int64(values.fileSize ?? 0)))
        }
        return images.sorted { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }
    }

    func save(_ write: (URL) throws -> Void) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let pending = directory.appendingPathComponent(".pending-\(id).png")
        let output = directory.appendingPathComponent(id + ".png")
        do {
            try write(pending)
            try files.moveItem(at: pending, to: output)
            return output
        } catch {
            let failure = error
            if files.fileExists(atPath: pending.path) { try files.removeItem(at: pending) }
            throw failure
        }
    }

    func delete(_ image: GeneratedImage) throws {
        // Use only a validated basename under the owned directory, never a caller's parent path.
        guard image.url.pathExtension == "png",
              UUID(uuidString: image.url.deletingPathExtension().lastPathComponent) == image.id else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let target = directory.appendingPathComponent(image.url.lastPathComponent)
        try FileManager.default.removeItem(at: target)
    }
}
