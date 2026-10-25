import SwiftUI
import AppKit
import ProcessCore

struct DiskImagesView: View {
    @EnvironmentObject private var store: ProcessStore
    @State private var selectedIDs = Set<String>()
    @State private var detailID: String?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filteredImages: [MountedDiskImage] {
        store.diskImages.filter { image in
            query.isEmpty || [image.name, image.sourcePath ?? "", image.imageType, image.mountedVolumeNames,
                              image.volumes.map(\.mountPoint).joined(separator: " ")]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var selectedImages: [MountedDiskImage] {
        store.diskImages.filter { selectedIDs.contains($0.id) }
    }

    private var detailImage: MountedDiskImage? {
        store.diskImages.first { $0.id == detailID } ?? filteredImages.first
    }

    private var allVisibleSelected: Bool {
        !filteredImages.isEmpty && filteredImages.allSatisfy { selectedIDs.contains($0.id) }
    }

    private var canTrashSelection: Bool {
        !selectedImages.isEmpty && selectedImages.allSatisfy(\.canMoveInstallerToTrash)
    }

    var body: some View {
        VStack(spacing: 0) {
            introduction
            controls
            HStack(spacing: 0) {
                imageList.frame(width: 318)
                Rectangle().fill(Palette.line).frame(width: 1)
                detailPane
            }
        }
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .onReceive(NotificationCenter.default.publisher(for: .focusProcessSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in Task { await store.refreshDiskImages() }
        }
        .onChange(of: store.diskImages.map(\.id)) { _, ids in
            selectedIDs.formIntersection(Set(ids))
            if !ids.contains(detailID ?? "") { detailID = ids.first }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("安装后，把磁盘映像收好。").font(.system(size: 17, weight: .semibold))
                    Text("查看当前挂载的镜像与卷；可多选推出，并将本地安装镜像移到废纸篓。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { Task { await store.refreshDiskImages() } } label: {
                    Label(store.scanningDiskImages ? "扫描中…" : "重新扫描", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }.disabled(store.scanningDiskImages || store.operatingDiskImages)
            }
            HStack(spacing: 28) {
                summary("已挂载镜像", value: store.diskImages.count, symbol: "externaldrive", tint: Palette.accent)
                summary("已挂载卷", value: store.diskImages.reduce(0) { $0 + $1.volumes.count }, symbol: "externaldrive.fill", tint: Palette.blue)
                summary("本次选择", value: selectedImages.count, symbol: "checkmark.circle", tint: Palette.purple)
                Spacer(minLength: 0)
                if let date = store.diskImageScannedAt {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("按需扫描").font(.system(size: 9)).foregroundStyle(Palette.muted)
                        Text(date, style: .time).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }.padding(15).background(Palette.background, in: RoundedRectangle(cornerRadius: 9))
            if let report = store.diskImageActionReport {
                VStack(alignment: .leading, spacing: 7) {
                    Label("上次操作", systemImage: report.hasIssues ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(report.hasIssues ? Palette.orange : Palette.accent)
                    Text(report.message).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.padding(12).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 17)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(allVisibleSelected ? "取消全选" : "全选当前结果") {
                if allVisibleSelected { selectedIDs.subtract(filteredImages.map(\.id)) }
                else { selectedIDs.formUnion(filteredImages.map(\.id)) }
            }
            .font(.system(size: 10)).disabled(filteredImages.isEmpty || store.operatingDiskImages)

            if !selectedIDs.isEmpty {
                Button("清除选择") { selectedIDs.removeAll() }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Palette.muted)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.muted)
                TextField("搜索镜像 / 挂载卷", text: $query).textFieldStyle(.plain).font(.system(size: 10))
                    .focused($searchFocused).accessibilityLabel("搜索安装镜像")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }.padding(.horizontal, 9).frame(width: 205, height: 30)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? Palette.accent.opacity(0.5) : Palette.line))
        }.padding(.horizontal, 24).padding(.bottom, 16)
    }

    private var imageList: some View {
        VStack(spacing: 0) {
            HStack { Text("已挂载的磁盘映像"); Spacer(); Text(String(filteredImages.count)) }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 18).frame(height: 34).background(Palette.background)
            if store.scanningDiskImages && store.diskImageScannedAt == nil {
                ProgressView("正在读取挂载镜像…").font(.system(size: 11)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredImages.isEmpty {
                EmptyState(symbol: "externaldrive", title: query.isEmpty ? "没有已挂载的磁盘映像" : "没有匹配的镜像",
                           message: query.isEmpty ? "挂载安装镜像后，可在这里批量推出并清理安装包。" : "试试其他镜像名、卷名或挂载路径。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredImages) { image in imageRow(image) }
                    }
                }
            }
        }
    }

    private func imageRow(_ image: MountedDiskImage) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                if selectedIDs.contains(image.id) { selectedIDs.remove(image.id) }
                else { selectedIDs.insert(image.id) }
            } label: {
                Image(systemName: selectedIDs.contains(image.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).foregroundStyle(selectedIDs.contains(image.id) ? Palette.accent : Palette.muted)
                    .frame(width: 20, height: 24)
            }.buttonStyle(.plain).accessibilityLabel(selectedIDs.contains(image.id) ? "取消选择\(image.name)" : "选择\(image.name)")

            Button { detailID = image.id } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        SymbolBadge(symbol: "externaldrive", tint: image.canMoveInstallerToTrash ? Palette.accent : Palette.blue, size: 29)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(image.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text("\(image.volumes.count) 个卷 · \(image.attachments.count) 个挂载实例")
                                .font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Text(image.mountedVolumeNames).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(image.canMoveInstallerToTrash ? "可移到废纸篓" : "仅可推出")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(image.canMoveInstallerToTrash ? Palette.accent : Palette.muted)
                    }
                }.padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .background(selectedIDs.contains(image.id) ? Palette.accent.opacity(0.045) : (detailID == image.id ? Color.primary.opacity(0.025) : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 0.5) }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detailPane: some View {
        if let image = detailImage {
            ScrollView {
                VStack(alignment: .leading, spacing: 21) {
                    HStack(alignment: .top, spacing: 12) {
                        SymbolBadge(symbol: "externaldrive", tint: Palette.accent, size: 44)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(image.name).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                            Text(image.imageType).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        property("来源文件", image.sourcePath ?? "系统未提供本地文件路径")
                        if let size = image.fileByteCount, size >= 0 {
                            property("安装包大小", Format.bytes(UInt64(size)))
                        }
                        property("挂载卷", "\(image.volumes.count) 个")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("挂载位置").font(.system(size: 11, weight: .medium))
                        ForEach(image.volumes) { volume in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Image(systemName: "externaldrive.fill").font(.system(size: 10)).foregroundStyle(Palette.accent)
                                    Text(volume.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                    Spacer()
                                    Button("在访达中打开") {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: volume.mountPoint))
                                    }.font(.system(size: 9)).buttonStyle(.plain).foregroundStyle(Palette.accent)
                                }
                                Text(volume.mountPoint).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }.padding(10).background(Palette.background, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }

                    if !image.canMoveInstallerToTrash {
                        Label("此来源不是可安全识别的本地安装镜像文件；可推出镜像，来源文件会保留。",
                              systemImage: "info.circle")
                            .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(selectedImages.isEmpty ? "先勾选要操作的镜像" : "已选择 \(selectedImages.count) 个镜像")
                            .font(.system(size: 11, weight: .medium))
                        HStack(spacing: 10) {
                            Button {
                                let targets = selectedImages
                                Task { await store.ejectDiskImages(targets, movingInstallersToTrash: true) }
                            } label: {
                                Label(store.operatingDiskImages ? "正在处理…" : "移到废纸篓并推出", systemImage: "trash")
                                    .font(.system(size: 10, weight: .medium)).frame(maxWidth: .infinity, minHeight: 34)
                            }.buttonStyle(.borderedProminent)
                                .disabled(!canTrashSelection || store.operatingDiskImages || store.scanningDiskImages)
                                .help(canTrashSelection ? "推出所选镜像，并把安装包移到废纸篓" : "请只选择来源文件可安全移到废纸篓的镜像")

                            Button {
                                let targets = selectedImages
                                Task { await store.ejectDiskImages(targets, movingInstallersToTrash: false) }
                            } label: {
                                Label("仅推出", systemImage: "eject").font(.system(size: 10, weight: .medium))
                                    .frame(minWidth: 90, minHeight: 34)
                            }.buttonStyle(.bordered)
                                .disabled(selectedImages.isEmpty || store.operatingDiskImages || store.scanningDiskImages)
                        }
                        Text("安装包会先成功推出镜像，再移入废纸篓；若卷仍被占用，文件会保留。")
                            .font(.system(size: 9)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }.padding(13).background(Palette.background, in: RoundedRectangle(cornerRadius: 9))

                    if !selectedIDs.contains(image.id) {
                        Button { selectedIDs.insert(image.id) } label: {
                            Label("将此镜像加入选择", systemImage: "plus.square")
                                .font(.system(size: 10)).foregroundStyle(Palette.accent)
                        }.buttonStyle(.plain)
                    }
                }.padding(24)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
        } else {
            EmptyState(symbol: "externaldrive", title: "选择一个磁盘映像", message: "勾选一个或多个镜像，批量推出并清理安装包。")
        }
    }

    private func summary(_ title: String, value: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 9)).foregroundStyle(Palette.muted)
                Text(String(value)).font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit()
            }
        }.frame(minWidth: 112, alignment: .leading)
    }

    private func property(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 10, design: title == "来源文件" ? .monospaced : .default))
                .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
