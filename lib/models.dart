int _int(dynamic v) => v is num ? v.toInt() : 0;
String _str(dynamic v) => v == null ? '' : v.toString();

class Participant {
  Participant.fromJson(Map<String, dynamic> j)
      : id = _str(j['id']),
        number = _str(j['number']),
        formatted = _str(j['formatted']),
        name = _str(j['name']),
        color = _str(j['color']),
        isMe = j['isMe'] == true;
  final String id, number, formatted, name, color;
  final bool isMe;

  String get display => name.isNotEmpty
      ? name
      : (formatted.isNotEmpty ? formatted : number);
}

class Conversation {
  Conversation.fromJson(Map<String, dynamic> j)
      : id = _str(j['id']),
        name = _str(j['name']),
        ts = _int(j['ts']),
        unread = j['unread'] == true,
        isGroup = j['isGroup'] == true,
        preview = _str(j['preview']),
        previewFromMe = j['previewFromMe'] == true,
        status = _str(j['status']),
        readOnly = j['readOnly'] == true,
        color = _str(j['color']),
        outgoingId = _str(j['outgoingId']),
        pinned = j['pinned'] == true,
        latestMsgId = _str(j['latestMsgId']),
        type = _str(j['type']),
        participants = ((j['participants'] as List?) ?? const [])
            .map((e) => Participant.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();

  final String id, name, status, color, outgoingId;

  /// 'RCS' 또는 'SMS' (휴대폰이 알려 주는 대화 종류)
  final String type;
  bool get isRcs => type == 'RCS';
  int ts;
  bool unread;
  final bool isGroup, readOnly, pinned;
  String preview;
  bool previewFromMe;
  String latestMsgId;
  final List<Participant> participants;

  List<Participant> get others => participants.where((p) => !p.isMe).toList();

  String get title {
    if (name.isNotEmpty) return name;
    final o = others.map((p) => p.display).where((s) => s.isNotEmpty).toList();
    return o.isEmpty ? '(알 수 없음)' : o.join(', ');
  }

  /// 1:1 대화의 상대. 내 번호가 '나'로 표시되지 않고 참여자에 섞여 오는 경우가 있어,
  /// 대화 이름과 맞는 참여자를 먼저 고른다.
  Participant? get peer {
    if (isGroup) return null;
    final o = others;
    if (o.isEmpty) return null;
    if (o.length == 1) return o.first;
    for (final p in o) {
      if (name.isNotEmpty &&
          (p.name == name || p.formatted == name || p.number == name)) {
        return p;
      }
    }
    return o.first;
  }

  String get subtitle {
    final p = peer;
    if (p != null) {
      final num = p.formatted.isNotEmpty ? p.formatted : p.number;
      return num == title ? '' : num;
    }
    final o = others;
    return o.isEmpty ? '' : '${o.length}명';
  }

  String get folder {
    switch (status) {
      case 'ARCHIVED':
      case 'KEEP_ARCHIVED':
        return 'archive';
      case 'SPAM_FOLDER':
      case 'BLOCKED_FOLDER':
        return 'spam';
      case 'DELETED':
      case 'TRASH_FOLDER':
        return 'deleted';
    }
    return 'inbox';
  }

  Participant? participant(String id) {
    for (final p in participants) {
      if (p.id == id) return p;
    }
    return null;
  }
}

class MediaItem {
  MediaItem.fromJson(Map<String, dynamic> j)
      // 원본 주소가 없고 미리보기만 온 사진(용량이 큰 사진 등)은 미리보기로 연다
      : mediaId = _full(j) ? _str(j['mediaId']) : _str(j['thumbId']),
        key = _full(j) ? _str(j['key']) : _str(j['thumbKey']),
        thumbOnly = !_full(j) &&
            _str(j['thumbId']).isNotEmpty &&
            _str(j['thumbKey']).isNotEmpty,
        partId = _str(j['partId']),
        mime = _str(j['mime']),
        name = _str(j['name']),
        size = _int(j['size']),
        w = _int(j['w']),
        h = _int(j['h']),
        localPath = j['localPath'] as String?;
  static bool _full(Map<String, dynamic> j) =>
      _str(j['mediaId']).isNotEmpty && _str(j['key']).isNotEmpty;

