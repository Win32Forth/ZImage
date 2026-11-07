import SwiftUI

/// Reorg lamp text. The helper bit is the only source. A missing status stays waiting.
enum ReorgCopy {
    static let waiting = "Waiting for the helper."
    static let safe = "Safe to reboot"
    static let unsafe = "Not safe to reboot"

    static func lamp(_ status: ReorgStatus?) -> String {
        guard let status else { return waiting }
        if status.reorgSafeToReboot { return safe }
        return unsafe
    }

    /// The helper's ledger total. The Mac does not add a second sum.
    static func cacheLine(_ bytes: Int64) -> String {
        "Cache \(bytes) bytes"
    }

    static let outsidePhotos = "The plan prefix must be Photos or a folder inside it."
    static let planTimedOut = "The plan request waited 10 seconds. The status line says whether the count is running. Nothing has been copied."
    static let planReturnedIdle = "The helper stopped planning and returned to idle. The plan was not saved. Press Plan to try again."
    static let startTimedOut = "The Mac stopped waiting after 10 seconds. Start may still be reaching the helper. This panel checks every 2 seconds."
    static let startWhilePlanning = "Start was not sent. The helper is counting files. Wait until the status line says the plan is ready."
    static let startWhilePlanOpen = "Start was not sent. The plan request is still open. Wait until the status line says the plan is ready."
    static let statusCheckFailed = "The status check failed. The lines above are the last answer. The next check is in 2 seconds."
    static let statusCheckTimedOut = "The status check waited 10 seconds and got no answer. The lines above are the last answer. The next check is in 2 seconds."
    static let statusCheckSilent = "The helper did not answer the status check. The lines above are the last answer. The next check is in 2 seconds."

    static func statusFault(_ error: Error) -> String {
        if let url = error as? URLError, url.code == .timedOut {
            return statusCheckTimedOut
        }
        if let helper = error as? HelperError {
            switch helper {
            case .unauthorized:
                return "The helper refused the token, so the status check failed. Pair again."
            case .notIPv4:
                return "The helper address is not IPv4, so the status check failed."
            case .hostChanged:
                return "The helper address changed, so the status check failed. Pair again."
            case .pinChanged:
                return "The helper certificate changed, so the status check failed. Pair again."
            case .keychain:
                return "The helper token could not be read, so the status check failed."
            case .offline:
                return statusCheckSilent
            }
        }
        return statusCheckFailed
    }
    static let countsGloss = "Move is copied. Already placed is already in the planned folder. Park goes to Review. Leave stays where it is."

    static func planFailure(_ code: String?) -> String {
        switch code {
        case "prefix":
            return outsidePhotos
        case "busy":
            return "The plan was refused because reorganize is already running."
        case "catalog":
            return "The plan was not saved because the catalog could not be updated."
        case "library_unavailable":
            return "The plan was not saved because the helper has no catalog open."
        case "method":
            return "The plan was refused because the helper did not accept the request."
        case "trim":
            return "The plan was refused because Trim is still running."
        case nil, "":
            return "The plan was refused and the helper did not say why. Nothing was copied."
        default:
            return "The plan was refused (\(code ?? "")). Nothing was copied."
        }
    }

    static func actionFailure(_ code: String, fallback: String) -> String {
        switch code {
        case "trim":
            return "Refused because Trim is still running. Reorganize waits until Trim is idle."
        case "plan":
            return "Refused because no Photos folder is saved. Press Plan first."
        case "busy":
            return "Refused because reorganize is already running."
        case "catalog":
            return "Refused because the catalog could not be updated."
        case "library_unavailable":
            return "Refused because the helper has no catalog open."
        case "prefix":
            return outsidePhotos
        case "method":
            return "Refused because the helper did not accept the request."
        default:
            return "\(fallback) The helper said \(code)."
        }
    }

    static func startNeedsPlan(typed: String, saved: String?) -> String {
        if let saved {
            return "Start was not sent. The field is \(typed) and the saved plan is \(saved). Press Plan for \(typed)."
        }
        return "Start was not sent. \(typed) has no plan yet. Press Plan. Start only copies a folder after Plan saves it."
    }

