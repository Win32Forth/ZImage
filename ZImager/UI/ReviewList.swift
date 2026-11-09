import SwiftUI

/// The park. Dates below 0.70 and files already under `Photos/_Review` live here.
struct ReviewList: View {
    @Bindable var browser: LibraryBrowser
    @Bindable var model: EditorModel
    /// Server mode. Disk leaves the review load idle.
    var live = true
    /// The list is on screen. Hiding it keeps the scroll offset.
    var onScreen = true

    var body: some View {
        HStack(spacing: 0) {
            List(browser.reviewRows, id: \.uid, selection: selection) { asset in
                VStack(alignment: .leading, spacing: 2) {
                    Text(browser.filename(for: asset))
                        .font(.system(size: 13))
                    if let confidence = asset.captureConfidence {
                        Text(String(format: "Confidence %.2f", confidence))
                            .font(.system(size: 11))
                            .foregroundStyle(ChromePalette.muted)
                    }
                }
                .pastelListRow(selected: browser.selectedUID == asset.uid)
                .tag(asset.uid)
                .contextMenu {
                    Button("Copy settings") {
                        if let url = browser.fileURL(for: asset) {
                            model.copySettings(from: url)
                        }
                    }
                    .disabled(!browser.isSettingsStill(asset))
                    Button("Paste settings") {
                        model.pasteLibraryStills(browser.settingsPasteTargets(clicked: asset)) { browser.fileURL(for: $0) }
                    }
                    .disabled(!model.hasCopiedSettings || model.folderRotateBusy || browser.settingsPasteTargets(clicked: asset).isEmpty)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .pastelListChrome()
            .modifier(KeptScroll(visible: onScreen, key: "review"))
            .accessibilityIdentifier("Review list")
        }
        .background(ChromePalette.panel)
        .task(id: live) {
            guard live else { return }
            await browser.loadReview()
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { browser.selectedUID },
            set: { browser.focusSelection($0) }
        )
    }
}
