import Foundation

public struct GLMCodingPlanCredential: Equatable, Sendable {
    public let authorizationValue: String
    public let planKind: GLMCodingPlanKind

    public init(authorizationValue: String, planKind: GLMCodingPlanKind) {
        self.authorizationValue = authorizationValue
        self.planKind = planKind
    }
}

public protocol GLMCodingPlanCredentialLoading: Sendable {
    func load() throws -> GLMCodingPlanCredential
}

/// ZCode account credentials are encrypted in its private store and have no documented
/// external read API. Fail closed; callers may supply an explicit key from a secure helper.
public struct ZCodeCodingPlanCredentialLoader: GLMCodingPlanCredentialLoading {
    public init() {}

    public func load() throws -> GLMCodingPlanCredential {
        throw GLMQuotaError.encryptedCredentialUnsupported
    }
}
