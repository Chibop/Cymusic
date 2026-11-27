import SwiftUI

private struct SharedSource: Decodable {
    let url: URL
    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: Decoder) throws {
        let record = try decoder.container(keyedBy: CodingKeys.self)
        guard try record.decode(String.self, forKey: .kind) == "url" else {
            throw ImportError("不再支持导入文件或脚本文本，请分享在线链接。")
        }
        url = try OnlineSource.link(record.decode(String.self, forKey: .value))
    }
}

// Settings and the host revalidate all incoming links, including old inbox records.
enum OnlineSource {
    static func webURL(_ value: String) -> URL? {
        guard value.utf8.count <= 8192,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !value.contains("\\"), let url = URL(string: value), url.absoluteString == value,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased()),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return url
    }

    static func link(_ value: String) throws -> URL {
        guard let url = webURL(value) else { throw ImportError("请输入有效的 HTTP 或 HTTPS 脚本链接。") }
        return url
    }

    static func name(_ url: URL) -> String {
        url.lastPathComponent.isEmpty ? "source.js" : url.lastPathComponent
    }

    static func download(_ url: URL) async throws -> String {
        let url = try link(url.absoluteString)
        let limit = 4 * 1024 * 1024
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: WebRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, let final = http.url, webURL(final.absoluteString) != nil else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw ImportError("服务器返回 HTTP \(http.statusCode)。") }
        guard response.expectedContentLength <= limit else { throw ImportError("脚本超过 4 MB。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ImportError("脚本超过 4 MB。") }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError("链接未返回有效的 UTF-8 脚本文本。")
        }
        return text
    }
}

private final class WebRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url.flatMap { OnlineSource.webURL($0.absoluteString) } != nil
        completionHandler(allowed ? request : nil)
    }
}

private struct ImportError: ChineseUIError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct InboxItem: Identifiable {
    let id: URL
    let content: Result<SharedSource, Error>
}

extension View {
    func receiveSharedSource(_ receive: @escaping @MainActor (String, String) async throws -> Void) -> some View {
        modifier(SharedSourceReceiver(receive: receive))
    }
}

private struct SharedSourceReceiver: ViewModifier {
    @Environment(\.scenePhase) private var phase
    let receive: @MainActor (String, String) async throws -> Void
    @State private var item: InboxItem?
    @State private var scanNext = false
    @State private var inboxError: String?

    func body(content: Content) -> some View {
        content.onAppear { scan() }
            .onChange(of: phase) { if $0 == .active { scan() } }
            .sheet(item: $item, onDismiss: {
                if scanNext { scanNext = false; scan() }
            }) { current in
                SharedSourceConfirmation(item: current, receive: receive) {
                    scanNext = true
                    item = nil
                }
            }
            .alert("无法读取共享目录", isPresented: Binding(get: { inboxError != nil }, set: { if !$0 { inboxError = nil } })) {
                Button("确定") { inboxError = nil }
            } message: { Text(inboxError ?? "") }
    }

    private func scan() {
        guard item == nil else { return }
        let files = FileManager.default
        do {
            guard let group = files.containerURL(forSecurityApplicationGroupIdentifier: "group.com.music.player.gyc") else {
                throw ImportError("请检查 CyMusic 的 App Group 配置。")
            }
            let inbox = group.appendingPathComponent("SharedSourceInbox", isDirectory: true)
            try files.createDirectory(at: inbox, withIntermediateDirectories: true)
            let urls = try files.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
            let oldest = try urls.filter { $0.pathExtension == "json" }.map { url in
                (url, try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast)
            }.min { $0.1 < $1.1 }
            if let url = oldest?.0 {
                item = InboxItem(id: url, content: Result {
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let limit = 64 * 1024
                    let data = try file.read(upToCount: limit + 1) ?? Data()
                    guard data.count <= limit else { throw ImportError("分享的链接记录过大。") }
                    return try JSONDecoder().decode(SharedSource.self, from: data)
                })
            }
        } catch { inboxError = L10n.message(for: error) }
    }
}

private struct SharedSourceConfirmation: View {
    let item: InboxItem
    let receive: @MainActor (String, String) async throws -> Void
    let finish: () -> Void
    @State private var busy = false
    @State private var imported = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                switch item.content {
                case .success(let source):
                    Section("分享内容") {
                        Text(verbatim: OnlineSource.name(source.url))
                        Text(verbatim: source.url.absoluteString).font(.footnote.monospaced()).foregroundStyle(.secondary)
                    }
                    if let errorMessage { Section("导入提示") { Text(verbatim: errorMessage) } }
                    Button {
                        guard !busy else { return }
                        busy = true
                        Task { @MainActor in
                            defer { busy = false }
                            do {
                                if !imported {
                                    let text = try await OnlineSource.download(source.url)
                                    try await receive(text, OnlineSource.name(source.url))
                                    imported = true
                                }
                                try removeItem()
                            } catch { errorMessage = L10n.message(for: error) }
                        }
                    } label: {
                        if busy { ProgressView() }
                        else { Text(imported ? "完成" : "下载并导入") }
                    }.disabled(busy)
                case .failure(let error):
                    Section("无法读取分享内容") { Text(errorMessage ?? L10n.message(for: error)) }
                }
                if !imported {
                    Button("丢弃", role: .destructive) {
                        do { try removeItem() } catch { errorMessage = L10n.message(for: error) }
                    }.disabled(busy)
                }
            }
            .navigationTitle("导入共享音源").navigationBarTitleDisplayMode(.inline)
        }.interactiveDismissDisabled(busy || imported)
    }

    private func removeItem() throws {
        try FileManager.default.removeItem(at: item.id)
        finish()
    }
}