    static func unreachable(_ error: HelperError, action: String) -> String {
        switch error {
        case .offline:
            return "The helper did not answer, so \(action) was not confirmed. Nothing new was copied. The panel checks every 2 seconds."
        case .unauthorized:
            return "The helper refused the token, so \(action) did not run. Pair again."
        case .notIPv4:
            return "The helper address is not IPv4, so \(action) did not run."
        case .hostChanged:
            return "The helper address changed, so \(action) did not run. Pair again."
        case .pinChanged:
            return "The helper certificate changed, so \(action) did not run. Pair again."
        case .keychain:
            return "The helper token could not be read, so \(action) did not run."
        }
    }

    static func recoveryLine(_ code: String) -> String? {
        switch code {
        case "", "none":
            return nil
        case "planned_kept":
            return "Last recovery: a file had not started copying, so it was left in place."
        case "scratch_reset":
            return "Last recovery: an unfinished temporary copy was discarded."
        case "catalog_updated":
            return "Last recovery: the catalog was updated after the new file was in place."
        case "source_detached":
            return "Last recovery: the original was set aside after the new file checked out."
        case "backup_unlinked":
            return "Last recovery: the temporary original was removed after the new file checked out."
        case "source_restored":
            return "Last recovery: the original was put back."
        case "failed":
            return "Last recovery: the open file was marked failed."
        default:
            return "Last recovery: \(code)."
        }
    }
}

/// A local button press that the helper has not confirmed yet.
enum ReorgPending: Equatable, Sendable {
    case planning(String)
    case starting
    case pausing
    case resuming
}

struct ReorgReadout: Equatable {
    var activity: String
    var next: String
    var showsCounts: Bool
    var countsNote: String
}

/// What the panel is doing, and what the next press should be.
enum ReorgActivity {
    static func folder(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Photos" }
        var text = trimmed
        while text.hasPrefix("/") { text.removeFirst() }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.isEmpty || parts.contains("..") || parts.contains(".") { return trimmed }
        return parts.joined(separator: "/")
    }

    static func savedFolder(_ phase: String) -> String? {
        if phase != "Photos" && !phase.hasPrefix("Photos/") { return nil }
        if phase == "Photos/_Duplicates" || phase.hasPrefix("Photos/_Duplicates/") { return nil }
        return phase
    }

    /// The counting line. A helper file count replaces the local 2-second clock.
    static func countingLine(status: ReorgStatus?, tick: Int) -> String {
        if status?.counting == true, let seen = status?.seen, seen > 0 {
            return "Counting \(seen)"
        }
        if tick > 0 {
            return "Counting \(tick)s"
        }
        return "Counting"
    }

    static func savedPlanLine(_ phase: String?) -> String {
        guard let phase, let saved = savedFolder(phase) else { return "Saved plan: none" }
        return "Saved plan: \(saved)"
    }

