import CoreGraphics
import CoreImage
import Foundation

// Value types for the edit log. Later PRs fill in behavior. They do not
// introduce these types again. Isolated from the main actor so the log can
// be replayed and tested without a window.

nonisolated struct LabColor: Codable, Equatable, Sendable {
    var L: Double
    var a: Double
    var b: Double
}

nonisolated struct SkinGrade: Codable, Equatable, Sendable {
    var presetID: String
    var sample: LabColor
    var target: LabColor
    var deltaA: Double
    var deltaB: Double
}

/// Slider positions. Zero is the identity photograph, except temperature,
/// whose identity is 6500 K. `TonePipeline` maps these onto Core Image.
nonisolated struct ToneState: Codable, Equatable, Sendable {
    var exposureEV: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var temperature: Double = 6500
    var tint: Double = 0
    var skinGrade: SkinGrade? = nil

    static let identity = ToneState()
}

nonisolated struct NormPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

nonisolated struct CornerPin: Codable, Equatable, Sendable {
    var topLeft: NormPoint
    var topRight: NormPoint
    var bottomRight: NormPoint
    var bottomLeft: NormPoint
}

nonisolated struct LensSetting: Codable, Equatable, Sendable {
    var profileID: String
    var k1: Double
    var k2: Double
    var cylindricalFOV: Double?

    static let identity = LensSetting(profileID: "none", k1: 0, k2: 0, cylindricalFOV: nil)
}

nonisolated struct GeometryState: Codable, Equatable, Sendable {
    var quarterTurns: Int = 0
    var straightenDegrees: Double = 0
    var verticalKeystone: Double = 0
    var horizontalKeystone: Double = 0
    var corners: CornerPin? = nil
    var lens: LensSetting = .identity
    /// −1...1. Zero omits the filter. Positive is a fine unsharp mask.
    var sharpness: Double = 0

    static let identity = GeometryState()

    init(
        quarterTurns: Int = 0,
        straightenDegrees: Double = 0,
        verticalKeystone: Double = 0,
        horizontalKeystone: Double = 0,
        corners: CornerPin? = nil,
        lens: LensSetting = .identity,
        sharpness: Double = 0
    ) {
        self.quarterTurns = quarterTurns
        self.straightenDegrees = straightenDegrees
        self.verticalKeystone = verticalKeystone
        self.horizontalKeystone = horizontalKeystone
        self.corners = corners
        self.lens = lens
        self.sharpness = sharpness
    }

    private enum CodingKeys: String, CodingKey {
        case quarterTurns
        case straightenDegrees
        case verticalKeystone
        case horizontalKeystone
        case corners
        case lens
        case sharpness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quarterTurns = try container.decode(Int.self, forKey: .quarterTurns)
        straightenDegrees = try container.decode(Double.self, forKey: .straightenDegrees)
        verticalKeystone = try container.decode(Double.self, forKey: .verticalKeystone)
        horizontalKeystone = try container.decode(Double.self, forKey: .horizontalKeystone)
        corners = try container.decodeIfPresent(CornerPin.self, forKey: .corners)
        lens = try container.decode(LensSetting.self, forKey: .lens)
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quarterTurns, forKey: .quarterTurns)
        try container.encode(straightenDegrees, forKey: .straightenDegrees)
        try container.encode(verticalKeystone, forKey: .verticalKeystone)
        try container.encode(horizontalKeystone, forKey: .horizontalKeystone)
        try container.encodeIfPresent(corners, forKey: .corners)
        try container.encode(lens, forKey: .lens)
        try container.encode(sharpness, forKey: .sharpness)
    }
}

nonisolated struct InpaintOp: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var maskPNG: Data
    var modelID: String
    var featherPx: Int
    /// 1 keeps the whole repair. 0 leaves the photo untouched. Older files omit this and mean 1.
    var strength: Double

    init(id: UUID, maskPNG: Data, modelID: String, featherPx: Int, strength: Double = 1) {
        self.id = id
        self.maskPNG = maskPNG
        self.modelID = modelID
        self.featherPx = featherPx
        self.strength = min(1, max(0, strength))
    }

    static func empty(id: UUID = UUID()) -> InpaintOp {
        InpaintOp(id: id, maskPNG: Data(), modelID: "lama-big-coreml-v1", featherPx: 8)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case maskPNG
        case modelID
        case featherPx
        case strength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedStrength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            maskPNG: try container.decode(Data.self, forKey: .maskPNG),
            modelID: try container.decode(String.self, forKey: .modelID),
            featherPx: try container.decode(Int.self, forKey: .featherPx),
            strength: decodedStrength
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(maskPNG, forKey: .maskPNG)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(featherPx, forKey: .featherPx)
        try container.encode(strength, forKey: .strength)
    }
}

