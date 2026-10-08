import Foundation
import Security

/// Legacy Keychain interaction is process-wide. All Claude/GLM access uses one
/// gate so a foreground connection cannot accidentally enable a background prompt.
public enum KeychainInteractionPolicy {
    private static let lock = NSLock()

    public enum Failure: Error { case unavailable }

    public static func withInteraction<T>(allowed: Bool = false, _ operation: () throws -> T) throws -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        var previous: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else {
            throw Failure.unavailable
        }
        defer {
            if SecKeychainSetUserInteractionAllowed(previous.boolValue) != errSecSuccess {
                CoreLogger.warning("Keychain interaction policy could not be restored")
            }
        }
        return try operation()
    }
}
