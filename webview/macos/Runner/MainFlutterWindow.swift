import Cocoa
import FlutterMacOS
import WebKit

class MainFlutterWindow: NSWindow {
  private func isInsideWebView(_ child: NSView?) -> Bool {
    var view = child
    while let current = view {
      if current is WKWebView { return true }
      view = current.superview
    }
    return false
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if modifiers == .command, let responder = firstResponder as? NSView,
       isInsideWebView(responder) {
      let action: Selector?
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "c": action = #selector(NSText.copy(_:))
      case "v": action = #selector(NSText.paste(_:))
      default: action = nil
      }
      if let action, responder.tryToPerform(action, with: self) { return true }
    }
    return super.performKeyEquivalent(with: event)
  }

  override func sendEvent(_ event: NSEvent) {
    // Reduce accelerated mouse-wheel steps over the page, keeping single
    // detents and precise trackpad scrolling on AppKit's normal path.
    if event.type == .scrollWheel, !event.hasPreciseScrollingDeltas,
       event.phase.isEmpty, event.momentumPhase.isEmpty,
       event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
       abs(event.scrollingDeltaY) > 1, let root = contentView,
       let parent = root.superview,
       isInsideWebView(root.hitTest(parent.convert(event.locationInWindow, from: nil))),
       let wheel = event.cgEvent?.copy() {
      let scale = max(1, floor(abs(event.scrollingDeltaY) / 2)) / abs(event.scrollingDeltaY)
      for field: CGEventField in [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1] {
        let delta = Double(wheel.getIntegerValueField(field))
        wheel.setIntegerValueField(field, value: Int64((delta * scale).rounded()))
      }
      let field = CGEventField.scrollWheelEventFixedPtDeltaAxis1
      wheel.setDoubleValueField(field, value: wheel.getDoubleValueField(field) * scale)
      if let adjusted = NSEvent(cgEvent: wheel) {
        super.sendEvent(adjusted)
        return
      }
    }
    super.sendEvent(event)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
