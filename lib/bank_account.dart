/// 사진에서 읽은 글자(줄 단위)에서 은행·계좌번호·예금주를 찾아낸다.
library;

class AccountInfo {
  const AccountInfo({required this.number, this.bank = '', this.holder = ''});

  /// 은행 이름 (못 찾으면 빈 글자)
  final String bank;

  /// 계좌번호: 하이픈·공백을 뺀 숫자만
  final String number;

  /// 예금주 (못 찾으면 빈 글자)
  final String holder;

  /// "은행 계좌번호 예금주" 한 줄
  String get summary =>
      [bank, number, holder].where((s) => s.isNotEmpty).join(' ');
}

/// 계좌번호에서 하이픈·공백 등 숫자가 아닌 것을 모두 뺀다
String cleanAccountNumber(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

class _Bank {
  const _Bank(this.name, this.strong, [this.weak]);
  final String name;

  /// 어디에 나와도 은행으로 보는 표기 (공백 없이, 영문은 대문자로 비교)
  final String strong;

  /// 흔한 낱말이기도 해서, 계좌번호와 같은 줄에 있을 때만 은행으로 보는 표기
  final String? weak;
}

const _banks = <_Bank>[
  _Bank('카카오뱅크', r'카카오뱅크|카카오BANK|KAKAOBANK|카뱅', r'카카오'),
  _Bank('토스뱅크', r'토스뱅크|TOSSBANK', r'토스'),
  _Bank('케이뱅크', r'케이뱅크|K뱅크|KBANK'),
  _Bank('KB국민은행', r'국민은행|KB국민|KB은행|KOOKMIN', r'국민|KB'),
  _Bank('신한은행', r'신한은행|SHINHAN', r'신한'),
  _Bank('우리은행', r'우리은행|WOORI', r'우리'),
  _Bank('하나은행', r'하나은행|KEB하나|외환은행|HANABANK', r'하나'),
  _Bank('NH농협은행', r'농협|NH은행|NONGHYUP', r'NH'),
  _Bank('IBK기업은행', r'기업은행|IBK', r'기업'),
  _Bank('SC제일은행', r'SC제일|제일은행|SC은행', r'제일'),
  _Bank('한국씨티은행', r'씨티은행|시티은행|CITIBANK', r'씨티'),
  _Bank('새마을금고', r'새마을금고|새마을|MG금고', r'MG'),
  _Bank('신협', r'신협|신용협동조합'),
  _Bank('우체국', r'우체국'),
  _Bank('수협은행', r'수협'),
  _Bank('KDB산업은행', r'산업은행|KDB', r'산업'),
  _Bank('부산은행', r'부산은행|BNK부산', r'부산'),
  _Bank('경남은행', r'경남은행|BNK경남', r'경남'),
  _Bank('iM뱅크(대구은행)', r'대구은행|IM뱅크|아이엠뱅크', r'대구'),
  _Bank('광주은행', r'광주은행', r'광주'),
  _Bank('전북은행', r'전북은행', r'전북'),
  _Bank('제주은행', r'제주은행', r'제주'),
  _Bank('저축은행', r'저축은행'),
  _Bank('산림조합', r'산림조합'),
  _Bank('미래에셋증권', r'미래에셋'),
  _Bank('삼성증권', r'삼성증권'),
  _Bank('키움증권', r'키움'),
  _Bank('한국투자증권', r'한국투자|한투증권'),
  _Bank('NH투자증권', r'NH투자'),
  _Bank('KB증권', r'KB증권'),
  _Bank('신한투자증권', r'신한투자|신한금융투자'),
  _Bank('토스증권', r'토스증권'),
];

/// 은행 이름을 찾는다. [sameLine] 이면 약한 표기(국민, 하나 …)도 받아들인다.
String _findBank(String line, {required bool sameLine}) {
  final t = line.replaceAll(RegExp(r'\s'), '').toUpperCase();
  String best = '';
  var bestAt = 1 << 30;
  for (final b in _banks) {
    final m = RegExp(b.strong).firstMatch(t);
    if (m != null && m.start < bestAt) {
      best = b.name;
      bestAt = m.start;
    }
  }
  if (best.isNotEmpty || !sameLine) return best;
  for (final b in _banks) {
    if (b.weak == null) continue;
    // 영문 약칭(KB, NH, MG)은 앞뒤가 영문이 아닐 때만
    final m = RegExp('(?<![A-Z])(?:${b.weak})(?![A-Z])').firstMatch(t);
    if (m != null && m.start < bestAt) {
      best = b.name;
      bestAt = m.start;
    }
  }
  return best;
}

final _labelRe = RegExp(r'계\s*좌|입\s*금|송\s*금|이\s*체|account', caseSensitive: false);

/// 숫자 묶음: 숫자로 시작해 숫자·하이픈·공백이 이어지는 것
final _numRe = RegExp(r'\d(?:[\d]|\s?[-‐‑–—―]\s?(?=\d)|\s(?=\d)){8,24}');

bool _looksLikeOther(String raw, String digits) {
  final groups = raw
      .split(RegExp(r'[^0-9]+'))
      .where((g) => g.isNotEmpty)
      .map((g) => g.length)
      .toList();
  // 휴대폰·지역번호·대표번호
  if (RegExp(r'^01[016789]').hasMatch(digits) &&
      (digits.length == 10 || digits.length == 11) &&
      groups.length == 3) {
    return true;
  }
  if (RegExp(r'^0(2|[3-6][1-5]|70|50\d)').hasMatch(digits) &&
      digits.length <= 12 &&
      groups.length >= 2 &&
      groups.last == 4) {
    return true;
  }
  // 카드번호 (4-4-4-4)
  if (groups.length == 4 && groups.every((g) => g == 4)) return true;
  // 사업자등록번호 (3-2-5)
  if (groups.length == 3 && groups[0] == 3 && groups[1] == 2 && groups[2] == 5) {
    return true;
  }
  // 주민등록번호 꼴 (6-7)
  if (groups.length == 2 && groups[0] == 6 && groups[1] == 7) return true;
  // 날짜·시각을 늘어놓은 것 (2026 11 21 10 30 …)
  if (RegExp(r'^(19|20)\d{2}$').hasMatch(raw.split(RegExp(r'[^0-9]+')).first) &&
      groups.length >= 3 &&
      groups.skip(1).every((g) => g <= 2)) {
    return true;
  }
  return false;
}

const _notNames = {
  '은행', '계좌', '계좌번호', '입금', '송금', '이체', '예금주', '금액', '원', '까지',
  '부탁', '감사', '입니다', '으로', '에서', '번호', '확인', '안내', '보내', '주세요',
};

String _tidyName(String s) {
  var t = s
      .replaceAll(RegExp(r'^[\s:：\-=·,.)\]]+'), '')
      .replaceAll(RegExp(r'[\s:：\-=·,.(\[]+$'), '');
  // 짝이 맞지 않는 닫는 괄호는 뗀다: "(예금주: 이영희)" 의 "이영희)"
  while (t.endsWith(')') &&
      ')'.allMatches(t).length > '('.allMatches(t).length) {
    t = t.substring(0, t.length - 1).trimRight();
  }
  // 뒤따르는 다른 항목은 잘라 낸다
  t = t.split(RegExp(r'\s{2,}|[,/|]|계\s*좌|은\s*행|입\s*금|금\s*액|\d{3,}')).first.trim();
  // "홍 길 동"처럼 한 글자씩 떨어진 이름은 붙인다
  if (RegExp(r'^(?:[가-힣]\s+){1,5}[가-힣]$').hasMatch(t)) {
    t = t.replaceAll(RegExp(r'\s+'), '');
  }
  t = t.replaceAll(RegExp(r'\s*(님|씨|귀하)$'), '').trim();
  if (t.length < 2 || t.length > 30) return '';
  if (!RegExp(r'[가-힣A-Za-z]').hasMatch(t)) return '';
  return t;
}

final _holderRe = RegExp(
    r'(?:예\s*금\s*주(?:\s*명)?|계\s*좌\s*주|수\s*취\s*인(?:\s*명)?|받\s*는\s*(?:분|사\s*람)|입\s*금\s*주)\s*[:：\-]?\s*(.*)$');

/// 글자 줄들에서 계좌 정보를 찾는다. 계좌번호를 못 찾으면 null.
AccountInfo? parseAccount(List<String> lines) {
  final all = lines.join('\n');
  final anyLabel = _labelRe.hasMatch(all) ||
      RegExp(r'예\s*금\s*주').hasMatch(all);
  final anyBank = lines.any((l) => _findBank(l, sameLine: false).isNotEmpty);

  // ── 계좌번호 후보에 점수를 매겨 가장 그럴듯한 것을 고른다 ──
  String number = '';
  var numLine = -1;
  var numEnd = 0;
  var bestScore = -1 << 30;
  for (var i = 0; i < lines.length; i++) {
    for (final m in _numRe.allMatches(lines[i])) {
      final raw = m.group(0)!.trim();
      final digits = cleanAccountNumber(raw);
      if (digits.length < 10 || digits.length > 16) continue;
      if (_looksLikeOther(raw, digits)) continue;
      var score = 0;
      final before = lines[i].substring(0, m.start);
      if (RegExp(r'계\s*좌').hasMatch(before)) score += 6;
      if (_labelRe.hasMatch(lines[i])) score += 3;
      if (i > 0 && RegExp(r'계\s*좌').hasMatch(lines[i - 1])) score += 3;
      if (_findBank(lines[i], sameLine: true).isNotEmpty) score += 4;
      if (i > 0 && _findBank(lines[i - 1], sameLine: false).isNotEmpty) score += 2;
      if (i + 1 < lines.length &&
          _findBank(lines[i + 1], sameLine: false).isNotEmpty) {
        score += 1;
      }
      if (raw.contains(RegExp(r'[-‐‑–—―]'))) score += 2;
      if (digits.length >= 11 && digits.length <= 14) score += 1;
      if (score > bestScore) {
        bestScore = score;
        number = digits;
        numLine = i;
        numEnd = m.end;
      }
    }
  }
  if (number.isEmpty) return null;
  // 은행 이름도 '계좌' 같은 말도 없으면 그냥 긴 숫자일 가능성이 크다
  var bank = _findBank(lines[numLine], sameLine: true);
  if (!anyBank && !anyLabel && bank.isEmpty) return null;

  // ── 은행: 계좌번호와 같은 줄 → 가까운 줄 순서로 ──
  for (var d = 1; bank.isEmpty && d <= 3; d++) {
    for (final j in [numLine - d, numLine + d]) {
      if (j < 0 || j >= lines.length) continue;
      bank = _findBank(lines[j], sameLine: false);
      if (bank.isNotEmpty) break;
    }
  }
  if (bank.isEmpty) {
    for (final l in lines) {
      bank = _findBank(l, sameLine: false);
      if (bank.isNotEmpty) break;
    }
  }

  // ── 예금주: "예금주: 홍길동" 꼴이 우선 ──
  var holder = '';
  for (var i = 0; i < lines.length && holder.isEmpty; i++) {
    final m = _holderRe.firstMatch(lines[i]);
    if (m == null) continue;
    holder = _tidyName(m.group(1) ?? '');
    // 이름이 다음 줄에 있는 경우
    if (holder.isEmpty && i + 1 < lines.length) {
      holder = _tidyName(lines[i + 1]);
    }
  }
  // 표시가 없으면 계좌번호 바로 뒤(같은 줄)의 짧은 한글 이름: "신한 110-123-456789 홍길동"
  if (holder.isEmpty) {
    final rest = lines[numLine].substring(numEnd.clamp(0, lines[numLine].length));
    final m = RegExp(r'^[\s()\[\]:：,·\-]*((?:[가-힣]\s?){2,4})(?![가-힣])')
        .firstMatch(rest);
    if (m != null) {
      final name = m.group(1)!.replaceAll(RegExp(r'\s'), '');
      if (!_notNames.contains(name) &&
          _findBank(name, sameLine: true).isEmpty) {
        holder = name;
      }
    }
  }
  if (_notNames.contains(holder)) holder = '';

  return AccountInfo(number: number, bank: bank, holder: holder);
}
