// 페이지 맨 위 가장자리의 배경색을 앱에 알려, 앱이 그리는 제목 표시줄이 같은 색을 쓰게 한다.
// Google 메시지의 밝게/어둡게 설정은 Windows 설정과 따로 바뀌므로 화면에서 직접 읽는다.
(() => {
  if (window.top !== window || window.__gmTheme) return;
  window.__gmTheme = true;

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

  // (x, y) 에 보이는 불투명한 배경: 그 자리의 요소에서 위로 올라가며 찾는다
  const backgroundAt = (x, y) => {
    for (let el = document.elementFromPoint(x, y); el; el = el.parentElement) {
      const c = rgba(getComputedStyle(el).backgroundColor);
      if (c[3] >= 230) return { el, color: (c[0] << 16) | (c[1] << 8) | c[2] };
    }
    return null;
  };

  let sent = '';
  const report = () => {
    const width = window.innerWidth;
    if (document.hidden || !document.body || width < 40) return;
    const left = backgroundAt(8, 2);
    const right = backgroundAt(width - 8, 2);
    if (!left || !right) return;
    // 왼쪽(대화 목록)과 오른쪽(대화)의 색이 다르면 어디서 갈리는지도 함께 보낸다
    let split = 0;
    if (left.color !== right.color) {
      const edge = left.el.getBoundingClientRect().right;
      split = edge < width - 1 ? edge : right.el.getBoundingClientRect().left;
    }
    const message = [left.color, right.color, Math.round(split)];
    const key = message.join();
    if (key === sent) return;
    try {
      window.flutter_inappwebview.callHandler('gmTheme', ...message);
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
    const options = { attributes: true, attributeFilter: ['class', 'style'] };
    const observer = new MutationObserver(schedule);
    observer.observe(document.documentElement, options);
    if (document.body) observer.observe(document.body, options);
    schedule();
  };

  window.addEventListener('flutterInAppWebViewPlatformReady', schedule);
  window.addEventListener('load', schedule);
  window.addEventListener('resize', schedule);
  document.addEventListener('visibilitychange', schedule);
  window.matchMedia('(prefers-color-scheme: dark)')
    .addEventListener('change', schedule);
  if (document.body) start();
  else document.addEventListener('DOMContentLoaded', start);
  // 화면 전환(로그인 → 대화 목록, 대화 열기 등)은 위 신호로 다 잡히지 않는다
  setInterval(report, 1000);
})();
