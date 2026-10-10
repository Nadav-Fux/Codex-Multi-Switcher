import CodexProfileCore
import Darwin
import Foundation

/// This process never returns a credential. Its only output is the normalized
/// usage response consumed by the app; it has no configurable account or home.
@main
enum ClaudeUsageHelperMain {
    static func main() async {
        _ = freopen("/dev/null", "w", stderr)
        guard CommandLine.arguments.count == 2,
              ["read", "authorize", "verify"].contains(CommandLine.arguments[1]) else {
            Self.emit(ClaudeUsageHelperResponse(error: .requestFailed))
            exit(1)
        }
        do {
            guard let account = getpwuid(getuid()), let directory = account.pointee.pw_dir else {
                throw ClaudeCurrentUsageError.credentialUnavailable
            }
            let home = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
            let profile = ClaudeProfileRegistry(paths: AppPaths(environment: [:])).defaultProfile
            guard URL(fileURLWithPath: profile.configDirectory).standardizedFileURL ==
                    home.appendingPathComponent(".claude").standardizedFileURL else {
                throw ClaudeCurrentUsageError.unsupportedProfile
            }
            let cli = ClaudeCLIService(environment: [:], userHome: home)
            let service = ClaudeCurrentUsageService(
                root: home.appendingPathComponent("Library/Application Support/Codex Multi Switcher/Claude Usage Helper", isDirectory: true),
                nativeHome: home)
            if CommandLine.arguments[1] == "authorize" {
                try service.authorizeNativeCredentialAccess(profile: profile)
                Self.emit(ClaudeUsageHelperResponse())
                return
            }
            let auth = try cli.identityMetadata(profile: profile)
            guard let identity = ClaudeUsageReader.accountFingerprint(auth) else {
                throw ClaudeCurrentUsageError.accountChanged
            }
            if CommandLine.arguments[1] == "verify" {
                _ = try ClaudeNativeCredentialLoader().accessToken()
                Self.emit(ClaudeUsageHelperResponse(identity: identity))
                return
            }
            let snapshot = try await service.fetch(profile: profile, authBefore: auth,
                                                   authAfter: { try cli.identityMetadata(profile: profile) })
            Self.emit(ClaudeUsageHelperResponse(identity: identity, snapshot: snapshot))
        } catch {
            Self.emit(ClaudeUsageHelperResponse(error: error as? ClaudeCurrentUsageError ?? .requestFailed))
        }
    }

    private static func emit(_ response: ClaudeUsageHelperResponse) {
        guard let data = try? JSONEncoder().encode(response) else { exit(1) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}
