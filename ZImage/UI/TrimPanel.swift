import SwiftUI

/// Trim lamp text. The helper trim bit is the only source. A missing status stays waiting.
enum TrimCopy {
    static let waiting = "Waiting for the helper."
    static let safe = "Safe to reboot"
    static let unsafe = "Not safe to reboot"

    static func lamp(_ status: TrimStatus?) -> String {
        guard let status else { return waiting }
        if status.safeToReboot { return safe }
        return unsafe
    }
}

/// Start, Pause, and Continue. Opening the panel does not plan or copy.
struct TrimPanel: View {
    @Bindable var browser: LibraryBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trim")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChromePalette.ink)
            Text(TrimCopy.lamp(browser.trim))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(lampColor)
                .accessibilityIdentifier("Trim lamp")
            HStack {
                Button("Start") {
                    Task { await browser.startTrim() }
                }
                .accessibilityIdentifier("Trim start")
                Button("Pause") {
                    Task { await browser.pauseTrim() }
                }
                .accessibilityIdentifier("Trim pause")
                Button("Continue") {
                    Task { await browser.continueTrim() }
                }
                .accessibilityIdentifier("Trim continue")
            }
            if let trim = browser.trim {
                Text("Eligible \(trim.eligible)")
                Text("Moved \(trim.moved)")
                Text("Waiting \(trim.waiting)")
                Text(trim.runState)
                    .foregroundStyle(ChromePalette.muted)
            }
            if let trimNotice = browser.trimNotice, !trimNotice.isEmpty {
                Text(trimNotice)
                    .font(.system(size: 12))
                    .foregroundStyle(ChromePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(ChromePalette.ink)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Trim panel")
        .task {
            await browser.loadTrim()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await browser.loadTrim()
            }
        }
    }

    private var lampColor: Color {
        guard let trim = browser.trim else { return ChromePalette.muted }
        if trim.safeToReboot {
            return Color(red: 0.12, green: 0.45, blue: 0.22)
        }
        return Color(red: 0.72, green: 0.42, blue: 0.08)
    }
}
