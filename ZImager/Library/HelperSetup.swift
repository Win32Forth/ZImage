import Network
import SwiftUI

enum HelperSetupError: LocalizedError {
    case missingBundle
    case stillRunning
    case unknownPort
    case badPath

    var errorDescription: String? {
        switch self {
        case .missingBundle:
            return "This copy of ZImager does not contain the helper programs."
        case .stillRunning:
            return "The helper is still answering on this server. Click Enabled on zimage-helper-stop, uncheck Enabled on zimage-helper, select zimage-helper-stop, and click Run. Then try again."
        case .unknownPort:
            return "ZImager could not tell whether the helper is running. Click Enabled on zimage-helper-stop, uncheck Enabled on zimage-helper, select zimage-helper-stop, and click Run. Then try again."
        case .badPath:
            return "The path on the Synology has to be an absolute path, such as /volume1/BackupData/PhotoVideoAudio."
        }
    }
}

nonisolated enum HelperPort {
    /// A refused connection means nothing is accepting port 8742.
    static func meansClosed(_ error: NWError) -> Bool {
        if case .posix(let code) = error {
            return code == .ECONNREFUSED
        }
        return false
    }

    /// True when TCP 8742 accepts a connection. False when the host refuses it. Nil when the check does not finish.
    static func isListening(host: String, timeout: Duration = .seconds(3)) async -> Bool? {
        guard HelperClient.isIPv4(host) else { return nil }
        let probe = PortProbe(host: host)
        return await withCheckedContinuation { continuation in
            probe.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    probe.finish(true, continuation: continuation)
                case .waiting(let error):
                    // A closed port stays in waiting with ECONNREFUSED. It does not move to failed.
                    if Self.meansClosed(error) {
                        probe.finish(false, continuation: continuation)
                    }
                case .failed(let error):
                    if Self.meansClosed(error) {
                        probe.finish(false, continuation: continuation)
                    } else {
                        probe.finish(nil, continuation: continuation)
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }
            probe.connection.start(queue: .global())
            Task {
                try? await Task.sleep(for: timeout)
                probe.finish(nil, continuation: continuation)
            }
        }
    }
}

private nonisolated final class PortProbe: @unchecked Sendable {
    let connection: NWConnection
    private let lock = NSLock()
    private var done = false

    init(host: String) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: 8742, using: .tcp)
    }

    func finish(_ value: Bool?, continuation: CheckedContinuation<Bool?, Never>) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        guard first else { return }
        connection.cancel()
        continuation.resume(returning: value)
    }
}

@MainActor
@Observable
final class HelperSetupSession: Identifiable {
    enum Mode {
        case install
        case update
        case uninstall
        case stop
    }

    enum Page {
        case path
        case task
        case done
        case confirmStop
        case stopHelp
    }

    let id = UUID()
    let mode: Mode
    var page: Page
    var nasPath: String
    var message: String?
    var busy = false
    var afterCopy: ((String) -> Void)?
    let libraryRoot: URL

    init(mode: Mode, libraryRoot: URL, nasPath: String) {
        self.mode = mode
        self.libraryRoot = libraryRoot
        self.nasPath = nasPath
        switch mode {
        case .install: self.page = .path
        case .stop: self.page = .stopHelp
        case .update, .uninstall: self.page = .confirmStop
        }
    }

    var title: String {
        switch mode {
        case .install: return "Install helper"
        case .update: return "Update helper"
        case .uninstall: return "Uninstall helper"
        case .stop: return "Stop helper"
        }
    }

    var taskCommand: String {
        HelperInstallPaths.taskCommand(nasPath: nasPath)
    }

    var stopCommand: String {
        HelperInstallPaths.stopCommand(nasPath: nasPath)
    }

    func copyPrograms() async {
        guard let cleaned = HelperInstallPaths.cleanNASPath(nasPath) else {
            message = HelperSetupError.badPath.errorDescription
            return
        }
        nasPath = cleaned
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await requireStopped()
            let bundled = try HelperBundle.binaries()
            try HelperPackage.install(
                libraryRoot: libraryRoot,
                arm: bundled.arm,
                intel: bundled.intel,
                version: HelperRelease.version
            )
            afterCopy?(nasPath)
            page = .task
        } catch {
            message = error.localizedDescription
        }
    }

    func removePrograms() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await requireStopped()
            try HelperPackage.removeProgram(at: libraryRoot)
            page = .done
        } catch {
            message = error.localizedDescription
        }
    }

    private func requireStopped() async throws {
        let host: String
        do {
            host = try LibraryPairing.ipv4(forLibraryRoot: libraryRoot)
        } catch {
            throw HelperSetupError.unknownPort
        }
        let listening = await HelperPort.isListening(host: host)
        if listening == true { throw HelperSetupError.stillRunning }
        if listening == nil { throw HelperSetupError.unknownPort }
    }
}

enum HelperBundle {
    static func binaries() throws -> (arm: URL, intel: URL) {
        guard let arm = Bundle.main.url(forResource: HelperPackage.armName, withExtension: nil, subdirectory: "Helper"),
              let intel = Bundle.main.url(forResource: HelperPackage.intelName, withExtension: nil, subdirectory: "Helper") else {
            throw HelperSetupError.missingBundle
        }
        return (arm, intel)
    }
}

