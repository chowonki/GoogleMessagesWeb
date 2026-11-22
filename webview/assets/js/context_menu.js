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

  const OVERLAY = '.cdk-overlay-container';
  const openPanel = () => document.querySelector(OVERLAY + ' .mat-mdc-menu-panel');

  // 열린 메뉴가 든 overlay 덩어리 (overlay 컨테이너 바로 아래 자식)
  const menuHost = () => {
    let el = openPanel();
    while (el && el.parentElement && !el.parentElement.matches(OVERLAY)) el = el.parentElement;
    return el;
  };

  // 메뉴의 투명한 막(backdrop). overlay 덩어리 바로 앞에 놓인다.
  // 대화상자 위에 메뉴가 뜬 경우 대화상자의 어두운 막도 있으므로, 첫 번째 막이 아니라 이것을 고른다.
  const menuBackdrop = () => {
    const host = menuHost();
    const prev = host && host.previousElementSibling;
    return prev && prev.classList.contains('cdk-overlay-backdrop') ? prev : null;
  };

  // 메뉴가 열려 있으면 화면 전체를 메뉴의 막이 덮는다. 그 아래의 실제 항목을 찾는다.
  // (대화상자가 열려 있으면 대화상자 안의 항목이 찾아진다)
  const targetUnder = (x, y) => {
    const host = menuHost(), backdrop = menuBackdrop();
    return document.elementsFromPoint(x, y).find((el) =>
      el !== backdrop && !(host && host.contains(el)) && !el.matches(OVERLAY)) || null;
  };

  // 열린 메뉴를 닫는다 (막을 누른 것과 같다). 닫히는 움직임이 끝나 메뉴가 사라지면 [then] 을 부른다.
  const closeMenuThen = (then) => {
    const backdrop = menuBackdrop();
    if (backdrop) backdrop.click();
    else document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27, bubbles: true }));
    let tries = 0;
    const wait = () => {
      if (!openPanel() || ++tries > 40) then();
      else requestAnimationFrame(wait);
    };
    requestAnimationFrame(wait);
  };

  document.addEventListener('contextmenu', (e) => {
    let target = e.target;
    if (!target || !target.closest) return;
    const x = e.clientX, y = e.clientY;
    const menuOpen = !!openPanel();
    if (target.closest(OVERLAY)) {
      // 열린 메뉴 위에서의 우클릭은 아무것도 하지 않는다
      if (target.closest('.mat-mdc-menu-panel') || !menuOpen) {
        if (menuOpen) e.preventDefault();
        return;
      }
      target = targetUnder(x, y);
      if (!target) return;
    }
    // 글자를 선택해 둔 상태면 기본 메뉴(복사)를 그대로 쓴다
    const sel = window.getSelection();
    if (!menuOpen && sel && !sel.isCollapsed && String(sel).trim()) return;
    const found = findMenuButton(target);
    if (!found) {
      // 메뉴가 열린 채로 메뉴가 없는 곳을 우클릭하면 열린 메뉴만 닫는다
      if (menuOpen) {
        e.preventDefault();
        closeMenuThen(() => {});
      }
      return;
    }
    e.preventDefault();
    e.stopPropagation();
    const open = () => {
      const button = found.host.querySelector(found.selector);
      if (!button) return false;
      button.click();
      placeMenuAt(x, y);
      return true;
    };
    const start = () => {
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
    };
    // 다른 항목의 메뉴가 열려 있으면 먼저 닫고 연다
    if (menuOpen) closeMenuThen(start);
    else start();
  }, true);
})();
