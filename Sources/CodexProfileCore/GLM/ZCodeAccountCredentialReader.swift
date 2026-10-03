import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Reads only ZCode's two documented credential entries and decrypts them in process.
/// No credential material is exposed through a public API or diagnostic string.
struct ZCodeAccountCredentials: Sendable {
    let zcodeJWT: String
    let zaiOAuthToken: String?
    let fileFingerprint: Data
    let subjectFingerprint: String?
    let resetCardsSelectedForIndividualPlan: Bool
}

struct ZCodeAccountCredentialReader: Sendable {
    private static let maximumFileSize = 1_048_576
    private static let jwtKey = "zcodejwttoken"
    private static let zaiOAuthKey = "oauth:zai:access_token"
    private static let unavailableSettingsMarker = Data("settings-unavailable".utf8)

    func load() throws -> ZCodeAccountCredentials {
        let data = try readPrivateFile()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encryptedJWT = object[Self.jwtKey] as? String,
              let activeProvider = object["oauth:active_provider"] as? String,
              (try? Self.decrypt(activeProvider)) == "zai" else {
            throw ZCodeAccountBenefitsError.credentialsUnavailable
        }
        let jwt = try Self.decrypt(encryptedJWT)
        guard Self.validToken(jwt) else { throw ZCodeAccountBenefitsError.credentialsUnavailable }
        let oauth = (object[Self.zaiOAuthKey] as? String).flatMap { try? Self.decrypt($0) }
            .flatMap { Self.validToken($0) ? $0 : nil }
        let settingsData = try? readPrivateFile(path: NSHomeDirectory() + "/.zcode/v2/setting.json", requirePrivate: false)
        let settingsFingerprint = Data(SHA256.hash(data: settingsData ?? Self.unavailableSettingsMarker))
        let selectionFingerprint = Self.selectionFingerprint(credentials: Data(SHA256.hash(data: data)),
                                                             settings: settingsFingerprint)
        return ZCodeAccountCredentials(zcodeJWT: jwt, zaiOAuthToken: oauth,
                                       fileFingerprint: selectionFingerprint,
                                       subjectFingerprint: Self.subjectFingerprint(jwt),
                                       resetCardsSelectedForIndividualPlan: settingsData.map(Self.isPersonalCodingPlanSelected) ?? false)
    }

    func verifyUnchanged(_ expected: Data) throws {
        let current = try readPrivateFile()
        let settingsData = try? readPrivateFile(path: NSHomeDirectory() + "/.zcode/v2/setting.json", requirePrivate: false)
        let actual = Self.selectionFingerprint(credentials: Data(SHA256.hash(data: current)),
                                               settings: Data(SHA256.hash(data: settingsData ?? Self.unavailableSettingsMarker)))
        guard Self.constantTimeEqual(expected, actual) else {
            throw ZCodeAccountBenefitsError.accountChanged
        }
    }

    private func readPrivateFile() throws -> Data {
        try readPrivateFile(path: NSHomeDirectory() + "/.zcode/v2/credentials.json")
    }

    private func readPrivateFile(path: String, requirePrivate: Bool = true) throws -> Data {
        #if canImport(Darwin)
        let fd = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw ZCodeAccountBenefitsError.credentialsUnavailable }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & (requirePrivate ? 0o077 : 0o022)) == 0,
              info.st_size >= 0, info.st_size <= Self.maximumFileSize else {
            throw ZCodeAccountBenefitsError.credentialsUnavailable
        }
        var result = Data()
        result.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, result.count + count <= Self.maximumFileSize else {
                throw ZCodeAccountBenefitsError.credentialsUnavailable
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
        #else
        throw ZCodeAccountBenefitsError.credentialsUnavailable
        #endif
    }

    private static func selectionFingerprint(credentials: Data, settings: Data) -> Data {
        var combined = Data("zcode-selection-v1\u{0}".utf8)
        combined.append(credentials)
        combined.append(settings)
        return Data(SHA256.hash(data: combined))
    }

    private static func isPersonalCodingPlanSelected(_ data: Data) -> Bool {
        guard data.count <= maximumFileSize,
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modes = settings["modelProviderFamilyModes"] as? [String: String], modes["zai"] == "oauth",
              let selectedKeys = settings["modelProviderFamilySelectedKeys"] as? [String: String],
              selectedKeys["zai"] == "coding-plan:builtin:zai-coding-plan",
              let selections = settings["providerFamilyConnectionSelections"] as? [String: Any],
              let zaiSelection = selections["zai"] as? [String: Any],
              zaiSelection["kind"] as? String == "individual-coding-plan",
              settings["providerFamilyDomain"] as? String == "zai" else { return false }
        return true
    }

    private static func decrypt(_ value: String) throws -> String {
        guard value.utf8.count <= 65_536 else { throw ZCodeAccountBenefitsError.credentialsUnavailable }
        if value.hasPrefix("enc:") && !value.hasPrefix("enc:v1:") {
            throw ZCodeAccountBenefitsError.credentialsUnavailable
        }
        guard value.hasPrefix("enc:v1:") else { return value }
        let components = value.dropFirst("enc:v1:".count).split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let nonceData = decodeBase64URL(String(components[0])), nonceData.count == 12,
              let tag = decodeBase64URL(String(components[1])), tag.count == 16,
              let ciphertext = decodeBase64URL(String(components[2])) else {
            throw ZCodeAccountBenefitsError.credentialsUnavailable
        }
        let secret: String
        if let processSecret = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"], !processSecret.isEmpty {
            secret = processSecret
        } else {
            secret = "zcode-credential-fallback:darwin:\(NSHomeDirectory()):\(NSUserName().isEmpty ? "unknown" : NSUserName())"
        }
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(box, using: key)
            guard plaintext.count <= 65_536, let decoded = String(data: plaintext, encoding: .utf8) else {
                throw ZCodeAccountBenefitsError.credentialsUnavailable
            }
            return decoded
        } catch {
            throw ZCodeAccountBenefitsError.credentialsUnavailable
        }
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard value.utf8.count <= 65_536,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 65_536
            && value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
    }

    /// Hashes a JWT subject for local correlation without retaining or exporting claims.
    /// Never compare these across different issuer namespaces.
    private static func subjectFingerprint(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let payload = decodeBase64URL(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let issuer = claims["iss"] as? String, !issuer.isEmpty,
              let subject = claims["sub"] as? String, !subject.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data((issuer + "\u{0}" + subject).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}
