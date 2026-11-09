import Foundation

/// Facial skin chromaticity targets. The file stores `id`. The label is temporary UI copy.
/// `mst` is the old card index and is not the color. a* and b* are measured face means,
/// so a click does not pull a photograph toward the pale blue-gray cards.
nonisolated struct SkinPreset: Equatable, Sendable, Identifiable {
    var id: String
    var label: String
    var mst: Int
    var lab: LabColor
    var sRGBHex: String
}

nonisolated enum SkinPresets {
    /// Lu et al., Skin Research and Technology, 2026, Table 2. Asian is the mean of the
    /// Chinese and Japanese rows. Middle Eastern is the mean of the Iraqi and Arabian rows.
    /// Hispanic is not in that table; it uses the same redness and yellowness band as the
    /// other medium faces. The hex is the sRGB of that Lab color.
    static let all: [SkinPreset] = [
        SkinPreset(id: "light", label: "Caucasian", mst: 2, lab: LabColor(L: 61.2, a: 11.0, b: 14.7), sRGBHex: "#b08c7a"),
        SkinPreset(id: "lightGolden", label: "Asian", mst: 3, lab: LabColor(L: 61.7, a: 10.0, b: 16.9), sRGBHex: "#b18e78"),
        SkinPreset(id: "mediumGolden", label: "Southeast Asian", mst: 4, lab: LabColor(L: 56.4, a: 10.0, b: 19.0), sRGBHex: "#a48067"),
        SkinPreset(id: "mediumOlive", label: "Middle Eastern", mst: 5, lab: LabColor(L: 58.8, a: 10.6, b: 16.9), sRGBHex: "#aa8670"),
        SkinPreset(id: "mediumWarm", label: "Hispanic", mst: 6, lab: LabColor(L: 58.0, a: 12.0, b: 17.5), sRGBHex: "#aa836d"),
        SkinPreset(id: "mediumDeep", label: "South Asian", mst: 7, lab: LabColor(L: 52.7, a: 10.4, b: 17.9), sRGBHex: "#9a7760"),
        SkinPreset(id: "deep", label: "African", mst: 9, lab: LabColor(L: 39.6, a: 10.2, b: 14.4), sRGBHex: "#755746"),
    ]

    static func preset(id: String) -> SkinPreset? {
        all.first { $0.id == id }
    }
}

/// Every eyedropper string the window shows. History titles are built from these.
nonisolated enum EyedropperCopy {
    static let panel = "Color"
    static let tool = "Eyedropper"
    static let toolHelp = "Samples the image. White maps that sample toward neutral. Skin shifts a* and b* toward the preset. Click again to leave."
    static let white = "White"
    static let skin = "Skin"
    static let presetMenu = "Skin preset"
    static let hint = "Click the image to sample."
    static let varied = "varied sample"
    static let whiteHistory = "White"

    static var userFacing: [String] {
        [panel, tool, toolHelp, white, skin, presetMenu, hint, varied, whiteHistory] + SkinPresets.all.map(\.label)
    }
}
