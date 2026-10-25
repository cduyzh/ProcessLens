import Foundation
import Dispatch

public struct MountedDiskVolume: Identifiable, Sendable, Hashable {
    public let mountPoint: String
    public let deviceEntry: String?

    public var id: String { "\(deviceEntry ?? "-")|\(mountPoint)" }
    public var name: String { URL(fileURLWithPath: mountPoint).lastPathComponent }

    public init(mountPoint: String, deviceEntry: String?) {
        self.mountPoint = mountPoint
        self.deviceEntry = deviceEntry
    }
}

public struct MountedDiskAttachment: Identifiable, Sendable, Hashable {
    /// The whole image device passed to `hdiutil detach` (for example `/dev/disk4`).
    public let ejectDevice: String
    public let volumes: [MountedDiskVolume]

    public var id: String { ejectDevice }

    public init(ejectDevice: String, volumes: [MountedDiskVolume]) {
        self.ejectDevice = ejectDevice
        self.volumes = volumes
    }
}

public struct MountedDiskImage: Identifiable, Sendable, Hashable {
    public let id: String
    public let sourcePath: String?
    public let imageType: String
    public let attachments: [MountedDiskAttachment]
    public let fileByteCount: Int64?
    public let fileModificationDate: Date?
    public let canMoveInstallerToTrash: Bool

    public var name: String {
        sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未命名磁盘映像"
    }

    public var volumes: [MountedDiskVolume] {
        var seen = Set<String>()
        return attachments.flatMap(\.volumes).filter { seen.insert($0.id).inserted }
    }

    public var mountedVolumeNames: String {
        let names = volumes.map(\.name)
        return names.isEmpty ? "没有已挂载卷" : names.joined(separator: "、")
    }

    public init(
        id: String,
        sourcePath: String?,
        imageType: String,
        attachments: [MountedDiskAttachment],
        fileByteCount: Int64?,
        fileModificationDate: Date?,
        canMoveInstallerToTrash: Bool
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.imageType = imageType
        self.attachments = attachments
        self.fileByteCount = fileByteCount
        self.fileModificationDate = fileModificationDate
        self.canMoveInstallerToTrash = canMoveInstallerToTrash
    }
}

public struct DiskImageActionOutcome: Identifiable, Sendable, Hashable {
    public let id: String
    public let imageName: String
    public let ejected: Bool
    public let movedToTrash: Bool
    public let detail: String?

    public init(id: String, imageName: String, ejected: Bool, movedToTrash: Bool, detail: String?) {
        self.id = id
        self.imageName = imageName
        self.ejected = ejected
        self.movedToTrash = movedToTrash
        self.detail = detail
    }
}

public struct DiskImageActionReport: Sendable, Hashable {
    public let outcomes: [DiskImageActionOutcome]

    public var ejectedCount: Int { outcomes.filter(\.ejected).count }
    public var trashedCount: Int { outcomes.filter(\.movedToTrash).count }
    public var failureCount: Int { outcomes.filter { !$0.ejected }.count }
    public var retainedPackageCount: Int { outcomes.filter { $0.ejected && !$0.movedToTrash && $0.detail != nil }.count }
    public var hasIssues: Bool { outcomes.contains { !$0.ejected || $0.detail != nil } }

    public var message: String {
        var parts = ["已推出 \(ejectedCount) 个镜像"]
        if trashedCount > 0 { parts.append("\(trashedCount) 个安装包已移到废纸篓") }
        if failureCount > 0 { parts.append("\(failureCount) 个镜像推出失败") }
        if retainedPackageCount > 0 { parts.append("\(retainedPackageCount) 个来源文件未移动") }
        let details = outcomes.compactMap { outcome in
            outcome.detail.map { "\(outcome.imageName)：\($0)" }
        }
        return (parts.joined(separator: "；") + "。")
            + (details.isEmpty ? "" : "\n" + details.joined(separator: "\n"))
    }

    public init(outcomes: [DiskImageActionOutcome]) {
        self.outcomes = outcomes
    }
}

