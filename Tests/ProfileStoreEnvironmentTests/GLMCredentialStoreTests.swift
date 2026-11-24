@testable import CodexMultiSwitcherApp
import CodexProfileCore
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

            #expect(try GLMCredentialStore.load() == nil)
            #expect(removeRan)
            #expect(try store.load() == nil)
            #expect(store.hasNoLegacyMigrationMarker)
        }
    }
}
