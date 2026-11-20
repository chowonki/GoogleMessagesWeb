import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'store.dart';

/// PIN 입력 대화상자. [confirm] 이면 두 번 입력받아 일치를 확인한다.
Future<String?> askPin(BuildContext context,
    {required String title, bool confirm = false, String? hint}) {
  final digits = [
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(4),
  ];
  final a = TextEditingController();
  final b = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      void submit() {
        if (a.text.length != 4) {
          setState(() => error = '숫자 4자리를 입력해 주세요');
        } else if (confirm && a.text != b.text) {
          setState(() => error = '두 PIN이 서로 다릅니다');
        } else {
          Navigator.pop(ctx, a.text);
        }
      }

      InputDecoration deco(String label) => InputDecoration(
            labelText: label,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          );
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(hint, style: const TextStyle(fontSize: 13)),
                ),
              TextField(
                controller: a,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                decoration: deco('휴대폰 번호 뒤 4자리'),
                onSubmitted: (_) => confirm ? null : submit(),
              ),
              if (confirm) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: b,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  decoration: deco('다시 입력'),
                  onSubmitted: (_) => submit(),
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(error!,
                      style: TextStyle(
                          color: Theme.of(ctx).colorScheme.error,
                          fontSize: 13)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(onPressed: submit, child: const Text('확인')),
        ],
      );
    }),
  );
}

/// 앱 잠금 화면: PIN을 입력해야 대화가 보인다.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.state});
  final AppState state;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pin = TextEditingController();
  final _focus = FocusNode();
  bool _wrong = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _pin.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.state.unlock(_pin.text)) return;
    setState(() => _wrong = true);
    _pin.clear();
    _focus.requestFocus();
  }

  Future<void> _forgot() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('잠금을 풀 수 없나요?'),
        content: const Text(
            '잠금 번호는 잠금을 켤 때의 휴대폰 번호 뒤 4자리입니다. 그래도 풀리지 않으면 로그아웃해서 잠금을 해제할 수 있고, 이후 Google 계정으로 다시 로그인해 휴대폰과 연결해야 합니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('로그아웃하고 잠금 해제')),
        ],
      ),
    );
    if (ok == true) await widget.state.resetLockByLogout();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.lock, size: 44, weight: 300, color: c.primary),
              const SizedBox(height: 14),
              const Text('잠겨 있습니다',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('휴대폰 번호 뒤 4자리를 입력하세요',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: c.onSurfaceVariant)),
              const SizedBox(height: 22),
              TextField(
                controller: _pin,
                focusNode: _focus,
                obscureText: true,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, letterSpacing: 6),
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                onSubmitted: (_) => _submit(),
                onChanged: (v) {
                  if (_wrong) setState(() => _wrong = false);
                  if (v.length == 4) _submit(); // 4자리를 다 치면 바로 확인
                },
                decoration: InputDecoration(
                  filled: true,
                  fillColor: c.surface,
                  hintText: '● ● ● ●',
                  hintStyle: const TextStyle(letterSpacing: 0, fontSize: 15),
                  errorText: _wrong ? '번호가 맞지 않습니다' : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(26),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton(
                style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 46)),
                onPressed: _submit,
                child: const Text('잠금 해제'),
              ),
              const SizedBox(height: 6),
              TextButton(onPressed: _forgot, child: const Text('번호가 맞지 않나요?')),
            ],
          ),
        ),
      ),
    );
  }
}
