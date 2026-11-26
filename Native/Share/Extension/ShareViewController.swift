import UIKit
import UniformTypeIdentifiers

private struct SharedSource: Encodable {
    var kind: String
    var value: String
    var name: String
}

private struct ShareError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let done = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.text = "正在读取分享内容…"
        done.setTitle("完成", for: .normal)
        done.isHidden = true
        done.addTarget(self, action: #selector(close), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [message, done])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
        preferredContentSize = CGSize(width: 360, height: 180)
        Task {
            do {
                let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
                let providers = items.flatMap { $0.attachments ?? [] }
                let source: SharedSource
                if let provider = providers.first, providers.count == 1 {
                    source = try await Self.read(provider)
                } else if providers.isEmpty, let text = items.first?.attributedContentText?.string {
                    source = try Self.textSource(text)
                } else {
                    throw ShareError("请每次分享一个脚本文件、链接或文本。")
                }
                let files = FileManager.default
                guard let group = files.containerURL(forSecurityApplicationGroupIdentifier: "group.com.music.player.gyc") else {
                    throw ShareError("无法访问 CyMusic 共享目录。")
                }
                let inbox = group.appendingPathComponent("SharedSourceInbox", isDirectory: true)
                try files.createDirectory(at: inbox, withIntermediateDirectories: true)
                let target = inbox.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
                try JSONEncoder().encode(source).write(to: target, options: .atomic)
                message.text = "已保存。打开 CyMusic 确认导入音源。"
            } catch {
                message.text = "无法保存分享内容：\(error.localizedDescription)"
            }
            done.isHidden = false
        }
    }

    @objc private func close() { extensionContext?.completeRequest(returningItems: nil) }

    private static let byteLimit = 4 * 1024 * 1024

    private static func textSource(_ text: String, name: String? = nil) throws -> SharedSource {
        guard text.utf8.count <= byteLimit else { throw ShareError("脚本超过 4 MB。") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !text.contains("\0") else { throw ShareError("分享内容不是有效的脚本文本。") }
        if name == nil, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           let url = URL(string: trimmed), ["https", "http"].contains(url.scheme?.lowercased()), url.host != nil {
            return SharedSource(kind: "url", value: url.absoluteString, name: url.lastPathComponent.isEmpty ? "source.js" : url.lastPathComponent)
        }
        return SharedSource(kind: "text", value: text, name: name ?? "source.js")
    }

    private static func fileSource(_ url: URL, name: String?) throws -> SharedSource {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard bytes.count <= byteLimit else { throw ShareError("脚本超过 4 MB。") }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ShareError("请分享 UTF-8 编码的脚本。") }
        return try textSource(text, name: name ?? url.lastPathComponent)
    }

    private static func read(_ provider: NSItemProvider) async throws -> SharedSource {
        let ids = provider.registeredTypeIdentifiers
        if provider.canLoadObject(ofClass: NSURL.self) {
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                provider.loadObject(ofClass: NSURL.self) { object, error in
                    if let url = object as? URL { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: error ?? ShareError("无法读取链接。")) }
                }
            }
            if url.isFileURL { return try fileSource(url, name: nil) }
            let source = try textSource(url.absoluteString)
            guard source.kind == "url" else { throw ShareError("只支持 HTTP 或 HTTPS 链接。") }
            return source
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
            if let url = item as? URL, url.isFileURL { return try fileSource(url, name: nil) }
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                return try fileSource(url, name: nil)
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
            if let url = item as? URL {
                if url.isFileURL { return try fileSource(url, name: nil) }
                let source = try textSource(url.absoluteString)
                guard source.kind == "url" else { throw ShareError("只支持 HTTP 或 HTTPS 链接。") }
                return source
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), provider.suggestedName == nil {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
            if let text = item as? String { return try textSource(text) }
            if let url = item as? URL, url.isFileURL { return try fileSource(url, name: nil) }
            if let bytes = item as? Data, let text = String(data: bytes, encoding: .utf8) { return try textSource(text) }
        }
        guard let id = ids.first(where: { UTType($0)?.conforms(to: .data) == true }) else {
            throw ShareError("未找到脚本文件、链接或文本。")
        }
        // Providers may remove their temporary file as soon as the completion handler returns.
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: id) { url, error in
                do {
                    guard let url else { throw error ?? ShareError("无法读取分享文件。") }
                    continuation.resume(returning: try fileSource(url, name: suggestedName))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