    static func readout(status: ReorgStatus?, typedPrefix: String, pending: ReorgPending?) -> ReorgReadout {
        let typed = folder(typedPrefix)
        let saved = status.flatMap { savedFolder($0.phase) }
        let matches = saved == typed
        if let pending {
            switch pending {
            case .planning:
                return ReorgReadout(
                    activity: "Counting",
                    next: "",
                    showsCounts: status?.counting == true,
                    countsNote: ""
                )
            case .starting:
                if let status, Self.copyHasStarted(status.runState) {
                    break
                }
                let keep = matches && (status.map(Self.showsCounts) ?? false)
                return ReorgReadout(
                    activity: "Starting",
                    next: "This line changes when a copy is running. Do not press Start again.",
                    showsCounts: keep,
                    countsNote: keep ? "" : "Counts stay hidden until the helper confirms the copy."
                )
            case .pausing:
                if let status, status.pauseRequested || status.runState == "paused" || status.runState == "pause_requested" {
                    break
                }
                return ReorgReadout(
                    activity: "Pausing",
                    next: "The file already started still finishes.",
                    showsCounts: matches && status != nil,
                    countsNote: matches ? "" : "Counts cleared. They were for another folder."
                )
            case .resuming:
                if let status, status.runState == "running" || status.runState == "completed" || status.runState == "blocked" {
                    break
                }
                return ReorgReadout(
                    activity: "Resuming",
                    next: "This line changes when copying is running again.",
                    showsCounts: matches && status != nil,
                    countsNote: matches ? "" : "Counts cleared. They were for another folder."
                )
            }
        }
        guard let status else {
            return ReorgReadout(
                activity: "Nothing is in process. The helper has not answered.",
                next: "The panel checks the helper every 2 seconds.",
                showsCounts: false,
                countsNote: "No file counts yet."
            )
        }
        let activity = process(status, saved: saved)
        if !matches {
            let next: String
            let note: String
            if status.runState == "planning", let saved {
                next = "The helper is counting files. The saved plan stays \(saved) until that count finishes."
                note = "Counts stay hidden until this plan finishes."
            } else if let saved {
                if status.runState == "running" || status.runState == "pause_requested" || status.runState == "recovering" {
                    next = "The folder in the field is \(typed). This copy still uses \(saved). Press Plan after it finishes to count \(typed)."
                } else {
                    next = "The folder changed to \(typed). Press Plan to count that folder."
                }
                note = "Counts cleared. They were for \(saved), not \(typed)."
            } else {
                next = "Press Plan to count \(typed)."
                note = "No file counts yet. Plan creates them."
            }
            return ReorgReadout(activity: activity, next: next, showsCounts: false, countsNote: note)
        }
        return ReorgReadout(
            activity: activity,
            next: nextStep(status, saved: saved ?? typed),
            showsCounts: showsCounts(status),
            countsNote: showsCounts(status) ? "" : "No file counts yet. Plan creates them."
        )
    }

    private static func copyHasStarted(_ runState: String) -> Bool {
        switch runState {
        case "running", "pause_requested", "paused", "recovering", "blocked", "completed":
            return true
        default:
            return false
        }
    }

    private static func showsCounts(_ status: ReorgStatus) -> Bool {
        if status.runState == "planning" {
            return status.counting == true
        }
        switch status.runState {
        case "plan_ready", "running", "pause_requested", "paused", "recovering", "blocked", "completed":
            return true
        default:
            return false
        }
    }

    private static func process(_ status: ReorgStatus, saved: String?) -> String {
        if status.runState == "planning" {
            return "Counting"
        }
        if status.runState == "pause_requested" || (status.pauseRequested && status.runState == "running") {
            return "Pausing"
        }
        switch status.runState {
        case "running":
            return "Copying"
        case "paused":
            return "Paused"
        case "recovering":
            return "Recovering"
        case "blocked":
            return "Blocked"
        case "completed":
            return "Finished"
        case "plan_ready":
            if status.pauseRequested {
                return "Paused"
            }
            return "Plan ready"
        case "idle":
            if saved != nil {
                return "Plan ready"
            }
            return "Idle"
        default:
            return status.runState
        }
    }

    private static func nextStep(_ status: ReorgStatus, saved: String) -> String {
        if status.runState == "planning" {
            return "Wait for the count. A plan does not move files."
        }
        if status.runState == "pause_requested" || (status.pauseRequested && status.runState == "running") {
            return "Wait for Paused. Resume continues \(saved)."
        }
        switch status.runState {
        case "running":
            return "The Move count is files still waiting to copy. It updates every 2 seconds. Pause finishes the file already started."
        case "paused":
            return "Press Resume to continue \(saved)."
        case "recovering":
            return "Wait until this line changes. The lamp stays Not safe to reboot until the open file is finished."
        case "blocked":
            return "Free about 1 GB plus the size of the next file on the share, then press Start."
        case "completed":
            return "Choose another folder and press Plan, or leave \(saved) as it is."
        case "plan_ready":
            if status.pauseRequested {
                return "Press Resume to clear the pause. Press Start to copy \(saved)."
            }
            if status.move == 0 && status.alreadyPlaced == 0 && status.park == 0 && status.leave == 0 {
                return "The catalog has no files under \(saved), so every count is zero. Nothing will be copied."
            }
            return "Read Move, Already placed, Park, and Leave. Press Start to copy."
        case "idle":
            return "Press Plan to count \(saved)."
        default:
            return "Wait for the next status check."
        }
    }
}