public enum DiskImageError: LocalizedError, Sendable {
    case commandFailed(String, String)
    case malformedOutput
    case imageChanged
    case imageStillAttached
    case installerChanged

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, detail):
            "\(command) 失败：\(detail)"
        case .malformedOutput:
            "无法解析 macOS 返回的磁盘映像信息。"
        case .imageChanged:
            "镜像状态已变化，请刷新列表后重试。"
        case .imageStillAttached:
            "镜像仍处于挂载状态，安装包已保留。请关闭正在使用该卷的文件后重试。"
        case .installerChanged:
            "安装包在扫描后发生变化或已不可访问，未将其移到废纸篓。"
        }
    }
}

public struct DiskImageInspector: Sendable {
    public init() {}

    public func scan() async throws -> [MountedDiskImage] {
        try await Self.onWorker { try Self.scanSynchronously() }
    }

    private static func scanSynchronously() throws -> [MountedDiskImage] {
        try scanRecords(readImageRecords())
    }

    fileprivate static func scanRecords(_ records: [[String: Any]]) throws -> [MountedDiskImage] {
        var builders: [String: ImageBuilder] = [:]

        for record in records {
            let entities = record["system-entities"] as? [[String: Any]] ?? []
            let mountedVolumes = entities.compactMap { entity -> MountedDiskVolume? in
                guard let mountPoint = entity["mount-point"] as? String,
                      mountPoint.hasPrefix("/") else { return nil }
                return MountedDiskVolume(mountPoint: mountPoint,
                                         deviceEntry: entity["dev-entry"] as? String)
            }
            guard !mountedVolumes.isEmpty else { continue }

            let deviceEntries = entities.compactMap { $0["dev-entry"] as? String }
            guard let ejectDevice = deviceEntries.first(where: isWholeDiskDevice)
                    ?? deviceEntries.first.map(wholeDiskDevice(from:)) else { continue }

            let rawPath = record["image-path"] as? String
            let sourcePath = rawPath.flatMap(normalizedLocalPath)
            let key = sourcePath ?? "device:\(ejectDevice)"
            let imageType = record["image-type"] as? String ?? "磁盘映像"
            var builder = builders[key] ?? ImageBuilder(key: key, sourcePath: sourcePath,
                                                        imageType: imageType)
            builder.imageType = imageType
            builder.add(MountedDiskAttachment(ejectDevice: ejectDevice, volumes: mountedVolumes))
            builders[key] = builder
        }

        return builders.values.map(\.build).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    fileprivate static func readImageRecords() throws -> [[String: Any]] {
        let data = try runHdiutil(["info", "-plist"])
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            throw DiskImageError.malformedOutput
        }
        return images
    }

