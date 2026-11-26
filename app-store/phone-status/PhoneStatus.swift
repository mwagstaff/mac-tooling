import SwiftUI

private enum Connection {
    case checking, connected, locked, unlocked, unavailable, unknown

    var symbol: String {
        switch self {
        case .checking: "ellipsis.circle"
        case .connected: "iphone"
        case .locked: "lock.iphone"
        case .unlocked: "iphone.badge.checkmark"
        case .unavailable: "iphone.slash"
        case .unknown: "questionmark.diamond"
        }
    }
}

@MainActor
private final class Monitor: ObservableObject {
    @Published var connection = Connection.checking
    @Published var message = "Checking Mike’s iPhone…"
    @Published var ipadRows = ["Checking Skyla’s iPad…", "Checking Nova’s iPad…"]
    private var checkingIPads = false
    private var checking = false
    private var timer: Timer?

    init() {
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        if !checkingIPads {
            checkingIPads = true
            Task {
                ipadRows = await Task.detached { Self.checkIPads() }.value
                checkingIPads = false
            }
        }
        guard !checking else { return }
        checking = true
        Task {
            let (status, detail) = await Task.detached { Self.check() }.value
            connection = status
            message = detail
            checking = false
        }
    }

    nonisolated private static func runHelper(_ arguments: [String]) -> (Int32, Data)? {
        guard let helper = Bundle.main.url(forResource: "phone_status", withExtension: "py") else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path] + arguments
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    nonisolated private static func checkIPads() -> [String] {
        guard let (code, data) = runHelper(["--ipads"]), code == 0,
              let rows = try? JSONDecoder().decode([String].self, from: data) else {
            return ["Couldn’t check Skyla’s iPad", "Couldn’t check Nova’s iPad"]
        }
        return rows
    }

    nonisolated private static func check() -> (Connection, String) {
        let failure = (Connection.unknown, "Could not check Mike’s iPhone. Check your Xcode installation.")
        guard let (code, data) = runHelper([]),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return failure }
        switch code {
        case 0: return (.connected, text)
        case 1: return (.unavailable, text)
        case 3: return (.locked, text)
        case 4: return (.unlocked, text)
        default: return (.unknown, text)
        }
    }
}

@main
struct PhoneStatusApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            switch monitor.connection {
            case .checking: Text("Checking Mike’s iPhone…")
            case .connected: Text("Mike’s iPhone is connected · Lock state unknown")
            case .locked: Text("Mike’s iPhone is locked")
            case .unlocked: Text("Mike’s iPhone is unlocked")
            case .unavailable: Text("Mike’s iPhone is unavailable")
            case .unknown: Text("Couldn’t check Mike’s iPhone")
            }
            Divider()
            ForEach(monitor.ipadRows, id: \.self) { row in Text(row) }
            Divider()
            Button("Check Again") { monitor.refresh() }
            Button("Quit Phone Status") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: monitor.connection.symbol)
                .accessibilityLabel(monitor.message)
                .help(monitor.message)
        }
    }
}
