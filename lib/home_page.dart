import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'drag_out.dart';
import 'fade_menu.dart';
import 'image_viewer.dart';
import 'link_preview.dart';
import 'models.dart';
import 'sound.dart';
import 'style.dart';
import 'store.dart';

Color _hexColor(String hex, Color fallback) {
  var h = hex.replaceAll('#', '');
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(v);
}

/// 트레이 메뉴 등 화면 밖에서 "새 메시지" 창을 띄울 때 쓴다
VoidCallback? openNewChat;

/// 지금 열려 있는 대화창 (단축키 전달용)
_ChatPaneState? _activeChat;

// ── Windows: 모든 입력 칸에서 Win+V(클립보드 기록) 붙여넣기 ──
// 메시지 입력창은 자체 처리(사진·파일 첨부 포함)하고, 그 밖의 칸(검색 등)은 여기서 맡는다.
Timer? _winVWatch;

EditableTextState? _focusedEditable() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorStateOfType<EditableTextState>();

/// 앱 전체 키 처리에서 부른다. 처리했으면 true.
bool handleGlobalPasteKeys(KeyEvent e) {
  if (!Platform.isWindows || e is! KeyDownEvent) return false;
  final chat = _activeChat;
  if (chat != null && chat._focus.hasFocus) return false;
  final k = e.logicalKey;
  final hk = HardwareKeyboard.instance;
  if (k == LogicalKeyboardKey.metaLeft || k == LogicalKeyboardKey.metaRight) {
    _armWinVWatch();
    return false;
  }
  // Win 키가 눌린 것으로 남아 있으면 기본 Ctrl+V 단축키가 동작하지 않으므로 직접 붙인다
  if (k == LogicalKeyboardKey.keyV &&
      hk.isControlPressed &&
      hk.isMetaPressed &&
      !hk.isShiftPressed &&
      !hk.isAltPressed) {
    final et = _focusedEditable();
    if (et != null) {
      _winVWatch?.cancel();
      et.pasteText(SelectionChangedCause.keyboard);
      return true;
    }
  }
  if (_winVWatch?.isActive == true &&
      k != LogicalKeyboardKey.keyV &&
      k != LogicalKeyboardKey.controlLeft &&
      k != LogicalKeyboardKey.controlRight) {
    _winVWatch?.cancel(); // 다른 키를 눌렀으면 Win+V 가 아니다
  }
  return false;
}

void _armWinVWatch() {
  _winVWatch?.cancel();
  final start = clipboardSequence();
  var ticks = 0;
  _winVWatch = Timer.periodic(const Duration(milliseconds: 120), (t) {
    if (++ticks > 125) {
      t.cancel(); // 15초쯤 지나면 그만둔다
      return;
    }
    if (clipboardSequence() == start) return;
    t.cancel();
    final et = _focusedEditable();
    if (et == null) return;
    final before = et.textEditingValue.text;
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      // 그 사이 이미 붙었거나(글이 바뀜) 다른 칸으로 옮겼으면 건드리지 않는다
      if (!et.mounted || _focusedEditable() != et) return;
      if (et.textEditingValue.text != before) return;
      et.pasteText(SelectionChangedCause.keyboard);
    });
  });
}
final FocusNode _searchFocus = FocusNode(debugLabel: 'conversation-search');

PopupMenuItem<String> _mi(String value, IconData icon, String label,
        {bool danger = false}) =>
    PopupMenuItem<String>(
      value: value,
      height: 40,
      child: Builder(builder: (context) {
        final c = Theme.of(context).colorScheme;
        final color = danger ? c.error : c.onSurface;
        return Row(
          children: [
            Icon(icon, size: 18, color: danger ? c.error : c.onSurfaceVariant),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontSize: 13.5, color: color)),
          ],
        );
      }),
    );


/// 대화 우클릭 메뉴 (대화 목록·대화창 헤더 공용)
Future<void> _conversationMenu(
    BuildContext context, AppState state, Conversation conv, Offset pos,
    {bool inChat = false}) async {
  final archived = conv.folder == 'archive';
  final peer = conv.peer;
  final number = peer != null
      ? (peer.formatted.isNotEmpty ? peer.formatted : peer.number)
      : '';
  final v = await showFadeMenu<String>(
    context: context,
    at: pos,
    items: [
      if (!inChat) _mi('open', Icons.chat_bubble_outline_rounded, '대화 열기'),
      if (inChat) _mi('search', Icons.search, '이 대화에서 검색'),
      if (conv.unread) _mi('read', Icons.done_all_rounded, '읽음으로 표시'),
      _mi('pin', state.isPinned(conv) ? Icons.push_pin : Icons.push_pin_outlined,
          state.isPinned(conv) ? '고정 해제' : '상단에 고정'),
      _mi(
          'mute',
          state.isMuted(conv.id)
              ? Icons.notifications_active_outlined
              : Icons.notifications_off_outlined,
          state.isMuted(conv.id) ? '알림 켜기' : '알림 끄기'),
      if (number.isNotEmpty) _mi('copyNumber', Icons.copy_rounded, '전화번호 복사'),
      if (conv.title.isNotEmpty && conv.title != number)
        _mi('copyName', Icons.badge_outlined, '이름 복사'),
      const PopupMenuDivider(),
      if (conv.folder != 'spam')
        _mi(archived ? 'unarchive' : 'archive',
            archived ? Icons.unarchive_outlined : Icons.archive_outlined,
            archived ? '보관 해제' : '보관'),
      _mi('delete', Icons.delete_outline_rounded, '대화 삭제', danger: true),
    ],
  );
  if (v == null || !context.mounted) return;
  switch (v) {
    case 'open':
      return state.select(conv.id);
    case 'search':
      return _activeChat?.toggleSearch();
    case 'read':
      return state.markRead(conv.id);
    case 'pin':
      return state.togglePin(conv.id);
    case 'mute':
      return state.toggleMute(conv.id);
    case 'copyNumber':
      await Clipboard.setData(ClipboardData(text: number));
      if (context.mounted) _toast(context, '전화번호를 복사했습니다');
      return;
    case 'copyName':
      await Clipboard.setData(ClipboardData(text: conv.title));
      if (context.mounted) _toast(context, '이름을 복사했습니다');
      return;
  }
  if (v == 'delete') {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('대화를 삭제할까요?'),
        content: Text('"${conv.title}" 대화가 휴대폰에서도 삭제됩니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true) return;
  }
  try {
    await state.updateConversation(conv.id, v);
  } catch (e) {
    if (context.mounted) _toast(context, '실패: $e');
  }
}

/// 헤더용 둥근 아이콘 버튼 — 크기·굵기·모양을 한 가지로 맞춘다.
class HeaderIcon extends StatefulWidget {
  const HeaderIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.filled = false,
    this.danger = false,
    this.box = 40,
    this.iconSize = 24,
    this.raised = false,
  });

  /// 새 메시지 버튼처럼 살짝 솟은 입체 버튼으로 그린다
  final bool raised;

  /// 닫기 버튼처럼 올렸을 때 빨갛게 표시
  final bool danger;
  final double box;
  final double iconSize;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  /// 켜진 상태(예: 대화창이 펼쳐져 있음)
  final bool active;

  /// 배경 위에 올릴 때(목록 헤더) 옅은 바탕을 깐다
  final bool filled;

  @override
  State<HeaderIcon> createState() => _HeaderIconState();
}

class _HeaderIconState extends State<HeaderIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final raised = widget.raised;
    final tab = widget.icon == kPanelIcon || widget.icon == kPanelOpenIcon;
    final icon = TweenAnimationBuilder<Color?>(
      duration: const Duration(milliseconds: 180),
      tween: ColorTween(
        end: widget.danger && _hover
            ? const Color(0xFFE5392D)
            : widget.active
                ? c.primary
                : raised
                    ? (_hover ? c.primary : c.onSurface.withValues(alpha: 0.9))
                    : (_hover
                        ? c.onSurface
                        : c.onSurface.withValues(alpha: 0.62)),
      ),
      builder: (_, color, __) => Icon(widget.icon,
          size: raised ? 23 : widget.iconSize,
          weight: raised ? 500 : 300,
          opticalSize: 24,
          color: color),
    );
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: !raised
              // 평면: 바탕 없이 아이콘 색만 살짝 진해진다 (창 제어 버튼)
              ? SizedBox(width: widget.box, height: widget.box, child: icon)
              // 헤더 버튼: 바탕 없는 선 아이콘. 접기/펼치기만 창 가장자리에 붙은 작은 탭
              : tab
                  ? AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 24,
                      height: 38,
                      margin: const EdgeInsets.only(left: 6),
                      decoration: BoxDecoration(
                        color: c.onSurface
                            .withValues(alpha: _hover ? 0.09 : 0.045),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                            color: c.onSurface.withValues(alpha: 0.07)),
                      ),
                      child: Center(child: icon),
                    )
                  : SizedBox(width: 38, height: 38, child: icon),
        ),
      ),
    );
  }
}

