import Foundation

struct LegacyProfileImportItem: Identifiable {
    enum CredentialState {
        case ready(source: String)
        case unavailable
        case conflictingCopies
    }

    let id: String
    let label: String
    let credentialState: CredentialState
    let destinationHasAuth: Bool
    let alreadyConfigured: Bool
}

struct LegacyProfileImportPreview: Identifiable {
    let id: UUID
    let sourcePath: String
    let items: [LegacyProfileImportItem]
    let warnings: [String]

    var credentialsToImport: Int {
        self.items.filter { item in
            if case .ready = item.credentialState {
                return !item.destinationHasAuth
            }
            return false
        }.count
    }

    var newProfiles: Int { self.items.filter { !$0.alreadyConfigured }.count }
}

struct LegacyProfileImportResult {
    let importedProfiles: Int
    let copiedCredentials: Int
    let skippedCredentials: Int
    let warnings: [String]
}

enum LegacyProfileImportError: LocalizedError {
    case sourceNotFound(String)
    case unsafePath(String)
    case stalePreview
    case noUndoAvailable
    case corruptBackup

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let path):
            return "No original Codex Profile Switcher data was found at \(path)."
        case .unsafePath(let path):
            return "Refusing to use a symbolic-link or overlapping data path: \(path)"
        case .stalePreview:
            return "The profile list changed after the preview. Scan the old data again before importing."
        case .noUndoAvailable:
            return "There is no previous profile import to undo."
        case .corruptBackup:
            return "The latest import backup could not be read, so no data was changed."
        }
    }
}