/// A picked folder becomes the plan prefix. The share root and the duplicates store are refused.
enum ReorgFolder {
    static func prefix(selected: URL, libraryRoot: URL) -> String? {
        let rootPath = libraryRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let pickedPath = selected.standardizedFileURL.resolvingSymlinksInPath().path
        let relative: String
        if pickedPath == rootPath {
            return nil
        }
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard pickedPath.hasPrefix(rootPrefix) else { return nil }
        relative = String(pickedPath.dropFirst(rootPrefix.count))
        let parts = relative.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.first == "Photos" else { return nil }
        let joined = parts.joined(separator: "/")
        if joined == "Photos/_Duplicates" || joined.hasPrefix("Photos/_Duplicates/") {
            return nil
        }
        return joined
    }
}

/// Dry-run, one Start, and the reorg lamp. Opening the panel does not plan or copy.
struct ReorgPanel: View {
    @Bindable var browser: LibraryBrowser

    private var activityText: String {
        if readout.activity == "Counting" {
            return ReorgActivity.countingLine(status: browser.reorg, tick: browser.reorgTick)
        }
        return readout.activity
    }

    private var readout: ReorgReadout {
        ReorgActivity.readout(
            status: browser.reorg,
            typedPrefix: browser.reorgPrefix,
            pending: browser.reorgPending
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reorganize")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChromePalette.ink)
            Text(ReorgCopy.lamp(browser.reorg))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(lampColor)
                .accessibilityIdentifier("Reorg lamp")
            Text(activityText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChromePalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("Reorg activity")
            TextField("Prefix", text: $browser.reorgPrefix)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("Reorg prefix")
                .onChange(of: browser.reorgPrefix) { old, new in
                    browser.reorgPrefixChanged(from: old, to: new)
                }
            Button("Choose Folder") {
                browser.chooseReorgFolder()
            }
            .accessibilityIdentifier("Reorg choose folder")
            HStack {
                Button("Plan") {
                    Task { await browser.planReorg() }
                }
                .accessibilityIdentifier("Reorg plan")
                Button("Start") {
                    Task { await browser.startReorg() }
                }
                .accessibilityIdentifier("Reorg start")
            }
            HStack {
                Button("Pause") {
                    Task { await browser.pauseReorg() }
                }
                Button("Resume") {
                    Task { await browser.resumeReorg() }
                }
            }
            if readout.showsCounts, let reorg = browser.reorg {
                Text("Move \(reorg.move)")
                Text("Already placed \(reorg.alreadyPlaced)")
                Text("Park \(reorg.park)")
                Text("Leave \(reorg.leave)")
                    .accessibilityIdentifier("Reorg counts")
            }
            if let reorgNotice = browser.reorgNotice, !reorgNotice.isEmpty {
                Text(reorgNotice)
                    .font(.system(size: 12))
                    .foregroundStyle(ChromePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Reorg notice")
            }
            if let fault = browser.reorgStatusFault, !fault.isEmpty {
                Text(fault)
                    .font(.system(size: 12))
                    .foregroundStyle(ChromePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Reorg status fault")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(ChromePalette.ink)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Reorganize panel")
        .task {
            await browser.loadReorg()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await browser.loadReorg()
            }
        }
    }

    private var lampColor: Color {
        guard let reorg = browser.reorg else { return ChromePalette.muted }
        if reorg.reorgSafeToReboot {
            return Color(red: 0.12, green: 0.45, blue: 0.22)
        }
        return Color(red: 0.72, green: 0.42, blue: 0.08)
    }
}
