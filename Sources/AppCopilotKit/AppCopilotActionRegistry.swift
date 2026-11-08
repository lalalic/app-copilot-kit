#if os(iOS)
import SwiftUI
import UIKit

/// Explicit, public-API action bridge for app-owned SwiftUI controls.
/// The app opts in only actions it wants its trusted development agent to invoke.
@MainActor
public final class AppCopilotActionRegistry {
    public static let shared = AppCopilotActionRegistry()

    public struct VisibleAction {
        public let id: String
        public let label: String
        public let kind: String
        public let frame: CGRect
        public let isEnabled: Bool
    }

    private struct Entry {
        let id: String
        var label: String
        var kind: String
        var frame: (UIWindow) -> CGRect?
        var isEnabled: () -> Bool
        var isVisible: () -> Bool
        var acceptsHit: (CGPoint, UIWindow) -> Bool
        var perform: () -> Void
    }
    // A stable public action ID may occur in multiple SwiftUI scenes. The
    // anchor-owned token prevents one window from replacing another's handler.
    private var entries: [String: [UUID: Entry]] = [:]
    private static let programmaticOwner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private init() {}

    /// Register a stable identifier and an app-owned handler. Coordinates are
    /// evaluated at snapshot/tap time, not captured from a previous layout.
    public func register(
        id: String, label: String, kind: String = "button",
        frame: @escaping (UIWindow) -> CGRect?,
        isEnabled: @escaping () -> Bool = { true },
        isVisible: @escaping () -> Bool = { true },
        acceptsHit: @escaping (CGPoint, UIWindow) -> Bool = { _, _ in false },
        perform: @escaping () -> Void
    ) {
        registerOwned(id: id, owner: Self.programmaticOwner, label: label, kind: kind,
                      frame: frame, isEnabled: isEnabled, isVisible: isVisible,
                      acceptsHit: acceptsHit, perform: perform)
    }

    fileprivate func registerOwned(
        id: String, owner: UUID, label: String, kind: String,
        frame: @escaping (UIWindow) -> CGRect?,
        isEnabled: @escaping () -> Bool,
        isVisible: @escaping () -> Bool,
        acceptsHit: @escaping (CGPoint, UIWindow) -> Bool,
        perform: @escaping () -> Void
    ) {
        precondition(!id.isEmpty && !label.isEmpty, "Copilot actions require a stable id and label")
        entries[id, default: [:]][owner] = Entry(
            id: id, label: label, kind: kind, frame: frame,
            isEnabled: isEnabled, isVisible: isVisible,
            acceptsHit: acceptsHit, perform: perform
        )
    }

    public func unregister(id: String) { entries.removeValue(forKey: id) }

    fileprivate func unregister(id: String, owner: UUID) {
        entries[id]?.removeValue(forKey: owner)
        if entries[id]?.isEmpty == true { entries.removeValue(forKey: id) }
    }

    public func visibleActions(in window: UIWindow) -> [VisibleAction] {
        entries.values.flatMap(\.values).compactMap { entry in
            guard entry.isVisible(), let rect = entry.frame(window),
                  rect.width > 0, rect.height > 0,
                  rect.intersects(window.bounds),
                  entry.acceptsHit(CGPoint(x: rect.midX, y: rect.midY), window) else { return nil }
            return VisibleAction(id: entry.id, label: entry.label, kind: entry.kind,
                                 frame: rect, isEnabled: entry.isEnabled())
        }.sorted {
            if abs($0.frame.minY - $1.frame.minY) > 5 { return $0.frame.minY < $1.frame.minY }
            return $0.frame.minX < $1.frame.minX
        }
    }

    /// Only invoke if the same control is still visible at its snapshotted location.
    /// Prevents silently reusing a stale ref after a layout/navigation change.
    @discardableResult
    public func invoke(id: String, in window: UIWindow, expectedFrame: CGRect? = nil) -> Bool {
        guard let matches = entries[id] else { return false }
        for entry in matches.values where entry.isEnabled() && entry.isVisible() {
            guard let frame = entry.frame(window), frame.width > 0, frame.height > 0,
                  frame.intersects(window.bounds),
                  entry.acceptsHit(CGPoint(x: frame.midX, y: frame.midY), window) else { continue }
            if let expectedFrame {
                let old = CGPoint(x: expectedFrame.midX, y: expectedFrame.midY)
                let now = CGPoint(x: frame.midX, y: frame.midY)
                guard hypot(old.x - now.x, old.y - now.y) <= 12 else { continue }
            }
            entry.perform()
            return true
        }
        return false
    }

    /// Coordinate taps target the smallest matching registered region.
    @discardableResult
    public func invoke(at point: CGPoint, in window: UIWindow) -> String? {
        let matches = visibleActions(in: window).filter { $0.frame.contains(point) }
            .sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let action = matches.first else { return nil }
        guard invoke(id: action.id, in: window) else {
            return "Error: action '\(action.id)' is no longer available or enabled"
        }
        return "Dispatched registered action '\(action.id)' [\(action.label)]"
    }