/// 대화창 접기/펼치기 아이콘: 단순한 > (펼치기) 와 < (접기)
const IconData kPanelIcon = Symbols.chevron_right;
const IconData kPanelOpenIcon = Symbols.chevron_left;

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.state,
    required this.onSettings,
    required this.onQuit,
  });
  final AppState state;
  final VoidCallback onSettings;
  final VoidCallback onQuit;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppState get state => widget.state;
  VoidCallback get onSettings => widget.onSettings;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    openNewChat = () {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) _newChat();
    };
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    openNewChat = null;
    super.dispose();
  }

  void _newChat() {
    showDialog<void>(
        context: context, builder: (_) => _NewChatDialog(state: state));
  }

  /// 화면이 바뀔 때 페이드로 전환
  Widget _fade(String key, Widget child) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 190),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: KeyedSubtree(key: ValueKey(key), child: child),
      );

  /// 전역 단축키 (대화상자가 떠 있을 때는 동작하지 않음)
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final hk = HardwareKeyboard.instance;
    final mod = Platform.isMacOS ? hk.isMetaPressed : hk.isControlPressed;
    final k = e.logicalKey;

    if (k == LogicalKeyboardKey.escape) {
      if (_activeChat?.escape() ?? false) return true;
      if (_searchFocus.hasFocus) {
        _searchFocus.unfocus();
        return true;
      }
      if (state.selectedId != null) {
        state.select(null);
        return true;
      }
      return false;
    }
    final up = k == LogicalKeyboardKey.arrowUp;
    final down = k == LogicalKeyboardKey.arrowDown;
    if ((up || down) && (mod || hk.isAltPressed)) {
      state.moveSelection(up ? -1 : 1);
      return true;
    }
    if (!mod) return false;
    if (k == LogicalKeyboardKey.keyL && state.lockEnabled) {
      state.lockNow();
    } else if (k == LogicalKeyboardKey.backslash) {
      state.toggleChat();
    } else if (k == LogicalKeyboardKey.keyN) {
      _newChat();
    } else if (k == LogicalKeyboardKey.keyF && hk.isShiftPressed) {
      _activeChat?.toggleSearch();
    } else if (k == LogicalKeyboardKey.keyF || k == LogicalKeyboardKey.keyK) {
      _searchFocus.requestFocus();
    } else if (k == LogicalKeyboardKey.keyO) {
      _activeChat?.pickFile();
    } else if (k == LogicalKeyboardKey.comma) {
      onSettings();
    } else if (k == LogicalKeyboardKey.keyW) {
      windowManager.close();
    } else if (k == LogicalKeyboardKey.keyQ) {
      widget.onQuit();
    } else {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    Widget panel(Widget child) => Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(oneUi ? 26 : 18),
          ),
          child: child,
        );
    return LayoutBuilder(builder: (context, box) {
      // 대화를 열었거나 창이 충분히 넓으면 대화창을 함께 보여 준다.
      final wide = box.maxWidth >= kListWindowWidth + 260;
      final showChat = wide;
      // 접힌(좁은) 창: 대화를 고르면 같은 창에서 대화창으로 바뀐다 (뒤로 가기로 목록)
      if (!wide && state.selected != null) {
        return _fade('chat', Padding(
          padding: oneUi
              ? const EdgeInsets.fromLTRB(12, 0, 12, 12)
              : const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: panel(ChatPane(
              key: ValueKey(state.selectedId),
              state: state,
              conv: state.selected!,
              compact: true)),
        ));
      }
      final listPane = oneUi
          ? _ConversationPane(state: state, onSettings: onSettings)
          : panel(_ConversationPane(state: state));
      return _fade('main', Padding(
        padding: oneUi
            ? const EdgeInsets.fromLTRB(0, 0, 12, 12)
            : const EdgeInsets.fromLTRB(0, 0, 10, 10),
        child: Row(
          children: [
            if (oneUi)
              const SizedBox(width: 12)
            else
              _Rail(state: state, onSettings: onSettings),
            if (showChat)
              SizedBox(
                  width: state.livePaneWidth
                      .clamp(280.0, (box.maxWidth - 340).clamp(280.0, 640.0)),
                  child: listPane)
            else
              Expanded(child: listPane),
            // 목록과 대화창 사이: 끌어서 너비 조절, 두 번 누르면 기본 너비
            if (showChat)
              MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (d) => state.setPaneWidth(
                      (state.livePaneWidth + d.delta.dx)
                          .clamp(280.0, (box.maxWidth - 340).clamp(280.0, 640.0))),
                  onHorizontalDragEnd: (_) =>
                      state.setPaneWidth(state.livePaneWidth, save: true),
                  onDoubleTap: () =>
                      state.setPaneWidth(oneUi ? 372 : 332, save: true),
                  child: SizedBox(
                    width: 10,
                    child: Center(
                      child: Container(
                        width: 3,
                        height: 36,
                        decoration: BoxDecoration(
                          color: c.onSurfaceVariant.withValues(alpha: 0.28),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (showChat)
              Expanded(
                child: panel(
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    switchInCurve: Curves.easeOut,
                    child: state.selected == null
                        ? _EmptyChat(
                            key: const ValueKey('empty'), state: state)
                        : ChatPane(
                            key: ValueKey(state.selectedId),
                            state: state,
                            conv: state.selected!),
                  ),
                ),
              ),
          ],
        ),
      ));
    });
  }
}

// ───────────────────────── 왼쪽 메뉴 ─────────────────────────

class _Rail extends StatelessWidget {
  const _Rail({required this.state, required this.onSettings});
  final AppState state;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final connected = state.connState == 'connected';
    return SizedBox(
      width: 76,
      child: Column(
        children: [
          const SizedBox(height: 6),
          _RailItem(
            icon: Icons.chat_bubble_outline_rounded,
            activeIcon: Icons.chat_bubble_rounded,
            label: '메시지',
            selected: state.folder == 'inbox',
            badge: state.unreadCount,
            onTap: () => state.setFolder('inbox'),
          ),
          _RailItem(
            icon: Icons.inventory_2_outlined,
            activeIcon: Icons.inventory_2_rounded,
            label: '보관함',
            selected: state.folder == 'archive',
            onTap: () => state.setFolder('archive'),
          ),
          _RailItem(
            icon: Icons.shield_outlined,
            activeIcon: Icons.shield_rounded,
            label: '스팸',
            selected: state.folder == 'spam',
            onTap: () => state.setFolder('spam'),
          ),
          const Spacer(),
          Tooltip(
            message: connected ? '휴대폰에 연결됨' : '연결 확인 중',
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: connected ? const Color(0xFF3DDC84) : c.outline,
              ),
            ),
          ),
          const SizedBox(height: 10),
          _RailItem(
            icon: Icons.settings_outlined,
            activeIcon: Icons.settings,
            label: '설정',
            selected: false,
            onTap: onSettings,
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge = 0,
  });
  final IconData icon, activeIcon;
  final String label;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final on = widget.selected;
    final fg = on ? c.onSurface : (_hover ? c.onSurface : c.onSurfaceVariant);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 48,
                height: 34,
                decoration: BoxDecoration(
                  color: on
                      ? c.primary.withValues(alpha: 0.22)
                      : (_hover
                          ? c.onSurface.withValues(alpha: 0.07)
                          : Colors.transparent),
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Icon(on ? widget.activeIcon : widget.icon,
                        size: 20, color: on ? c.primary : fg),
                    if (widget.badge > 0)
                      Positioned(
                        right: 4,
                        top: 1,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          constraints: const BoxConstraints(minWidth: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF4D67),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                              widget.badge > 99 ? '99+' : '${widget.badge}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 10,
                                  height: 1.3,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(widget.label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                      color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 72, color: c.outlineVariant),
          const SizedBox(height: 12),
          Text('대화를 선택하세요', style: TextStyle(color: c.onSurfaceVariant)),
        ],
      ),
    );
  }
}

// ───────────────────────── 대화 목록 ─────────────────────────

class _ConversationPane extends StatelessWidget {
  const _ConversationPane({required this.state, this.onSettings});
  final AppState state;
  final VoidCallback? onSettings;

