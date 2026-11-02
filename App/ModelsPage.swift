import SwiftUI
import UniformTypeIdentifiers

struct ModelsPage: View {
    @Environment(ModelLibrary.self) private var library
    @Environment(ChatSession.self) private var chat
    @State private var importing = false
    @State private var downloading = false
    @State private var query = ""
    @State private var pendingDelete: LocalModel?
    let selectModel: (LocalModel) -> Void

    private var filteredModels: [LocalModel] {
        library.models.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !library.isReady {
                    Section {
                        Button("重新打开模型库") { Task { await library.open() } }
                    }
                } else {
                    Section {
                        LabeledContent("本机模型", value: "\(library.models.count) 个")
                        LabeledContent("文件占用", value: bytes(library.totalBytes))
                    }
                    if library.isImporting {
                        Section {
                            ProgressView("正在复制并检查文件…")
                            Button("取消导入", role: .cancel) { library.cancelImport() }
                        }
                    }
                    if let download = library.download, let transfer = download.transfer {
                        Section("下载") { TransferRow(download: download, transfer: transfer) }
                    }
                    if library.models.isEmpty {
                        Section {
                            ContentUnavailableView {
                                Label("添加你的第一个模型", systemImage: "square.stack.3d.up")
                            } description: {
                                Text("从文件导入，或粘贴 HTTPS 文件直链。下载完成后还需要检查引擎兼容性。")
                            } actions: {
                                Button("从文件导入") { importing = true }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(library.isWriting)
                            }
                        }
                        .listRowBackground(Color.clear)
                    } else if filteredModels.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        Section("模型文件") {
                            ForEach(filteredModels) { model in
                                NavigationLink {
                                    ModelDetail(model: model, selectModel: selectModel)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(model.name).font(.headline).lineLimit(2)
                                        Text("\(model.format.rawValue) · \(bytes(model.byteCount))")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                        Text(model.adapter ?? model.architecture ?? "架构尚未确认")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .swipeActions {
                                    Button("删除", role: .destructive) { pendingDelete = model }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("模型")
            .searchable(text: $query, prompt: "搜索本机模型")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SettingsButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("添加模型", systemImage: "plus") {
                        Button("从文件导入", systemImage: "folder") { importing = true }
                            .disabled(library.isWriting)
                        Button("从 HTTPS 下载", systemImage: "arrow.down.circle") { downloading = true }
                            .disabled(library.download?.transfer != nil)
                    }
                    .disabled(!library.isReady)
                    .accessibilityIdentifier("addModel")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls) }
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $downloading) { DownloadSheet() }
            .confirmationDialog("删除模型文件？", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible) {
                if let model = pendingDelete {
                    Button("删除 \(model.name)", role: .destructive) {
                        Task {
                            if chat.loadedModelID == model.id || (chat.isBusy && chat.lastModelID == model.id) {
                                await chat.unload()
                            }
                            await library.delete(model)
                        }
                    }
                }
            } message: {
                Text("这会释放模型占用的存储空间。导入前的原始文件不会被删除。")
            }
        }
    }
}

private struct ModelDetail: View {
    let model: LocalModel
    let selectModel: (LocalModel) -> Void

    var body: some View {
        List {
            Section("文件") {
                LabeledContent("名称", value: model.name)
                LabeledContent("大小", value: bytes(model.byteCount))
                LabeledContent("导入时间", value: model.importedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("识别结果") {
                LabeledContent("格式", value: model.format.rawValue)
                LabeledContent("架构", value: model.architecture ?? "尚未确认")
                LabeledContent("量化", value: model.quantization ?? "尚未确认")
                LabeledContent("适配器", value: model.adapter ?? "未识别")
                Text(model.validationNote).font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Text(model.compatibilityDescription)
                if model.format == .litertLM {
                    Button("用于 AI 对话", systemImage: "bubble.left.and.bubble.right") { selectModel(model) }
                }
            } header: {
                Text("运行兼容性")
            } footer: {
                Text("文件头识别不等于完整性或运行验证。模型架构、量化与适配器必须由对应引擎实际加载确认。")
            }
        }
        .navigationTitle("模型详情")
        .navigationBarTitleDisplayMode(.inline)
        .textSelection(.enabled)
    }
}

private struct DownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ModelLibrary.self) private var library
    @State private var address = ""
    @State private var filename = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("文件直链") {
                    TextField("https://…/model.litertlm", text: $address, axis: .vertical)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("downloadURL")
                    TextField("文件名（可选）", text: $filename)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("downloadFilename")
                }
                Section {
                    Text("支持公开 HTTPS 文件直链，包括 Hugging Face 的 resolve 下载地址。网页、仓库目录和需要登录的链接不能直接下载。")
                    Text("进入后台时暂停。断点续传取决于服务器和系统是否保留临时文件。")
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("downloadError") }
                }
            }
            .navigationTitle("下载模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载") {
                        do {
                            let request = try DownloadRequest(address: address, name: filename)
                            guard let download = library.download else { return }
                            try download.start(request)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("startDownload")
                }
            }
        }
    }
}

private struct TransferRow: View {
    let download: ModelDownload
    let transfer: ModelTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(transfer.request.name).font(.headline).lineLimit(2)
            if transfer.phase == .importing {
                ProgressView("正在检查并保存…")
            } else if transfer.phase == .pausing {
                ProgressView("正在保存下载断点…")
            } else {
                if let progress = transfer.progress { ProgressView(value: progress) }
                else if transfer.phase == .downloading { ProgressView() }
                Text(transfer.expected > 0
                     ? "\(bytes(transfer.received)) / \(bytes(transfer.expected))"
                     : "已下载 \(bytes(transfer.received)) · 总大小未知")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let note = transfer.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                if transfer.phase == .downloading {
                    Button("暂停", systemImage: "pause") { Task { await download.pause() } }
                } else if !transfer.isBusy {
                    Button("继续", systemImage: "play") { Task { await download.resume() } }
                    Button("重新下载") { Task { await download.resume(restart: true) } }
                }
                Spacer()
                Button("取消", role: .destructive) { download.cancel() }
                    .disabled(transfer.phase == .importing || transfer.phase == .pausing)
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
        }
        .padding(.vertical, 6)
    }
}

private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
