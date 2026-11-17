import AppKit
import ImageIO
import SwiftUI

/// A node of a plugin's view, as `ViewNode` in thurm-proto has it.
struct PluginNode: Decodable, Equatable {
    var type: String = ""
    var children: [PluginNode] = []
    var text: String = ""
    var symbol: String = ""
    var image: String = ""
    var value: Double?
    var color: String = ""
    var size: Double = 0
    var weight: String = ""
    var width: Double = 0
    var height: Double = 0
    var spacing: Double = 0
    var padding: Double = 0
    var background: String = ""
    var tooltip: String = ""
    var action: PluginAction?
    var popover: Box?

    final class Box: Decodable, Equatable {
        let node: PluginNode
        init(from decoder: Decoder) throws { node = try PluginNode(from: decoder) }
        static func == (a: Box, b: Box) -> Bool { a.node == b.node }
    }

    struct PluginAction: Decodable, Equatable {
        var name: String
        var args: String?

        enum CodingKeys: String, CodingKey { case name, args }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            args = (try? c.decode(JSONValue.self, forKey: .args)).map { JSON.encode($0.any) }
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, children, text, symbol, image, value, color, size, weight, width, height, spacing,
             padding, background, tooltip, action, popover
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        children = (try? c.decode([PluginNode].self, forKey: .children)) ?? []
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        symbol = (try? c.decode(String.self, forKey: .symbol)) ?? ""
        image = (try? c.decode(String.self, forKey: .image)) ?? ""
        value = try? c.decode(Double.self, forKey: .value)
        color = (try? c.decode(String.self, forKey: .color)) ?? ""
        size = (try? c.decode(Double.self, forKey: .size)) ?? 0
        weight = (try? c.decode(String.self, forKey: .weight)) ?? ""
        width = (try? c.decode(Double.self, forKey: .width)) ?? 0
        height = (try? c.decode(Double.self, forKey: .height)) ?? 0
        spacing = (try? c.decode(Double.self, forKey: .spacing)) ?? 0
        padding = (try? c.decode(Double.self, forKey: .padding)) ?? 0
        background = (try? c.decode(String.self, forKey: .background)) ?? ""
        tooltip = (try? c.decode(String.self, forKey: .tooltip)) ?? ""
        action = try? c.decode(PluginAction.self, forKey: .action)
        popover = try? c.decode(Box.self, forKey: .popover)
    }
}

/// Any JSON value, to carry an action's arguments through as they came.
private struct JSONValue: Decodable {
    let any: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { any = NSNull() }
        else if let b = try? c.decode(Bool.self) { any = b }
        else if let n = try? c.decode(Double.self) { any = n }
        else if let s = try? c.decode(String.self) { any = s }
        else if let a = try? c.decode([JSONValue].self) { any = a.map(\.any) }
        else { any = try c.decode([String: JSONValue].self).mapValues(\.any) }
    }
}

/// A view a plugin mounted, as `MountedView` in thurm-proto has it.
struct MountedPluginView: Decodable, Equatable, Identifiable {
    var client: UInt64?
    var owner: String
    var id: String
    var slot: String
    var view: PluginNode

    var key: String { "\(client ?? 0)/\(id)" }
}

/// The views plugins mounted in the window, read from this Mac's daemon (`ui.views`) whenever it
/// says they changed.
final class PluginViews: ObservableObject {
    static let shared = PluginViews()
    static let slots = ["window.bottom_trailing", "window.bottom_leading", "window.top_trailing"]

    @Published private(set) var views: [MountedPluginView] = []
    private var refreshQueued = false
    private var asked = 0

    func refresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.refreshQueued = false
            self.asked += 1
            let asked = self.asked
            Extensions.shared.call("ui.views") { value, error in
                guard asked == self.asked else { return }
                // A daemon from before views says it has no such method: none show.
                let list = error == nil ? Self.decode(value) : []
                self.apply(list)
            }
        }
    }

    func clear() {
        asked += 1
        apply([])
    }

    func apply(_ list: [MountedPluginView]) {
        guard list != views else { return }
        views = list
        NotificationCenter.default.post(name: .pluginViewsChanged, object: nil)
    }

    static func decode(_ value: Any?) -> [MountedPluginView] {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return [] }
        return (try? JSONDecoder().decode([MountedPluginView].self, from: data)) ?? []
    }

    func views(in slot: String) -> [MountedPluginView] {
        views.filter { $0.slot == slot }
    }
}

extension Notification.Name {
    static let pluginViewsChanged = Notification.Name("ThurmPluginViewsChanged")
}

/// The views of one slot, side by side, in a tab.
struct PluginSlotView: View {
    @ObservedObject var store = PluginViews.shared
    let slot: String
    let run: (String, String?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(store.views(in: slot), id: \.key) { mounted in
                PluginNodeView(node: mounted.view, run: run)
            }
        }
        .fixedSize()
    }
}

