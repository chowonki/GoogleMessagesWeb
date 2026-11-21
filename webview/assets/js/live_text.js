// 라이브 텍스트와 이미지 확대 보기.
//  - 말풍선 글과 이미지 속 글자에서 전화번호·계좌번호·인증번호·이메일·운송장 번호를 인식해
//    표시하고, 클릭하면 복사한다. 이미지 글자는 드래그로 선택할 수도 있다. (OCR 은 앱이 처리)
//  - 이미지 확대 보기에서 휠·더블클릭·끌기·키보드로 확대/축소/이동한다.
(() => {
  if (window.__gmLiveText || !window.CSS || !CSS.highlights || !window.Highlight) return;
  window.__gmLiveText = true;

  const NAME = 'gm-live-text';
  const LABEL = {
    phone: '전화번호', account: '계좌번호', code: '인증번호',
    email: '이메일 주소', tracking: '운송장 번호',
  };

  // ───── 인식 규칙 ─────
  const PHONE = /(?<![\d-])(?:\+82[-\s]?1[016789]|01[016789])[-.\s]?\d{3,4}[-.\s]?\d{4}(?![\d-])|(?<![\d-])0\d{1,2}[-.\s]\d{3,4}[-.\s]\d{4}(?![\d-])|(?<![\d-])1[5-9]\d{2}-?\d{4}(?![\d-])/g;
  const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g;
  const HYPHEN_NUMBER = /(?<![\d-])\d{2,6}(?:-\d{2,7}){1,3}(?![\d-])/g;
  const PLAIN_NUMBER = /(?<![\d-])\d{4,16}(?![\d-])/g;
  const BANK_HINT = /은행|뱅크|농협|수협|신협|우체국|새마을|금고|증권|계좌|입금|송금|이체|예금주/;
  const CODE_HINT = /인증|승인번호|보안코드|확인코드|비밀번호|verification|verify|OTP|passcode|code/i;
  const TRACKING_HINT = /운송장|송장|택배|배송/;

  // 한 덩어리의 글에서 [시작, 끝, 종류, 복사할 값] 목록을 찾는다
  const detect = (text) => {
    const found = [];
    const taken = (s, e) => found.some((f) => s < f[1] && e > f[0]);
    const add = (re, classify) => {
      re.lastIndex = 0;
      for (let m; (m = re.exec(text)); ) {
        const s = m.index, e = s + m[0].length;
        if (taken(s, e)) continue;
        const r = classify(m[0], s, e);
        if (r) found.push([s, e, r[0], r[1]]);
      }
    };
    const near = (hint, s, e, span) =>
      hint.test(text.slice(Math.max(0, s - span), Math.min(text.length, e + span)));
    add(EMAIL, (v) => ['email', v]);
    add(PHONE, (v) => ['phone', v]);
    add(HYPHEN_NUMBER, (v) => {
      const digits = v.replace(/\D/g, '').length;
      if (digits < 9 || digits > 16) return null;
      if (/^(?:19|20)\d{2}-\d{1,2}-\d{1,2}$/.test(v)) return null; // 날짜
      return ['account', v];
    });
    add(PLAIN_NUMBER, (v, s, e) => {
      const n = v.length;
      if (n >= 10 && n <= 14 && near(TRACKING_HINT, s, e, 30)) return ['tracking', v];
      if (n >= 10 && n <= 16 && near(BANK_HINT, s, e, 30)) return ['account', v];
      if (n >= 4 && n <= 8 && CODE_HINT.test(text)) return ['code', v];
      return null;
    });
    return found;
  };

  // ───── 표시 (DOM 은 바꾸지 않고 CSS Highlight 로만 칠한다) ─────
  const highlight = new Highlight();
  CSS.highlights.set(NAME, highlight);
  try {
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(
      '::highlight(' + NAME + '){text-decoration:underline dotted;text-decoration-thickness:2px;' +
      'text-underline-offset:3px;background-color:rgba(26,115,232,.14)}');
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  } catch (e) {}

  let entries = []; // { range, node, type, value }
  const scanned = new WeakMap(); // 말풍선 → 마지막으로 읽은 글

  const scanBubble = (el) => {
    const text = el.textContent || '';
    if (scanned.get(el) === text) return;
    scanned.set(el, text);
    entries = entries.filter((x) => {
      if (!el.contains(x.node)) return true;
      highlight.delete(x.range);
      return false;
    });
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let node; (node = walker.nextNode()); ) {
      if (node.parentElement && node.parentElement.closest('a')) continue; // 링크는 그대로 둔다
      for (const [s, e, type, value] of detect(node.data)) {
        const range = new Range();
        range.setStart(node, s);
        range.setEnd(node, e);
        highlight.add(range);
        entries.push({ range, node, type, value });
      }
    }
  };

  let scheduled = false;
  const scanAll = () => {
    scheduled = false;
    entries = entries.filter((x) => {
      if (x.node.isConnected) return true;
      highlight.delete(x.range);
      return false;
    });
    document.querySelectorAll('mws-text-message-part .text-msg-content').forEach(scanBubble);
  };
  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    setTimeout(scanAll, 300);
  };
  const start = () => {
    new MutationObserver(schedule).observe(document.body,
      { childList: true, subtree: true, characterData: true });
    schedule();
  };
  if (document.body) start();
  else document.addEventListener('DOMContentLoaded', start);

  // ───── 클릭하면 복사 ─────
  const entryAt = (x, y) => {
    for (const en of entries) {
      if (!en.node.isConnected) continue;
      for (const r of en.range.getClientRects()) {
        if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return en;
      }
    }
    return null;
  };

  let toastEl = null, toastTimer = 0;
  const toast = (message) => {
    if (!toastEl) {
      toastEl = document.createElement('div');
      const s = toastEl.style;
      s.position = 'fixed'; s.left = '50%'; s.bottom = '88px'; s.transform = 'translateX(-50%)';
      s.zIndex = '2147483647'; s.padding = '10px 18px'; s.borderRadius = '8px';
      s.background = 'rgba(32,33,36,.94)'; s.color = '#fff'; s.fontSize = '14px';
      s.boxShadow = '0 4px 14px rgba(0,0,0,.3)'; s.pointerEvents = 'none';
      s.transition = 'opacity .2s'; s.maxWidth = '80vw'; s.whiteSpace = 'nowrap';
      s.overflow = 'hidden'; s.textOverflow = 'ellipsis';
    }
    toastEl.textContent = message;
    if (!toastEl.isConnected) document.body.appendChild(toastEl);
    toastEl.style.opacity = '1';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toastEl.style.opacity = '0'; }, 1800);
  };

  const copy = (value) => {
    try {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('gmCopy', value);
        return;
      }
    } catch (e) {}
    try { navigator.clipboard.writeText(value); } catch (e) {}
  };

  document.addEventListener('click', (e) => {
    if (e.button !== 0 || !entries.length) return;
    const sel = window.getSelection();
    if (sel && !sel.isCollapsed) return; // 드래그로 글자를 선택한 경우
    const en = entryAt(e.clientX, e.clientY);
    if (!en) return;
    e.preventDefault();
    e.stopPropagation();
    copy(en.value);
    toast(LABEL[en.type] + ' 복사됨: ' + en.value);
  }, true);

  // 인식된 글자 위에서는 손가락 커서
  let hoverEl = null, moveQueued = false, lastX = 0, lastY = 0;
  document.addEventListener('mousemove', (e) => {
    lastX = e.clientX; lastY = e.clientY;
    if (moveQueued || !entries.length) return;
    moveQueued = true;
    requestAnimationFrame(() => {
      moveQueued = false;
      const en = entryAt(lastX, lastY);
      const el = en ? en.node.parentElement : null;
      if (hoverEl && hoverEl !== el) { hoverEl.style.cursor = ''; hoverEl.title = ''; }
      if (el) { el.style.cursor = 'pointer'; el.title = LABEL[en.type] + ' 복사'; }
      hoverEl = el;
    });
  }, true);

  // ───── 이미지 라이브 텍스트 ─────
  // 말풍선 이미지를 앱(Windows 내장 OCR)에 보내 글자를 읽고, 이미지 위에 투명한 글자 층을 겹친다.
  //   - 글자는 드래그로 선택해 복사할 수 있다
  //   - 전화번호·계좌번호 등은 파랗게 표시되고 클릭하면 복사된다
  const IMG_SELECTOR = 'mws-image img';
  const ocrCache = new Map();      // 이미지 주소 → OCR 결과 (없으면 null)
  const layers = new WeakMap();    // img → 겹쳐 놓은 층
  const queued = new WeakSet();
  const ocrQueue = [];
  let ocrBusy = false;

  const hasOcr = () => !!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler);

  try {
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(
      '.gm-ocr-layer{position:absolute;overflow:hidden;container-type:size;z-index:1;pointer-events:none}' +
      '.gm-ocr-line{position:absolute;white-space:pre;color:transparent;line-height:1;cursor:text;' +
      'user-select:text;-webkit-user-select:text;pointer-events:auto;transform-origin:0 0;' +
      'font-family:"Malgun Gothic","Segoe UI",sans-serif}' +
      '.gm-ocr-line::selection{background:rgba(26,115,232,.4);color:transparent}' +
      '.gm-ocr-hit{position:absolute;pointer-events:auto;cursor:pointer;border-radius:3px;' +
      'background:rgba(26,115,232,.25);box-shadow:0 0 0 1px rgba(26,115,232,.75)}' +
      '.gm-ocr-hit:hover{background:rgba(26,115,232,.45)}');
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  } catch (e) {}

  // 이미지를 OCR 에 알맞은 크기의 PNG/JPEG 로 바꾼다
  const encodeImage = (img) => {
    const nw = img.naturalWidth, nh = img.naturalHeight;
    if (nw < 40 || nh < 20) return null;
    let scale = 1;
    const longSide = Math.max(nw, nh);
    if (longSide > 2400) scale = 2400 / longSide;
    else if (longSide < 900) scale = Math.min(2, 1200 / longSide); // 작은 이미지는 키워야 잘 읽힌다
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(nw * scale);
    canvas.height = Math.round(nh * scale);
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    return canvas.width * canvas.height > 1500000
      ? canvas.toDataURL('image/jpeg', 0.92)
      : canvas.toDataURL('image/png');
  };

  // 줄의 단어들을 이어 붙인 글과, 글자 위치 → 단어 대응표를 만든다.
  // OCR 이 "123 - 45" 처럼 하이픈 둘레를 띄어 읽은 경우는 붙인다.
  const joinWords = (words) => {
    let text = '';
    const spans = [];
    words.forEach((w, i) => {
      if (i > 0) {
        const prev = words[i - 1].t;
        const glue = /-$/.test(prev) || /^-/.test(w.t);
        if (!glue) text += ' ';
      }
      spans.push([text.length, text.length + w.t.length, w]);
      text += w.t;
    });
    return { text, spans };
  };

  const pct = (v, total) => (v / total * 100) + '%';

  const buildLayer = (img, result) => {
    const layer = document.createElement('div');
    layer.className = 'gm-ocr-layer';
    const W = result.w, H = result.h;
    for (const line of result.lines) {
      const words = line.words || [];
      if (!words.length) continue;
      const x0 = Math.min(...words.map((w) => w.x)), y0 = Math.min(...words.map((w) => w.y));
      const x1 = Math.max(...words.map((w) => w.x + w.w)), y1 = Math.max(...words.map((w) => w.y + w.h));
      const { text, spans } = joinWords(words);

      const el = document.createElement('span');
      el.className = 'gm-ocr-line';
      el.textContent = text;
      el.style.left = pct(x0, W);
      el.style.top = pct(y0, H);
      el.style.fontSize = ((y1 - y0) / H * 100) + 'cqh';
      el.dataset.w = String((x1 - x0) / W); // 층 너비에 대한 비율: 나중에 가로로 맞춘다
      layer.appendChild(el);

      for (const [s, e, type, value] of detect(text)) {
        const hitWords = spans.filter((sp) => sp[0] < e && sp[1] > s).map((sp) => sp[2]);
        if (!hitWords.length) continue;
        const hx0 = Math.min(...hitWords.map((w) => w.x)), hy0 = Math.min(...hitWords.map((w) => w.y));
        const hx1 = Math.max(...hitWords.map((w) => w.x + w.w)), hy1 = Math.max(...hitWords.map((w) => w.y + w.h));
        const hit = document.createElement('div');
        hit.className = 'gm-ocr-hit';
        hit.style.left = pct(hx0, W);
        hit.style.top = pct(hy0, H);
        hit.style.width = pct(hx1 - hx0, W);
        hit.style.height = pct(hy1 - hy0, H);
        hit.title = LABEL[type] + ' 복사';
        hit.dataset.type = type;
        hit.dataset.value = value;
        layer.appendChild(hit);
      }
    }
    return layer;
  };

  // 층을 이미지 상자에 맞추고, 각 줄의 글자 너비를 실제 글자 너비에 맞춘다
  const fitLayer = (img, layer) => {
    layer.style.left = img.offsetLeft + 'px';
    layer.style.top = img.offsetTop + 'px';
    layer.style.width = img.offsetWidth + 'px';
    layer.style.height = img.offsetHeight + 'px';
    const lw = img.offsetWidth;
    if (!lw) return;
    for (const el of layer.querySelectorAll('.gm-ocr-line')) {
      el.style.transform = '';
      const natural = el.offsetWidth; // 배치 크기 (확대 배율과 무관)
      const want = Number(el.dataset.w) * lw;
      if (natural > 0 && want > 0) el.style.transform = 'scaleX(' + (want / natural) + ')';
    }
  };

  const resizeObserver = new ResizeObserver((list) => {
    for (const item of list) {
      const layer = layers.get(item.target);
      if (layer && layer.isConnected) fitLayer(item.target, layer);
    }
  });

  const attach = (img, result) => {
    const old = layers.get(img);
    if (old) old.remove();
    if (!result || !result.lines || !result.lines.length || !img.parentElement) return;
    const layer = buildLayer(img, result);
    img.parentElement.appendChild(layer);
    layers.set(img, layer);
    fitLayer(img, layer);
    resizeObserver.observe(img);
  };

  const pumpOcr = async () => {
    if (ocrBusy) return;
    ocrBusy = true;
    while (ocrQueue.length) {
      const img = ocrQueue.shift();
      if (!img.isConnected) { queued.delete(img); continue; }
      const key = img.currentSrc || img.src;
      let result = null;
      try {
        const data = encodeImage(img);
        if (data) result = await window.flutter_inappwebview.callHandler('gmOcr', data);
      } catch (e) {}
      if (!result || !result.ok) result = null;
      if (ocrCache.size > 300) ocrCache.clear();
      ocrCache.set(key, result);
      queued.delete(img);
      if (img.isConnected && (img.currentSrc || img.src) === key) attach(img, result);
    }
    ocrBusy = false;
  };

  const considerImage = (img) => {
    if (!img.__gmLoadHooked) {
      img.__gmLoadHooked = true; // 로딩이 끝나거나 더 큰 이미지로 바뀌면 다시 본다
      img.addEventListener('load', () => considerImage(img));
    }
    if (!img.complete || !img.naturalWidth) return;
    // 확대 보기(원본 크기)에서는 항상 읽는다. 대화 안의 작은 미리보기는 글씨가 뭉개져
    // 잘못 읽히므로, 충분히 큰 이미지일 때만 읽는다.
    const inViewer = !!img.closest('mws-lightbox');
    if (!inViewer && Math.max(img.naturalWidth, img.naturalHeight) < 600) return;
    const layer = layers.get(img);
    if (layer && layer.isConnected) return;
    const key = img.currentSrc || img.src;
    if (ocrCache.has(key)) {
      attach(img, ocrCache.get(key)); // 화면이 다시 그려져 층이 사라진 경우
      return;
    }
    if (queued.has(img)) return;
    queued.add(img);
    // 원본이 다 내려와 그려질 때까지 기다린다. 그사이 더 큰 이미지로 바뀌면 그때 다시 온다.
    const settle = async () => {
      try { if (img.decode) await img.decode(); } catch (e) {}
      await new Promise((r) => setTimeout(r, 400));
      if (!img.isConnected || !img.complete || (img.currentSrc || img.src) !== key) {
        queued.delete(img);
        if (img.isConnected) considerImage(img);
        return;
      }
      if (inViewer) ocrQueue.unshift(img); // 지금 보고 있는 이미지를 먼저
      else ocrQueue.push(img);
      pumpOcr();
    };
    settle();
  };

  // 화면에 보이는 이미지만 읽는다
  const visibility = new IntersectionObserver((list) => {
    for (const item of list) {
      if (item.isIntersecting) considerImage(item.target);
    }
  }, { rootMargin: '200px' });

  const scanImages = () => {
    if (!hasOcr()) return;
    document.querySelectorAll(IMG_SELECTOR).forEach((img) => {
      visibility.observe(img);
      // 이미 본 이미지인데 층만 사라졌으면 바로 다시 붙인다
      const key = img.currentSrc || img.src;
      const layer = layers.get(img);
      if (ocrCache.get(key) && !(layer && layer.isConnected) && img.complete) attach(img, ocrCache.get(key));
    });
  };
  const startImages = () => {
    let pending = false;
    new MutationObserver(() => {
      if (pending) return;
      pending = true;
      setTimeout(() => { pending = false; scanImages(); scanViewer(); }, 400);
    }).observe(document.body, { childList: true, subtree: true });
    scanImages();
  };
  if (document.body) startImages();
  else document.addEventListener('DOMContentLoaded', startImages);

  // 층 위 클릭: 인식된 항목이면 복사, 그냥 글자면 (선택 중이 아닐 때) 이미지 클릭으로 넘긴다
  document.addEventListener('click', (e) => {
    const t = e.target;
    if (!t || !t.closest) return;
    const hit = t.closest('.gm-ocr-hit');
    if (hit) {
      e.preventDefault();
      e.stopPropagation();
      copy(hit.dataset.value);
      toast(LABEL[hit.dataset.type] + ' 복사됨: ' + hit.dataset.value);
      return;
    }
    const line = t.closest('.gm-ocr-line');
    if (!line) return;
    e.preventDefault();
    e.stopPropagation();
    const sel = window.getSelection();
    if (sel && !sel.isCollapsed) return;
    const img = line.parentElement.parentElement.querySelector(IMG_SELECTOR);
    if (img) img.click();
  }, true);

  // ───── 이미지 확대 보기: 확대·축소·이동 ─────
  //   휠: 마우스 위치를 중심으로 확대/축소      더블클릭: 2.5배 ↔ 원래 크기
  //   끌기: 확대한 상태에서 이동               키보드: + / - / 0
  const MIN_ZOOM = 1, MAX_ZOOM = 8;
  const zoomStates = new WeakMap(); // mws-lightbox → 상태

  const setupZoom = (box) => {
    if (zoomStates.has(box)) return;
    const content = box.querySelector('mat-dialog-content');
    if (!content) return;
    const st = { scale: 1, tx: 0, ty: 0, src: '', label: null, drag: null, dragged: false };
    zoomStates.set(box, st);
    content.style.overflow = 'hidden';

    const target = () => box.querySelector('mat-dialog-content mws-image');
    const apply = () => {
      const el = target();
      if (!el) return;
      el.style.position = 'relative';
      el.style.transformOrigin = '50% 50%';
      el.style.transform = st.scale === 1 ? '' : 'translate(' + st.tx + 'px,' + st.ty + 'px) scale(' + st.scale + ')';
      el.style.cursor = st.scale > 1 ? (st.drag ? 'grabbing' : 'grab') : '';
      if (st.label) st.label.textContent = Math.round(st.scale * 100) + '%';
    };
    // (cx, cy) 화면 좌표를 고정점으로 삼아 배율을 바꾼다
    const zoomTo = (scale, cx, cy) => {
      const el = target();
      if (!el) return;
      scale = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, scale));
      if (scale === st.scale) return;
      if (scale === 1) {
        st.tx = 0; st.ty = 0;
      } else {
        const r = el.getBoundingClientRect();
        const centerX = r.left + r.width / 2, centerY = r.top + r.height / 2;
        if (cx === undefined) { cx = centerX; cy = centerY; }
        const k = scale / st.scale;
        st.tx += (cx - centerX) * (1 - k);
        st.ty += (cy - centerY) * (1 - k);
      }
      st.scale = scale;
      apply();
    };
    const reset = () => { st.scale = 1; st.tx = 0; st.ty = 0; apply(); };
    st.reset = reset;

    content.addEventListener('wheel', (e) => {
      e.preventDefault();
      zoomTo(st.scale * Math.exp(-e.deltaY * 0.0015), e.clientX, e.clientY);
    }, { passive: false });

    content.addEventListener('dblclick', (e) => {
      if (e.target.closest && e.target.closest('.gm-ocr-line, .gm-ocr-hit')) return;
      e.preventDefault();
      e.stopPropagation();
      if (st.scale > 1) reset();
      else zoomTo(2.5, e.clientX, e.clientY);
    }, true);

    // 끌어서 이동 (글자 층 위에서는 글자 선택이 우선)
    content.addEventListener('pointerdown', (e) => {
      if (e.button !== 0 || st.scale <= 1) return;
      if (e.target.closest && e.target.closest('.gm-ocr-line, .gm-ocr-hit, button')) return;
      st.drag = { x: e.clientX, y: e.clientY, tx: st.tx, ty: st.ty };
      st.dragged = false;
      content.setPointerCapture(e.pointerId);
      e.preventDefault();
      apply();
    });
    content.addEventListener('pointermove', (e) => {
      if (!st.drag) return;
      const dx = e.clientX - st.drag.x, dy = e.clientY - st.drag.y;
      if (Math.abs(dx) + Math.abs(dy) > 3) st.dragged = true;
      st.tx = st.drag.tx + dx;
      st.ty = st.drag.ty + dy;
      apply();
    });
    const endDrag = (e) => {
      if (!st.drag) return;
      st.drag = null;
      try { content.releasePointerCapture(e.pointerId); } catch (err) {}
      apply();
    };
    content.addEventListener('pointerup', endDrag);
    content.addEventListener('pointercancel', endDrag);
    // 끌고 난 직후의 클릭은 삼킨다
    content.addEventListener('click', (e) => {
      if (!st.dragged) return;
      st.dragged = false;
      e.preventDefault();
      e.stopPropagation();
    }, true);

    // 아래쪽 가운데의 − 100% + 단추
    const bar = document.createElement('div');
    bar.className = 'gm-zoom-bar';
    const s = bar.style;
    s.position = 'absolute'; s.left = '50%'; s.bottom = '20px'; s.transform = 'translateX(-50%)';
    s.zIndex = '5'; s.display = 'flex'; s.alignItems = 'center'; s.gap = '2px'; s.padding = '4px';
    s.borderRadius = '22px'; s.background = 'rgba(32,33,36,.82)'; s.color = '#fff';
    s.boxShadow = '0 2px 10px rgba(0,0,0,.35)'; s.userSelect = 'none'; s.fontSize = '13px';
    const button = (text, title, onClick, wide) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.textContent = text;
      b.title = title;
      const bs = b.style;
      bs.minWidth = wide ? '58px' : '34px'; bs.height = '34px'; bs.border = '0'; bs.borderRadius = '17px';
      bs.background = 'transparent'; bs.color = 'inherit'; bs.cursor = 'pointer';
      bs.fontSize = wide ? '13px' : '20px'; bs.lineHeight = '1';
      b.addEventListener('mouseenter', () => { bs.background = 'rgba(255,255,255,.16)'; });
      b.addEventListener('mouseleave', () => { bs.background = 'transparent'; });
      b.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); onClick(); });
      bar.appendChild(b);
      return b;
    };
    button('−', '축소 (-)', () => zoomTo(st.scale / 1.5));
    st.label = button('100%', '원래 크기 (0)', reset, true);
    button('+', '확대 (+)', () => zoomTo(st.scale * 1.5));
    const host = box.querySelector('.lightbox-main') || box;
    if (getComputedStyle(host).position === 'static') host.style.position = 'relative';
    host.appendChild(bar);

    st.zoomBy = (factor) => zoomTo(st.scale * factor);
  };

  // 확대 보기가 열려 있을 때의 키보드
  document.addEventListener('keydown', (e) => {
    if (e.ctrlKey || e.altKey || e.metaKey) return;
    const box = document.querySelector('mws-lightbox');
    const st = box && zoomStates.get(box);
    if (!st) return;
    if (e.key === '+' || e.key === '=') st.zoomBy(1.5);
    else if (e.key === '-' || e.key === '_') st.zoomBy(1 / 1.5);
    else if (e.key === '0') st.reset();
    else return;
    e.preventDefault();
    e.stopPropagation();
  }, true);

  // 확대 보기가 새로 열리거나 다른 이미지로 바뀌면 준비/초기화한다
  const scanViewer = () => {
    const box = document.querySelector('mws-lightbox');
    if (!box) return;
    setupZoom(box);
    const st = zoomStates.get(box);
    const img = box.querySelector('mat-dialog-content mws-image img');
    const src = img ? (img.currentSrc || img.src) : '';
    if (st && st.src !== src) {
      st.src = src;
      st.reset();
    }
  };

  window.__gmLiveTextDebug = {
    detect,
    count: () => entries.length,
    types: () => entries.map((x) => x.type),
    images: () => ({ cached: ocrCache.size, queued: ocrQueue.length }),
    zoom: () => { const b = document.querySelector('mws-lightbox'); const z = b && zoomStates.get(b); return z ? { scale: z.scale, tx: z.tx, ty: z.ty } : null; },
  };
})();
