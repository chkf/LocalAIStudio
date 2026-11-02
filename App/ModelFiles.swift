import Foundation

actor ModelFiles {
    private let directory: URL
    private let files = FileManager.default

    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        // Interrupted imports never enter the visible library. Reclaim their staging files on launch.
        for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if entry.lastPathComponent.hasPrefix(".import-"), UUID(uuidString: String(entry.lastPathComponent.dropFirst(8))) != nil {
                try FileManager.default.removeItem(at: entry)
            }
        }
    }

    func list() throws -> [LocalModel] {
        let folders = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        return try folders.compactMap { folder -> LocalModel? in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            do {
                let metadata = folder.appendingPathComponent("metadata.json")
                let model = try JSONDecoder().decode(LocalModel.self, from: Data(contentsOf: metadata))
                let values = try fileURL(for: model).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard model.id == id, values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, Int64(size) == model.byteCount else {
                    throw ModelFileError.invalidLibraryEntry(folder.lastPathComponent)
                }
                return model
            } catch {
                throw ModelFileError.invalidLibraryEntry(folder.lastPathComponent)
            }
        }.sorted { $0.importedAt > $1.importedAt }
    }

    nonisolated func fileURL(for model: LocalModel) -> URL {
        directory.appendingPathComponent(model.id.uuidString, isDirectory: true)
            .appendingPathComponent("model.\(model.format.fileExtension)")
    }

    /// Owned downloads can be hard-linked on the same volume. The caller removes their source only after success.
    func importFile(from source: URL, name: String? = nil, link: Bool = false) throws -> LocalModel {
        try storeFile(from: source, name: name, transfer: link ? .link : .copy)
    }

    /// Only the native picker's sandbox copy is consumed; never the user's source file.
    func importPickerCopy(from source: URL) throws -> LocalModel {
        try checkPickerCopy(source)
        return try storeFile(from: source, name: nil, transfer: .move)
    }

    func discardPickerCopies(_ urls: [URL]) throws {
        for url in urls {
            try checkPickerCopy(url)
            do { try files.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile { continue } // Already moved into the library.
        }
    }

    private func checkPickerCopy(_ url: URL) throws {
        // Resolve directory aliases before testing ownership; a provider URL must never be moved/deleted.
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = [files.temporaryDirectory,
                     files.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox")]
        guard url.isFileURL, roots.contains(where: {
            path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        }) else {
            throw ModelFileError.invalid("系统没有返回 App 内的导入副本，原文件未被改动。")
        }
    }

    private enum Transfer { case copy, link, move }

    private func storeFile(from source: URL, name: String?, transfer: Transfer) throws -> LocalModel {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw ModelFileError.unsupportedFile
        }
        if transfer == .copy {
            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let available, Int64(size) > available { throw ModelFileError.notEnoughSpace }
        }
        let displayName = URL(fileURLWithPath: name ?? source.lastPathComponent).lastPathComponent
        let id = UUID()
        let staging = directory.appendingPathComponent(".import-\(id.uuidString)", isDirectory: true)
        let stagedFile = staging.appendingPathComponent("payload")
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try Task.checkCancellation()
            switch transfer {
            case .move:
                // Both URLs are in this app's sandbox: adopt the system copy, without a second full copy.
                try files.moveItem(at: source, to: stagedFile)
            case .link:
                // Killing the app during import must not discard an already completed download.
                try files.linkItem(at: source, to: stagedFile)
            case .copy:
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readableURL in
                    do { try copyFile(from: readableURL, to: stagedFile) }
                    catch { copyError = error }
                }
                if let coordinationError { throw coordinationError }
                if let copyError { throw copyError }
            }
            let inspection = try ModelFile.inspect(stagedFile, name: displayName)
            let copiedSize = try stagedFile.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard copiedSize == size else { throw ModelFileError.invalid("导入期间源文件大小发生变化，请重试。") }
            let model = LocalModel(
                id: id, name: displayName, byteCount: Int64(size), importedAt: .now,
                format: inspection.format, architecture: inspection.architecture,
                quantization: inspection.quantization, adapter: inspection.adapter, validationNote: inspection.note
            )
            let destination = staging.appendingPathComponent("model.\(model.format.fileExtension)")
            try files.moveItem(at: stagedFile, to: destination)
            try JSONEncoder().encode(model).write(to: staging.appendingPathComponent("metadata.json"), options: .atomic)
            try Task.checkCancellation()
            // Both names are within the same directory/volume: the finished model appears atomically.
            try files.moveItem(at: staging, to: directory.appendingPathComponent(id.uuidString, isDirectory: true))
            return model
        } catch {
            let importError = error
            do {
                try files.removeItem(at: staging)
            } catch {
                throw ModelFileError.cleanupFailed("\(importError.localizedDescription)；\(error.localizedDescription)")
            }
            throw importError
        }
    }

    func delete(_ model: LocalModel) throws {
        try files.removeItem(at: directory.appendingPathComponent(model.id.uuidString, isDirectory: true))
    }

    private func copyFile(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { input.closeFile() }
        guard files.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { output.closeFile() }
        while let chunk = try input.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
    }
}
