import SwiftUI
import WebKit

/// The opening scene shown after each unlock: the owner's macOS_Ragnarok_Opening_Scene.html (Downloads, 2026-11-01),
/// cut down to just the animation — two lemniscates, the centre spark and em-dash, the particle burst, and the
/// single-stroke "~Ragnarok" signature, same paths and timings. Staggered 2026-11-12 on the owner's ask:
/// option D (their pick), then the symbol moved into the square they drew: symbol 78 left and
/// 19 up of the original, signature 40 right of where it was (translate 42 -> 82). (splash.js carries the same change). The demo's window frame, buttons, Tailwind and
/// Google Fonts are left out, so it runs offline. Click or any key skips; it tells Swift when it's done.
struct SplashView: View {
    var onDone: () -> Void
    var body: some View {
        SplashWeb(onDone: onDone)
            .background(Color(red: 5 / 255, green: 5 / 255, blue: 7 / 255))
            .ignoresSafeArea()
    }

    nonisolated static let html = #"""
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8">
    <style>
      html, body { margin: 0; height: 100%; background: #050507; overflow: hidden; cursor: default;
                   user-select: none; -webkit-user-select: none; }
      #stage { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
               background: radial-gradient(circle at center, rgba(255,255,255,0.05) 0%, #09090b 55%, #040405 100%);
               transition: opacity 0.5s ease; }
      svg { width: 100%; height: 100%; max-width: 620px; max-height: 620px; overflow: visible;
            filter: drop-shadow(0 0 3px rgba(255,255,255,0.9)) drop-shadow(0 0 8px rgba(230,240,255,0.6))
                    drop-shadow(0 0 22px rgba(210,230,255,0.25)); }
      canvas { position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; }
    </style></head>
    <body>
    <div id="stage">
      <svg id="splashSvg" viewBox="0 0 600 600">
        <defs>
          <linearGradient id="whiteGlow" x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" stop-color="#ffffff" stop-opacity="1"/>
            <stop offset="50%" stop-color="#f0f5ff" stop-opacity="0.95"/>
            <stop offset="100%" stop-color="#ffffff" stop-opacity="1"/>
          </linearGradient>
          <radialGradient id="coreGlowGrad" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stop-color="#ffffff" stop-opacity="1"/>
            <stop offset="25%" stop-color="rgba(255,255,255,0.9)"/>
            <stop offset="55%" stop-color="rgba(220,235,255,0.4)"/>
            <stop offset="100%" stop-color="rgba(0,0,0,0)"/>
          </radialGradient>
        </defs>
        <g id="symbol" transform="translate(-78, -19)"><path id="pathVertical" d="M 300 270 C 340 180, 335 125, 300 125 C 265 125, 260 180, 300 270 C 340 360, 335 415, 300 415 C 265 415, 260 360, 300 270 Z"
              fill="none" stroke="url(#whiteGlow)" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>
        <path id="pathHorizontal" d="M 300 270 C 390 230, 445 235, 445 270 C 445 305, 390 310, 300 270 C 210 230, 155 235, 155 270 C 155 305, 210 310, 300 270 Z"
              fill="none" stroke="url(#whiteGlow)" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>
        <g>
          <line id="emDashLineGlow" x1="130" y1="270" x2="470" y2="270" stroke="#ffffff" stroke-width="3" stroke-linecap="round"
                style="filter: drop-shadow(0 0 8px rgba(255,255,255,0.8)) drop-shadow(0 0 16px rgba(255,255,255,0.4))" opacity="0"/>
          <line id="emDashLine" x1="130" y1="270" x2="470" y2="270" stroke="#ffffff" stroke-width="1.6" stroke-linecap="round" opacity="0"/>
        </g>
        <circle id="coreNodeCircle" cx="300" cy="270" r="18" fill="url(#coreGlowGrad)" opacity="0"/>
        <circle id="centerSparkle" cx="300" cy="270" r="2.8" fill="#ffffff" opacity="0" style="filter: drop-shadow(0 0 6px #ffffff)"/>
        <circle id="penTip1" r="3" fill="#ffffff" opacity="0" style="filter: drop-shadow(0 0 6px #fff)"/>
        <circle id="penTip2" r="3" fill="#ffffff" opacity="0" style="filter: drop-shadow(0 0 6px #fff)"/>
        </g><circle id="penTip3" r="2.5" fill="#ffffff" opacity="0" style="filter: drop-shadow(0 0 6px #fff)"/>
        <g transform="translate(82, 42)">
          <path id="pathText" d="M 175 435 C 183 425, 191 426, 197 435 C 202 443, 210 442, 217 433 L 226 433 C 230 422, 233 400, 235 385 C 235 410, 233 430, 235 440 C 236 415, 245 392, 258 392 C 268 392, 273 401, 268 412 C 262 421, 248 421, 240 420 C 246 423, 255 430, 264 440 C 272 432, 279 418, 287 418 C 278 421, 273 430, 276 438 C 280 442, 287 441, 292 433 C 292 426, 293 420, 293 439 C 299 432, 306 418, 314 418 C 305 422, 301 430, 303 438 C 307 442, 314 440, 319 432 C 320 425, 321 420, 321 440 C 322 455, 317 465, 308 466 C 298 467, 300 456, 312 446 C 322 436, 332 424, 335 422 C 336 427, 335 435, 336 440 C 340 430, 347 421, 354 421 C 358 421, 360 425, 360 432 L 360 440 C 367 431, 374 418, 383 418 C 374 421, 370 430, 373 438 C 377 442, 384 440, 389 433 C 389 425, 390 420, 390 440 C 396 430, 403 421, 410 422 C 413 423, 414 427, 411 432 C 408 435, 404 437, 408 440 C 414 434, 422 418, 431 418 C 424 420, 420 428, 422 436 C 425 442, 432 441, 437 435 C 438 428, 437 422, 434 420 C 439 424, 442 432, 447 440 C 447 420, 447 388, 448 385 C 449 408, 447 430, 448 440 C 453 430, 461 422, 467 425 C 467 431, 458 434, 453 436 C 458 438, 464 440, 471 440 C 485 439, 498 436, 510 433"
                fill="none" stroke="url(#whiteGlow)" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
        </g>
      </svg>
      <canvas id="particleCanvas"></canvas>
    </div>
    <script>
      const $ = id => document.getElementById(id);
      const pathV = $('pathVertical'), pathH = $('pathHorizontal'), pathT = $('pathText');
      const pen1 = $('penTip1'), pen2 = $('penTip2'), pen3 = $('penTip3');
      const emDash = $('emDashLine'), emDashGlow = $('emDashLineGlow'), coreNode = $('coreNodeCircle'), centerSpark = $('centerSparkle');
      const canvas = $('particleCanvas'), pCtx = canvas.getContext('2d');
      const lenV = pathV.getTotalLength(), lenH = pathH.getTotalLength(), lenT = pathT.getTotalLength();
      for (const [p, l] of [[pathV, lenV], [pathH, lenH], [pathT, lenT]]) { p.style.strokeDasharray = `${l} ${l}`; p.style.strokeDashoffset = l; }

