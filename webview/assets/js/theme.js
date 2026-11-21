// 창 단추(최소화·최대화·닫기)를 페이지 머리말 위에 얹기 위한 연결.
// 앱에 알려 주는 것:
// - 창 단추 자리의 배경색 (Google 메시지의 밝게/어둡게 설정은 Windows 설정과 따로 바뀌므로
//   화면에서 직접 읽는다)
// - 머리말의 높이: 창 단추를 같은 높이로 그린다
// - 머리말에서 아무것도 없는 가로 구간: 앱이 그 자리를 끌어 창을 옮기는 손잡이로 쓴다
// 그리고 머리말 오른쪽 끝을 창 단추 너비만큼 비운다.
// 창 단추를 앱이 직접 그리는 경우(Windows)에만 앱이 __gmCaptionWidth 를 넣어 준다.
(() => {
  if (window.top !== window || window.__gmTheme) return;
  window.__gmTheme = true;

  const captionWidth = window.__gmCaptionWidth || 0;
  // 머리말을 찾지 못한 화면(로그인 등)에서 손잡이로 쓰는 맨 위 띠의 높이
  const STRIP_HEIGHT = 40;
  // 이보다 좁은 빈 구간은 손잡이로 쓰지 않는다
  const MIN_GAP = 24;

  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });

  // CSS 색 문자열(rgb, oklch, color() …) → [r, g, b, a]
  const rgba = (css) => {
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = '#000';
    ctx.fillStyle = css;
    ctx.fillRect(0, 0, 1, 1);
    return ctx.getImageData(0, 0, 1, 1).data;
  };

  // (x, y) 에 보이는 불투명한 배경색: 그 자리의 요소에서 위로 올라가며 찾는다
  const backgroundAt = (x, y) => {
    for (let el = document.elementFromPoint(x, y); el; el = el.parentElement) {
      const c = rgba(getComputedStyle(el).backgroundColor);
      if (c[3] >= 230) return (c[0] << 16) | (c[1] << 8) | c[2];
    }
    return null;
  };

  // 화면 맨 위를 가로로 꽉 채운 머리말. Google 메시지의 머리말이 없으면 모양으로 찾는다.
  const findHeader = () => {
    const known = document.querySelector('mw-branded-header');
    if (known && known.getBoundingClientRect().height > 0) return known;
    const width = window.innerWidth;
    for (let el = document.elementFromPoint(width / 2, 3); el; el = el.parentElement) {
      const r = el.getBoundingClientRect();
      if (r.top <= 1 && r.width >= width - 2 && r.height >= 40 && r.height <= 80) {
        return el;
      }
    }
    return null;
  };

  const INTERACTIVE = 'a, button, input, textarea, select, label, [role="button"], ' +
    '[role="link"], [role="menuitem"], [role="tab"], [contenteditable=""], ' +
    '[contenteditable="true"], [tabindex]:not([tabindex="-1"])';

  // 머리말(없으면 맨 위 띠)에서 누를 것이 없는 가로 구간들: [왼쪽, 오른쪽, 왼쪽, 오른쪽, …]
  const emptySpans = (header, bottom) => {
    const limit = window.innerWidth - captionWidth;
    const taken = [];
    for (const el of (header || document).querySelectorAll(INTERACTIVE)) {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < bottom &&
          r.right > 0 && r.left < limit) {
        taken.push([r.left - 4, r.right + 4]);
      }
    }
    taken.sort((a, b) => a[0] - b[0]);
    taken.push([limit, limit]);
    const spans = [];
    let from = 0;
    for (const [left, right] of taken) {
      if (left - from >= MIN_GAP) {
        // 메뉴·대화상자 같은 것이 그 자리를 덮고 있으면 손잡이로 쓰지 않는다
        const top = document.elementFromPoint((from + left) / 2, bottom / 2);
        const free = header ? header.contains(top) : top && !top.closest(INTERACTIVE);
        if (free) spans.push(Math.round(from), Math.round(left));
      }
      from = Math.max(from, right);
    }
    return spans;
  };

  let sent = '';
  const report = () => {
    const width = window.innerWidth;
    if (document.hidden || !document.body || width < 40) return;
    // 창 단추가 놓이는 자리(오른쪽 위)의 색
    const color = backgroundAt(width - Math.max(captionWidth / 2, 8), 6);
    if (color === null) return;
    const header = findHeader();
    const height = header ? Math.round(header.getBoundingClientRect().height) : 0;
    const spans = captionWidth ? emptySpans(header, height || STRIP_HEIGHT) : [];
    const key = [color, height, ...spans].join();
    if (key === sent) return;
    try {
      window.flutter_inappwebview.callHandler('gmTheme', color, height, spans);
      sent = key;
    } catch (e) {
      // 앱과의 연결이 아직 준비되지 않음: 다음 기회에 다시 보낸다
    }
  };

  let queued = false;
  const schedule = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      report();
    });
  };

  const start = () => {
    if (captionWidth) {
      const style = document.createElement('style');
      style.textContent =
        `mw-branded-header .container { padding-right: ${captionWidth}px !important; ` +
        'box-sizing: border-box !important; }';
      document.head.appendChild(style);
    }
    const options = { attributes: true, attributeFilter: ['class', 'style'] };
    const observer = new MutationObserver(schedule);
    observer.observe(document.documentElement, options);
    observer.observe(document.body, options);
    schedule();
  };

  // 누른 뒤에는 메뉴가 열리거나 화면이 바뀌기 쉽다: 곧바로, 그리고 움직임이 끝난 뒤 다시 본다
  window.addEventListener('click', () => {
    schedule();
    setTimeout(report, 350);
  }, true);
  window.addEventListener('flutterInAppWebViewPlatformReady', schedule);
  window.addEventListener('load', schedule);
  window.addEventListener('resize', schedule);
  document.addEventListener('visibilitychange', schedule);
  window.matchMedia('(prefers-color-scheme: dark)')
    .addEventListener('change', schedule);
  if (document.body) start();
  else document.addEventListener('DOMContentLoaded', start);
  // 화면 전환(로그인 → 대화 목록, 설정 열기 등)은 위 신호로 다 잡히지 않는다
  setInterval(report, 1000);
})();
