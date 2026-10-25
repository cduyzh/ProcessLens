import Foundation

/// 正式应用读取自身包；SwiftPM 开发运行读取根 Info.plist，避免写死另一个版本。
struct AppVersion: Equatable {
    let version: String
    let build: String
    let buildDate: Date?
    let releaseDate: String?
    let sourceRevision: String?
    let sourceHash: String?
    let runPath: String
    let isInstalled: Bool
    let isApplicationBundle: Bool

    static let productIdentifier = "com.cduyzh.process-tool"
    static let installedPath = "/Applications/cduyzhProcessTool.app"
    static let current: AppVersion = {
        let bundle = Bundle.main
        let isApp = bundle.bundleURL.pathExtension.lowercased() == "app"
        let info = isApp ? bundle.infoDictionary : developmentInfo
        let path = isApp ? bundle.bundleURL.resolvingSymlinksInPath().path : (bundle.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments.first ?? "未知")
        let date = (info?["CDUYZHBuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return AppVersion(
            version: info?["CFBundleShortVersionString"] as? String ?? "未标记",
            build: info?["CFBundleVersion"] as? String ?? "未标记",
            buildDate: date,
            releaseDate: info?["CDUYZHReleaseDate"] as? String,
            sourceRevision: info?["CDUYZHSourceRevision"] as? String,
            sourceHash: info?["CDUYZHSourceHash"] as? String,
            runPath: path,
            isInstalled: isApp && path == installedPath && bundle.bundleIdentifier == productIdentifier,
            isApplicationBundle: isApp
        )
    }()

    var displayString: String { "\(version) (\(build))" }
    var releaseHistory: [AppRelease] { ReleaseHistory.shared.releases }
    var releaseRecord: AppRelease? { releaseHistory.first { $0.version == version && $0.build == build } }
    var remoteUpdatesConfigured: Bool { false }
    var updateStatusText: String { "尚未配置在线更新源" }
    var buildDateDisplayString: String? {
        guard let buildDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter.string(from: buildDate)
    }
    var releaseDateDisplayString: String? {
        releaseDate.flatMap(AppRelease.formattedDate) ?? releaseRecord?.dateDisplayString
    }

    fileprivate static var developmentRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var developmentInfo: [String: Any]? {
        guard let data = try? Data(contentsOf: developmentRoot.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == productIdentifier else { return nil }
        return info
    }
}

struct AppRelease: Decodable, Identifiable, Equatable {
    let version: String
    let build: String
    let date: String
    let title: String
    let summary: String
    let highlights: [String]
    let notes: [String]

    var id: String { "\(version)|\(build)" }
    var displayString: String { "\(version) (\(build))" }
    var dateDisplayString: String { Self.formattedDate(date) ?? date }

    static func formattedDate(_ value: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        parser.isLenient = false
        guard let parsed = parser.date(from: value), parser.string(from: parsed) == value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy 年 M 月 d 日"
        return formatter.string(from: parsed)
    }
}

struct ReleaseHistory {
    let releases: [AppRelease]
    let isAvailable: Bool
    static let shared = load()
    var latest: AppRelease? { releases.first }

    private struct Document: Decodable { let releases: [AppRelease] }
    private static func load() -> ReleaseHistory {
        let main = Bundle.main
        var candidates = [main.url(forResource: "ReleaseHistory", withExtension: "json")].compactMap { $0 }
        // 兼容未来 SwiftPM 资源打包，无需强制依赖 Bundle.module 生成器。
        for directory in [main.resourceURL, main.executableURL?.deletingLastPathComponent()].compactMap({ $0 }) {
            if let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                candidates += urls.filter { $0.pathExtension == "bundle" && $0.lastPathComponent.hasPrefix("cduyzhProcessTool_") }
                    .compactMap { Bundle(url: $0)?.url(forResource: "ReleaseHistory", withExtension: "json") }
            }
        }
        if main.bundleURL.pathExtension.lowercased() != "app" {
            candidates.append(AppVersion.developmentRoot.appendingPathComponent("Resources/ReleaseHistory.json"))
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url), let history = try? JSONDecoder().decode(Document.self, from: data), !history.releases.isEmpty else { continue }
            var seen = Set<String>()
            let releases = history.releases.filter { !$0.version.isEmpty && !$0.build.isEmpty && seen.insert($0.id).inserted }
                .sorted { $0.build.compare($1.build, options: .numeric) == .orderedDescending }
            return ReleaseHistory(releases: releases, isAvailable: !releases.isEmpty)
        }
        return ReleaseHistory(releases: [], isAvailable: false)
    }
}