nonisolated struct EditState: Codable, Equatable, Sendable {
    var tone: ToneState = .identity
    var geometry: GeometryState = .identity
    var inpaints: [InpaintOp] = []
    /// Rectangle of the geometry output that remains. Nil leaves that output whole.
    var crop: NormRect? = nil

    static let identity = EditState()

    static func replay(_ commands: [EditCommand]) -> EditState {
        var state = EditState.identity
        for command in commands {
            command.apply(to: &state)
        }
        return state
    }

    private enum CodingKeys: String, CodingKey {
        case tone
        case geometry
        case inpaints
        case crop
    }

    init(tone: ToneState = .identity, geometry: GeometryState = .identity, inpaints: [InpaintOp] = [], crop: NormRect? = nil) {
        self.tone = tone
        self.geometry = geometry
        self.inpaints = inpaints
        self.crop = crop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tone = try container.decode(ToneState.self, forKey: .tone)
        geometry = try container.decode(GeometryState.self, forKey: .geometry)
        inpaints = try container.decode([InpaintOp].self, forKey: .inpaints)
        crop = try container.decodeIfPresent(NormRect.self, forKey: .crop)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tone, forKey: .tone)
        try container.encode(geometry, forKey: .geometry)
        try container.encode(inpaints, forKey: .inpaints)
        try container.encodeIfPresent(crop, forKey: .crop)
    }
}

nonisolated enum EditCommand: Codable, Equatable, Sendable {
    case keyframe(EditState)
    case setTone(ToneState, label: String)
    case setGeometry(GeometryState, label: String)
    case addInpaint(InpaintOp)
    case setInpaintStrength(id: UUID, strength: Double, label: String)
    case removeInpaint(UUID)
    case setCrop(NormRect)
    case pasteSettings(tone: ToneState, geometry: GeometryState)

    var historyTitle: String {
        switch self {
        case .keyframe:
            return "Earlier edits"
        case .setTone(_, let label):
            return label
        case .setGeometry(_, let label):
            return label
        case .addInpaint(let op):
            if op.modelID == InpaintModel.dust {
                return "Dust"
            }
            if op.modelID == InpaintModel.scratch {
                return "Scratches"
            }
            if op.modelID == InpaintModel.colorSelection {
                return "Remove object, color selection"
            }
            return "Remove object"
        case .setInpaintStrength(_, _, let label):
            return label
        case .removeInpaint:
            return "Restore object"
        case .setCrop:
            return "Crop"
        case .pasteSettings:
            return "Paste settings"
        }
    }

    var isKeyframe: Bool {
        if case .keyframe = self { return true }
        return false
    }

    func apply(to state: inout EditState) {
        switch self {
        case .keyframe(let snapshot):
            state = snapshot
        case .setTone(let tone, _):
            state.tone = tone
        case .setGeometry(let geometry, _):
            state.geometry = geometry
        case .addInpaint(let op):
            state.inpaints.append(op)
        case .setInpaintStrength(let id, let strength, _):
            if let index = state.inpaints.firstIndex(where: { $0.id == id }) {
                state.inpaints[index].strength = min(1, max(0, strength))
            }
        case .removeInpaint(let id):
            state.inpaints.removeAll { $0.id == id }
        case .setCrop(let crop):
            state.crop = crop
        case .pasteSettings(let tone, let geometry):
            state.tone = tone
            state.geometry = geometry
        }
    }
}

nonisolated enum RenderPurpose: Equatable, Sendable {
    case proxy(longEdge: Int)
    case visibleTile(longEdge: Int)
    case exportTile(tile: CGRect)
}

nonisolated protocol EditRendering {
    func render(base: CIImage, state: EditState, purpose: RenderPurpose) throws -> CIImage
}
