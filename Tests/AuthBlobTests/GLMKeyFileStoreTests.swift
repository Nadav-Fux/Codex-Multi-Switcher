import CodexProfileCore
import Foundation
import Testing

struct GLMKeyFileStoreTests {
    private func withStore(_ body: (GLMKeyFileStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-key-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("glm/coding-plan-key")
        try body(GLMKeyFileStore(url: url), url)
    }

    private func mode(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1
    }

    @Test
    func missingFileMeansNoKey() throws {
        try self.withStore { store, _ in
            let loaded = try store.load()
            #expect(loaded == nil)
        }
    }

    @Test
    func savesPrivatelyAndRoundTrips() throws {
        try self.withStore { store, url in
            try store.save("  sk.test-key_123  \n")
            let loaded = try store.load()
            let fileMode = try self.mode(url)
            let directoryMode = try self.mode(url.deletingLastPathComponent())
            #expect(loaded == "sk.test-key_123")
            #expect(fileMode == 0o600)
            #expect(directoryMode == 0o700)
        }
    }

    @Test
    func rejectsInvalidKeys() throws {
        try self.withStore { store, url in
            #expect(throws: GLMKeyFileStore.Failure.invalidKey) { try store.save("has space") }
            #expect(throws: GLMKeyFileStore.Failure.invalidKey) { try store.save("") }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test
    func refusesAFileOtherUsersCanRead() throws {
        try self.withStore { store, url in
            try store.save("sk.test")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            #expect(throws: GLMKeyFileStore.Failure.unreadable) { try store.load() }
        }
    }

    @Test
    func removeDeletesTheKey() throws {
        try self.withStore { store, _ in
            try store.save("sk.test")
            try store.remove()
            let loaded = try store.load()
            #expect(loaded == nil)
            try store.remove()
        }
    }

    @Test
    func defaultLocationIsUnderTheSwitcherHome() {
        let paths = AppPaths(environment: ["CODEX_PROFILE_HOME": "/tmp/example-home"])
        #expect(GLMKeyFileStore(paths: paths).url.path
            == "/tmp/example-home/.codex-multi-switcher/glm/coding-plan-key")
    }
}

struct ClaudeHelperStaleBlockTests {
    @Test
    func clearsOnlyFlagsOfOtherHelperDigests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("claude-usage-helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let digest = SHA256Hex.of(try Data(contentsOf: binary))
        let manifest = root.appendingPathComponent("claude-usage-helper.json")
        try Data(#"{"schemaVersion":1,"sha256":"\#(digest)"}"#.utf8).write(to: manifest)

        let suite = "stale-block-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "claudeUsageHelperAccessBlocked.61b0old")
        defaults.set(true, forKey: "claudeUsageHelperAccessBlocked.\(digest)")
        defaults.set(true, forKey: "unrelatedKey")

        let client = ClaudeUsageHelperClient(executable: binary, manifest: manifest, preferences: defaults)
        #expect(client.clearStaleAccessBlocks() == 1)
        #expect(defaults.object(forKey: "claudeUsageHelperAccessBlocked.61b0old") == nil)
        #expect(defaults.bool(forKey: "claudeUsageHelperAccessBlocked.\(digest)"))
        #expect(defaults.bool(forKey: "unrelatedKey"))
    }
}

import CryptoKit

private enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
