import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
// 패키지의 끌기 시작 함수를 직접 부르기 위해 내부 파일을 쓴다
// ignore: implementation_imports
import 'package:super_drag_and_drop/src/drag_internal.dart'
    show DesktopDragDetector;

/// 파일(사진)을 끌어서 다른 앱·폴더에 놓을 수 있게 한다.
///
/// 패키지 기본 위젯은 글자 선택·화면 이동 같은 다른 끌기 동작과 경쟁하다가 져서
/// 끌기가 시작되지 않거나 늦게 시작된다. 여기서는 경쟁 없이 포인터를 직접 지켜보다가
/// 조금(3px)만 움직여도 곧바로 끌기를 시작하고, 커서 옆에 작은 미리보기를 붙인다.
class DragOutFile extends StatefulWidget {
  const DragOutFile({
    super.key,
    required this.path,
    required this.child,
    this.name = '',
    this.enabled,
  });
  final String path;
  final String name;
  final bool Function()? enabled;
  final Widget child;

  @override
  State<DragOutFile> createState() => _DragOutFileState();
}

class _DragOutFileState extends State<DragOutFile> {
  Offset? _down;
  int? _pointer;
  bool _started = false;

  bool get _on => widget.enabled?.call() ?? true;

  void _start(Offset pos) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final path = widget.path;
    final base = path.split(Platform.pathSeparator).last;
    final detector = DesktopDragDetector(
      isLocationDraggable: (_) => true,
      hitTestBehavior: HitTestBehavior.deferToChild,
      dragConfiguration: (position, session) async {
        // 커서 옆에 붙는 작은 미리보기
        const w = 132.0;
        final codec = await ui.instantiateImageCodec(
            await File(path).readAsBytes(),
            targetWidth: (w * dpr).round());
        final image = (await codec.getNextFrame()).image;
        final h = w * image.height / image.width;
        final item =
            DragItem(suggestedName: widget.name.isNotEmpty ? widget.name : base);
        item.add(Formats.fileUri(Uri.file(path)));
        return DragConfiguration(
          allowedOperations: [DropOperation.copy],
          items: [
            DragConfigurationItem(
              item: item,
              image: TargetedWidgetSnapshot(
                WidgetSnapshot.image(image),
                Rect.fromLTWH(position.dx - w / 2, position.dy - h / 2, w, h),
              ),
            ),
          ],
        );
      },
      child: const SizedBox.shrink(),
    );
    detector.maybeStartDrag(context, _pointer, pos, dpr);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.mouse &&
            e.buttons == kPrimaryMouseButton) {
          _down = e.position;
          _pointer = e.pointer;
          _started = false;
        }
      },
      onPointerMove: (e) {
        final d = _down;
        if (d == null || _started || !_on) return;
        if ((e.position - d).distance > 3) {
          _started = true;
          _start(e.position);
        }
      },
      onPointerUp: (_) => _down = null,
      onPointerCancel: (_) => _down = null,
      // 패키지 초기화를 위해 기본 위젯도 둔다 (끌기 시작은 위에서 직접 한다)
      child: DragItemWidget(
        allowedOperations: () => [DropOperation.copy],
        dragItemProvider: (_) => null,
        child: DraggableWidget(
          isLocationDraggable: (_) => false,
          child: widget.child,
        ),
      ),
    );
  }
}
