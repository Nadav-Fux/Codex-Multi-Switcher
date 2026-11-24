import Foundation

/// File-backed storage for the user's Z.ai Coding Plan key, the same model as
/// the Codex profile store: one mode-0600 file in a mode-0700 directory under
/// the switcher home. Unlike a Keychain item it does not depend on the app's
/// code signature, so a rebuilt app reads it without a Keychain prompt.
/// The key is never logged.
public struct GLMKeyFileStore: Sendable {
    public let url: URL

    public init(paths: AppPaths = AppPaths()) {
        self.url = paths.switcherHome
            .appendingPathComponent("glm", isDirectory: true)
            .appendingPathComponent("coding-plan-key")
    }

    public init(url: URL) {
        self.url = url
    }

    public enum Failure: Error, Equatable {
        case invalidKey
        case unreadable
    }

    /// Printable ASCII without spaces, at most 8 KiB.
    public static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192 && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    /// nil when no key file exists. Throws when a file exists but is not a
    /// usable key, or is reachable by other users (it is never trusted then).
    public func load() throws -> String? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: self.url.path) else { return nil }
        guard let attributes = try? manager.attributesOfItem(atPath: self.url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let mode = attributes[.posixPermissions] as? Int, mode & 0o077 == 0,
              let data = try? Data(contentsOf: self.url), data.count <= 8192,
              let raw = String(data: data, encoding: .utf8) else {
            throw Failure.unreadable
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(value) else { throw Failure.unreadable }
        return value
    }

    public func save(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(value) else { throw Failure.invalidKey }
        // AtomicFileWriter creates the directory 0700 and the file 0600 from the
        // moment it exists, then renames it into place.
        try AtomicFileWriter.write(Data(value.utf8), to: self.url)
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: self.url.path) {
            try FileManager.default.removeItem(at: self.url)
        }
    }

    /// Next to the key file: records that the app already decided this key's
    /// state (saved or removed), so a leftover legacy Keychain item must never
    /// be migrated back in.
    public var noLegacyMigrationMarkerURL: URL {
        self.url.appendingPathExtension("no-legacy-migration")
    }

    public var hasNoLegacyMigrationMarker: Bool {
        FileManager.default.fileExists(atPath: self.noLegacyMigrationMarkerURL.path)
    }

    public func markNoLegacyMigration() throws {
        try AtomicFileWriter.write(Data("no-legacy-migration\n".utf8), to: self.noLegacyMigrationMarkerURL)
    }
}