    fileprivate static func runHdiutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw DiskImageError.commandFailed("hdiutil", error.localizedDescription)
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiskImageError.commandFailed("hdiutil \(arguments.first ?? "")",
                                               detail?.isEmpty == false ? detail! : "退出码 \(process.terminationStatus)")
        }
        return output
    }

    fileprivate static func onWorker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    fileprivate static func normalizedLocalPath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    fileprivate static func isWholeDiskDevice(_ path: String) -> Bool {
        path.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil
    }

    fileprivate static func wholeDiskDevice(from path: String) -> String {
        path.replacingOccurrences(of: #"s\d+$"#, with: "", options: .regularExpression)
    }

    fileprivate struct ImageBuilder {
        let key: String
        let sourcePath: String?
        var imageType: String
        var attachments: [String: MountedDiskAttachment] = [:]

        mutating func add(_ attachment: MountedDiskAttachment) {
            if let previous = attachments[attachment.ejectDevice] {
                let volumes = Dictionary((previous.volumes + attachment.volumes).map { ($0.id, $0) },
                                          uniquingKeysWith: { first, _ in first })
                attachments[attachment.ejectDevice] = MountedDiskAttachment(
                    ejectDevice: attachment.ejectDevice,
                    volumes: volumes.values.sorted { $0.mountPoint < $1.mountPoint }
                )
            } else {
                attachments[attachment.ejectDevice] = attachment
            }
        }

        var build: MountedDiskImage {
            let file = sourcePath.flatMap(fileMetadata)
            return MountedDiskImage(
                id: key,
                sourcePath: sourcePath,
                imageType: imageType,
                attachments: attachments.values.sorted { $0.ejectDevice < $1.ejectDevice },
                fileByteCount: file?.byteCount,
                fileModificationDate: file?.modificationDate,
                canMoveInstallerToTrash: file?.canTrash ?? false
            )
        }
    }

    fileprivate struct FileMetadata {
        let byteCount: Int64?
        let modificationDate: Date?
        let canTrash: Bool
    }

    fileprivate static func fileMetadata(_ path: String) -> FileMetadata? {
        let url = URL(fileURLWithPath: path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType,
              type != .typeSymbolicLink else { return nil }

        let ext = url.pathExtension.lowercased()
        let supported = ["dmg", "iso", "cdr", "img", "sparseimage", "sparsebundle", "toast"].contains(ext)
        let isExpectedPackage = type == .typeRegular || (type == .typeDirectory && ext == "sparsebundle")
        return FileMetadata(byteCount: (attributes[.size] as? NSNumber)?.int64Value,
                            modificationDate: attributes[.modificationDate] as? Date,
                            canTrash: supported && isExpectedPackage)
    }
}

public enum DiskImageActions {
    /// Rechecks each selected image before ejecting. Installer files are moved to Trash only
    /// after the image is detached and macOS reports no remaining attachment for that source.
    public static func eject(_ images: [MountedDiskImage], movingInstallersToTrash: Bool) async -> DiskImageActionReport {
        if movingInstallersToTrash && images.contains(where: { !$0.canMoveInstallerToTrash }) {
            return DiskImageActionReport(outcomes: images.map {
                DiskImageActionOutcome(id: $0.id, imageName: $0.name, ejected: false,
                                       movedToTrash: false, detail: "所选项目中包含不可安全识别的安装包；请仅选择可移到废纸篓的镜像，或改用“仅推出”。")
            })
        }
        do {
            return try await DiskImageInspector.onWorker {
                try performSynchronously(images, movingInstallersToTrash: movingInstallersToTrash)
            }
        } catch {
            return DiskImageActionReport(outcomes: images.map {
                DiskImageActionOutcome(id: $0.id, imageName: $0.name, ejected: false,
                                       movedToTrash: false, detail: error.localizedDescription)
            })
        }
    }

    private static func performSynchronously(_ images: [MountedDiskImage], movingInstallersToTrash: Bool) throws -> DiskImageActionReport {
        var outcomes: [DiskImageActionOutcome] = []

        for expected in images {
            var ejected = false
            do {
                let currentRecords = try DiskImageInspector.readImageRecords()
                let current = try DiskImageInspector.scanRecords(currentRecords)
                    .first { $0.id == expected.id }
                guard let current,
                      current.imageType == expected.imageType,
                      current.volumes == expected.volumes,
                      Set(current.attachments.map(\.ejectDevice)) == Set(expected.attachments.map(\.ejectDevice)) else {
                    throw DiskImageError.imageChanged
                }

                for attachment in current.attachments {
                    _ = try DiskImageInspector.runHdiutil(["detach", attachment.ejectDevice])
                }

                let remainingRecords = try DiskImageInspector.readImageRecords()
                let stillAttached = remainingRecords.contains { record in
                    if let expectedPath = expected.sourcePath,
                       DiskImageInspector.normalizedLocalPath(record["image-path"] as? String) == expectedPath {
                        return true
                    }
                    let entities = record["system-entities"] as? [[String: Any]] ?? []
                    return expected.sourcePath == nil && entities.compactMap { $0["dev-entry"] as? String }
                        .contains(where: { expected.attachments.map(\.ejectDevice).contains(DiskImageInspector.wholeDiskDevice(from: $0)) })
                }
                guard !stillAttached else { throw DiskImageError.imageStillAttached }
                ejected = true

                var movedToTrash = false
                if movingInstallersToTrash {
                    guard expected.canMoveInstallerToTrash,
                          let path = expected.sourcePath,
                          let before = DiskImageInspector.fileMetadata(path), before.canTrash,
                          before.byteCount == expected.fileByteCount,
                          before.modificationDate == expected.fileModificationDate else {
                        throw DiskImageError.installerChanged
                    }
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
                    movedToTrash = true
                }

                outcomes.append(DiskImageActionOutcome(id: expected.id, imageName: expected.name,
                                                       ejected: true, movedToTrash: movedToTrash, detail: nil))
            } catch {
                outcomes.append(DiskImageActionOutcome(id: expected.id, imageName: expected.name,
                                                       ejected: ejected, movedToTrash: false,
                                                       detail: error.localizedDescription))
            }
        }
        return DiskImageActionReport(outcomes: outcomes)
    }
}
