import Darwin
import Foundation

final class TerminalTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        data.append(incoming)
        if data.count > 1_500_000 { data.removeFirst(data.count - 1_500_000) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

final class PseudoTerminalProcess: @unchecked Sendable {
    private let executableURL: URL
    private let currentDirectoryURL: URL
    private let process = Process()
    private let transcriptStore = TerminalTranscript()
    private var master: FileHandle?
    private var slaveDescriptor: Int32 = -1

    init(executableURL: URL, currentDirectoryURL: URL) throws {
        self.executableURL = executableURL
        self.currentDirectoryURL = currentDirectoryURL

        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        var size = winsize(ws_row: 80, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterDescriptor, &slaveDescriptor, nil, nil, &size) == 0 else {
            throw UsageProviderError.protocolError("pty")
        }
        master = FileHandle(fileDescriptor: masterDescriptor, closeOnDealloc: true)
        self.slaveDescriptor = slaveDescriptor
    }

    var transcript: String { transcriptStore.text }

    func start() throws {
        guard let master else { throw UsageProviderError.protocolError("pty") }
        let slave = FileHandle(fileDescriptor: slaveDescriptor, closeOnDealloc: false)
        process.executableURL = executableURL
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLUMNS"] = "120"
        environment["LINES"] = "80"
        process.environment = environment
        master.readabilityHandler = { [transcriptStore] handle in
            transcriptStore.append(handle.availableData)
        }
        do {
            try process.run()
            close(slaveDescriptor)
            slaveDescriptor = -1
        } catch {
            master.readabilityHandler = nil
            close(slaveDescriptor)
            slaveDescriptor = -1
            throw UsageProviderError.executableNotFound
        }
    }

    func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        try? master?.write(contentsOf: data)
    }

    func stop() {
        write("\u{1B}")
        write("/exit\r")
        if process.isRunning { process.terminate() }
        master?.readabilityHandler = nil
        if slaveDescriptor >= 0 { close(slaveDescriptor) }
        slaveDescriptor = -1
        try? master?.close()
        master = nil
    }
}
