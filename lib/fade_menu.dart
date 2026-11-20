import 'package:flutter/material.dart';

/// 페이드로 나타나고 사라지는 팝업 메뉴. 항목은 [PopupMenuItem]·[PopupMenuDivider] 를
/// 그대로 쓰며, 고르면 그 값이 돌아온다.
Future<T?> showFadeMenu<T>({
  required BuildContext context,
  required Offset at,
  required List<PopupMenuEntry<T>> items,
  double minWidth = 190,
}) {
  final theme = Theme.of(context);
  final pm = PopupMenuTheme.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '메뉴 닫기',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (ctx, _, __) => CustomSingleChildLayout(
      delegate: _MenuLayout(at),
      child: Material(
        color: pm.color ?? theme.colorScheme.surfaceContainerHigh,
        elevation: pm.elevation ?? 8,
        shadowColor: pm.shadowColor ?? Colors.black54,
        surfaceTintColor: Colors.transparent,
        shape: pm.shape ??
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: minWidth, maxWidth: 340),
          child: IntrinsicWidth(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: items,
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (_, a, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
      child: child,
    ),
  );
}

class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.at);
  final Offset at;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) =>
      BoxConstraints.loose(Size(c.maxWidth - 16, c.maxHeight - 16));

  @override
  Offset getPositionForChild(Size size, Size child) {
    var x = at.dx, y = at.dy;
    if (x + child.width > size.width - 8) x = size.width - child.width - 8;
    if (y + child.height > size.height - 8) y = size.height - child.height - 8;
    return Offset(x < 8 ? 8 : x, y < 8 ? 8 : y);
  }

  @override
  bool shouldRelayout(_MenuLayout old) => old.at != at;
}