  /// One UI: 큰 제목 + 안 읽은 수, 오른쪽에 아이콘 버튼
  Widget _oneUiHeader(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final unread = state.unreadCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 22, 4, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_folders[state.folder]!,
                    style: const TextStyle(
                        fontSize: 30, height: 1.15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                    state.folder == 'inbox' && unread > 0
                        ? '읽지 않은 대화 $unread개'
                        : '대화 ${state.visible.length}개',
                    style: TextStyle(fontSize: 13, color: c.onSurfaceVariant)),
              ],
            ),
          ),
          HeaderIcon(
            icon: Symbols.settings,
            raised: true,
            tooltip: '설정 ($kMod,)',
            onTap: onSettings,
          ),
          HeaderIcon(
            icon: state.wide ? kPanelOpenIcon : kPanelIcon,
            raised: true,
            tooltip: state.wide
                ? '대화창 접기 ($kMod\\)'
                : '대화창 펼치기 ($kMod\\)',
            onTap: state.toggleChat,
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// One UI: 목록을 둥근 카드에 담고, 아래에 떠 있는 알약 모양 탭을 둔다
  Widget _wrapList(BuildContext context, Widget child) {
    if (!oneUi) return child;
    final c = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget tab(String folder, IconData icon, IconData active, String label) =>
        Expanded(
          child: _PillTab(
            selected: state.folder == folder,
            icon: icon,
            activeIcon: active,
            label: label,
            useAppIcon: folder == 'inbox',
            onTap: () => state.setFolder(folder),
          ),
        );

    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(26),
            ),
            child: child,
          ),
        ),
        // 새 메시지 작성: 목록 위에 떠 있는 입체 버튼
        Positioned(
          right: 18,
          bottom: 90,
          child: _ComposeFab(
            onTap: () => showDialog<void>(
                context: context,
                builder: (_) => _NewChatDialog(state: state)),
          ),
        ),
        Positioned(
          left: 34,
          right: 34,
          bottom: 14,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: c.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                  color: c.outlineVariant.withValues(alpha: 0.6)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.5 : 0.14),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                tab('inbox', Icons.chat_bubble_outline_rounded,
                    Icons.chat_bubble_rounded, '메시지'),
                tab('archive', Icons.inventory_2_outlined,
                    Icons.inventory_2_rounded, '보관함'),
                tab('spam', Icons.shield_outlined, Icons.shield_rounded, '스팸'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static const _folders = {'inbox': '메시지', 'archive': '보관함', 'spam': '스팸 및 차단'};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = state.visible;
    return Column(
      children: [
        if (oneUi)
          _oneUiHeader(context)
        else
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 10, 10),
          child: Row(
            children: [
              Text(_folders[state.folder]!,
                  style: const TextStyle(
                      fontSize: 21, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                tooltip: Platform.isMacOS ? '새 대화 (⌘N)' : '새 대화 (Ctrl+N)',
                icon: const Icon(Icons.edit_outlined, size: 21),
                onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => _NewChatDialog(state: state)),
              ),
              IconButton(
                tooltip: state.wide
                    ? '대화창 접기 (⌘\\)'
                    : '대화창 펼치기 (⌘\\)',
                icon: Icon(
                    state.wide
                        ? Icons.chevron_left_rounded
                        : Icons.chevron_right_rounded,
                    size: 24),
                onPressed: state.toggleChat,
              ),
            ],
          ),
        ),
        Padding(
          padding: oneUi
              ? const EdgeInsets.fromLTRB(0, 0, 0, 10)
              : const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            focusNode: _searchFocus,
            onChanged: state.setQuery,
            decoration: InputDecoration(
              isDense: true,
              hintText: Platform.isMacOS ? '검색 (⌘F)' : '검색 (Ctrl+F)',
              prefixIcon: const Icon(Icons.search, size: 20),
              filled: true,
              fillColor: oneUi
                  ? theme.colorScheme.surface
                  : theme.colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(26),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  EdgeInsets.symmetric(vertical: oneUi ? 13 : 8),
            ),
          ),
        ),
        _FilterChips(state: state),
        _ConnectionBanner(state: state),
        Expanded(
          child: _wrapList(context, list.isEmpty
              ? Center(
                  child: state.convsLoading || state.connState == 'connecting'
                      ? const CircularProgressIndicator()
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                                state.convsError ??
                                    switch (state.filter) {
                                      'unread' => '읽지 않은 대화가 없습니다',
                                      'pinned' => '고정한 대화가 없습니다',
                                      'disaster' => '재난문자가 없습니다',
                                      _ => '대화가 없습니다',
                                    },
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color:
                                        theme.colorScheme.onSurfaceVariant)),
                            const SizedBox(height: 8),
                            TextButton(
                                onPressed: state.loadConversations,
                                child: const Text('새로고침')),
                          ],
                        ),
                )
              : GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapDown: (d) async {
                    final v = await showFadeMenu<String>(
                      context: context,
                      at: d.globalPosition,
                      items: [
                        _mi('new', Icons.edit_outlined, '새 대화'),
                        _mi('refresh', Icons.refresh_rounded, '목록 새로고침'),
                        _mi('readAll', Icons.done_all_rounded, '모두 읽음으로 표시'),
                      ],
                    );
                    if (v == 'new' && context.mounted) {
                      showDialog<void>(
                          context: context,
                          builder: (_) => _NewChatDialog(state: state));
                    } else if (v == 'refresh') {
                      state.loadConversations();
                    } else if (v == 'readAll') {
                      state.markAllRead();
                    }
                  },
                  child: ListView.builder(
                    padding: oneUi
                        ? const EdgeInsets.fromLTRB(8, 8, 8, 160)
                        : const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: list.length,
                    itemBuilder: (_, i) =>
                        _ConversationTile(state: state, conv: list[i]),
                  ),
                )),
        ),
      ],
    );
  }
}

/// 새 메시지 버튼: Google 메시지 아이콘처럼 위는 밝은 보랏빛, 아래는 파란
/// 그라데이션에 윗면 하이라이트와 색 그림자를 얹어 입체감을 준다.
class _ComposeFab extends StatefulWidget {
  const _ComposeFab({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ComposeFab> createState() => _ComposeFabState();
}

class _ComposeFabState extends State<_ComposeFab> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    const r = BorderRadius.all(Radius.circular(16));
    return Tooltip(
      message: '새 메시지 (${kMod}N)',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _down = false;
        }),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 140),
            scale: _down ? 0.95 : (_hover ? 1.04 : 1.0),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                borderRadius: r,
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFA9A6FF), Color(0xFF5B8DFF), Color(0xFF2F7BFF)],
                  stops: [0.0, 0.55, 1.0],
                ),
                boxShadow: [
                  // 아래로 떨어지는 색 그림자
                  BoxShadow(
                    color: const Color(0xFF2F6BFF)
                        .withValues(alpha: _hover ? 0.55 : 0.42),
                    blurRadius: _hover ? 16 : 11,
                    offset: Offset(0, _hover ? 10 : 7),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  // 윗면 하이라이트
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 23,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(16)),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(alpha: 0.38),
                            Colors.white.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 가장자리 얇은 빛
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: r,
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.28),
                            width: 1),
                      ),
                    ),
                  ),
                  const Center(
                    child: Icon(Symbols.edit_square,
                        size: 21,
                        weight: 500,
                        fill: 1,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                              color: Color(0x551B3FA8),
                              blurRadius: 6,
                              offset: Offset(0, 2)),
                        ]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 하단 알약 탭의 항목 (마우스를 올리면 은은하게 밝아진다)
class _PillTab extends StatefulWidget {
  const _PillTab({
    required this.selected,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.useAppIcon,
    required this.onTap,
  });
  final bool selected, useAppIcon;
  final IconData icon, activeIcon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_PillTab> createState() => _PillTabState();
}