      let particles = [];
      function resizeCanvas() { canvas.width = canvas.offsetWidth; canvas.height = canvas.offsetHeight; }
      window.addEventListener('resize', resizeCanvas);
      function triggerSparks() {
        const rect = $('splashSvg').getBoundingClientRect(), pr = canvas.getBoundingClientRect();
        const cx = (rect.left - pr.left) + rect.width * (222 / 600), cy = (rect.top - pr.top) + rect.height * (251 / 600);
        particles = [];
        for (let i = 0; i < 36; i++) {
          const a = Math.random() * Math.PI * 2, s = Math.random() * 2.4 + 0.4;
          particles.push({ x: cx, y: cy, vx: Math.cos(a) * s, vy: Math.sin(a) * s, life: 1, decay: Math.random() * 0.02 + 0.015, size: Math.random() * 1.5 + 0.6 });
        }
      }
      function updateParticles() {
        pCtx.clearRect(0, 0, canvas.width, canvas.height);
        for (let i = particles.length - 1; i >= 0; i--) {
          const p = particles[i]; p.x += p.vx; p.y += p.vy; p.life -= p.decay;
          if (p.life <= 0) { particles.splice(i, 1); continue; }
          pCtx.beginPath(); pCtx.arc(p.x, p.y, p.size, 0, Math.PI * 2);
          pCtx.fillStyle = `rgba(255,255,255,${p.life * 0.8})`; pCtx.shadowBlur = 4; pCtx.shadowColor = '#ffffff'; pCtx.fill();
        }
      }
      const ease = x => x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
      const easeOutQuad = x => 1 - (1 - x) * (1 - x);
      function draw(path, len, pen, t, a, b, dx, dy) {
        if (t < a) { path.style.strokeDashoffset = len; pen.setAttribute('opacity', '0'); }
        else if (t <= b) {
          const pr = ease((t - a) / (b - a)); path.style.strokeDashoffset = len * (1 - pr);
          const pt = path.getPointAtLength(len * pr);
          pen.setAttribute('cx', pt.x + dx); pen.setAttribute('cy', pt.y + dy); pen.setAttribute('opacity', '1');
        } else { path.style.strokeDashoffset = 0; pen.setAttribute('opacity', '0'); }
      }
      function setDash(half, op) {
        for (const l of [emDash, emDashGlow]) { l.setAttribute('x1', `${300 - half}`); l.setAttribute('x2', `${300 + half}`); }
        emDash.setAttribute('opacity', op); emDashGlow.setAttribute('opacity', op * (op === 0.9 ? 0.56 : 0.7));
      }
      function renderFrame(t) {
        draw(pathV, lenV, pen1, t, 0.1, 1.3, 0, 0);     // 1. vertical loop
        draw(pathH, lenH, pen2, t, 0.9, 2.1, 0, 0);     // 2. horizontal loop
        const fStart = 2.05, fEnd = 2.8;             // 3. centre spark + em dash
        if (t < fStart) { setDash(0, 0); centerSpark.setAttribute('opacity', '0'); coreNode.setAttribute('opacity', '0'); }
        else if (t <= fEnd) {
          const s = easeOutQuad(Math.min((t - fStart) / (fEnd - fStart) * 1.3, 1));
          setDash(170 * s, Math.min(s * 0.95, 0.95)); centerSpark.setAttribute('opacity', `${s}`); coreNode.setAttribute('opacity', `${0.9 * s}`);
        } else { setDash(170, 0.9); centerSpark.setAttribute('opacity', '1'); coreNode.setAttribute('opacity', '0.6'); }
        draw(pathT, lenT, pen3, t, 2.6, 4.5, 82, 42);    // 4. "~Ragnarok"
      }
      const total = 4.8, hold = 0.6;
      let start = null, sparked = false, finished = false;
      function finish() {
        if (finished) return; finished = true;
        $('stage').style.opacity = '0';
        setTimeout(() => { try { window.webkit.messageHandlers.done.postMessage('done'); } catch (e) {} }, 500);
      }
      function loop(ts) {
        if (start === null) start = ts;
        const t = (ts - start) / 1000;
        if (t >= 2.08 && !sparked) { triggerSparks(); sparked = true; }
        updateParticles(); renderFrame(Math.min(t, total));
        if (t < total + hold) requestAnimationFrame(loop); else finish();
      }
      window.addEventListener('mousedown', finish); window.addEventListener('keydown', finish);
      resizeCanvas(); renderFrame(0); requestAnimationFrame(loop);
    </script>
    </body></html>
    """#
}

private struct SplashWeb: NSViewRepresentable {
    var onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "done")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.loadHTMLString(SplashView.html, baseURL: nil)
        // If the page never reports back (WebKit trouble), don't trap the owner behind it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { context.coordinator.fire() }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "done")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onDone: () -> Void
        private var fired = false
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func fire() { guard !fired else { return }; fired = true; onDone() }
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) { fire() }
    }
}
