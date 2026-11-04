import SwiftUI
import ImageIO
import UIKit

struct ImageHistoryPage: View {
    @Environment(ImageGenerationSession.self) private var generator
    @State private var pendingDelete: GeneratedImage?

    var body: some View {
        List {
            if generator.history.isEmpty {
                ContentUnavailableView("暂无生成图片", systemImage: "photo.on.rectangle.angled",
                                       description: Text("生成的图片会保存在这里，重新打开 App 后仍可查看和分享。"))
            } else {
                ForEach(generator.history) { image in
                    NavigationLink {
                        ImageHistoryDetail(image: image)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(image.date.formatted(date: .abbreviated, time: .standard))
                            Text(ByteCountFormatter.string(fromByteCount: image.byteCount, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { pendingDelete = image }
                    }
                }
            }
        }
        .navigationTitle("生成历史")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { generator.refreshHistory() }
        .confirmationDialog("删除这张图片？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let image = pendingDelete { generator.deleteImage(image) }
                pendingDelete = nil
            }
        }
        .alert("图片历史", isPresented: Binding(
            get: { generator.historyError != nil },
            set: { if !$0 { generator.historyError = nil } }
        )) {
            Button("好") { generator.historyError = nil }
        } message: { Text(generator.historyError ?? "") }
    }
}

private struct ImageHistoryDetail: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ImageGenerationSession.self) private var generator
    @State private var confirmingDelete = false
    let image: GeneratedImage

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GeneratedImagePreview(url: image.url)
                Text(image.date.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                ShareLink("分享或保存图片", item: image.url).buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("生成图片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("删除图片", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("删除这张图片？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                if generator.deleteImage(image) { dismiss() }
            }
        }
    }
}

/// Decode only the visible image and cap preview pixels; sharing retains the original PNG.
struct GeneratedImagePreview: View {
    let url: URL
    @State private var picture: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let picture {
                Image(uiImage: picture).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            } else if failed {
                ContentUnavailableView("无法预览图片", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task(id: url) {
            picture = nil
            failed = false
            let imageURL = url
            let result = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1600
                      ] as CFDictionary) else { return UIImage?.none }
                return UIImage(cgImage: thumbnail)
            }.value
            guard !Task.isCancelled else { return }
            picture = result
            failed = result == nil
        }
    }
}
