import SwiftUI

/// Export choices. WebP, JPEG XL, and linear DNG are in this list.
struct ExportPanel: View {
    @Bindable var model: EditorModel
    @State private var container: ExportContainer = .jpeg
    @State private var quality: Double = ExportContainer.jpeg.defaultQuality
    @State private var bitDepth: Int = ExportContainer.jpeg.defaultBitDepth
    @State private var tiffCompression: TIFFCompression = .lzw
    @State private var tiffExtension = "tiff"
    @State private var lossless = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityIdentifier("Export")
            Picker("Format", selection: $container) {
                ForEach(ExportContainer.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Format")
            .onChange(of: container) { _, newValue in
                quality = newValue.defaultQuality
                bitDepth = newValue.defaultBitDepth
                tiffCompression = .lzw
                tiffExtension = newValue.defaultExtension
                lossless = false
            }
            if container.offersLosslessToggle {
                Toggle("Lossless", isOn: $lossless)
                    .accessibilityLabel("Lossless")
            }
            if container.usesQualitySlider && !(container == .webp && lossless) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(qualityLabel)
                        .foregroundStyle(ChromePalette.muted)
                    Slider(value: $quality, in: container.qualityRange)
                        .accessibilityLabel("Quality")
                }
            }
            if container.allowsBitDepthChoice {
                Picker("Bit depth", selection: $bitDepth) {
                    Text("8-bit").tag(8)
                    Text("16-bit").tag(16)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Bit depth")
            }
            if container == .tiff {
                Picker("Compression", selection: $tiffCompression) {
                    ForEach(TIFFCompression.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Compression")
                Picker("Extension", selection: $tiffExtension) {
                    Text(".tiff").tag("tiff")
                    Text(".tif").tag("tif")
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Extension")
            }
            Text(currentRequest.panelCopy)
                .font(.callout)
                .foregroundStyle(ChromePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.showsExportPanel = false }
                Button("Export") { model.exportStill(currentRequest) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(ChromePalette.panel)
        .foregroundStyle(ChromePalette.ink)
    }

    private var currentRequest: ExportRequest {
        var request = ExportRequest.standard(container)
        request.quality = quality
        request.bitDepth = bitDepth
        request.tiffCompression = tiffCompression
        request.fileExtension = container == .tiff ? tiffExtension : container.defaultExtension
        request.lossless = container.offersLosslessToggle && lossless
        return request
    }

    private var qualityLabel: String {
        if container == .webp {
            return "Quality \(Int(quality.rounded()))"
        }
        return "Quality \(String(format: "%.2f", quality))"
    }
}