class _PillTabState extends State<_PillTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final on = widget.selected;
    final fg = on ? c.primary : (_hover ? c.onSurface : c.onSurfaceVariant);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          height: 48,
          decoration: BoxDecoration(
            color: on
                ? c.primary.withValues(alpha: dark ? 0.26 : 0.13)
                : (_hover
                    ? c.onSurface.withValues(alpha: 0.05)
                    : Colors.transparent),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.useAppIcon)
                // 메시지 탭은 Google 메시지 원본 아이콘 (선택 안 됐을 땐 흐리게)
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: on ? 1 : (_hover ? 0.85 : 0.55),
                  child: Image.asset('assets/app_icon.png',
                      width: 21,
                      height: 21,
                      filterQuality: FilterQuality.medium),
                )
              else
                Icon(on ? widget.activeIcon : widget.icon, size: 19, color: fg),
              const SizedBox(width: 6),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                    color: fg),
                child: Text(widget.label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 전체 / 읽지 않음 / 고정 필터
class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final inFolder =
        state.convs.values.where((x) => x.folder == state.folder).toList();
    final unread =
        inFolder.where((x) => x.unread && !state.isDisaster(x)).length;
    final pinned = inFolder.where(state.isPinned).length;
    Widget chip(String key, String label, int? count) {
      final on = state.filter == key;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: on ? c.primary : (oneUi ? c.surface : c.surfaceContainerHighest),
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => state.setFilter(key),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Text(
                  count != null && count > 0 ? '$label $count' : label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      color: on ? c.onPrimary : c.onSurfaceVariant)),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: oneUi
          ? const EdgeInsets.fromLTRB(2, 0, 0, 10)
          : const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
        children: [
          chip('all', '전체', null),
          chip('unread', '읽지 않음', unread),
          chip('pinned', '고정', pinned),
          chip('disaster', '재난문자', null),
        ],
      )),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    String? text;
    var retry = false;
    switch (state.connState) {
      case 'connected':
        return const SizedBox.shrink();
      case 'connecting':
        text = '연결 중…';
      case 'reconnecting':
        text = '다시 연결하는 중…';
      case 'phone_not_responding':
        text = '휴대폰이 응답하지 않습니다. 휴대폰의 인터넷 연결을 확인하세요.';
      case 'auth_error':
        text = '로그인이 만료되었습니다. 설정에서 로그아웃 후 다시 로그인해 주세요.';
      default:
        text = '연결 오류: ${state.connMessage}';
        retry = true;
    }
    return Container(
      width: double.infinity,
      margin: oneUi
          ? const EdgeInsets.fromLTRB(0, 0, 0, 10)
          : const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: c.onTertiaryContainer)),
          ),
          if (retry)
            TextButton(onPressed: state.reconnect, child: const Text('재연결')),
        ],
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.state, required this.conv, this.radius = 22});
  final AppState state;
  final Conversation conv;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final others = conv.others;
    final peer = conv.peer;
    if (peer != null) {
      final bytes = state.avatars[peer.id];
      if (bytes != null) {
        return CircleAvatar(radius: radius, backgroundImage: MemoryImage(bytes));
      }
    }
    final bg = _hexColor(
        conv.color.isNotEmpty
            ? conv.color
            : (others.isNotEmpty ? others.first.color : ''),
        c.primary);
    final title = conv.title;
    final first = title.isEmpty ? '' : String.fromCharCodes(title.runes.take(1));
    final letter = RegExp(r'[0-9+(]').hasMatch(first) ? '' : first;
    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      foregroundColor: Colors.white,
      child: conv.isGroup
          ? Icon(Icons.group, size: radius)
          : (letter.isEmpty
              ? Icon(Icons.person, size: radius * 1.1)
              : Text(letter,
                  style: TextStyle(
                      fontSize: radius * 0.85, fontWeight: FontWeight.w500))),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.state, required this.conv});
  final AppState state;
  final Conversation conv;

  Future<void> _menu(BuildContext context, Offset pos) =>
      _conversationMenu(context, state, conv, pos);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final selected = state.selectedId == conv.id;
    final typing = state.typing[conv.id]?.isAfter(DateTime.now()) ?? false;
    final preview = typing
        ? '입력 중…'
        : '${conv.previewFromMe ? '나: ' : ''}${conv.preview.replaceAll('\n', ' ')}';
    return GestureDetector(
      onSecondaryTapDown: (d) => _menu(context, d.globalPosition),
      child: Material(
        color: selected ? c.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => state.select(conv.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                Avatar(state: state, conv: conv),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (state.isPinned(conv))
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(Icons.push_pin,
                                  size: 13, color: c.onSurfaceVariant),
                            ),
                          Expanded(
                            // 연락처에 저장된 상대도 이름 옆에 번호를 함께 보여 준다
                            child: Text.rich(
                                TextSpan(text: conv.title, children: [
                                  if (!conv.isGroup &&
                                      conv.subtitle.isNotEmpty)
                                    TextSpan(
                                        text: '  ${conv.subtitle}',
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w400,
                                            color: c.onSurfaceVariant)),
                                ]),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: conv.unread
                                        ? FontWeight.w700
                                        : FontWeight.w500)),
                          ),
                          if (state.isMuted(conv.id))
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(Icons.notifications_off_outlined,
                                  size: 13, color: c.onSurfaceVariant),
                            ),
                          const SizedBox(width: 6),
                          Text(formatListTime(conv.ts),
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: conv.unread
                                      ? FontWeight.w700
                                      : FontWeight.normal,
                                  color: conv.unread
                                      ? c.primary
                                      : c.onSurfaceVariant)),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Expanded(
                            child: Text(preview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: conv.unread
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                    color: conv.unread
                                        ? c.onSurface
                                        : c.onSurfaceVariant)),
                          ),
                          if (conv.unread)
                            Container(
                              width: 10,
                              height: 10,
                              margin: const EdgeInsets.only(left: 6),
                              decoration: BoxDecoration(
                                  color: c.primary, shape: BoxShape.circle),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 새 대화 ─────────────────────────

class _NewChatDialog extends StatefulWidget {
  const _NewChatDialog({required this.state});
  final AppState state;

  @override
  State<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<_NewChatDialog> {
  List<Map<String, dynamic>>? _contacts;
  final _field = TextEditingController();
  final List<Map<String, String>> _picked = []; // {name, number}
  String _q = '';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.state.contacts().then((c) {
      c.sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
      if (mounted) setState(() => _contacts = c);
    }).catchError((e) {
      if (mounted) setState(() => _contacts = []);
    });
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _add(String name, String number) {
    if (number.isEmpty) return;
    setState(() {
      if (!_picked.any((p) => p['number'] == number)) {
        _picked.add({'name': name, 'number': number});
      }
      _q = '';
      _field.clear();
    });
  }

  Future<void> _start() async {
    if (_picked.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final conv = await widget.state
          .startConversation(_picked.map((p) => p['number']!).toList());
      widget.state.select(conv.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final q = _q.trim().toLowerCase();
    final digits = q.replaceAll(RegExp(r'[^0-9+]'), '');
    final matches = (_contacts ?? const <Map<String, dynamic>>[]).where((ct) {
      if (q.isEmpty) return true;
      return '${ct['name']}'.toLowerCase().contains(q) ||
          (digits.isNotEmpty &&
              '${ct['number']}'
                  .replaceAll(RegExp(r'[^0-9+]'), '')
                  .contains(digits));
    }).toList();
    final canDial = digits.length >= 3 &&
        digits.length == q.replaceAll(RegExp(r'[\s\-()]'), '').length;
    return AlertDialog(
      title: Text(_picked.length > 1 ? '새 그룹 대화' : '새 대화'),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: SizedBox(
        width: 420,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_picked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in _picked)
                      InputChip(
                        label: Text(p['name']!.isNotEmpty
                            ? p['name']!
                            : p['number']!),
                        onDeleted: _busy
                            ? null
                            : () => setState(() => _picked.remove(p)),
                      ),
                  ],
                ),
              ),
            TextField(
              controller: _field,
              autofocus: true,
              enabled: !_busy,
              onChanged: (v) => setState(() => _q = v),
              onSubmitted: (_) {
                if (canDial) {
                  _add('', digits);
                } else if (q.isEmpty) {
                  _start();
                }
              },
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '이름 또는 전화번호 (여러 명 선택 가능)',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: c.error)),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: _busy || _contacts == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        if (canDial)
                          ListTile(
                            leading:
                                const CircleAvatar(child: Icon(Icons.dialpad)),
                            title: Text('$digits 번호 추가'),
                            onTap: () => _add('', digits),
                          ),
                        for (final ct in matches.take(200))
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  _hexColor('${ct['color']}', c.primary),
                              foregroundColor: Colors.white,
                              child: const Icon(Icons.person),
                            ),
                            title: Text('${ct['name']}'),
                            subtitle: Text('${ct['formatted']}'),
                            trailing: _picked
                                    .any((p) => p['number'] == '${ct['number']}')
                                ? Icon(Icons.check_circle, color: c.primary)
                                : null,
                            onTap: () =>
                                _add('${ct['name']}', '${ct['number']}'),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('닫기')),
        FilledButton(
            onPressed: _picked.isEmpty || _busy ? null : _start,
            child: Text(_picked.length > 1
                ? '그룹 대화 시작 (${_picked.length}명)'
                : '대화 시작')),
      ],
    );
  }
}

// ───────────────────────── 대화창 ─────────────────────────

class ChatPane extends StatefulWidget {
  const ChatPane({
    super.key,
    required this.state,
    required this.conv,
    this.compact = false,
  });
  final AppState state;
  final Conversation conv;

  /// 접힌(좁은) 창에서 대화창만 보일 때: 뒤로 가기 버튼을 보여 준다
  final bool compact;

  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  /// 보낼 첨부 파일들 (대화별로 앱 상태에 보관)
  List<String> get _files =>
      s.draftFiles.putIfAbsent(conv.id, () => <String>[]);
  Message? _replyTo;
  bool _searching = false;
  bool _dragging = false;
  String _searchQ = '';

