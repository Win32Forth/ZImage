import SwiftUI

/// The park. Dates below 0.70 and files already under `Photos/_Review` live here.
struct ReviewList: View {
    @Bindable var browser: LibraryBrowser

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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .pastelListChrome()
            .accessibilityIdentifier("Review list")
        }
        .background(ChromePalette.panel)
        .task {
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
