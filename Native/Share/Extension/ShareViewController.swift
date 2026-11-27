import UIKit
import UniformTypeIdentifiers

private struct SharedSource: Encodable {
    let kind = "url"
    let value: String
}

private struct ShareError: ChineseUIError {
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
                guard items.count == 1, providers.count == 1, let provider = providers.first else {
                    throw ShareError("请每次分享一个 HTTP 或 HTTPS 链接。")
                }
                let source = try await Self.read(provider)
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
                message.text = "无法保存分享内容：\(L10n.message(for: error))"
            }
            done.isHidden = false
        }
    }

    @objc private func close() { extensionContext?.completeRequest(returningItems: nil) }

    private static func webURL(_ value: String) -> URL? {
        guard value.utf8.count <= 8192,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !value.contains("\\"), let url = URL(string: value), url.absoluteString == value,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased()),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return url
    }

    private static func read(_ provider: NSItemProvider) async throws -> SharedSource {
        guard !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
              provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else {
            throw ShareError("只支持 HTTP 或 HTTPS 链接。")
        }
        let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
        guard let url = item as? URL, webURL(url.absoluteString) != nil else {
            throw ShareError("分享内容不是有效的在线链接。")
        }
        return SharedSource(value: url.absoluteString)
    }
}