extension LibraryPairing {
    static func ipv4(forLibraryRoot root: URL) throws -> String {
        guard let source = mountSource(forPath: root.path),
              let mountHost = mountHost(fromMountSource: source) else {
            throw HelperError.notIPv4
        }
        return try firstIPv4(mountHost: mountHost, resolve: HelperClient.resolveIPv4)
    }
}

struct HelperSetupSheet: View {
    @Bindable var session: HelperSetupSession
    var onPair: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.title)
                .font(.system(size: 18, weight: .semibold))
            content
            if let message = session.message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
                action
            }
        }
        .padding(24)
        .frame(width: session.page == .confirmStop || session.page == .stopHelp ? 640 : 560)
    }

    @ViewBuilder
    private var content: some View {
        switch session.page {
        case .path:
            Text("ZImager copies the helper onto this share. Photos stay where they are. The path below is the folder that contains Photos, written the way DSM sees it. If a helper is already running on this server, click Enabled on zimage-helper-stop, uncheck Enabled on zimage-helper, select zimage-helper-stop, and click Run before copying.")
            TextField("Path on the Synology", text: $session.nasPath)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("Helper NAS path")
        case .confirmStop:
            HelperStopSteps(command: session.stopCommand)
            Text(session.mode == .uninstall
                ? "When that task has stopped the helper, ZImager removes the program from the share. Photos and the catalog stay."
                : "When that task has stopped the helper, ZImager replaces the program. Photos and the catalog stay. A duplicate scan on this server stops with the helper. Fingerprints already saved stay.")
        case .stopHelp:
            HelperStopSteps(command: session.stopCommand)
            Text("To start the helper again, uncheck Enabled on zimage-helper-stop, click Enabled on zimage-helper, select zimage-helper, and click Run.")
        case .task:
            if session.mode == .update {
                Text("The new helper is on the share. In DSM, open Control Panel, then Task Scheduler. Select zimage-helper and click Edit.")
                Text("Click Task Settings. Replace everything in User-defined script with this command.")
            } else {
                Text("In DSM, open Control Panel, then Task Scheduler. Click Create, then Triggered Task, then User-defined script.")
                Text("On General, name the task zimage-helper. Choose a user who can change this shared folder. Do not use root. Set the event to Boot-up, and leave Enabled checked.")
                Text("Click Task Settings. Paste this command into User-defined script.")
            }
            Text(session.taskCommand)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("Helper task command")
            Text("Click OK. If zimage-helper-stop is in the list, uncheck Enabled on it. Click Enabled on zimage-helper. Then select zimage-helper and click Run.")
            Text("When the task is running, pair this Mac with the helper.")
        case .done:
            Text(session.mode == .uninstall
                ? "The helper program is off the share. Delete that boot task in Task Scheduler so the server does not try to start it again. Photos and the catalog are still there."
                : "The helper files are on the share.")
        }
    }

    @ViewBuilder
    private var action: some View {
        switch session.page {
        case .path:
            Button(session.busy ? "Copying…" : "Copy helper to the share") {
                Task { await session.copyPrograms() }
            }
            .disabled(session.busy)
            .accessibilityIdentifier("Copy helper")
        case .confirmStop:
            Button(session.busy ? "Checking…" : "The task is stopped") {
                Task {
                    if session.mode == .uninstall {
                        await session.removePrograms()
                    } else {
                        await session.copyPrograms()
                    }
                }
            }
            .disabled(session.busy)
            .accessibilityIdentifier("Helper task stopped")
        case .stopHelp:
            EmptyView()
        case .task:
            Button("Pair with Helper") { onPair() }
                .accessibilityIdentifier("Pair after install")
        case .done:
            EmptyView()
        }
    }
}

private struct HelperStopSteps: View {
    var command: String

    var body: some View {
        Text("The task zimage-helper starts the helper. The running program is named zimage-helper-aarch64, or zimage-helper-x86_64 on an Intel NAS. DSM does not stop it until you add a second task named zimage-helper-stop.")
        Text("In DSM, open Control Panel, then Task Scheduler. If zimage-helper-stop is already in the list, select it and click Edit. Click Task Settings. Replace the User-defined script with the command below, then click OK. Click Enabled on zimage-helper-stop, and uncheck Enabled on zimage-helper. Select zimage-helper-stop and click Run. That stops zimage-helper.")
        Text("If it is not listed, click Create, then Scheduled task, then User-defined script. On General, name the task zimage-helper-stop. Choose the same user as zimage-helper. Do not use root. Leave Enabled unchecked on this screen so the task does not run on a schedule.")
        Text("Click Task Settings. Paste this command into User-defined script.")
        Text(command)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityIdentifier("Helper stop command")
        Text("Click OK. Click Enabled on zimage-helper-stop, and uncheck Enabled on zimage-helper. Then select zimage-helper-stop and click Run. That stops zimage-helper. Photos and the catalog stay.")
    }
}