  static const _emojiSet = [
    '😀', '😂', '🤣', '😊', '😍', '😘', '😎', '🤔', '😅', '😭', '😡', '😴',
    '👍', '👎', '👏', '🙏', '💪', '👌', '🙌', '🤝', '❤️', '💕', '🔥', '✨',
    '🎉', '🎂', '☕', '🍺', '🚗', '🏠', '📞', '✅', '❌', '⭐', '💯', '🙇',
  ];

  /// Esc: 검색 → 답장 → 첨부 순으로 취소. 처리했으면 true
  bool escape() {
    if (_searching) {
      setState(() {
        _searching = false;
        _searchQ = '';
      });
      _focus.requestFocus();
      return true;
    }
    if (_replyTo != null || _files.isNotEmpty) {
      setState(() {
        _replyTo = null;
        _files.clear();
      });
      return true;
    }
    return false;
  }

  void toggleSearch() {
    setState(() {
      _searching = !_searching;
      _searchQ = '';
    });
    if (!_searching) _focus.requestFocus();
  }

  void pickFile() => _pick();

  void _insertEmoji(String e) {
    final v = _input.value;
    final start = v.selection.isValid ? v.selection.start : v.text.length;
    final end = v.selection.isValid ? v.selection.end : v.text.length;
    _input.value = TextEditingValue(
      text: v.text.replaceRange(start, end, e),
      selection: TextSelection.collapsed(offset: start + e.length),
    );
    _focus.requestFocus();
  }

  /// 클립보드에 이미지가 있으면 첨부로 붙여넣기
  /// 붙여넣기: 클립보드가 사진이면 첨부하고, 글자면 커서 자리에 넣는다
  // ── Win+V(클립보드 기록) 지원 ──
  // 기록 창에서 항목을 고르면 Windows 가 그 항목을 클립보드에 올리고 붙여넣기를
  // 시도하는데, 그 붙여넣기 신호가 앱까지 오지 않는 경우가 있다. 그래서 Win 키를 누른
  // 뒤 클립보드가 바뀌는지 잠깐 지켜보다가, 바뀌었는데 붙여넣기가 안 됐으면 직접 붙인다.
  bool _hasText = false;
  Timer? _clipWatch;
  DateTime _lastPaste = DateTime.fromMillisecondsSinceEpoch(0);

