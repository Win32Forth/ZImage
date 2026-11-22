import SwiftUI

/// Builds a preview for each photo in the folder on screen that does not already have one.
struct BuildPreviewsPanel: View {
    var note: String?
    var busy: Bool
    var enabled: Bool
    var build: () -> Void
    @AppStorage(FolderPanelStore.build) private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorPanelHeader(title: "Build previews", collapsed: collapsed) { collapsed.toggle() }
            if !collapsed {
                Text(FolderPreviewBuild.intro)
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(ChromePalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("Build previews status")
                }
                Button("Build") {
                    build()
                }
                .disabled(!enabled || busy)
                .accessibilityIdentifier("Build previews")
                .help("Builds a preview for each photo in this folder that does not have one.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Build previews panel")
    }
}
