import SwiftUI

struct ContentView: View {
    @Bindable var model: EditorModel
    @Bindable var browser: LibraryBrowser

    var body: some View {
        Chrome(model: model, browser: browser)
    }
}

#Preview {
    ContentView(
        model: EditorModel(),
        browser: LibraryBrowser(
            client: LibraryAppClient.offline(),
            libraryRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            openFile: { _, _ in }
        )
    )
    .frame(width: 1100, height: 700)
}
