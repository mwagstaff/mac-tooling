import SwiftUI

private enum Connection {
    case checking, connected, unavailable, unknown

    var symbol: String {
        switch self {
        case .checking: "ellipsis.circle"
        case .connected: "iphone.badge.checkmark"
        case .unavailable: "iphone.slash"
        case .unknown: "questionmark.diamond"
        }
    }
}

@MainActor
private final class Monitor: ObservableObject {
    @Published var connection = Connection.checking
    @Published var message = "Checking Mike’s iPhone…"
    private var checking = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.2
    }

    func refresh() {
        guard !checking else { return }
        checking = true
        Task {
            let (status, detail) = await Task.detached { Self.check() }.value
            connection = status
            message = detail
            checking = false
        }
    }

    nonisolated private static func check() -> (Connection, String) {
        let failure = (Connection.unknown, "Could not check Mike’s iPhone. Check your Xcode installation.")
        guard let helper = Bundle.main.url(forResource: "phone_status", withExtension: "py") else { return failure }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path]
        process.standardOutput = pipe
        do { try process.run() } catch { return failure }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return failure }
        switch process.terminationStatus {
        case 0: return (.connected, text)
        case 1: return (.unavailable, text)
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
            case .connected: Text("Mike’s iPhone is connected")
            case .unavailable: Text("Mike’s iPhone is unavailable")
            case .unknown: Text("Couldn’t check Mike’s iPhone")
            }
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
