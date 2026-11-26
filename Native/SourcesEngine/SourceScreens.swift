import SwiftUI

struct SourcesScreen: View {
    @EnvironmentObject private var engine: SourceEngine
    @State private var adding = false
    @State private var busy = false
    @State private var input = ""
    @State private var error: String?


    var body: some View {
        List {
            Section {
                Picker("播放音质", selection: Binding(get: { engine.quality }, set: { value in
                    do { try engine.setQuality(value) } catch { self.error = error.localizedDescription }
                })) {
                    ForEach(SourceEngine.Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            Section("已安装") {
                if engine.scripts.isEmpty { Text("尚未导入音源").foregroundStyle(.secondary) }
                if !engine.scripts.isEmpty {
                    Button("测试音源") { engine.testAll() }
                }
                ForEach(engine.scripts) { item in
                    VStack(alignment: .leading) {
                        Text(item.name)
                        if let status = engine.statuses[item.id] { Text(status).font(.caption) }
                        if let author = item.metadata["author"] { Text([author, item.metadata["version"]].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    }.swipeActions { Button("删除", role: .destructive) { run { try engine.remove(item) } } }
                }
            }
            if let error = error ?? engine.notice { Text(error).foregroundStyle(.secondary) }
        }.navigationTitle("音源")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { input = ""; adding = true } label: { Label("添加音源", systemImage: "plus") }
                    .disabled(busy)
            }
        }
        .alert("添加在线音源", isPresented: $adding) {
            TextField("https://…", text: $input)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("下载并导入") {
                let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
                busy = true
                run {
                    defer { busy = false }
                    let url = try OnlineSource.link(value)
                    let script = try await OnlineSource.download(url)
                    try await engine.importScript(script, name: OnlineSource.name(url))
                }
            }
        } message: { Text("粘贴 HTTP 或 HTTPS 脚本链接。导入后会运行脚本，请只使用可信来源。") }
        .overlay { if busy { ProgressView("正在导入…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task { @MainActor in
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
}
