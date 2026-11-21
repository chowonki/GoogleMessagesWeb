import Cocoa
import FlutterMacOS
import Vision
import WebKit

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
      switch call.method {
      case "bounce":
        NSApp.requestUserAttention(.informationalRequest)
        result(nil)
      case "setHardwareAcceleration":
        // 돌려주는 값: 설정을 적용한 WebView 개수 (아직 화면에 붙지 않았으면 0)
        let on = call.arguments as? Bool ?? true
        let views = NSApp.windows.compactMap(\.contentView).flatMap(AppDelegate.webViews(in:))
        for view in views { AppDelegate.setHardwareAcceleration(on, of: view.configuration.preferences) }
        let applied = views.first.map { "\($0.configuration.preferences.value(forKey: "acceleratedDrawingEnabled") ?? "?")" }
        NSLog("gm: hardware acceleration %@, webviews=%d, acceleratedDrawing=%@",
              on ? "on" : "off", views.count, applied ?? "-")
        result(views.count)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let channel = FlutterMethodChannel(name: "gm/ocr", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "recognize", let data = call.arguments as? FlutterStandardTypedData else {
        result(FlutterMethodNotImplemented)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let json = AppDelegate.recognize(data: data.data)
        DispatchQueue.main.async { result(json) }
      }
    }
  }

  // ───── 하드웨어 가속 ─────
  // WKWebView 는 GPU 를 끄는 공개 설정이 없다. WebKit 의 내부 설정 두 가지로 페이지 내용과
  // canvas 를 CPU 로 그리게 한다(Safari 개발자 메뉴의 같은 이름 옵션과 같은 것).
  // 화면 합성(Core Animation)은 macOS 가 늘 GPU 로 한다. 설정이 없는 macOS 에서는 아무것도 하지 않는다.
  static func setHardwareAcceleration(_ on: Bool, of prefs: WKPreferences) {
    for key in ["acceleratedDrawingEnabled", "canvasUsesAcceleratedDrawing"]
    where prefs.responds(to: NSSelectorFromString("_set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
      prefs.setValue(on, forKey: key)
    }
  }

  static func webViews(in view: NSView) -> [WKWebView] {
    if let web = view as? WKWebView { return [web] }
    return view.subviews.flatMap(webViews(in:))
  }

  /// {"ok":true,"w":..,"h":..,"lines":[{"words":[{"t":..,"x":..,"y":..,"w":..,"h":..}]}]}
  static func recognize(data: Data) -> String {
    func encode(_ obj: [String: Any]) -> String {
      let d = try? JSONSerialization.data(withJSONObject: obj)
      return String(data: d ?? Data(), encoding: .utf8) ?? "{\"ok\":false}"
    }
    func fail(_ m: String) -> String { encode(["ok": false, "error": m]) }

    guard #available(macOS 10.15, *) else { return fail("macOS 10.15 이상 필요") }
    // 파일을 거치지 않고 받은 바이트에서 바로 연다
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
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
    let gray = Gray(cg)
    // Vision 상자: 0~1 비율, 원점이 왼쪽 아래 → 픽셀, 원점 왼쪽 위
    func box(_ b: CGRect) -> [String: Double] {
      return ["x": Double(b.minX) * W, "y": (1 - Double(b.maxY)) * H,
              "w": Double(b.width) * W, "h": Double(b.height) * H]
    }

    var lines: [[String: Any]] = []
    for obs in request.results ?? [] {
      guard let top = obs.topCandidates(1).first else { continue }
      // Vision 의 줄 상자는 줄에 따라 글자보다 위아래로 넉넉히 잡힐 때가 있어,
      // 상자 안에서 글자가 실제로 칠해진 행을 찾아 세로 범위를 좁힌다.
      let lineBox = gray?.tighten(obs.boundingBox) ?? obs.boundingBox
      let s = top.string
      var words: [[String: Any]] = []
      // 띄어쓰기로 나눈 낱말마다 위치를 구한다 (페이지가 낱말 단위로 인식 결과를 쓴다)
      var idx = s.startIndex
      while idx < s.endIndex {
        guard let start = s[idx...].firstIndex(where: { !$0.isWhitespace }) else { break }
        let end = s[start...].firstIndex(where: { $0.isWhitespace }) ?? s.endIndex
        let word = String(s[start..<end])
        // 높이는 줄 상자를 쓴다. 낱말 상자는 가로 위치는 정확하지만 세로가 들쭉날쭉하고
        // 글자보다 크게 잡히는 일이 많아, 겹친 글자가 아래로 밀려 보였다.
        var rect = obs.boundingBox
        if let wb = try? top.boundingBox(for: start..<end) {
          let b = wb.boundingBox
          rect = CGRect(x: b.minX, y: lineBox.minY, width: b.width, height: lineBox.height)
          // 한 줄에 큰 글자와 작은 글자가 섞여 있으면("구매가 50만원") 낱말마다 다시 좁힌다
          if let g = gray { rect = g.tighten(rect, minRatio: 0.3) }
        } else {
          rect = lineBox
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

  /// 밝기만 담은 사진. 글자 줄 상자의 세로 범위를 실제 글자에 맞춰 좁히는 데 쓴다.
  struct Gray {
    let w: Int, h: Int
    let px: [UInt8]

    init?(_ cg: CGImage) {
      let w = cg.width, h = cg.height
      guard w > 0, h > 0 else { return nil }
      var buf = [UInt8](repeating: 0, count: w * h)
      let ok = buf.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
      }
      guard ok else { return nil }
      self.w = w
      self.h = h
      px = buf
    }

    /// [b] 는 Vision 비율 좌표(원점 왼쪽 아래). 같은 좌표계로 좁힌 상자를 돌려준다.
    func tighten(_ b: CGRect, minRatio: CGFloat = 0.5) -> CGRect {
      // 픽셀 행: 0 이 맨 위
      let x0 = max(0, Int(b.minX * CGFloat(w))), x1 = min(w, Int(ceil(b.maxX * CGFloat(w))))
      let pad = Int(b.height * CGFloat(h) * 0.15)
      let top = max(0, Int((1 - b.maxY) * CGFloat(h)) - pad)
      let bottom = min(h, Int(ceil((1 - b.minY) * CGFloat(h))) + pad)
      guard x1 - x0 > 4, bottom - top > 4 else { return b }
      // 행마다 밝기 폭(가장 밝은 점 - 가장 어두운 점). 글자가 지나는 행은 폭이 크다.
      var ranges = [Int](repeating: 0, count: bottom - top)
      let step = max(1, (x1 - x0) / 400)
      for y in top..<bottom {
        var lo = 255, hi = 0
        let row = y * w
        var x = x0
        while x < x1 {
          let v = Int(px[row + x])
          if v < lo { lo = v }
          if v > hi { hi = v }
          x += step
        }
        ranges[y - top] = hi - lo
      }
      guard let peak = ranges.max(), peak >= 40 else { return b }
      let limit = peak * 35 / 100
      // Vision 상자 가운데에서 위아래로 넓혀 가며, 글자가 끊기는 행을 찾는다
      let mid = (Int((1 - b.midY) * CGFloat(h)) - top).clamped(0, ranges.count - 1)
      guard let seed = (0..<ranges.count).min(by: { abs($0 - mid) + (ranges[$0] >= limit ? 0 : 10_000) <
                                                    abs($1 - mid) + (ranges[$1] >= limit ? 0 : 10_000) }),
            ranges[seed] >= limit else { return b }
      // 글자 사이 작은 틈(받침과 모음 사이 등)은 건너뛴다
      let gapAllowed = max(2, Int(b.height * CGFloat(h) * 0.12))
      func extend(_ from: Int, _ dir: Int) -> Int {
        var last = from, i = from, gap = 0
        while i + dir >= 0 && i + dir < ranges.count {
          i += dir
          if ranges[i] >= limit { last = i; gap = 0 } else { gap += 1; if gap > gapAllowed { break } }
        }
        return last
      }
      let a = extend(seed, -1) + top, z = extend(seed, 1) + top + 1
      let newH = CGFloat(z - a) / CGFloat(h)
      // 너무 크게 바뀌면(사진 배경 탓일 수 있음) Vision 상자를 그대로 쓴다
      if newH < b.height * minRatio || newH > b.height * 1.3 { return b }
      return CGRect(x: b.minX, y: 1 - CGFloat(z) / CGFloat(h), width: b.width, height: newH)
    }
  }
}

private extension Int {
  func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