  void _armClipWatch() {
    if (!Platform.isWindows) return;
    _clipWatch?.cancel();
    final start = clipboardSequence();
    var ticks = 0;
    _clipWatch = Timer.periodic(const Duration(milliseconds: 120), (t) {
      if (!mounted || ++ticks > 125) {
        t.cancel(); // 15초쯤 지나면 그만둔다
        return;
      }
      if (clipboardSequence() == start) return;
      t.cancel();
      final changedAt = DateTime.now();
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (!mounted) return;
        // 그 무렵 이미 붙여넣기가 됐으면(정상 동작) 또 붙이지 않는다
        if (changedAt.difference(_lastPaste).inMilliseconds < 1000) return;
        // 그 사이 다른 입력 칸(검색 등)으로 옮겨 갔으면 건드리지 않는다
        final pf = FocusManager.instance.primaryFocus;
        if (!_focus.hasFocus &&
            pf?.context?.findAncestorWidgetOfExactType<EditableText>() !=
                null) {
          return;
        }
        _focus.requestFocus();
        _paste();
      });
    });
  }

  /// 붙여넣기: 글자면 커서 자리에 넣고, 사진·파일이면 첨부한다.
  /// 클립보드가 잠깐 잠겨 있을 수 있어(Win+V 직후 등) 몇 번 다시 읽어 본다.
  Future<void> _paste() async {
    _lastPaste = DateTime.now();
    for (var i = 0; i < 5; i++) {
      if (i > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 90));
      }
      if (!mounted) return;
      String? text;
      try {
        text = (await Clipboard.getData(Clipboard.kTextPlain)
                .timeout(const Duration(seconds: 1)))
            ?.text;
      } catch (_) {}
      if (text != null && text.isNotEmpty) {
        if (!mounted) return;
        final v = _input.value;
        final sel = v.selection.isValid
            ? v.selection
            : TextSelection.collapsed(offset: v.text.length);
        _input.value = TextEditingValue(
          text: v.text.replaceRange(sel.start, sel.end, text),
          selection: TextSelection.collapsed(offset: sel.start + text.length),
        );
        _lastPaste = DateTime.now();
        return;
      }
      if (await _pasteImage() || await _pasteFiles()) {
        _lastPaste = DateTime.now();
        return;
      }
    }
  }

  /// 클립보드의 사진을 첨부한다 (첨부했으면 true)
  Future<bool> _pasteImage() async {
    try {
      final bytes =
          await Pasteboard.image.timeout(const Duration(seconds: 2));
      if (bytes == null || bytes.isEmpty || !mounted) return false;
      final dir = Directory('${s.cacheDir}${Platform.pathSeparator}paste');
      await dir.create(recursive: true);
      final f = File(
          '${dir.path}${Platform.pathSeparator}image_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(bytes);
      if (!mounted) return false;
      setState(() => _files.add(f.path));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 탐색기 등에서 복사한 파일을 첨부한다 (첨부했으면 true)
  Future<bool> _pasteFiles() async {
    try {
      final files =
          await Pasteboard.files().timeout(const Duration(seconds: 2));
      final ok = [
        for (final f in files)
          if (f.isNotEmpty && File(f).existsSync()) f
      ];
      if (ok.isEmpty || !mounted) return false;
      setState(() => _files.addAll(ok));
      return true;
    } catch (_) {
      return false;
    }
  }

  AppState get s => widget.state;
  Conversation get conv => widget.conv;

  @override
  void initState() {
    super.initState();
    // 쓰던 글을 되살리고, 바뀔 때마다 보관한다
    _input.text = s.drafts[conv.id] ?? '';
    _hasText = _input.text.trim().isNotEmpty;
    _input.addListener(() {
      s.drafts[conv.id] = _input.text;
      // 보낼 글이 생기거나 없어질 때만 다시 그린다 (보내기 버튼 표시)
      final has = _input.text.trim().isNotEmpty;
      if (has != _hasText && mounted) setState(() => _hasText = has);
    });
    _focus.onKeyEvent = _onKey;
    _activeChat = this;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    if (_activeChat == this) _activeChat = null;
    _input.dispose();
    _clipWatch?.cancel();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (Platform.isWindows && e is KeyDownEvent) {
      final k = e.logicalKey;
      final isMeta = k == LogicalKeyboardKey.metaLeft ||
          k == LogicalKeyboardKey.metaRight;
      if (isMeta) {
        _armClipWatch(); // Win 키: 뒤이어 Win+V 로 고를 수 있다
      } else if (_clipWatch?.isActive == true &&
          k != LogicalKeyboardKey.keyV &&
          k != LogicalKeyboardKey.controlLeft &&
          k != LogicalKeyboardKey.controlRight) {
        _clipWatch?.cancel(); // 다른 키를 눌렀으면 Win+V 가 아니다
      }
      // Shift+Insert 도 붙여넣기
      if (k == LogicalKeyboardKey.insert &&
          HardwareKeyboard.instance.isShiftPressed) {
        _paste();
        return KeyEventResult.handled;
      }
    }
    // Windows: Ctrl+V 를 여기서 직접 처리한다. Win+V 로 붙일 때는 Win 키가 눌린 것으로
    // 남아 있어 기본 붙여넣기 단축키가 동작하지 않기 때문이다.
    if (Platform.isWindows &&
        e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      _paste();
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent &&
        (e.logicalKey == LogicalKeyboardKey.enter ||
            e.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      // 'Enter 로 보내기'가 꺼져 있으면 Enter 는 줄바꿈, Ctrl(⌘)+Enter 로 보낸다
      final hk = HardwareKeyboard.instance;
      final mod = hk.isControlPressed || hk.isMetaPressed;
      if (s.enterSends || mod) {
        _send();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  static String? _mimeFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const map = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
      'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic',
      'bmp': 'image/bmp', 'mp4': 'video/mp4', 'mov': 'video/quicktime',
      '3gp': 'video/3gpp', 'mp3': 'audio/mpeg', 'm4a': 'audio/mp4',
      'wav': 'audio/wav', 'ogg': 'audio/ogg', 'pdf': 'application/pdf',
      'vcf': 'text/x-vcard', 'txt': 'text/plain',
    };
    return map[ext];
  }

  void _send() {
    final text = _input.text.trim();
    final files = List<String>.of(_files);
    if (text.isEmpty && files.isEmpty) return;
    // 한글 조합 중 Enter: 조합 글자가 다시 들어오지 않도록 포커스를 잠깐 해제
    final composing = _input.value.composing.isValid &&
        !_input.value.composing.isCollapsed;
    if (composing) {
      _focus.unfocus();
      _input.clear();
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focus.requestFocus());
    } else {
      _input.clear();
    }
    final reply = _replyTo;
    setState(() {
      _files.clear();
      _replyTo = null;
    });
    if (files.isEmpty) {
      s.send(conv.id, text, replyTo: reply?.id);
      return;
    }
    // 첨부는 메시지 하나에 한 개씩 차례로 보낸다 (글은 첫 번째에 함께)
    final id = conv.id;
    () async {
      for (var i = 0; i < files.length; i++) {
        final name = files[i].split(Platform.pathSeparator).last;
        await s.send(id, i == 0 ? text : '',
            path: files[i],
            mime: _mimeFor(name),
            replyTo: i == 0 ? reply?.id : null);
      }
    }();
  }

  Future<void> _pick() async {
    final picked = await openFiles();
    if (picked.isNotEmpty && mounted) {
      setState(() => _files.addAll(picked.map((f) => f.path)));
    }
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final chat = s.chats[conv.id] ?? ChatState();
    final sq = _searchQ.trim().toLowerCase();
    final msgs = _searching && sq.isNotEmpty
        ? chat.messages
            .where((m) => m.text.toLowerCase().contains(sq))
            .toList()
        : chat.messages;
    final typing = s.typing[conv.id]?.isAfter(DateTime.now()) ?? false;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) {
        if (d.files.isEmpty || conv.readOnly) return;
        setState(() {
          _dragging = false;
          _files.addAll(d.files.map((f) => f.path));
        });
        _focus.requestFocus();
      },
      child: Stack(children: [
        Column(
      children: [
        // 헤더
        Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: c.outlineVariant.withValues(alpha: 0.5)))),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onSecondaryTapDown: (d) => _conversationMenu(
                context, s, conv, d.globalPosition,
                inChat: true),
            child: Row(
            children: [
              if (widget.compact) ...[
                HeaderIcon(
                  icon: Symbols.arrow_back,
                  raised: true,
                  tooltip: '목록으로 (Esc)',
                  onTap: () => s.select(null),
                ),
                const SizedBox(width: 4),
              ],
              Avatar(state: s, conv: conv, radius: 19),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(conv.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    if (typing || conv.subtitle.isNotEmpty)
                      Text(typing ? '입력 중…' : conv.subtitle,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: typing ? c.primary : c.onSurfaceVariant)),
                  ],
                ),
              ),
              HeaderIcon(
                icon: Symbols.search,
                raised: true,
                tooltip: Platform.isMacOS
                    ? '대화에서 검색 (⌘⇧F)'
                    : '대화에서 검색 (Ctrl+Shift+F)',
                active: _searching,
                onTap: toggleSearch,
              ),
              HeaderIcon(
                icon: Symbols.refresh,
                raised: true,
                tooltip: '새로고침',
                onTap: () => s.loadMessages(conv.id, refresh: true),
              ),
              HeaderIcon(
                icon: widget.compact ? kPanelIcon : kPanelOpenIcon,
                raised: true,
                tooltip: widget.compact
                    ? (Platform.isMacOS
                        ? '목록과 함께 펼치기 (⌘\\)'
                        : '목록과 함께 펼치기 (Ctrl+\\)')
                    : (Platform.isMacOS
                        ? '대화창 접기 (⌘\\)'
                        : '대화창 접기 (Ctrl+\\)'),
                onTap: s.toggleChat,
              ),
            ],
          )),
        ),
        if (_searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _searchQ = v),
              decoration: InputDecoration(
                isDense: true,
                hintText: '이 대화에서 검색 (불러온 메시지 기준)',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: toggleSearch),
                filled: true,
                fillColor: c.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        // 메시지 목록
        Expanded(
          child: msgs.isEmpty
              ? Center(
                  child: chat.loading || !chat.loaded && chat.error == null
                      ? const CircularProgressIndicator()
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                                chat.error ??
                                    (sq.isNotEmpty
                                        ? '검색 결과가 없습니다'
                                        : '메시지가 없습니다'),
                                style: TextStyle(color: c.onSurfaceVariant)),
                            if (chat.error != null)
                              TextButton(
                                  onPressed: () => s.loadMessages(conv.id),
                                  child: const Text('다시 시도')),
                          ],
                        ),
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.pixels >= n.metrics.maxScrollExtent - 300) {
                      s.loadMessages(conv.id, older: true);
                    }
                    return false;
                  },
                  // 메시지 글자를 마우스로 끌어 선택하고 Ctrl+C 로 복사할 수 있다
                  child: SelectionArea(
                    contextMenuBuilder: (_, __) => const SizedBox.shrink(),
                    child: ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      itemCount: msgs.length + 1,
                      itemBuilder: (ctx, i) {
                        if (i == msgs.length) {
                          return SizedBox(
                            height: 36,
                            child: Center(
                              child: chat.loading
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : null,
                            ),
                          );
                        }
                        final idx = msgs.length - 1 - i;
                        final m = msgs[idx];
                        final older = idx > 0 ? msgs[idx - 1] : null;
                        final newer =
                            idx < msgs.length - 1 ? msgs[idx + 1] : null;
                        return _MessageRow(
                          state: s,
                          conv: conv,
                          msg: m,
                          showDate: older == null || !sameDay(older.ts, m.ts),
                          showSender: conv.isGroup &&
                              !s.isMine(m) &&
                              (older == null ||
                                  older.participantId != m.participantId ||
                                  older.tombstone),
                          showMeta: newer == null ||
                              s.isMine(newer) != s.isMine(m) ||
                              newer.participantId != m.participantId ||
                              newer.ts - m.ts > 3 * 60 * 1000 ||
                              m.failed ||
                              newer.tombstone,
                          onReply: () {
                            setState(() => _replyTo = m);
                            _focus.requestFocus();
                          },
                        );
                      },
                    ),
                  ),
                ),
        ),
        // 입력창
        if (conv.readOnly)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('이 대화에는 답장할 수 없습니다.',
                style: TextStyle(color: c.onSurfaceVariant)),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 16, 14),
            child: Column(
              children: [
                if (_replyTo != null)
                  _Chip(
                    icon: Icons.reply,
                    text: _replyTo!.summary,
                    onClose: () => setState(() => _replyTo = null),
                  ),
                // 첨부: 사진은 미리보기, 그 밖의 파일은 이름으로 (여러 개 가능)
                if (_files.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 44, bottom: 8),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (final f in List<String>.of(_files))
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: _ImageAttachment(
                                  path: f,
                                  isImage: (_mimeFor(f
                                              .split(Platform.pathSeparator)
                                              .last) ??
                                          '')
                                      .startsWith('image/'),
                                  onClose: () =>
                                      setState(() => _files.remove(f)),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: Platform.isMacOS
                          ? '파일 첨부 (⌘O)'
                          : '파일 첨부 (Ctrl+O)',
                      icon: const Icon(Icons.add_circle_outline),
                      iconSize: 21,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints.tightFor(width: 34, height: 44),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(34, 44),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _pick,
                    ),
                    PopupMenuButton<String>(
                      tooltip: '이모티콘',
                      popUpAnimationStyle: AnimationStyle(
                          curve: Curves.easeOut,
                          duration: const Duration(milliseconds: 150)),
                      icon: const Icon(Icons.emoji_emotions_outlined, size: 21),
                      padding: EdgeInsets.zero,
                      // (여기에 constraints 를 주면 버튼이 아니라 뜨는 창 크기가 줄어든다)
                      style: IconButton.styleFrom(
                        minimumSize: const Size(34, 44),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onSelected: _insertEmoji,
                      itemBuilder: (ctx) => [
                        PopupMenuItem<String>(
                          padding: const EdgeInsets.all(8),
                          child: SizedBox(
                            width: 264,
                            child: Wrap(
                              children: [
                                for (final e in _emojiSet)
                                  InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () => Navigator.pop(ctx, e),
                                    child: SizedBox(
                                      width: 44,
                                      height: 40,
                                      child: Center(
                                        child: Text(e,
                                            style:
                                                const TextStyle(fontSize: 22)),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          Actions(
                        actions: {
                          PasteTextIntent: CallbackAction<PasteTextIntent>(
                              onInvoke: (_) => _paste()),
                        },
                        child: TextField(
                        controller: _input,
                        focusNode: _focus,
                        // 글씨는 조금 작게, 칸은 넉넉하게 (2줄부터 시작해 10줄까지 늘어난다)
                        minLines: 2,
                        maxLines: 10,
                        style: const TextStyle(fontSize: 13.5, height: 1.4),
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          hintText: '메시지 입력',
                          hintStyle: TextStyle(
                              fontSize: 13.5, color: c.onSurfaceVariant),
                          isDense: true,
                          filled: true,
                          fillColor: c.surfaceContainerHighest,
                          // 오른쪽은 안에 들어가는 보내기 버튼 자리
                          contentPadding:
                              const EdgeInsets.fromLTRB(16, 12, 48, 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      )),
                          // 보내기 버튼: 입력 칸 안 오른쪽 아래. 보낼 것이 있을 때만 나타난다
                          Positioned(
                            right: 6,
                            bottom: 6,
                            child: IgnorePointer(
                              ignoring: !(_hasText || _files.isNotEmpty),
                              child: AnimatedScale(
                                duration: const Duration(milliseconds: 140),
                                curve: Curves.easeOut,
                                scale: _hasText || _files.isNotEmpty ? 1 : 0.6,
                                child: AnimatedOpacity(
                                  duration: const Duration(milliseconds: 140),
                                  opacity:
                                      _hasText || _files.isNotEmpty ? 1 : 0,
                                  child: IconButton.filled(
                                    tooltip: s.enterSends
                                        ? '보내기 (Enter)'
                                        : '보내기 (${kMod}Enter)',
                                    icon: const Icon(Icons.arrow_upward_rounded),
                                    iconSize: 18,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(
                                        width: 32, height: 32),
                                    style: IconButton.styleFrom(
                                      minimumSize: const Size(32, 32),
                                      fixedSize: const Size(32, 32),
                                      padding: EdgeInsets.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: _send,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
        ),
        if (_dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.primary.withValues(alpha: 0.12),
                  border: Border.all(color: c.primary, width: 2),
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Text('여기에 놓아 첨부',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: c.primary)),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, required this.onClose});
  final IconData icon;
  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 44, bottom: 6),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: c.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
          IconButton(
              icon: const Icon(Icons.close, size: 16), onPressed: onClose),
        ],
      ),
    );
  }
}

/// 보내기 전 사진 첨부 미리보기
class _ImageAttachment extends StatelessWidget {
  const _ImageAttachment(
      {required this.path, required this.onClose, this.isImage = true});
  final String path;
  final bool isImage;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final name = path.split(Platform.pathSeparator).last;
    return Stack(
          children: [
            if (!isImage)
              Container(
                width: 150,
                height: 64,
                padding: const EdgeInsets.fromLTRB(12, 8, 30, 8),
                decoration: BoxDecoration(
                  color: c.secondaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(children: [
                  const Icon(Icons.attach_file, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5))),
                ]),
              )
            else
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxHeight: 110, maxWidth: 180),
                child: Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) => Container(
                    width: 120,
                    height: 80,
                    color: c.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Icon(Icons.image_outlined,
                        color: c.onSurfaceVariant),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 5,
              right: 5,
              child: Tooltip(
                message: '첨부 취소',
                child: GestureDetector(
                  onTap: onClose,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: const BoxDecoration(
                          color: Color(0xB3000000), shape: BoxShape.circle),
                      child: const Icon(Icons.close,
                          size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ],
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.state,
    required this.conv,
    required this.msg,
    required this.showDate,
    required this.showSender,
    required this.showMeta,
    required this.onReply,
  });
  final AppState state;
  final Conversation conv;
  final Message msg;
  final bool showDate, showSender, showMeta;
  final VoidCallback onReply;

  static const _emojis = ['👍', '😍', '😂', '😮', '😥', '😠', '👎'];

  Future<void> _menu(BuildContext context, Offset pos) async {
    MediaItem? media;
    for (final m in msg.media) {
      if (m.downloadable) {
        media = m;
        break;
      }
    }
    final v = await showFadeMenu<String>(
      context: context,
      at: pos,
      items: [
        if (!msg.isLocal)
          PopupMenuItem(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final e in _emojis)
                  InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => Navigator.pop(context, 'react:$e'),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Text(e, style: const TextStyle(fontSize: 21)),
                    ),
                  ),
              ],
            ),
          ),
        if (!msg.isLocal) const PopupMenuDivider(),
        if (msg.text.isNotEmpty) _mi('copy', Icons.copy_rounded, '복사'),
        if (!msg.isLocal) _mi('reply', Icons.reply_rounded, '답장'),
        if (media != null && media.isImage)
          _mi('view', Icons.image_outlined, '사진 크게 보기'),
        if (media != null) _mi('save', Icons.download_rounded, '다른 이름으로 저장'),
        if (media != null)
          _mi('openExt', Icons.open_in_new_rounded, '기본 앱으로 열기'),
        if (msg.failed && msg.text.isNotEmpty)
          _mi('resend', Icons.refresh_rounded, '다시 보내기'),
        _mi('info', Icons.info_outline_rounded, '정보'),
        const PopupMenuDivider(),
        _mi('delete', Icons.delete_outline_rounded, msg.isLocal ? '지우기' : '삭제',
            danger: true),
      ],
    );
    if (v == null || !context.mounted) return;
    try {
      if (v == 'copy') {
        await Clipboard.setData(ClipboardData(text: msg.text));
      } else if (v == 'reply') {
        onReply();
      } else if (v == 'delete') {
        if (msg.isLocal) {
          state.removeLocal(msg);
        } else {
          await state.deleteMessage(msg);
        }
      } else if (v == 'view' || v == 'save' || v == 'openExt') {
        final path = await state.mediaFile(media!);
        if (!context.mounted) return;
        if (v == 'view') {
          await _showImageViewer(context, state, media);
        } else if (v == 'openExt') {
          await launchUrl(Uri.file(path));
        } else {
          final base = path.split(Platform.pathSeparator).last;
          final loc = await getSaveLocation(
              suggestedName: media.name.isNotEmpty ? media.name : base);
          if (loc != null) {
            await File(path).copy(loc.path);
            if (context.mounted) _toast(context, '저장했습니다');
          }
        }
      } else if (v == 'resend') {
        final text = msg.text;
        if (msg.isLocal) state.removeLocal(msg);
        await state.send(msg.convId, text);
      } else if (v == 'info') {
        final d = DateTime.fromMillisecondsSinceEpoch(msg.ts);
        final p = conv.participant(msg.participantId);
        final mine = state.isMine(msg);
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('메시지 정보'),
            content: Text([
              '${mine ? '받는 사람' : '보낸 사람'}: ${mine ? conv.title : (p?.display ?? conv.title)}',
              '시각: ${formatDay(msg.ts)} ${formatTime(msg.ts)}:${d.second.toString().padLeft(2, '0')}',
              if (mine && msg.statusLabel.isNotEmpty) '상태: ${msg.statusLabel}',
              if (msg.media.isNotEmpty) '첨부: ${msg.media.length}개',
            ].join('\n')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('닫기')),
            ],
          ),
        );
      } else if (v.startsWith('react:')) {
        await state.react(msg, v.substring(6));
      }
    } catch (e) {
      if (context.mounted) _toast(context, '실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final children = <Widget>[];
    if (showDate) {
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text(formatDay(msg.ts),
              style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)),
        ),
      ));
    }
    if (msg.tombstone) {
      if (msg.text.isNotEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Center(
            child: Text(msg.text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)),
          ),
        ));
      }
      return Column(children: children);
    }

    final mine = state.isMine(msg);
    final dark = theme.brightness == Brightness.dark;
    final bubbleColor = !mine
        ? c.surfaceContainerHighest
        : oneUi
            ? (dark ? const Color(0xFF1B4A8F) : const Color(0xFFD3E5FF))
            : c.primary;
    final textColor = !mine
        ? c.onSurface
        : oneUi
            ? (dark ? Colors.white : const Color(0xFF0B1B33))
            : c.onPrimary;
    final align = mine ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    if (showSender) {
      final p = conv.participant(msg.participantId);
      final name = p?.display ?? msg.senderName;
      if (name.isNotEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.only(left: 12, top: 8, bottom: 2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(name,
                style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)),
          ),
        ));
      }
    }

    final parts = <Widget>[];
    for (final item in msg.media) {
      // MMS 배치 정보(SMIL) 같은 부분은 사람이 볼 내용이 아니므로 숨긴다
      if (item.mime.contains('smil') ||
          (item.mime.isEmpty && item.name.isEmpty && !item.downloadable)) {
        continue;
      }
      parts.add(Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: _MediaView(state: state, msg: msg, item: item, mine: mine),
      ));
    }
    if (msg.text.isNotEmpty) {
      parts.add(Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: msg.failed ? c.errorContainer : bubbleColor,
          borderRadius: BorderRadius.circular(oneUi ? 22 : 20),
        ),
        child: LinkText(msg.text,
            linkColor: msg.failed
                ? c.onErrorContainer
                : (mine && !oneUi
                    ? Colors.white
                    : (dark ? const Color(0xFF8AB8FF) : const Color(0xFF0B57D0))),
            style: TextStyle(
                fontSize: 14.5,
                height: 1.35,
                color: msg.failed ? c.onErrorContainer : textColor)),
      ));
      // 링크 미리보기 (스팸 폴더에서는 자동으로 불러오지 않는다)
      if (state.linkPreviews && conv.folder != 'spam') {
        final link = firstLink(msg.text);
        if (link != null) parts.add(LinkPreviewCard(uri: link));
      }
    }
    if (msg.reactions.isNotEmpty) {
      parts.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Wrap(
          spacing: 4,
          children: [
            for (final r in msg.reactions)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border.all(color: c.outlineVariant),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                    r.participants.length > 1
                        ? '${r.emoji} ${r.participants.length}'
                        : r.emoji,
                    style: const TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ));
    }
    if (showMeta) {
      final status = mine ? msg.statusLabel : '';
      final label = msg.localError != null
          ? '전송 실패: ${msg.localError}'
          : [
              formatTime(msg.ts),
              if (msg.typeLabel.isNotEmpty) msg.typeLabel,
              if (status.isNotEmpty) status,
            ].join(' · ');
      parts.add(Padding(
        padding: const EdgeInsets.only(top: 3, left: 6, right: 6, bottom: 6),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                color: msg.failed ? c.error : c.onSurfaceVariant)),
      ));
    }

    children.add(Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: _BubbleHover(
          mine: mine,
          onMore: (pos) => _menu(context, pos),
          onCopy: msg.text.isEmpty
              ? null
              : () => Clipboard.setData(ClipboardData(text: msg.text)),
          onReact: msg.isLocal ? null : (e) => state.react(msg, e),
          emojis: _emojis,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: GestureDetector(
              onSecondaryTapDown: (d) => _menu(context, d.globalPosition),
              child: Column(crossAxisAlignment: align, children: parts),
            ),
          ),
        ),
      ),
    ));
    return Column(children: children);
  }
}

