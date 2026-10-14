import 'package:cses_document_collab/src/model/text_delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('computes insertion using UTF-16 offsets', () {
    final delta = TextDelta.between('A😀B', 'A😀 hello B');

    expect(delta.index, 3);
    expect(delta.deleteLength, 0);
    expect(delta.insertText, ' hello ');
  });

  test('computes replacement', () {
    final delta = TextDelta.between('offline first', 'offline-first');

    expect(delta.index, 7);
    expect(delta.deleteLength, 1);
    expect(delta.insertText, '-');
  });

  test('computes deletion', () {
    final delta = TextDelta.between('Flutter + Rust', 'Flutter Rust');

    expect(delta.index, 8);
    expect(delta.deleteLength, 2);
    expect(delta.insertText, '');
  });
}
