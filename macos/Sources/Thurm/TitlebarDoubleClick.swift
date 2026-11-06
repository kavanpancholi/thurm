import AppKit

enum TitlebarDoubleClick: Equatable {
    case zoom, fill, minimize, ignore

    init(action: String?, legacyMinimize: Bool) {
        switch action {
        case "Maximize": self = .zoom
        case "Fill": self = .fill
        case "Minimize": self = .minimize
        case "None": self = .ignore
        default: self = action == nil && legacyMinimize ? .minimize : .zoom
        }
    }

    static var current: TitlebarDoubleClick {
        let defaults = UserDefaults.standard
        return TitlebarDoubleClick(action: defaults.string(forKey: "AppleActionOnDoubleClick"),
                                   legacyMinimize: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"))
    }

    func perform(on window: NSWindow) {
        switch self {
        case .zoom:
            window.performZoom(nil)
        case .fill:
            let fill = Selector(("_zoomFill:"))
            if window.responds(to: fill) {
                window.perform(fill, with: nil)
            } else {
                window.performZoom(nil)
            }
        case .minimize:
            window.performMiniaturize(nil)
        case .ignore:
            break
        }
    }
}
