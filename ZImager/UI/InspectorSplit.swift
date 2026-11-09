import AppKit
import SwiftUI

/// Stored heights of the three adjustment panels. History uses whatever is left.
struct InspectorHeights: Equatable {
    var tone: CGFloat
    var geometry: CGFloat
    var eyedropper: CGFloat
}

/// Which inspector panels are folded down to their titles.
struct InspectorCollapse: Equatable {
    var tone = false
    var geometry = false
    var eyedropper = false
    var history = false
}

/// Title-row disclosure. Up while the panel is collapsed, down while it is open.
enum InspectorDisclosure {
    static func symbol(collapsed: Bool) -> String {
        collapsed ? "chevron.up" : "chevron.down"
    }
}

/// Tone, Geometry, and Eyedropper each stay tall enough to show a title and scroll.
enum InspectorPanelSpan {
    static let minimum: CGFloat = 96
    static let historyMinimum: CGFloat = 80
    static let toneInitial: CGFloat = 200
    static let geometryInitial: CGFloat = 180
    static let eyedropperInitial: CGFloat = 150
    /// Title row only: top inset, the title line, and the bottom inset.
    static let collapsedHeight: CGFloat = 44
    /// Drag strip under each adjustment panel. Half of the previous 8-point hit.
    static let dividerHit: CGFloat = 4
    static let chrome: CGFloat = dividerHit * 3

    /// Keeps half of the empty space under the controls. A panel that already scrolls stays as it is.
    static func halfBlank(_ stored: CGFloat, content: CGFloat) -> CGFloat {
        guard content > 1, stored > content else { return stored }
        return content + (stored - content) / 2
    }

    /// Dragging a line resizes the panel above it. Panels below keep their heights, and History
    /// absorbs the change. History stays at least `historyMinimum` when the column is tall enough.
    static func resizeAbove(proposed: CGFloat, current: CGFloat, history: CGFloat) -> CGFloat {
        let span = max(0, current) + max(0, history)
        let panelFloor: CGFloat
        let historyFloor: CGFloat
        if span >= minimum + historyMinimum {
            panelFloor = minimum
            historyFloor = historyMinimum
        } else {
            panelFloor = 0
            historyFloor = 0
        }
        return min(max(proposed, panelFloor), max(panelFloor, span - historyFloor))
    }

    /// Fits the stored heights into the inspector. Extra space stays with History.
    /// A collapsed panel keeps `collapsedHeight` and its stored open height.
    static func fitted(
        _ preferred: InspectorHeights,
        available: CGFloat,
        collapsed: InspectorCollapse = InspectorCollapse()
    ) -> InspectorHeights {
        let historyFloor = collapsed.history ? collapsedHeight : historyMinimum
        let space = max(0, available)
        if collapsed.tone || collapsed.geometry || collapsed.eyedropper {
            return fitFolded(preferred, space: space, historyFloor: historyFloor, collapsed: collapsed)
        }
        if space <= historyFloor {
            let each = space / 4
            return InspectorHeights(tone: each, geometry: each, eyedropper: each)
        }
        let room = space - historyFloor
        if room < minimum * 3 {
            let each = room / 3
            return InspectorHeights(tone: each, geometry: each, eyedropper: each)
        }
        let tone0 = max(preferred.tone, minimum)
        let geometry0 = max(preferred.geometry, minimum)
        let eyedropper0 = max(preferred.eyedropper, minimum)
        let sum = tone0 + geometry0 + eyedropper0
        if sum <= room {
            return InspectorHeights(tone: tone0, geometry: geometry0, eyedropper: eyedropper0)
        }
        let extra = sum - minimum * 3
        let overflow = sum - room
        let scale = extra > 0 ? max(0, 1 - overflow / extra) : 0
        let tone = minimum + (tone0 - minimum) * scale
        let geometry = minimum + (geometry0 - minimum) * scale
        let eyedropper = room - tone - geometry
        return InspectorHeights(tone: tone, geometry: geometry, eyedropper: eyedropper)
    }

