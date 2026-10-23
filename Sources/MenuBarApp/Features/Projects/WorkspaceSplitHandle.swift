import SwiftUI

struct WorkspaceSplitHandle: View {
    @Binding var width: CGFloat
    let displayedWidth: CGFloat
    let availableWidth: CGFloat
    var label = "Resize workspace sidebar"
    var keyboardResizing = false
    var keepsDetailMinimum = false
    @State private var dragStart: CGFloat?
    @FocusState private var focused: Bool

    var body: some View {
        Rectangle().fill(focused ? Theme.accent.opacity(0.25) : .clear)
            .frame(width: ExplorerSplitLayout.handleWidth)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? displayedWidth
                    dragStart = start
                    width = ExplorerSplitLayout.treeWidth(start + value.translation.width,
                                                          availableWidth: availableWidth,
                                                          keepsDetailMinimum: keepsDetailMinimum)
                }
                .onEnded { _ in dragStart = nil })
            .cursorOnHover(.resizeLeftRight)
            .appTooltip(keyboardResizing ? "Drag or use the arrow keys to resize" : "Drag to resize")
            .focusable(keyboardResizing)
            .focused($focused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard keyboardResizing, direction == .left || direction == .right else { return }
                width = ExplorerSplitLayout.treeWidth(displayedWidth + (direction == .right ? 16 : -16),
                                                      availableWidth: availableWidth,
                                                      keepsDetailMinimum: keepsDetailMinimum)
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(displayedWidth)) points wide")
            .accessibilityAdjustableAction { direction in
                let change: CGFloat = switch direction {
                case .increment: 32
                case .decrement: -32
                @unknown default: 0
                }
                width = ExplorerSplitLayout.treeWidth(displayedWidth + change, availableWidth: availableWidth,
                                                      keepsDetailMinimum: keepsDetailMinimum)
            }
    }
}