/// 말풍선에 마우스를 올리면 옆에 빠른 동작(공감·복사·더보기)이 나타난다
class _BubbleHover extends StatefulWidget {
  const _BubbleHover({
    required this.mine,
    required this.child,
    required this.onMore,
    required this.emojis,
    this.onCopy,
    this.onReact,
  });
  final bool mine;
  final Widget child;
  final void Function(Offset pos) onMore;
  final VoidCallback? onCopy;
  final void Function(String emoji)? onReact;
  final List<String> emojis;

  @override
  State<_BubbleHover> createState() => _BubbleHoverState();
}

class _BubbleHoverState extends State<_BubbleHover> {
  bool _hover = false;
  bool _busy = false; // 메뉴가 떠 있는 동안은 계속 보인다

  Widget _btn(IconData icon, String tip, void Function(Offset pos) onTap) {
    final c = Theme.of(context).colorScheme;
    return Tooltip(
      message: tip,
      child: InkResponse(
        radius: 16,
        onTapUp: (d) => onTap(d.globalPosition),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 17, weight: 400, color: c.onSurfaceVariant),
        ),
      ),
    );
  }

  Future<void> _pickEmoji(Offset pos) async {
    setState(() => _busy = true);
    final v = await showFadeMenu<String>(
      context: context,
      at: pos + const Offset(-90, 14),
      minWidth: 0,
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Builder(
            builder: (ctx) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final e in widget.emojis)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => Navigator.pop(ctx, e),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Text(e, style: const TextStyle(fontSize: 20)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
    if (mounted) setState(() => _busy = false);
    if (v != null) widget.onReact?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final actions = AnimatedOpacity(
      duration: const Duration(milliseconds: 140),
      opacity: _hover || _busy ? 1 : 0,
      child: IgnorePointer(
        ignoring: !(_hover || _busy),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onReact != null)
                _btn(Symbols.add_reaction, '공감', _pickEmoji),
              if (widget.onCopy != null)
                _btn(Symbols.content_copy, '복사', (_) => widget.onCopy!()),
              _btn(Symbols.more_vert, '더보기', (pos) async {
                setState(() => _busy = true);
                widget.onMore(pos);
                await Future<void>.delayed(const Duration(milliseconds: 300));
                if (mounted) setState(() => _busy = false);
              }),
            ],
          ),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.mine) actions,
          Flexible(child: widget.child),
          if (!widget.mine) actions,
        ],
      ),
    );
  }
}

