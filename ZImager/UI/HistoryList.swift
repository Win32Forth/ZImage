import SwiftUI

struct HistoryList: View {
    let log: HistoryLog
    @Binding var collapsed: Bool
    let select: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorPanelHeader(title: "History", collapsed: collapsed) { collapsed.toggle() }
            if !collapsed {
                if log.commands.isEmpty {
                    Text("No edits yet")
                        .font(.body)
                        .foregroundStyle(ChromePalette.muted)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.commands.enumerated()), id: \.offset) { index, command in
                            historyRow(index: index, command: command)
                        }
                    }
                }
            }
        }
        .padding(EdgeInsets(
            top: InspectorMetrics.panelTopPadding,
            leading: 16,
            bottom: collapsed ? InspectorMetrics.panelBottomPadding : 16,
            trailing: 16
        ))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ChromePalette.panel)
    }

    private func historyRow(index: Int, command: EditCommand) -> some View {
        let isApplied = index < log.cursor
        let isCurrent = index == log.cursor - 1
        return Button {
            select(index)
        } label: {
            HStack {
                Text(command.historyTitle)
                    .font(.body)
                    .foregroundStyle(ChromePalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isCurrent ? ChromePalette.accentSoft : Color.clear)
            .opacity(isApplied ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(command.historyTitle)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
