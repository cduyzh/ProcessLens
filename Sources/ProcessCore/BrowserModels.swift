import Foundation

public enum BrowserSessionClassification: String, Sendable, Hashable {
    case automation
    case dailyBrowser
    case application
    case unverified

    public var displayName: String {
        switch self {
        case .automation: "自动化浏览器"
        case .dailyBrowser: "日常浏览器 · 已保护"
        case .application: "桌面应用 · 已保护"
        case .unverified: "来源待确认 · 已保护"
        }
    }
}

/// 只读诊断快照。RSS 为成员驻留内存之和，包含共享页，不能作为可释放内存承诺。
public struct BrowserSession: Identifiable, Sendable, Hashable {
    public let id: String
    public let rootPID: Int32
    public let name: String
    public let members: [ProcessRecord]
    public let residentMemoryBytes: UInt64
    public let profileURL: URL?
    public let isHeadless: Bool
    public let evidence: [String]
    public let redactedCommand: String
    public let ownerDescription: String
    public let ancestorChain: [String]
    public let age: TimeInterval?
    public let classification: BrowserSessionClassification
    public let risk: String
    public let isOrphanCandidate: Bool
    public let canClose: Bool
    public let closeRestriction: String?
}

public struct BrowserCloseReport: Sendable {
    public let sessionID: String
    public let rootPID: Int32
    public let requestedPIDs: [Int32]
    public let signalledPIDs: [Int32]
    public let remainingPIDs: [Int32]
    public let unverifiedPIDs: [Int32]
    public let skippedPIDs: [Int32]
    public let profileStillExists: Bool?
    public let message: String
}

public enum BrowserInspectionError: LocalizedError, Sendable {
    case protectedSession(String)
    case sessionChanged

    public var errorDescription: String? {
        switch self {
        case let .protectedSession(reason): reason
        case .sessionChanged: "浏览器实例已变化，请重新扫描后确认。"
        }
    }
}
