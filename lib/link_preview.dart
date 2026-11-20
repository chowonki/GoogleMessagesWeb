import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

final RegExp kUrlPattern = RegExp(
    r'''((?:https?://|www\.)[^\s<>"'`]+)''',
    caseSensitive: false);

/// 문장 끝 구두점은 주소에서 뺀다
String _trimUrl(String u) {
  var s = u;
  while (s.isNotEmpty && '.,!?;:)]}>\'"'.contains(s[s.length - 1])) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

Uri? _toUri(String raw) {
  final t = _trimUrl(raw);
  final u = Uri.tryParse(t.toLowerCase().startsWith('http') ? t : 'https://$t');
  if (u == null || u.host.isEmpty || !u.host.contains('.')) return null;
  return u;
}

/// 글 속 첫 번째 링크
Uri? firstLink(String text) {
  for (final m in kUrlPattern.allMatches(text)) {
    final u = _toUri(m.group(0)!);
    if (u != null) return u;
  }
  return null;
}

Future<void> openLink(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// 링크를 눌러 열 수 있는 메시지 글
class LinkText extends StatefulWidget {
  const LinkText(this.text, {super.key, required this.style, required this.linkColor});
  final String text;
  final TextStyle style;
  final Color linkColor;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  final List<TapGestureRecognizer> _recognizers = [];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final text = widget.text;
    final spans = <InlineSpan>[];
    var pos = 0;
    for (final m in kUrlPattern.allMatches(text)) {
      final raw = _trimUrl(m.group(0)!);
      final uri = _toUri(raw);
      if (uri == null) continue;
      if (m.start > pos) spans.add(TextSpan(text: text.substring(pos, m.start)));
      final rec = TapGestureRecognizer()..onTap = () => openLink(uri);
      _recognizers.add(rec);
      spans.add(TextSpan(
        text: raw,
        recognizer: rec,
        mouseCursor: SystemMouseCursors.click,
        style: TextStyle(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
            decorationColor: widget.linkColor.withValues(alpha: 0.6)),
      ));
      pos = m.start + raw.length;
    }
    if (spans.isEmpty) return Text(text, style: widget.style);
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    return Text.rich(TextSpan(children: spans), style: widget.style);
  }
}

// ───────────────────────── 미리보기 정보 가져오기 ─────────────────────────

class LinkInfo {
  LinkInfo({required this.host, this.title = '', this.description = '', this.image});
  final String host, title, description;
  final String? image;
  bool get hasContent => title.isNotEmpty || description.isNotEmpty || image != null;
}

final Map<String, Future<LinkInfo?>> _cache = {};

Future<LinkInfo?> fetchLinkInfo(Uri uri) =>
    _cache.putIfAbsent(uri.toString(), () => _fetch(uri));

String _decodeEntities(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String? _meta(String html, List<String> keys) {
  for (final k in keys) {
    final key = RegExp.escape(k);
    for (final p in [
      '<meta[^>]+(?:property|name)\\s*=\\s*["\']$key["\'][^>]*?content\\s*=\\s*["\']([^"\']*)["\']',
      '<meta[^>]+content\\s*=\\s*["\']([^"\']*)["\'][^>]*?(?:property|name)\\s*=\\s*["\']$key["\']',
    ]) {
      final m = RegExp(p, caseSensitive: false).firstMatch(html);
      final v = m?.group(1);
      if (v != null && v.trim().isNotEmpty) return _decodeEntities(v);
    }
  }
  return null;
}

Future<LinkInfo?> _fetch(Uri uri) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36 facebookexternalhit/1.1';
  try {
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 8));
    req.headers.set(HttpHeaders.acceptHeader, 'text/html,*/*;q=0.8');
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'ko-KR,ko;q=0.9,en;q=0.7');
    final res = await req.close().timeout(const Duration(seconds: 8));
    final finalUri = res.redirects.isNotEmpty ? res.redirects.last.location : uri;
    final base = finalUri.hasScheme ? finalUri : uri.resolveUri(finalUri);
    final type = res.headers.contentType;
    if (res.statusCode >= 400) return null;
    if (type != null && type.primaryType == 'image') {
      return LinkInfo(host: base.host, image: base.toString());
    }
    if (type != null && type.subType != 'html' && type.subType != 'xhtml+xml') {
      return null;
    }
    // 앞쪽 300KB 만 읽는다 (meta 태그는 head 에 있다)
    final bytes = <int>[];
    await for (final chunk in res.timeout(const Duration(seconds: 8))) {
      bytes.addAll(chunk);
      if (bytes.length > 300 * 1024) break;
    }
    final charset = (type?.charset ?? '').toLowerCase();
    var html = utf8.decode(bytes, allowMalformed: true);
    final legacy = charset.contains('euc-kr') ||
        charset.contains('949') ||
        RegExp(r'charset\s*=\s*["\x27]?(euc-kr|ks_c|cp949)', caseSensitive: false)
            .hasMatch(html);
    var title = legacy ? '' : (_meta(html, ['og:title', 'twitter:title']) ?? '');
    if (title.isEmpty && !legacy) {
      final m = RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false)
          .firstMatch(html);
      title = _decodeEntities(m?.group(1) ?? '');
    }
    final desc = legacy
        ? ''
        : (_meta(html, ['og:description', 'twitter:description', 'description']) ?? '');
    var image = _meta(html, ['og:image', 'og:image:url', 'twitter:image']);
    if (image != null) {
      try {
        image = base.resolve(image).toString();
      } catch (_) {
        image = null;
      }
    }
    html = '';
    return LinkInfo(host: base.host, title: title, description: desc, image: image);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 링크 미리보기 카드 (제목·설명·대표 이미지). 정보를 못 가져오면 아무것도 그리지 않는다.
class LinkPreviewCard extends StatefulWidget {
  const LinkPreviewCard({super.key, required this.uri});
  final Uri uri;

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  late Future<LinkInfo?> _future = fetchLinkInfo(widget.uri);

  @override
  void didUpdateWidget(LinkPreviewCard old) {
    super.didUpdateWidget(old);
    if (old.uri != widget.uri) _future = fetchLinkInfo(widget.uri);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return FutureBuilder<LinkInfo?>(
      future: _future,
      builder: (ctx, snap) {
        final info = snap.data;
        if (info == null || !info.hasContent) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => openLink(widget.uri),
              child: Container(
                width: 300,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: c.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                      color: c.outlineVariant.withValues(alpha: 0.6)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (info.image != null)
                      Image.network(info.image!,
                          width: 300,
                          height: 150,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const SizedBox.shrink()),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(13, 10, 13, 11),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (info.title.isNotEmpty)
                            Text(info.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: c.onSurface)),
                          if (info.description.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(info.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      height: 1.35,
                                      color: c.onSurfaceVariant)),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Text(info.host,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11.5, color: c.primary)),
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
      },
    );
  }
}
