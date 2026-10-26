import SwiftUI

// The root of a window whose hosting controller takes its minimum size from the view.
// The controller asks for that minimum on every layout pass, and asking a whole window's
// content means measuring all of it, so even a one-character change paid for an extra
// pass over the window. Here the minimum comes from an empty frame, and the content sits
// in an overlay, which takes the frame's size without ever being measured for it.
struct WindowMinimum<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        Color.clear
            .frame(minWidth: width, maxWidth: .infinity, minHeight: height, maxHeight: .infinity)
            .overlay { content }
    }
}