/// One node and what is under it.
struct PluginNodeView: View {
    let node: PluginNode
    let run: (String, String?) -> Void
    @State private var hovering = false

    var body: some View {
        decorated(content)
    }

    @ViewBuilder private var content: some View {
        let spacing: CGFloat? = node.spacing > 0 ? CGFloat(node.spacing) : nil
        switch node.type {
        case "row":
            HStack(spacing: spacing) { children }
        case "column":
            VStack(alignment: .leading, spacing: spacing) { children }
        case "stack":
            ZStack(alignment: .topTrailing) { children }
        case "text":
            Text(node.text)
                .font(.system(size: node.size > 0 ? node.size : 12, weight: fontWeight))
                .foregroundStyle(color(default: .primary))
                .fixedSize(horizontal: false, vertical: true)
        case "icon":
            Image(systemName: node.symbol.isEmpty ? "questionmark" : node.symbol)
                .font(.system(size: node.size > 0 ? node.size : 13, weight: fontWeight))
                .foregroundStyle(color(default: .primary))
        case "image":
            if let image = Self.image(node.image) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: node.width > 0 ? node.width : nil, height: node.height > 0 ? node.height : nil)
            }
        case "ring":
            let size = node.size > 0 ? node.size : 30
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.3), lineWidth: size * 0.1)
                Circle()
                    .trim(from: 0, to: min(1, max(0, node.value ?? 0)))
                    .stroke(color(default: .accentColor), style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                children
            }
            .frame(width: size, height: size)
        case "bar":
            let value = min(1, max(0, node.value ?? 0))
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(color(default: .primary)).frame(width: g.size.width * value)
                    }
                }
                .frame(width: node.width > 0 ? node.width : nil, height: node.height > 0 ? node.height : 5)
                .frame(maxWidth: node.width > 0 ? nil : .infinity)
        case "badge":
            Text(node.text)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .frame(minWidth: 14, minHeight: 14)
                .background(Circle().fill(color(default: .white)))
                .offset(x: 6, y: -6)
        case "divider":
            Rectangle()
                .fill(color(default: Color.primary.opacity(0.2)))
                .frame(width: node.width > 0 ? node.width : 1, height: node.height > 0 ? node.height : 18)
        case "spacer":
            Spacer(minLength: node.width > 0 ? node.width : 0)
        default:
            EmptyView()
        }
    }

    private var children: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
            PluginNodeView(node: child, run: run)
        }
    }

    @ViewBuilder private func decorated(_ view: some View) -> some View {
        let padded = view.padding(node.padding)
        let backed = Group {
            switch node.background {
            case "pill":
                padded.background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            case "card":
                padded.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
            default:
                padded
            }
        }
        backed
            .help(node.tooltip)
            .contentShape(Rectangle())
            .onTapGesture {
                if let action = node.action { run(action.name, action.args) }
            }
            .onHover { inside in
                if node.popover != nil { hovering = inside }
            }
            .popover(isPresented: $hovering, arrowEdge: .top) {
                if let popover = node.popover?.node {
                    PluginNodeView(node: popover, run: run).padding(12)
                }
            }
    }

    /// Most pixels on a side an image keeps: a small PNG may say it is far larger.
    static let maxImagePixels = 512

    static func image(_ base64: String) -> NSImage? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w * h <= 4096 * 4096,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private var fontWeight: Font.Weight {
        switch node.weight {
        case "bold": .bold
        case "medium": .medium
        default: .regular
        }
    }

    private func color(default fallback: Color) -> Color {
        Self.color(node.color) ?? fallback
    }

    static func color(_ name: String) -> Color? {
        switch name {
        case "": nil
        case "primary": .primary
        case "secondary": .secondary
        case "accent": .accentColor
        case "green": .green
        case "yellow": .yellow
        case "orange": .orange
        case "red": .red
        case "white": .white
        default: hex(name)
        }
    }

    static func hex(_ s: String) -> Color? {
        guard s.hasPrefix("#"), s.count == 7, let v = UInt32(s.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255,
                     blue: Double(v & 0xff) / 255)
    }
}

/// The host of one slot's views in a tab: sized to them, hidden when there are none.
final class PluginSlotHost: NSHostingView<PluginSlotView> {
    let slot: String

    init(slot: String, run: @escaping (String, String?) -> Void) {
        self.slot = slot
        super.init(rootView: PluginSlotView(slot: slot, run: run))
        isHidden = PluginViews.shared.views(in: slot).isEmpty
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init(rootView: PluginSlotView) { fatalError("init(rootView:) is not supported") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isEmpty: Bool { PluginViews.shared.views(in: slot).isEmpty }
}
