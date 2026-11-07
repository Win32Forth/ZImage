import AppKit
import SwiftUI

/// The middle of a slider track. A double-click on the knob returns the value here.
enum SliderReset {
    static func middle(of range: ClosedRange<Double>) -> Double {
        (range.lowerBound + range.upperBound) / 2
    }

    /// Temperature, Dehaze, k1, and k2 stay where they are.
    static func resets(title: String) -> Bool {
        title != "Temperature" && title != "Dehaze" && title != "k1" && title != "k2"
    }
}

/// AppKit slider so a double-click on the knob can be told from a drag.
struct InspectorSlider: NSViewRepresentable {
    var value: Double
    var range: ClosedRange<Double>
    var onChange: (Double) -> Void
    var onEditingChanged: (Bool) -> Void
    var onReset: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ResetSlider {
        let slider = ResetSlider()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        slider.onEditingChanged = { [weak coordinator = context.coordinator] editing in
            coordinator?.editingChanged(editing)
        }
        slider.onReset = { [weak coordinator = context.coordinator] in
            coordinator?.reset()
        }
        return slider
    }

    func updateNSView(_ slider: ResetSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if !context.coordinator.tracking {
            slider.doubleValue = value
        }
        slider.onEditingChanged = { [weak coordinator = context.coordinator] editing in
            coordinator?.editingChanged(editing)
        }
        slider.onReset = { [weak coordinator = context.coordinator] in
            coordinator?.reset()
        }
    }

    final class Coordinator: NSObject {
        var parent: InspectorSlider
        var tracking = false

        init(_ parent: InspectorSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSlider) {
            parent.onChange(sender.doubleValue)
        }

        func editingChanged(_ editing: Bool) {
            tracking = editing
            parent.onEditingChanged(editing)
        }

        func reset() {
            parent.onReset?()
        }
    }
}

final class ResetSlider: NSSlider {
    var onEditingChanged: ((Bool) -> Void)?
    var onReset: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2, onReset != nil, knobHitRect.contains(point) {
            onReset?()
            return
        }
        onEditingChanged?(true)
        super.mouseDown(with: event)
        onEditingChanged?(false)
    }

    private var knobHitRect: NSRect {
        guard let cell = cell as? NSSliderCell else { return bounds }
        return cell.knobRect(flipped: isFlipped).insetBy(dx: -4, dy: -4)
    }
}
