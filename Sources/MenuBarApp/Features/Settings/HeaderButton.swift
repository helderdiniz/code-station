// A button in a session's header that the person can choose to hide.
enum HeaderButton: String, CaseIterable, Hashable {
    case preview

    var title: String {
        switch self {
        case .preview: "Preview"
        }
    }

    var icon: String {
        switch self {
        case .preview: "globe"
        }
    }

    var detail: String {
        switch self {
        case .preview: "Opens the running app in place of the conversation."
        }
    }
}
