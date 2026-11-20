import Cocoa
import FlutterMacOS
import Vision

@main
class AppDelegate: FlutterAppDelegate {
  // 창을 닫아도(숨겨도) 앱은 계속 실행되어 문자 알림을 받는다.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // 사진 속 글자 인식(라이브 텍스트): 시스템 Vision 으로 줄 단위 글자와 위치를 돌려준다.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 사진 창으로 실행된 경우에는 Dock 아이콘 없이 창만 띄운다
    if ProcessInfo.processInfo.environment["GM_IMAGE_VIEWER"] != nil {
      NSApp.setActivationPolicy(.accessory)
      NSApp.activate(ignoringOtherApps: true)
    }
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "gm/ocr", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "recognize", let path = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let json = AppDelegate.recognize(path: path)
        DispatchQueue.main.async { result(json) }
      }
    }
  }

  static func recognize(path: String) -> String {
    func fail(_ m: String) -> String {
      let d = try? JSONSerialization.data(withJSONObject: ["error": m])
      return String(data: d ?? Data(), encoding: .utf8) ?? "{}"
    }
    guard #available(macOS 10.15, *) else { return fail("macOS 10.15 이상 필요") }
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return fail("사진을 열지 못했습니다")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if #available(macOS 13.0, *) {
      request.recognitionLanguages = ["ko-KR", "en-US"]
    }
    do {
      try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
    } catch {
      return fail(error.localizedDescription)
    }
    let w = Double(cg.width), h = Double(cg.height)
    var lines: [[String: Any]] = []
    for obs in request.results ?? [] {
      guard let top = obs.topCandidates(1).first else { continue }
      let b = obs.boundingBox  // 0~1, 원점이 왼쪽 아래
      lines.append([
        "t": top.string,
        "x": Double(b.minX) * w,
        "y": (1 - Double(b.maxY)) * h,
        "w": Double(b.width) * w,
        "h": Double(b.height) * h,
      ])
    }
    let d = try? JSONSerialization.data(withJSONObject: ["w": w, "h": h, "lines": lines])
    return String(data: d ?? Data(), encoding: .utf8) ?? "{}"
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Dock 아이콘을 누르면 숨긴 창을 다시 띄운다.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in sender.windows where window is MainFlutterWindow {
        window.makeKeyAndOrderFront(self)
      }
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }
}
