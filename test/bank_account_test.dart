import 'package:flutter_test/flutter_test.dart';
import 'package:google_messages/bank_account.dart';

void main() {
  AccountInfo? p(String text) => parseAccount(text.split('\n'));

  test('하이픈·공백을 뺀다', () {
    expect(cleanAccountNumber('110-123-456789'), '110123456789');
    expect(cleanAccountNumber(' 3333 01 2345678 '), '3333012345678');
  });

  test('은행 · 계좌번호 · 예금주가 한 줄에', () {
    final a = p('신한 110-123-456789 홍길동')!;
    expect(a.bank, '신한은행');
    expect(a.number, '110123456789');
    expect(a.holder, '홍길동');
  });

  test('항목 이름이 붙은 여러 줄', () {
    final a = p('입금 안내\n은행 : 카카오뱅크\n계좌번호 : 3333-01-2345678\n예금주 : 김 철 수\n금액 : 35,000원')!;
    expect(a.bank, '카카오뱅크');
    expect(a.number, '3333012345678');
    expect(a.holder, '김철수');
  });

  test('공백으로 띄운 계좌번호와 회사 예금주', () {
    final a = p('국민은행 123456 04 123456\n예금주 (주)가나다상사')!;
    expect(a.bank, 'KB국민은행');
    expect(a.number, '12345604123456');
    expect(a.holder, '(주)가나다상사');
  });

  test('전화번호가 함께 있어도 계좌번호를 고른다', () {
    final a = p('문의 010-1234-5678\n농협 302-1234-5678-91 (예금주: 이영희)\n2026-11-21 까지 입금')!;
    expect(a.bank, 'NH농협은행');
    expect(a.number, '3021234567891');
    expect(a.holder, '이영희');
  });

  test('예금주가 다음 줄에', () {
    final a = p('우리은행 1002-123-456789\n예금주\n박민수')!;
    expect(a.bank, '우리은행');
    expect(a.holder, '박민수');
  });

  test('계좌가 아닌 것은 찾지 않는다', () {
    expect(p('안녕하세요 내일 3시에 봬요'), isNull);
    expect(p('연락처 010-1234-5678'), isNull);
    expect(p('주문번호 20261121123456'), isNull);
    expect(p('카드 1234-5678-9012-3456 우리 가족'), isNull);
    expect(p('사업자등록번호 123-45-67890 하나은행 본점'), isNull);
  });

  test('은행 이름 없이 계좌번호 표시만', () {
    final a = p('계좌번호 110-123-456789')!;
    expect(a.bank, '');
    expect(a.number, '110123456789');
  });
}
