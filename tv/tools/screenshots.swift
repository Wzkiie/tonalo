// Renders README screenshots at TV resolution (1920x1080) with macOS WebKit – no browser download needed.
// 1. node tv/tools/mock_server.js
// 2. swift tv/tools/screenshots.swift http://localhost:4599 <output folder>
import Cocoa
import WebKit

let args = CommandLine.arguments
let base = args.count > 1 ? args[1] : "http://localhost:4600"
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "screenshots")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Each step runs JavaScript in the page, waits, then optionally saves a screenshot.
let steps: [(shot: String?, wait: Double, js: String)] = [
  (nil, 1.5, """
    localStorage.clear();
    const acc = (id, user) => ({ id, url: '\(base)', user, salt: 'demo', token: 'demo' });
    localStorage.setItem('nd.accounts', JSON.stringify([acc('demo1', 'Alex'), acc('demo2', 'Sam')]));
    localStorage.setItem('nd.lastAccount', JSON.stringify('demo1'));
    localStorage.setItem('nd.lang', JSON.stringify('en'));
    location.reload();
    """),
  ("users", 0.5, ""),
  (nil, 2.5, """
    document.querySelector('.user-card').click();
    await new Promise(r => setTimeout(r, 800));
    const al = (await API.albumList('newest', 12))[3];
    const album = await API.album(al.id);
    Player.playList(album.song, 2);
    Player.pause();
    // Pretend the song is playing at 1:24 so player bar and lyrics look alive
    Player.paused = () => false; Player.position = () => 84;
    Player.setShuffle(true); Player.setShuffle(false);
    App.go('home', null, { root: true });
    """),
  ("home", 2.5, ""),
  (nil, 2.5, "const al = (await API.albumList('alphabeticalByName', 40))[7]; App.go('album', { id: al.id });"),
  ("album", 0, ""),
  (nil, 3.0, "App.go('artist', { id: 'ar1' });"),
  ("artist", 0, ""),
  (nil, 2.5, """
    App.go('search', null, { root: true });
    await new Promise(r => setTimeout(r, 300));
    const i = document.querySelector('.search-input'); i.value = 'glass'; i.blur();
    i.dispatchEvent(new Event('input'));
    """),
  ("search", 0, ""),
  (nil, 3.0, "App.go('nowplaying'); "),
  ("nowplaying", 0, ""),
]

final class Runner: NSObject, WKNavigationDelegate {
  let web: WKWebView
  let window: NSWindow
  var loaded: CheckedContinuation<Void, Never>?

  override init() {
    let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
    window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    super.init()
    web.navigationDelegate = self
    window.contentView = web
    window.setFrameOrigin(NSPoint(x: -4000, y: -4000)) // off screen
    window.orderFrontRegardless()
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }

  @MainActor func load(_ url: URL) async {
    await withCheckedContinuation { c in loaded = c; web.load(URLRequest(url: url)) }
  }

  @MainActor func run(_ js: String) async {
    if js.isEmpty { return }
    do { _ = try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS-Fehler:", error.localizedDescription) }
  }

  @MainActor func snap(_ name: String) async throws {
    let cfg = WKSnapshotConfiguration()
    cfg.rect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    cfg.snapshotWidth = 1920
    let img = try await web.takeSnapshot(configuration: cfg)
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "snap", code: 1) }
    try png.write(to: outDir.appendingPathComponent(name + ".png"))
    print("✓", name)
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let runner = Runner()
Task { @MainActor in
  await runner.load(URL(string: base + "/")!)
  for step in steps {
    if step.js.contains("location.reload()") {
      await runner.run(step.js.replacingOccurrences(of: "location.reload();", with: ""))
      await runner.load(URL(string: base + "/")!)
    } else {
      await runner.run(step.js)
    }
    try? await Task.sleep(nanoseconds: UInt64(step.wait * 1_000_000_000))
    if let name = step.shot {
      // An off-screen window reports no visibility and runs no CSS transitions:
      // load all covers directly and switch transitions off, otherwise covers stay invisible
      await runner.run("""
        if (!document.getElementById('shot-css')) {
          const st = document.createElement('style'); st.id = 'shot-css';
          st.textContent = '*{transition:none!important;animation:none!important}';
          document.head.appendChild(st);
        }
        document.querySelectorAll('img[data-src]').forEach(img => {
          img.onload = () => img.classList.add('loaded'); img.src = img.getAttribute('data-src'); img.removeAttribute('data-src');
        });
        """)
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      try? await runner.snap(name)
    }
  }
  exit(0)
}
app.run()
