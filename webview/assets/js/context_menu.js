// 메뉴(⋮)가 있는 항목 — 대화 목록, 말풍선, 대화 상단 막대 등 — 을 오른쪽 클릭하면
// 그 항목의 메뉴를 마우스 위치에 연다.
(() => {
  if (window.__gmContextMenu) return;
  window.__gmContextMenu = true;

  // 우클릭한 곳에 해당하는 메뉴 단추(⋮ 등)를 찾는다
  const RULES = [
    ['mws-conversation-list-item', 'button[data-e2e-conversation-list-item-menu]'], // 대화 목록 항목
    ['.msg-part-with-menu', 'button[data-e2e-message-action-menu]'],                // 말풍선
    ['mw-conversation-header', 'button[data-e2e-conversation-menu-button]'],        // 대화 상단 막대
  ];
  const MENU_BUTTON = 'button[aria-haspopup="menu"], button.mat-mdc-menu-trigger';
  const findMenuButton = (target) => {
    // 입력창에서는 기본 메뉴(붙여넣기 등)를 그대로 쓴다
    if (target.closest('input, textarea, [contenteditable=""], [contenteditable="true"], mws-message-compose')) return null;
    for (const [hostSel, selector] of RULES) {
      const host = target.closest(hostSel);
      if (host) return { host, selector };
    }
    // 그 밖의 항목: 가까운 상위 요소(한 줄 크기) 안에 메뉴 단추가 하나뿐이면 그것을 연다
    let el = target;
    for (let depth = 0; el && el !== document.body && depth < 5; depth++, el = el.parentElement) {
      const buttons = el.querySelectorAll(MENU_BUTTON);
      // 큰 영역(메시지 목록 전체 등)의 빈 곳에서는 열지 않는다: 한 줄짜리 항목만 대상
      if (el.getBoundingClientRect().height > 120) break;
      if (buttons.length === 1) return { host: el, selector: MENU_BUTTON };
      if (buttons.length > 1) break;
    }
    return null;
  };

  // 메뉴는 원래 ⋮ 단추 옆에 뜬다. 마우스 위치로 옮긴다.
  const placeMenuAt = (x, y) => {
    let tries = 0;
    const place = () => {
      const panel = document.querySelector('.cdk-overlay-pane .mat-mdc-menu-panel');
      const pane = panel && panel.closest('.cdk-overlay-pane');
      if (!pane) {
        if (++tries < 20) requestAnimationFrame(place);
        return;
      }
      const r = pane.getBoundingClientRect();
      const left = Math.max(4, Math.min(x, window.innerWidth - r.width - 4));
      const top = Math.max(4, Math.min(y, window.innerHeight - r.height - 4));
      const set = (k, v) => pane.style.setProperty(k, v, 'important');
      set('position', 'fixed');
      set('left', left + 'px');
      set('top', top + 'px');
      set('right', 'auto');
      set('bottom', 'auto');
    };
    requestAnimationFrame(place);
  };

  document.addEventListener('contextmenu', (e) => {
    const target = e.target;
    if (!target || !target.closest) return;
    // 글자를 선택해 둔 상태면 기본 메뉴(복사)를 그대로 쓴다
    const sel = window.getSelection();
    if (sel && !sel.isCollapsed && String(sel).trim()) return;
    const found = findMenuButton(target);
    if (!found) return;
    e.preventDefault();
    e.stopPropagation();
    const x = e.clientX, y = e.clientY;
    const open = () => {
      const button = found.host.querySelector(found.selector);
      if (!button) return false;
      button.click();
      placeMenuAt(x, y);
      return true;
    };
    if (open()) return;
    // 말풍선의 ⋮ 단추는 마우스를 올려야 만들어진다
    for (const type of ['pointerenter', 'mouseenter', 'pointerover', 'mouseover', 'mousemove']) {
      target.dispatchEvent(new MouseEvent(type, { bubbles: true, clientX: x, clientY: y }));
    }
    let tries = 0;
    const retry = () => {
      if (!open() && ++tries < 15) requestAnimationFrame(retry);
    };
    requestAnimationFrame(retry);
  }, true);
})();
