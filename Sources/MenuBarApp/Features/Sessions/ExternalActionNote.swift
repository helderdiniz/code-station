import SwiftUI

// Lets a click deep inside a pane leave a note when its work happens outside the window,
// such as revealing a file in Finder or copying a path. Nothing in the window moves for
// those, so without the note the click leaves no trace.
//
// Every copy counts as equal. SwiftUI cannot compare closures, so a bare closure in the
// environment would count as new each time the pane that hands it down is drawn again,
// and every view that reads it would be drawn again with it, down to each line of a long
// transcript. The closure only ever calls back into the pane that owns the note, so an
// older copy does the same thing as a newer one.
struct ExternalNote: Equatable {
    var show: ((_ text: String, _ icon: String) -> Void)?

    init(_ show: ((_ text: String, _ icon: String) -> Void)? = nil) {
        self.show = show
    }

    func callAsFunction(_ text: String, _ icon: String) {
        show?(text, icon)
    }

    static func == (_: ExternalNote, _: ExternalNote) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var showExternalNote = ExternalNote()
}
