import SwiftUI

/// Shown by ZImage Library when the helper was up and then stopped answering.
/// The editor window does not mount this view.
struct OfflineBanner: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
            Text(LibraryCopy.recoveryHint)
                .font(.system(size: 12))
                .foregroundStyle(ChromePalette.muted)
        }
        .font(.system(size: 13))
        .foregroundStyle(ChromePalette.ink)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Helper offline")
    }
}

/// Empty library pane. There is no saved grid to show.
struct LibraryEmptyState: View {
    var body: some View {
        OfflineBanner(text: LibraryCopy.emptyTitle)
            .accessibilityIdentifier("Library offline")
    }
}
