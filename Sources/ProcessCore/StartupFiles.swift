import CryptoKit
import Darwin
import Foundation

enum StartupFiles {
    struct SystemReadTrust {
        let root: URL
        let owner: uid_t
        static let apple = Self(root: URL(fileURLWithPath: "/System", isDirectory: true), owner: 0)
    }

    static func validLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 255
            && label.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }

    static func read(_ url: URL, allowHardLinks: Bool = false) throws -> (Data, StartupFileSnapshot) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw StartupError.refused("文件不可安全读取或为符号链接：\(url.lastPathComponent)") }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              (allowHardLinks || before.st_nlink == 1), before.st_size >= 0, before.st_size <= 2_097_152 else {
            throw StartupError.refused("文件类型、硬链接或体积不符合管理要求：\(url.lastPathComponent)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 2_097_153) ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == data.count,
              before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw StartupError.refused("文件读取期间发生变化，请重新扫描。")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, StartupFileSnapshot(owner: after.st_uid, device: after.st_dev,
                                         inode: after.st_ino, mode: after.st_mode, sha256: digest))
    }

    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw StartupError.refused("plist 顶层不是字典。")
        }
        return dictionary
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// 检查 home 到目标目录的每一级；不跟随符号链接，不允许其他用户写入。
    static func userDirectory(_ url: URL, environment: StartupEnvironment, create: Bool) throws {
        let home = environment.home.standardizedFileURL
        let target = url.standardizedFileURL
        guard environment.uid != 0, target.path == home.path || target.path.hasPrefix(home.path + "/") else {
            throw StartupError.refused("管理路径不属于当前用户的受控目录。")
        }
        var cursor = home
        let suffix = target.pathComponents.dropFirst(home.pathComponents.count)
        for component in [String?](arrayLiteral: nil) + suffix.map(Optional.some) {
            if let component { cursor.appendPathComponent(component, isDirectory: true) }
            var info = stat()
            if lstat(cursor.path, &info) != 0 {
                guard create, errno == ENOENT, mkdir(cursor.path, 0o700) == 0,
                      lstat(cursor.path, &info) == 0 else {
                    throw StartupError.refused("无法访问受控目录：\(cursor.lastPathComponent)")
                }
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == environment.uid,
                  info.st_mode & 0o022 == 0, info.st_mode & 0o700 == 0o700 else {
                throw StartupError.refused("目录所有者、权限或符号链接校验失败：\(cursor.lastPathComponent)")
            }
        }
    }

    static func sourceURL(_ url: URL, environment: StartupEnvironment) throws {
        guard url.isFileURL, url.standardizedFileURL == url,
              url.deletingLastPathComponent().path == environment.userAgents.path,
              url.pathExtension.lowercased() == "plist", !url.lastPathComponent.hasPrefix(".") else {
            throw StartupError.refused("仅管理当前用户 LaunchAgents 中的直接 plist 文件。")
        }
        try userDirectory(environment.userAgents, environment: environment, create: false)
    }

    static func validateUserFile(_ snapshot: StartupFileSnapshot, environment: StartupEnvironment) throws {
        guard snapshot.owner == environment.uid, snapshot.mode & 0o022 == 0 else {
            throw StartupError.refused("文件不属于当前用户或允许其他用户写入。")
        }
    }

    static func moveExclusive(_ source: URL, _ destination: URL) throws {
        guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw StartupError.transactionFailed("无法原子移动文件；不会覆盖已有目标（errno \(errno)）。")
        }
    }

    static func writeManifest(_ manifest: StartupBackupManifest, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".manifest-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StartupError.transactionFailed("无法写入备份记录。") }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw StartupError.transactionFailed("备份记录写入失败。") }
                offset += amount
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            throw StartupError.transactionFailed("备份记录无法落盘。")
        }
    }

    /// 仅用于系统 Label 的只读去重；用户文件始终走不跟随链接的 read。
    /// 每一级链接都必须由受信任系统所有者持有，且展开后仍位于受保护的系统根内。
    private static func readSystem(_ url: URL, directory: URL, trust: SystemReadTrust) throws -> (Data, StartupFileSnapshot) {
        let root = trust.root.standardizedFileURL
        func insideRoot(_ candidate: URL) -> Bool {
            candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
        }
        guard url.isFileURL, url.standardizedFileURL == url,
              url.deletingLastPathComponent().path == directory.path,
              insideRoot(directory), url.pathExtension.lowercased() == "plist" else {
            throw StartupError.refused("系统配置不属于受保护的只读扫描目录。")
        }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
              rootInfo.st_uid == trust.owner, rootInfo.st_mode & 0o022 == 0 else {
            throw StartupError.refused("系统扫描根的所有者、权限或链接校验失败。")
        }
        var pending = Array(url.pathComponents.dropFirst(root.pathComponents.count))
        var cursor = root
        var followedLinks = 0
        while !pending.isEmpty {
            cursor.appendPathComponent(pending.removeFirst())
            var info = stat()
            guard lstat(cursor.path, &info) == 0, info.st_uid == trust.owner else {
                throw StartupError.refused("系统配置路径不可读取或所有者不可信：\(url.lastPathComponent)")
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                followedLinks += 1
                guard followedLinks <= 32 else { throw StartupError.refused("系统配置符号链接层级过多。") }
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)
                let target = (destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                    : cursor.deletingLastPathComponent().appendingPathComponent(destination)).standardizedFileURL
                guard insideRoot(target) else {
                    throw StartupError.refused("系统配置符号链接离开受保护的系统目录。")
                }
                pending = Array(target.pathComponents.dropFirst(root.pathComponents.count)) + pending
                cursor = root
                continue
            }
            let protectedCryptex = Self.protectedCryptexNamespace(cursor, nextComponent: pending.first, trust: trust)
            guard (info.st_mode & 0o022 == 0 || protectedCryptex),
                  info.st_mode & S_IFMT == (pending.isEmpty ? S_IFREG : S_IFDIR) else {
                throw StartupError.refused("系统配置路径的类型或写入权限不安全：\(url.lastPathComponent)")
            }
            if pending.isEmpty {
                // Apple 系统 plist 也可能是硬链接；此例外只用于系统目录的只读去重。
                let result = try read(cursor, allowHardLinks: true)
                guard result.1.owner == trust.owner, result.1.mode & 0o022 == 0,
                      result.1.device == info.st_dev, result.1.inode == info.st_ino else {
                    throw StartupError.refused("系统配置在校验后发生变化，请重新扫描。")
                }
                return result
            }
        }
        throw StartupError.refused("系统配置符号链接未指向普通文件。")
    }

    private static func protectedCryptexNamespace(_ directory: URL, nextComponent: String?, trust: SystemReadTrust) -> Bool {
        // Apple 的此容器可为 0777；只接受其 root 拥有且 SF_NOUNLINK 保护的 App 目录。
        guard trust.owner == 0, trust.root.path == "/System", nextComponent == "App",
              directory.path == "/System/Volumes/Preboot/Cryptexes" else { return false }
        var app = stat()
        return lstat(directory.appendingPathComponent("App").path, &app) == 0
            && app.st_uid == 0 && app.st_mode & S_IFMT == S_IFDIR && app.st_mode & 0o022 == 0
            && app.st_flags & UInt32(SF_NOUNLINK) != 0
    }

    static func duplicateLabels(_ environment: StartupEnvironment, systemTrust: SystemReadTrust = .apple) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for directory in [environment.userAgents, environment.administratorAgents, environment.systemAgents] {
            guard exists(directory) else { continue }
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in entries where file.pathExtension.lowercased() == "plist" {
                let (data, _) = try (directory == environment.systemAgents
                    ? readSystem(file, directory: directory, trust: systemTrust) : read(file))
                let dictionary = try self.dictionary(data)
                if let label = dictionary["Label"] as? String { counts[label, default: 0] += 1 }
            }
        }
        return counts
    }

    static func applicationURL(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/"), let range = path.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app", isDirectory: true)
    }
}
