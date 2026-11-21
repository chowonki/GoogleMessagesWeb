import Cocoa
import FlutterMacOS
import Vision

@main
class AppDelegate: FlutterAppDelegate {
  // 창을 닫아도(숨겨도) 앱은 계속 실행되어 문자 알림을 받는다.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
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

  // 이미지 속 글자 인식: macOS 내장 Vision 으로 이 Mac 안에서만 처리한다.
  // 결과는 Windows 보조 프로그램(gm_ocr.exe)과 같은 JSON 형식으로 돌려준다.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    // 새 메시지가 왔는데 창이 앞에 없으면 Dock 아이콘을 한 번 튕긴다
    let app = FlutterMethodChannel(name: "gm/app", binaryMessenger: controller.engine.binaryMessenger)
    app.setMethodCallHandler { call, result in
      if call.method == "bounce" {
        NSApp.requestUserAttention(.informationalRequest)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
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

  /// {"ok":true,"w":..,"h":..,"lines":[{"words":[{"t":..,"x":..,"y":..,"w":..,"h":..}]}]}
  static func recognize(path: String) -> String {
    func encode(_ obj: [String: Any]) -> String {
      let d = try? JSONSerialization.data(withJSONObject: obj)
      return String(data: d ?? Data(), encoding: .utf8) ?? "{\"ok\":false}"
    }
    func fail(_ m: String) -> String { encode(["ok": false, "error": m]) }

    guard #available(macOS 10.15, *) else { return fail("macOS 10.15 이상 필요") }
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return fail("이미지를 열지 못했습니다")
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

    let W = Double(cg.width), H = Double(cg.height)
    // Vision 상자: 0~1 비율, 원점이 왼쪽 아래 → 픽셀, 원점 왼쪽 위
    func box(_ b: CGRect) -> [String: Double] {
      return ["x": Double(b.minX) * W, "y": (1 - Double(b.maxY)) * H,
              "w": Double(b.width) * W, "h": Double(b.height) * H]
    }

    var lines: [[String: Any]] = []
    for obs in request.results ?? [] {
      guard let top = obs.topCandidates(1).first else { continue }
      let s = top.string
      var words: [[String: Any]] = []
      // 띄어쓰기로 나눈 낱말마다 위치를 구한다 (페이지가 낱말 단위로 인식 결과를 쓴다)
      var idx = s.startIndex
      while idx < s.endIndex {
        guard let start = s[idx...].firstIndex(where: { !$0.isWhitespace }) else { break }
        let end = s[start...].firstIndex(where: { $0.isWhitespace }) ?? s.endIndex
        let word = String(s[start..<end])
        var rect = obs.boundingBox
        if let wb = try? top.boundingBox(for: start..<end) {
          rect = wb.boundingBox
        }
        var entry: [String: Any] = box(rect)
        entry["t"] = word
        words.append(entry)
        idx = end
      }
      if !words.isEmpty { lines.append(["words": words]) }
    }
    return encode(["ok": true, "w": W, "h": H, "lines": lines])
  }
}