    private static func fitFolded(
        _ preferred: InspectorHeights,
        space: CGFloat,
        historyFloor: CGFloat,
        collapsed: InspectorCollapse
    ) -> InspectorHeights {
        func open(_ value: CGFloat, _ isCollapsed: Bool) -> CGFloat {
            isCollapsed ? collapsedHeight : max(value, minimum)
        }
        let tone = open(preferred.tone, collapsed.tone)
        let geometry = open(preferred.geometry, collapsed.geometry)
        let eyedropper = open(preferred.eyedropper, collapsed.eyedropper)
        let room = max(0, space - historyFloor)
        let sum = tone + geometry + eyedropper
        if sum <= room {
            return InspectorHeights(tone: tone, geometry: geometry, eyedropper: eyedropper)
        }
        let locked = (collapsed.tone ? tone : 0) + (collapsed.geometry ? geometry : 0) + (collapsed.eyedropper ? eyedropper : 0)
        let flexRoom = max(0, room - locked)
        let flexSum = sum - locked
        let scale = flexSum > 0 ? flexRoom / flexSum : 0
        return InspectorHeights(
            tone: collapsed.tone ? tone : tone * scale,
            geometry: collapsed.geometry ? geometry : geometry * scale,
            eyedropper: collapsed.eyedropper ? eyedropper : eyedropper * scale
        )
    }
}

/// The title line of an inspector panel, with the disclosure at the right end.
/// An accessory, when there is one, sits immediately to the right of the title.
struct InspectorPanelHeader<Accessory: View>: View {
    var title: String
    var collapsed: Bool
    var accessory: Accessory
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ChromePalette.ink)
            accessory
            Spacer(minLength: 8)
            Button(action: toggle) {
                Image(systemName: InspectorDisclosure.symbol(collapsed: collapsed))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChromePalette.ink)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Expand \(title)" : "Collapse \(title)")
            .accessibilityIdentifier("\(title) disclosure")
            .help(collapsed ? "Expands \(title)." : "Collapses \(title).")
        }
    }
}

extension InspectorPanelHeader where Accessory == EmptyView {
    init(title: String, collapsed: Bool, toggle: @escaping () -> Void) {
        self.title = title
        self.collapsed = collapsed
        self.accessory = EmptyView()
        self.toggle = toggle
    }
}

struct InspectorContentHeight: Equatable {
    var tone: CGFloat = 0
    var geometry: CGFloat = 0
    var eyedropper: CGFloat = 0
}

struct InspectorContentKey: PreferenceKey {
    static var defaultValue = InspectorContentHeight()
    static func reduce(value: inout InspectorContentHeight, nextValue: () -> InspectorContentHeight) {
        let next = nextValue()
        if next.tone > 0 { value.tone = next.tone }
        if next.geometry > 0 { value.geometry = next.geometry }
        if next.eyedropper > 0 { value.eyedropper = next.eyedropper }
    }
}

struct PanelHeightReader: View {
    var onHeight: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onHeight(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, new in onHeight(new) }
        }
    }
}

/// One inspector line. Dragging it moves this line and every line below it.
struct InspectorPanelDivider: View {
    var above: CGFloat
    var history: CGFloat
    var label: String
    var identifier: String
    var enabled: Bool = true
    var onResize: (CGFloat) -> Void
    @State private var originAbove: CGFloat?
    @State private var originHistory: CGFloat?

    var body: some View {
        Rectangle()
            .fill(ChromePalette.hairline)
            .frame(height: 1)
            .frame(height: InspectorPanelSpan.dividerHit)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled else { return }
                        if originAbove == nil {
                            originAbove = above
                            originHistory = history
                        }
                        let next = InspectorPanelSpan.resizeAbove(
                            proposed: (originAbove ?? above) + value.translation.height,
                            current: originAbove ?? above,
                            history: originHistory ?? history
                        )
                        onResize(next)
                    }
                    .onEnded { _ in
                        originAbove = nil
                        originHistory = nil
                    }
            )
            .onContinuousHover { phase in
                guard enabled else {
                    if case .ended = phase { NSCursor.arrow.set() }
                    return
                }
                switch phase {
                case .active:
                    NSCursor.resizeUpDown.set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}
