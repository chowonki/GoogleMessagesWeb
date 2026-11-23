// 저장된 연락처는 이름만 보이므로, 이름 바로 아래에 전화번호를 함께 적는다.
// (대화 목록과 열어 둔 대화의 머리말)
// 번호는 Google 메시지가 이 컴퓨터에 저장해 두는 연락처 캐시(IndexedDB)에서 읽는다.
// 페이지가 아직 캐시에 넣지 않은 연락처는 번호를 알 수 없어 표시하지 않는다.
(() => {
  if (window.top !== window || window.__gmContactNumber) return;
  window.__gmContactNumber = true;
  if (location.hostname !== 'messages.google.com') return;
  if (!window.indexedDB || !indexedDB.databases) return;

  const CLASS = 'gm-contact-number';
  const RELOAD_MS = 20000;

  /** 저장된 이름 → 전화번호들 */
  let numbers = new Map();

  // ───── 연락처 캐시 읽기 ─────
  // 값은 protobuf: 2번(안의 2·3번)이 번호, 3번이 저장된 이름. 키도 번호다.
  const readFields = (bytes) => {
    const fields = [];
    let i = 0;
    const varint = () => {
      let value = 0, shift = 0;
      for (;;) {
        if (i >= bytes.length) throw new Error('truncated');
        const b = bytes[i++];
        value += (b & 127) * 2 ** shift;
        shift += 7;
        if (b < 128) return value;
      }
    };
    while (i < bytes.length) {
      const tag = varint();
      const wire = tag & 7;
      if (wire === 0) varint();
      else if (wire === 1) i += 8;
      else if (wire === 5) i += 4;
      else if (wire === 2) {
        const length = varint();
        if (i + length > bytes.length) throw new Error('truncated');
        fields.push([Math.floor(tag / 8), bytes.subarray(i, i + length)]);
        i += length;
      } else throw new Error('wire type');
    }
    return fields;
  };

  const isPhone = (s) => /^\+?[\d\s\-()]{5,}$/.test(s);

  // +821012345678 → 010-1234-5678 (한국 번호만 다듬고, 나머지는 그대로)
  const format = (number) => {
    const digits = number.replace(/[^\d+]/g, '');
    let local;
    if (digits.startsWith('+82')) local = '0' + digits.slice(3);
    else if (/^0\d+$/.test(digits)) local = digits;
    else return number;
    const m = local.match(/^(02)(\d{3,4})(\d{4})$/) ||
      local.match(/^(0\d{2})(\d{3,4})(\d{4})$/);
    return m ? m.slice(1).join('-') : local;
  };

  const readStore = (name) => new Promise((resolve) => {
    const rows = [];
    const done = () => resolve(rows);
    const open = indexedDB.open(name);
    open.onerror = done;
    // 페이지가 아직 만들지 않은 저장소를 우리가 만들어 버리지 않는다
    open.onupgradeneeded = () => open.transaction.abort();
    open.onsuccess = () => {
      const db = open.result;
      try {
        const cursor = db.transaction('objectstore').objectStore('objectstore').openCursor();
        cursor.onerror = () => { db.close(); done(); };
        cursor.onsuccess = () => {
          const c = cursor.result;
          if (!c) { db.close(); return done(); }
          rows.push([c.key, c.value && c.value.value]);
          c.continue();
        };
      } catch (e) {
        db.close();
        done();
      }
    };
  });

  const load = async () => {
    const found = new Map();
    const utf8 = new TextDecoder();
    for (const info of await indexedDB.databases()) {
      if (!/ContactCache$/.test(info.name || '')) continue;
      for (const [key, value] of await readStore(info.name)) {
        if (typeof key !== 'string' || !isPhone(key) || !(value instanceof Uint8Array)) continue;
        try {
          const name = readFields(value).find(([field]) => field === 3);
          if (!name) continue;
          const text = utf8.decode(name[1]).trim();
          if (!text || isPhone(text)) continue; // 이름이 곧 번호면 저장된 연락처가 아니다
          const list = found.get(text) || [];
          const number = format(key);
          if (!list.includes(number)) list.push(number);
          found.set(text, list);
        } catch (e) {
          // 형식이 바뀐 항목은 건너뛴다
        }
      }
    }
    numbers = found;
    schedule();
  };

  // ───── 화면에 적기 ─────
  // anchor 바로 다음에 번호 한 줄을 둔다. text 가 없으면 지운다.
  const put = (anchor, name) => {
    if (!anchor) return;
    const text = numberFor(name);
    const next = anchor.nextElementSibling;
    let line = next && next.classList.contains(CLASS) ? next : null;
    if (!text) {
      if (line) line.remove();
      return;
    }
    if (!line) {
      line = document.createElement('div');
      line.className = CLASS;
      anchor.after(line);
    }
    if (line.textContent !== text) line.textContent = text;
    const color = getComputedStyle(name).color;
    if (line.style.color !== color) line.style.color = color;
  };

  const numberFor = (el) => {
    const list = el && numbers.get(el.textContent.trim());
    return list ? list.join(', ') : '';
  };

  const apply = () => {
    for (const item of document.querySelectorAll('mws-conversation-list-item')) {
      put(item.querySelector('h2.name'),
        item.querySelector('[data-e2e-conversation-name]'));
    }
    const title = document.querySelector('mws-header [data-e2e-header-title]');
    if (title) put(title, title.querySelector('h2'));
  };

  // 화면은 글자를 칠 때마다도 바뀐다: 바뀔 때마다가 아니라 잠깐 모아서 한 번만 다시 적는다
  let queued = false;
  const schedule = () => {
    if (queued) return;
    queued = true;
    setTimeout(() => {
      queued = false;
      if (!document.hidden) apply();
    }, 120);
  };

  const start = () => {
    const style = document.createElement('style');
    style.textContent =
      `.${CLASS} { font-family: "Google Sans", Roboto, "Helvetica Neue", "Apple SD Gothic Neo", ` +
      '"Malgun Gothic", sans-serif; font-size: 12px; line-height: 16px; font-weight: 400; ' +
      'letter-spacing: 0.1px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }';
    document.head.appendChild(style);
    // 목록은 계속 다시 그려진다(같은 칸이 다른 대화로 바뀌기도 한다)
    new MutationObserver((changes) => {
      if (changes.some(({ target }) => !target.parentElement?.closest('.' + CLASS) &&
          !target.classList?.contains(CLASS))) schedule();
    }).observe(document.documentElement, {
      childList: true, subtree: true, characterData: true, attributes: true,
      attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode', 'color-scheme'],
    });
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', schedule);
    load();
    setInterval(() => { if (!document.hidden) load(); }, RELOAD_MS);
    document.addEventListener('visibilitychange', schedule);
  };

  if (document.body) start();
  else document.addEventListener('DOMContentLoaded', start);
})();
