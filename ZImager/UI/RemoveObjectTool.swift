import SwiftUI

/// One click selects the object under the pointer. The toolbar button has no shortcut.
struct RemoveObjectTool: View {
    @Bindable var model: EditorModel

    var body: some View {
        Button("Remove object") { model.selectCanvasTool(.removeObject) }
            .help("One click removes the object under the pointer.")
    }
}
