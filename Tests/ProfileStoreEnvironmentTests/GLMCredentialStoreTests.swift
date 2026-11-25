@testable import CodexMultiSwitcherApp
import CodexProfileCore
import Darwin
import Foundation
import Security
import Testing

/// File-backed fixtures only: the legacy Keychain read/delete are injected
/// fakes, so these tests never touch the real Keychain.
@Suite(.serialized)
struct GLMCredentialStoreTests {
    private func withStore(_ body: (GLMKeyFileStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-credential-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GLMKeyFileStore(url: root.appendingPathComponent("glm/coding-plan-key"))
        let originalProvider = GLMCredentialStore.fileStoreProvider
        let originalReader = GLMCredentialStore.legacyItemReader
        let originalDeleter = GLMCredentialStore.legacyItemDeleter
        GLMCredentialStore.fileStoreProvider = { store }
        defer {
            GLMCredentialStore.fileStoreProvider = originalProvider
            GLMCredentialStore.legacyItemReader = originalReader
            GLMCredentialStore.legacyItemDeleter = originalDeleter
        }
        try body(store)
    }

    @Test
    func removedKeyNeverMigratesBackFromTheLegacyItem() throws {
        try self.withStore { store in
            var legacyReads = 0
            GLMCredentialStore.legacyItemReader = { _ in
                legacyReads += 1
                return "legacy-key"
            }
            GLMCredentialStore.legacyItemDeleter = { errSecSuccess }

            // Before any save/remove decision, the legacy item migrates once.
            #expect(try GLMCredentialStore.load() == "legacy-key")
            #expect(legacyReads == 1)
            #expect(try store.load() == "legacy-key")

            try GLMCredentialStore.remove()
            #expect(store.hasNoLegacyMigrationMarker)
            #expect(try GLMCredentialStore.load() == nil)
            #expect(legacyReads == 1)

            // Saving again also records the decision next to the key file.
            try GLMCredentialStore.save("sk.new-key")
            #expect(store.hasNoLegacyMigrationMarker)
            #expect(try GLMCredentialStore.load() == "sk.new-key")
            try GLMCredentialStore.remove()
            #expect(try GLMCredentialStore.load() == nil)
            #expect(legacyReads == 1)
        }
    }

    @Test
    func saveAloneWritesTheNoMigrationMarker() throws {
        try self.withStore { store in
            GLMCredentialStore.legacyItemReader = { _ in "legacy-key" }
            GLMCredentialStore.legacyItemDeleter = { errSecSuccess }

            // A fresh store has no marker: `save` itself must record it.
            #expect(!store.hasNoLegacyMigrationMarker)
            try GLMCredentialStore.save("sk.new-key")
            #expect(store.hasNoLegacyMigrationMarker)
            #expect(try GLMCredentialStore.load() == "sk.new-key")
        }
    }

    @Test
    func failedLegacyDeleteCannotResurrectTheKey() throws {
        try self.withStore { store in
            var legacyReads = 0
            GLMCredentialStore.legacyItemReader = { _ in
                legacyReads += 1
                return "legacy-key"
            }
            // The legacy delete is refused outright: remove() reports failure,
            // yet the marker already written must still prevent a resurrection.
            GLMCredentialStore.legacyItemDeleter = { errSecParam }

            try GLMCredentialStore.save("sk.key")
            #expect(throws: GLMCredentialStore.Failure.self) { try GLMCredentialStore.remove() }
            #expect(store.hasNoLegacyMigrationMarker)
            #expect(try GLMCredentialStore.load() == nil)
            #expect(legacyReads == 0)
        }
    }

    @Test
    func removeLandingDuringTheLegacyReadWins() throws {
        try self.withStore { store in
            GLMCredentialStore.legacyItemDeleter = { errSecSuccess }
            var removeRan = false
            GLMCredentialStore.legacyItemReader = { _ in
                // This runs while `load` holds no lock: remove() must not be
                // blocked by the read, and its decision wins over the key.
                try GLMCredentialStore.remove()
                removeRan = true
                return "legacy-key"
            }

            // Evaluate outside #expect: the macro cannot propagate a throw here
            // (CI: "errors thrown from here are not handled").
            let loaded = try GLMCredentialStore.load()
            let stored = try store.load()
            #expect(loaded == nil)
            #expect(removeRan)
            #expect(stored == nil)
            #expect(store.hasNoLegacyMigrationMarker)
        }
    }

    @Test
    func externalImportWinsWhileMigrationWaitsForTheFileLock() throws {
        try self.withStore { store in
            let legacyReadStarted = DispatchSemaphore(value: 0)
            let returnLegacy = DispatchSemaphore(value: 0)
            let legacyReadFinished = DispatchSemaphore(value: 0)
            GLMCredentialStore.legacyItemReader = { _ in
                legacyReadStarted.signal()
                try #require(returnLegacy.wait(timeout: .now() + 5) == .success)
                legacyReadFinished.signal()
                return "legacy-key"
            }
            GLMCredentialStore.legacyItemDeleter = { errSecSuccess }

            let migration = DispatchGroup()
            DispatchQueue.global().async(group: migration) {
                do {
                    let loaded = try GLMCredentialStore.load()
                    #expect(loaded == "sk.imported-key")
                } catch { Issue.record(error) }
            }
            defer {
                returnLegacy.signal()
                migration.wait()
            }
            try #require(legacyReadStarted.wait(timeout: .now() + 5) == .success)

            let lockURL = store.url.appendingPathExtension("lock")
            let directory = lockURL.deletingLastPathComponent()
            let lockAttributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            #expect(lockAttributes[.posixPermissions] as? Int == 0o600)
            #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)
            let descriptor = open(lockURL.path, O_RDONLY | O_CLOEXEC)
            try #require(descriptor >= 0)
            do {
                defer { close(descriptor) }
                // A separate open file description acts as the importer, with
                // no access to any in-process lock in GLMCredentialStore.
                try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
                returnLegacy.signal()
                try #require(legacyReadFinished.wait(timeout: .now() + 5) == .success)
                #expect(migration.wait(timeout: .now() + .milliseconds(200)) == .timedOut)
                #expect(try store.load() == nil)

                try store.save("sk.imported-key")
                try store.markNoLegacyMigration()
            }

            migration.wait()
            #expect(try store.load() == "sk.imported-key")
            #expect(store.hasNoLegacyMigrationMarker)
        }
    }

    @Test
    func saveWaitsForAnExternalFileLock() throws {
        try self.withStore { store in
            GLMCredentialStore.legacyItemReader = { _ in nil }
            GLMCredentialStore.legacyItemDeleter = { errSecSuccess }

            let saveStarted = DispatchSemaphore(value: 0)
            let save = DispatchGroup()
            defer { save.wait() }
            try CacheLock.withLock(at: store.url.appendingPathExtension("lock")) {
                DispatchQueue.global().async(group: save) {
                    saveStarted.signal()
                    do { try GLMCredentialStore.save("sk.imported-key") }
                    catch { Issue.record(error) }
                }
                try #require(saveStarted.wait(timeout: .now() + 5) == .success)
                #expect(save.wait(timeout: .now() + .milliseconds(200)) == .timedOut)
                #expect(try store.load() == nil)
                #expect(!store.hasNoLegacyMigrationMarker)
            }

            save.wait()
            #expect(try store.load() == "sk.imported-key")
            #expect(store.hasNoLegacyMigrationMarker)
        }
    }

    @Test
    func unavailableFileLockPreventsReadingOrChangingTheKey() throws {
        try self.withStore { store in
            GLMCredentialStore.legacyItemReader = { _ in
                Issue.record("An unavailable lock must prevent fallback to the legacy reader")
                return "legacy-key"
            }
            GLMCredentialStore.legacyItemDeleter = {
                Issue.record("An unavailable lock must prevent legacy cleanup")
                return errSecSuccess
            }
            let lockURL = store.url.appendingPathExtension("lock")
            let directory = lockURL.deletingLastPathComponent()
            try AtomicFileWriter.ensurePrivateDirectory(directory)
            try FileManager.default.createSymbolicLink(
                at: lockURL, withDestinationURL: directory.appendingPathComponent("missing/lock"))

            #expect(throws: GLMCredentialStore.Failure.unavailable) { try GLMCredentialStore.load() }
            #expect(throws: GLMCredentialStore.Failure.unavailable) { try GLMCredentialStore.save("sk.imported-key") }
            #expect(throws: GLMCredentialStore.Failure.unavailable) { try GLMCredentialStore.remove() }
            #expect(try store.load() == nil)
            #expect(!store.hasNoLegacyMigrationMarker)
        }
    }
}
