import SwiftUI

struct ContentView: View {
    @Bindable var model: EditorModel

    var body: some View {
        Chrome(model: model)
    }
}

#Preview {
    ContentView(model: EditorModel())
        .frame(width: 1100, height: 700)
}
