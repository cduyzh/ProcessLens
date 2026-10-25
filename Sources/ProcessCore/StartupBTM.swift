import Foundation

enum StartupBTM {
    struct Record {
        let uid: Int32
        let fields: [String: String]
    }

    static func parse(_ output: String, uid: UInt32, existingPlists: Set<String>) throws -> [StartupItem] {
        guard output.contains("Records for UID") else { throw StartupError.refused("无法解析 BTM 输出。") }
        var records: [Record] = []
        var currentUID: Int32?
        var fields: [String: String] = [:]
        func flush() {
            if let currentUID, !fields.isEmpty { records.append(Record(uid: currentUID, fields: fields)) }
            fields = [:]
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID ") {
                flush()
                currentUID = Int32(line.dropFirst("Records for UID ".count).split(separator: " ").first ?? "")
            } else if line.hasPrefix("#"), line.hasSuffix(":"), !line.dropLast().contains(":") {
                flush()
            } else if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon])
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if ["UUID", "Name", "Type", "Disposition", "Identifier", "URL", "Executable Path", "Parent Identifier"].contains(key) {
                    fields[key] = value
                }
            }
        }
        flush()
        let owned = records.filter { $0.uid == Int32(uid) }
        let parents = Dictionary(owned.compactMap { record -> (String, URL)? in
            guard let identifier = record.fields["Identifier"], let raw = record.fields["URL"],
                  let url = URL(string: raw), url.isFileURL, url.pathExtension == "app" else { return nil }
            return (identifier, url)
        }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return owned.compactMap { record in
            let fields = record.fields
            let type = (fields["Type"] ?? "").lowercased()
            let isLogin = type.hasPrefix("login item ")
            let isAgent = type.hasPrefix("agent ") || type.hasPrefix("legacy agent ")
            let isDaemon = type.hasPrefix("daemon ") || type.hasPrefix("legacy daemon ")
            // app / developer 是归属汇总；dock tile、quicklook、spotlight 是扩展，不能当启动项。
            guard isLogin || isAgent || isDaemon, let identifier = fields["Identifier"] else { return nil }
            let rawURL = fields["URL"] ?? ""
            let resolved: URL?
            if let url = URL(string: rawURL), url.isFileURL { resolved = url.standardizedFileURL }
            else if let parent = fields["Parent Identifier"].flatMap({ parents[$0] }),
                    let relative = rawURL.removingPercentEncoding, relative.hasPrefix("Contents/") {
                let candidate = parent.appendingPathComponent(relative).standardizedFileURL
                resolved = candidate.path.hasPrefix(parent.path + "/") ? candidate : nil
            } else { resolved = nil }
            if let resolved, existingPlists.contains(resolved.path) { return nil }
            let key = identifier + "|" + rawURL
            guard seen.insert(key).inserted else { return nil }
            let disposition = fields["Disposition"] ?? ""
            let tokens = disposition.components(separatedBy: CharacterSet(charactersIn: "[],")).map { $0.trimmingCharacters(in: .whitespaces) }
            let state: StartupState = tokens.contains("disabled") ? .disabled
                : (tokens.contains("enabled") && tokens.contains("allowed") ? .enabled : .unknown)
            let executable = fields["Executable Path"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            let application = resolved.flatMap { url -> URL? in
                if url.pathExtension == "app" { return url }
                return StartupFiles.applicationURL(url.path)
            } ?? StartupFiles.applicationURL(executable)
            let name = fields["Name"].flatMap { $0 == "(null)" ? nil : $0 } ?? identifier
            return StartupItem(id: "btm:\(uid):\(key)", label: identifier, name: name,
                               source: .backgroundTaskManagement, kind: isLogin ? .loginItem : .backgroundItem,
                               state: state, runAtLoad: nil, keepAlive: nil,
                               plistURL: resolved?.pathExtension == "plist" ? resolved : nil,
                               applicationURL: application, executablePath: executable,
                               canDisable: false, managementReason: "第三方 SMAppService / BTM 项目由系统设置管理。",
                               details: "当前用户 UID \(uid) 的 BTM 登记；\(type)。Disposition：\(disposition)。登记/批准状态不代表当前正在运行。",
                               fileSnapshot: nil)
        }
    }
}