  /// 원본 없이 미리보기 화질로만 볼 수 있음
  final bool thumbOnly;

  /// 메시지 안에서 이 첨부를 가리키는 번호 (원본 요청에 쓴다)
  final String partId;
  final String mediaId, key, mime, name;
  final int size, w, h;
  final String? localPath;

  bool get isImage => mime.startsWith('image/');
  bool get downloadable =>
      localPath != null || (mediaId.isNotEmpty && key.isNotEmpty);
}

class Reaction {
  Reaction(this.emoji, this.participants);
  final String emoji;
  final List<String> participants;
}

class Message {
  Message.fromJson(Map<String, dynamic> j)
      : id = _str(j['id']),
        convId = _str(j['convId']),
        participantId = _str(j['participantId']),
        ts = _int(j['ts']),
        status = _int(j['status']),
        msgType = _int(j['msgType']),
        text = _str(j['text']),
        tmpId = _str(j['tmpId']),
        senderName = _str(j['senderName']),
        media = ((j['media'] as List?) ?? const [])
            .map((e) => MediaItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        reactions = ((j['reactions'] as List?) ?? const [])
            .map((e) => Reaction(_str((e as Map)['emoji']),
                ((e['participants'] as List?) ?? const []).map(_str).toList()))
            .toList();

  final String id, convId, participantId, text, tmpId, senderName;
  final int ts;
  int status;

  /// 1 = SMS, 2 = MMS, 3 = 아직 받지 않은 MMS, 4 = RCS(채팅)
  final int msgType;
  String get typeLabel => switch (msgType) {
        1 => 'SMS',
        2 || 3 => 'MMS',
        4 => '채팅',
        _ => '',
      };
  final List<MediaItem> media;
  final List<Reaction> reactions;
  String? localError;

  bool get isLocal => id.startsWith('local:');
  bool get incoming => status >= 100 && status < 200;
  bool get outgoing => status > 0 && status < 100;
  bool get tombstone => status >= 200 && status < 300;
  bool get deleted => status == 300 || status == 23;

  bool get failed =>
      localError != null ||
      const {8, 9, 12, 13, 17, 18, 19, 21, 22, 24, 25, 26, 27}.contains(status);
  bool get sending => const {4, 5, 6, 7, 10, 20}.contains(status);

  String get statusLabel {
    if (failed) return '전송 실패';
    if (sending) return '전송 중…';
    switch (status) {
      case 2:
        return '전달됨';
      case 11:
        return '읽음';
      case 16:
        return '예약됨';
      case 1:
      case 14:
        return '전송됨';
    }
    return '';
  }

  String get summary {
    if (text.isNotEmpty) return text;
    if (media.isNotEmpty) {
      return media.first.isImage ? '사진' : '첨부 파일';
    }
    return '';
  }
}

String formatTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '${d.hour < 12 ? '오전' : '오후'} $h:$m';
}

bool sameDay(int a, int b) {
  final x = DateTime.fromMillisecondsSinceEpoch(a);
  final y = DateTime.fromMillisecondsSinceEpoch(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

String formatDay(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  const wd = ['월', '화', '수', '목', '금', '토', '일'];
  if (d.year == now.year) {
    return '${d.month}월 ${d.day}일 ${wd[d.weekday - 1]}요일';
  }
  return '${d.year}년 ${d.month}월 ${d.day}일';
}

/// 대화 목록용 짧은 시각 표시
String formatListTime(int ms) {
  if (ms <= 0) return '';
  final now = DateTime.now().millisecondsSinceEpoch;
  if (sameDay(ms, now)) return formatTime(ms);
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  if (d.year == DateTime.now().year) return '${d.month}월 ${d.day}일';
  return '${d.year}. ${d.month}. ${d.day}.';
}
