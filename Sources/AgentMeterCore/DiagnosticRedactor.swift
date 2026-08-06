import Foundation

public enum DiagnosticRedactor {
    /// 認証値らしい文字列、メールアドレス、絶対パスを診断出力から除去する。
    public static func redact(_ value: String) -> String {
        var result = value
        let patterns = [
            "Bearer\\s+[^\\s,]+",
            "(token|secret|authorization|cookie|password)\\s*[:=]\\s*[^\\s,]+",
            "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
            "/(?:Users|private|var|home)/[^\\s,\\\"]+",
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[REDACTED]", options: [.regularExpression, .caseInsensitive])
        }
        return result
    }
}
