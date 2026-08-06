import AgentMeterCore
import Foundation

@main
struct AgentMeterSpikeMain {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "antigravity" {
            await runAntigravity()
            return
        }
        let cli = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_CLI_PATH"] ?? "/usr/local/bin/codex")
        let iterations = Int(CommandLine.arguments.dropFirst().first ?? "1") ?? 1
        let provider = AppServerProvider(executableURL: cli)
        do {
            for _ in 0..<iterations { _ = try await provider.fetchSnapshot() }
            await provider.disconnect()
            let message = "取得成功: \(iterations) 回。値やアカウント情報は出力していません。\n"
            FileHandle.standardOutput.write(Data(message.utf8))
        } catch {
            await provider.disconnect()
            fputs("取得失敗: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func runAntigravity() async {
        let cli = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ANTIGRAVITY_CLI_PATH"] ?? "/usr/local/bin/agy")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("agent-meter-antigravity", isDirectory: true)
        let provider = AntigravityCLIProvider(executableURL: cli, workingDirectoryURL: workspace)
        do {
            let snapshot = try await provider.fetchSnapshot()
            let summary = snapshot.limits.map { limit in
                "\(limit.displayName ?? limit.id): \(limit.primary?.remainingPercent ?? 0)%"
            }.joined(separator: ", ")
            FileHandle.standardOutput.write(Data("取得成功: \(summary)\n".utf8))
        } catch {
            fputs("取得失敗: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}
