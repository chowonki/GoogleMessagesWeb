// 웹페이지의 알림을 OS 알림으로 넘긴다.
// WebView 는 웹 알림을 직접 띄우지 못하므로 Notification API 를 앱 쪽으로 연결한다.
(() => {
  if (window.__gmWebBridge) return;
  window.__gmWebBridge = true;
  const send = (title, opts) => {
    try {
      window.flutter_inappwebview.callHandler(
        'gmNotify', String(title || ''), String((opts && opts.body) || ''));
    } catch (e) {}
  };
  class GMNotification extends EventTarget {
    constructor(title, opts) {
      super();
      this.title = title;
      this.body = (opts && opts.body) || '';
      this.tag = (opts && opts.tag) || '';
      this.data = opts && opts.data;
      this.onclick = null;
      this.onclose = null;
      this.onerror = null;
      this.onshow = null;
      window.__gmLastNotification = this;
      send(title, opts);
    }
    close() {}
    static get permission() { return 'granted'; }
    static requestPermission(cb) {
      if (typeof cb === 'function') cb('granted');
      return Promise.resolve('granted');
    }
  }
  window.Notification = GMNotification;
  if (window.ServiceWorkerRegistration) {
    ServiceWorkerRegistration.prototype.showNotification = function (title, opts) {
      send(title, opts);
      return Promise.resolve();
    };
  }
  if (navigator.permissions && navigator.permissions.query) {
    const query = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = (d) =>
      d && d.name === 'notifications'
        ? Promise.resolve({
            state: 'granted', onchange: null,
            addEventListener() {}, removeEventListener() {},
          })
        : query(d);
  }
  // 알림을 클릭했을 때 앱이 호출: 웹페이지가 해당 대화를 열게 한다
  window.__gmNotificationClicked = () => {
    const n = window.__gmLastNotification;
    if (!n) return;
    const ev = new Event('click');
    if (typeof n.onclick === 'function') n.onclick(ev);
    n.dispatchEvent(ev);
  };
})();