    /// Public UIKit tab-bar geometry: usable by SwiftUI TabView owners that
    /// explicitly register selection actions. Never uses private tab bar classes.
    public static func tabFrame(index: Int, in window: UIWindow) -> CGRect? {
        func findBar(_ view: UIView) -> UITabBar? {
            if let bar = view as? UITabBar, !bar.isHidden, bar.alpha > 0 { return bar }
            for child in view.subviews {
                if let match = findBar(child) { return match }
            }
            return nil
        }
        guard let bar = findBar(window), let items = bar.items,
              items.indices.contains(index), !items.isEmpty else { return nil }
        let itemFrame = items[index].accessibilityFrame
        if itemFrame.width > 0, itemFrame.height > 0 {
            let frame = window.convert(itemFrame, from: nil)
            if frame.intersects(window.bounds), isTabVisible(bar, frame: frame, window: window) {
                return frame
            }
        }
        let frame = bar.convert(bar.bounds, to: window)
        let width = frame.width / CGFloat(items.count)
        let itemRect = CGRect(x: frame.minX + width * CGFloat(index), y: frame.minY,
                              width: width, height: frame.height)
        guard isTabVisible(bar, frame: itemRect, window: window) else { return nil }
        return itemRect
    }

    private static func isTabVisible(_ bar: UITabBar, frame: CGRect, window: UIWindow) -> Bool {
        guard let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) else {
            return false
        }
        return hit === bar || hit.isDescendant(of: bar)
    }

    public func registerTab(
        id: String, label: String, index: Int, perform: @escaping () -> Void
    ) {
        register(id: id, label: label,
                 frame: { window in Self.tabFrame(index: index, in: window) },
                 acceptsHit: { point, window in
                     guard let frame = Self.tabFrame(index: index, in: window) else { return false }
                     return frame.contains(point)
                 },
                 perform: perform)
    }
}

/// Opt-in modifier for regular SwiftUI buttons. The invisible UIKit layout
/// anchor never intercepts touches; it only exports the control's live frame.
public extension View {
    func appCopilotAction(
        id: String, label: String, isEnabled: Bool = true,
        isVisible: Bool = true, perform: @escaping @MainActor () -> Void
    ) -> some View {
        background(AppCopilotActionAnchor(
            id: id, label: label, isEnabled: isEnabled,
            isVisible: isVisible, perform: perform
        ))
    }
}

private struct AppCopilotActionAnchor: UIViewRepresentable {
    @Environment(\.isEnabled) private var environmentEnabled
    let id: String
    let label: String
    let isEnabled: Bool
    let isVisible: Bool
    let perform: @MainActor () -> Void

    func makeUIView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.configure(id: id, label: label,
                       isEnabled: isEnabled && environmentEnabled,
                       isVisible: isVisible, perform: perform)
    }

    final class AnchorView: UIView {
        private var id: String?
        private let registrationOwner = UUID()
        private var label = ""
        private var enabled = true
        private var visible = true
        private var action: (@MainActor () -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

        func configure(id: String, label: String, isEnabled: Bool,
                       isVisible: Bool, perform: @escaping @MainActor () -> Void) {
            if let old = self.id, old != id {
                AppCopilotActionRegistry.shared.unregister(id: old, owner: registrationOwner)
            }
            self.id = id
            self.label = label
            enabled = isEnabled
            visible = isVisible
            action = perform
            synchronize()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            synchronize()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            synchronize()
        }

        private func synchronize() {
            guard let id else { return }
            guard window != nil else {
                AppCopilotActionRegistry.shared.unregister(id: id, owner: registrationOwner)
                return
            }
            AppCopilotActionRegistry.shared.registerOwned(
                id: id, owner: registrationOwner, label: label, kind: "button",
                frame: { [weak self] window in
                    guard let self, self.window === window else { return nil }
                    // SwiftUI TabView keeps inactive scenes in the UIKit
                    // hierarchy. A registered action must never outlive its
                    // actually visible button.
                    var visibleRect = self.convert(self.bounds, to: window)
                    var ancestor: UIView? = self
                    while let view = ancestor {
                        guard !view.isHidden, view.alpha > 0.01,
                              !view.bounds.isEmpty else { return nil }
                        if view.clipsToBounds || view is UIScrollView {
                            visibleRect = visibleRect.intersection(
                                view.convert(view.bounds, to: window)
                            )
                            guard !visibleRect.isNull, visibleRect.width > 0,
                                  visibleRect.height > 0 else { return nil }
                        }
                        ancestor = view.superview
                    }
                    visibleRect = visibleRect.intersection(window.bounds)
                    guard !visibleRect.isNull, visibleRect.width > 0,
                          visibleRect.height > 0 else { return nil }
                    return visibleRect
                },
                isEnabled: { [weak self] in self?.enabled ?? false },
                isVisible: { [weak self] in self?.visible ?? false },
                acceptsHit: { [weak self] point, window in
                    guard let self, let hit = window.hitTest(point, with: nil) else { return false }
                    return Self.sameInteractionSurface(self, hit: hit)
                },
                perform: { [weak self] in self?.action?() }
            )
        }

        private static func sameInteractionSurface(_ anchor: UIView, hit: UIView) -> Bool {
            // The actual hit target must be on the anchor's own responder
            // ancestry. A sibling overlay can share a hosting controller but
            // must never be treated as the button below it.
            guard anchor === hit || anchor.isDescendant(of: hit) else {
                return false
            }
            func owningController(_ view: UIView) -> UIViewController? {
                var responder: UIResponder? = view
                while let value = responder {
                    if let owner = value as? UIViewController { return owner }
                    responder = value.next
                }
                return nil
            }
            guard let owner = owningController(anchor), let top = owningController(hit) else {
                return false
            }
            return owner === top
        }
    }
}
#endif
