import SwiftUI

/// Renames one event. The helper marks `name_source` user and does not move the photos.
struct EventRename: View {
    @Bindable var browser: LibraryBrowser
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Events")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChromePalette.ink)
            if browser.events.isEmpty {
                Text("No events are stored. An event is created from photos that already have a capture date.")
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List(browser.events, id: \.uid, selection: selection) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.name)
                        .font(.system(size: 13))
                    Text(event.nameSource)
                        .font(.system(size: 11))
                        .foregroundStyle(ChromePalette.muted)
                }
                .pastelListRow(selected: browser.selectedEventUID == event.uid)
                .tag(event.uid)
            }
            .pastelListChrome()
            .accessibilityIdentifier("Event list")
            TextField("Event name", text: $name)
                .textFieldStyle(.roundedBorder)
            Button("Rename") {
                guard let uid = browser.selectedEventUID else { return }
                let typed = name
                Task { await browser.renameEvent(uid: uid, name: typed) }
            }
            .disabled(browser.selectedEventUID == nil)
            if let source = selectedSource {
                Text(source)
                    .font(.system(size: 13))
                    .foregroundStyle(ChromePalette.ink)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
        .accessibilityIdentifier("Event rename")
        .task {
            await browser.loadEvents()
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { browser.selectedEventUID },
            set: { browser.selectedEventUID = $0 }
        )
    }

    private var selectedSource: String? {
        guard let uid = browser.selectedEventUID,
              let event = browser.events.first(where: { $0.uid == uid }) else {
            return nil
        }
        return event.nameSource
    }
}
