import Foundation

/// Only app-authored localized errors may supply text directly to the UI.
protocol ChineseUIError: LocalizedError {}

enum L10n {
    static let locale = Locale(identifier: "zh-Hans")

    static func quality(_ value: String) -> String {
        var parts = value.components(separatedBy: " · ")
        switch parts[0] {
        case "Hi-Res Lossless": parts[0] = "高解析度无损"
        case "Lossless", "flac": parts[0] = value == "flac" ? "无损（FLAC）" : "无损"
        case "128k": parts[0] = "标准（128 kbps）"
        case "320k": parts[0] = "高品质（320 kbps）"
        default: return value
        }
        return parts.joined(separator: " · ")
    }

    static func message(for error: Error) -> String {
        if let known = error as? ChineseUIError, let text = known.errorDescription { return text }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet: return "未连接网络，请检查网络连接。"
            case .timedOut: return "请求超时，请重试。"
            case .badURL, .unsupportedURL: return "链接无效或不受支持。"
            default: return "无法完成网络请求（错误码：\(url.errorCode)）。"
            }
        }
        if error is DecodingError { return "数据格式有误，无法读取。" }
        return "操作失败（错误码：\((error as NSError).code)）。"
    }
}
