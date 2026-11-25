import Darwin
import Foundation

public enum AtomicFileWriter {
    public static func ensurePrivateDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    public static func write(_ data: Data, to destination: URL, fileManager: FileManager = .default) throws {
        try self.ensurePrivateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try self.createFilePrivately(at: temp, contents: data)
        defer { try? fileManager.removeItem(at: temp) }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: destination)
        }
    }

    /// Same write as `write`, but committed only when the destination still
    /// holds `expected`. With nil, publish only if the path is absent.
    /// The temp file is created and fsynced FIRST, then the
    /// destination is re-read and compared, then the rename happens
    /// immediately — nothing else runs between the compare and the rename, so
    /// a concurrent external write is caught everywhere except the rename
    /// itself. Returns false (and deletes the temp file) when the destination
    /// changed. `beforeCommit` is a test seam that runs after the temp file is
    /// prepared and before the final compare.
    @discardableResult
    public static func writeIfUnchanged(
        _ data: Data,
        to destination: URL,
        expected: Data?,
        beforeCommit: (() -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws -> Bool {
        try self.ensurePrivateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try self.createFilePrivately(at: temp, contents: data)
        defer { try? fileManager.removeItem(at: temp) }
        beforeCommit?()
        guard let expected else {
            // A hard link publishes the prepared file without replacing any
            // entry that Desktop creates concurrently, even if it is unreadable.
            let result = temp.path.withCString { source in
                destination.path.withCString { link(source, $0) }
            }
            if result == 0 { return true }
            let code = POSIXError.Code(rawValue: errno) ?? .EIO
            if code == .EEXIST { return false }
            throw POSIXError(code)
        }
        guard (try? Data(contentsOf: destination)) == expected else {
            return false
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: destination)
        }
        return true
    }

    /// Creates `url` at mode 0600 from the moment it exists, instead of writing
    /// with the process's default permissions (0644 under a typical umask) and
    /// narrowing afterward. A crash between those two steps would otherwise
    /// leave a live credential briefly world-readable on disk. `O_EXCL`
    /// preserves the no-overwrite guarantee the caller relies on for its
    /// randomly-named temp file.
    private static func createFilePrivately(at url: URL, contents: Data) throws {
        let fd = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard fd >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: contents)
            // Flush the bytes before publishing the file so a power loss cannot
            // replace a live credential with a zero-length or truncated file.
            guard fsync(fd) == 0 else {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            try handle.close()
        } catch {
            _ = url.path.withCString { unlink($0) }
            throw error
        }
    }
}