class _MediaView extends StatefulWidget {
  const _MediaView(
      {required this.state,
      required this.msg,
      required this.item,
      required this.mine});
  final AppState state;
  final Message msg;
  final MediaItem item;
  final bool mine;

  @override
  State<_MediaView> createState() => _MediaViewState();
}

class _MediaViewState extends State<_MediaView> {
  Future<String>? _future;
  bool _opening = false;

  MediaItem get item => widget.item;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  void _prepare() {
    _future = item.isImage && item.downloadable
        ? widget.state.mediaFile(item)
        : null;
    // 원본이 아직 없으면(미리보기뿐이거나 아무것도 없으면) 휴대폰에 원본을 요청한다
    if (item.localPath == null && (item.thumbOnly || !item.downloadable)) {
      widget.state.requestFullImage(widget.msg, item);
    }
  }

  @override
  void didUpdateWidget(_MediaView old) {
    super.didUpdateWidget(old);
    // 원본이 도착해 주소가 바뀌면 다시 불러온다
    if (old.item.mediaId != item.mediaId) _prepare();
  }

  Future<void> _open() async {
    if (!item.downloadable || _opening) return;
    setState(() => _opening = true);
    try {
      if (item.isImage && mounted) {
        await _showImageViewer(context, widget.state, item);
      } else {
        final path = await widget.state.mediaFile(item);
        await launchUrl(Uri.file(path));
      }
    } catch (e) {
      if (mounted) _toast(context, '파일을 열지 못했습니다: $e');
    }
    if (mounted) setState(() => _opening = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    if (_future != null) {
      var w = 280.0;
      var h = 200.0;
      if (item.w > 0 && item.h > 0) {
        final scale = [280 / item.w, 320 / item.h, 1.0]
            .reduce((a, b) => a < b ? a : b);
        w = item.w * scale;
        h = item.h * scale;
      }
      return FutureBuilder<String>(
        future: _future,
        builder: (ctx, snap) {
          Widget child;
          if (snap.hasData) {
            child = Image.file(File(snap.data!),
                width: item.w > 0 ? w : null,
                height: item.w > 0 ? h : null,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fileChip(c));
          } else if (snap.hasError) {
            child = _fileChip(c);
          } else {
            child = Container(
              width: w,
              height: h,
              color: c.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          final picture = GestureDetector(
            onTap: _open,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 280, maxHeight: 320),
                child: child,
              ),
            ),
          );
          if (!snap.hasData) return picture;
          // 대화창의 사진도 끌어서 다른 앱·폴더에 놓을 수 있다
          final path = snap.data!;
          return DragOutFile(path: path, name: item.name, child: picture);
        },
      );
    }
    return GestureDetector(onTap: _open, child: _fileChip(c));
  }

  Widget _fileChip(ColorScheme c) {
    final icon = item.mime.startsWith('video/')
        ? Icons.movie_outlined
        : item.mime.startsWith('audio/')
            ? Icons.audiotrack
            : item.isImage
                ? Icons.image_outlined
                : Icons.insert_drive_file_outlined;
    final name = item.name.isNotEmpty
        ? item.name
        : (item.isImage ? '사진' : '첨부 파일');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _opening
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, size: 22),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
                item.downloadable
                    ? name
                    : '$name (휴대폰 Google 메시지에서 먼저 받아 주세요)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, color: c.onSurface)),
          ),
        ],
      ),
    );
  }
}


/// 앱 안 사진 뷰어 열기: 지금 대화의 사진들을 좌우로 넘겨 볼 수 있다
Future<void> _showImageViewer(
    BuildContext context, AppState state, MediaItem item) {
  final conv = state.convs[state.selectedId];
  final who = conv == null
      ? ''
      : [
          conv.title,
          if (!conv.isGroup && conv.subtitle.isNotEmpty) conv.subtitle,
        ].join(' ');
  String title(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int v) => v.toString().padLeft(2, '0');
    return [
      if (who.isNotEmpty) who,
      '${d.year}.${two(d.month)}.${two(d.day)} ${formatTime(ts)}',
    ].join('  ·  ');
  }

  final all = <MediaItem>[];
  final titles = <String>[];
  for (final m
      in state.chats[state.selectedId]?.messages ?? const <Message>[]) {
    for (final x in m.media) {
      if (x.isImage && x.downloadable) {
        all.add(x);
        titles.add(title(m.ts));
      }
    }
  }
  var index = all.indexWhere((x) => identical(x, item));
  if (index < 0) {
    index = all.indexWhere(
        (x) => x.mediaId.isNotEmpty && x.mediaId == item.mediaId);
  }
  if (index < 0) return showImageViewer(context, state, [item], 0, [who]);
  return showImageViewer(context, state, all, index, titles);
}
