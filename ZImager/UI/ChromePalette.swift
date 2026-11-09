import SwiftUI

enum ChromePalette {
    static let panel = Color(red: 247 / 255, green: 243 / 255, blue: 236 / 255)
    static let ink = Color(red: 31 / 255, green: 26 / 255, blue: 20 / 255)
    static let muted = Color(red: 92 / 255, green: 83 / 255, blue: 72 / 255)
    static let accentSoft = Color(red: 184 / 255, green: 90 / 255, blue: 18 / 255).opacity(0.12)
    /// Dark neutral gray around the photograph. Equal channels, so it adds no color cast.
    static let canvas = Color(red: 0x5C / 255, green: 0x5C / 255, blue: 0x5C / 255)
    static let hairline = Color(red: 224 / 255, green: 216 / 255, blue: 204 / 255)
    /// Light pastel blue. Dark ink stays readable on the row and on the selection.
    static let listWash = Color(red: 214 / 255, green: 232 / 255, blue: 245 / 255)
    static let listSelected = Color(red: 176 / 255, green: 210 / 255, blue: 234 / 255)
    /// Active tool border. Same brown as the Select button.
    static let toolActive = Color(red: 140 / 255, green: 90 / 255, blue: 60 / 255)
}

extension View {
    /// Brown while the tool is on. A thin black line while it is off.
    func toolToggleBorder(active: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(active ? ChromePalette.toolActive : Color.black, lineWidth: active ? 2 : 1)
                .allowsHitTesting(false)
        )
    }
}

extension View {
    /// Replaces the system list blue with the pastel wash.
    func pastelListChrome() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ChromePalette.listWash)
            .environment(\.colorScheme, .light)
            .tint(ChromePalette.listSelected)
    }

    /// Paints the row itself so the selection highlight cannot cover the ink.
    func pastelListRow(selected: Bool) -> some View {
        self
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? ChromePalette.listSelected : ChromePalette.listWash)
            .foregroundStyle(ChromePalette.ink)
            .listRowBackground(ChromePalette.listWash)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparatorTint(ChromePalette.listSelected)
    }
}

/// Short push button. A toolbar capsule grows tall and rounds the ends.
/// A disabled button is greyed so it does not look pressable.
struct LibraryPushButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LibraryPushButtonLabel(configuration: configuration)
    }
}

private struct LibraryPushButtonLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(isEnabled ? ChromePalette.ink : ChromePalette.muted)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isPressed && isEnabled ? ChromePalette.hairline : Color.white.opacity(isEnabled ? 0.72 : 0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(ChromePalette.muted.opacity(isEnabled ? 0.45 : 0.25), lineWidth: 1)
            )
            .fixedSize()
            .opacity(isEnabled ? 1 : 0.55)
    }
}

func libraryPushButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
        .buttonStyle(LibraryPushButtonStyle())
        .accessibilityIdentifier(identifier)
}
