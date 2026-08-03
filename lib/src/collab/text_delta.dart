class TextDelta {
  const TextDelta({
    required this.index,
    required this.deleteLength,
    required this.insertText,
  });

  final int index;
  final int deleteLength;
  final String insertText;

  bool get isEmpty => deleteLength == 0 && insertText.isEmpty;

  static TextDelta between(String previous, String next) {
    var prefix = 0;
    final shortestLength = previous.length < next.length
        ? previous.length
        : next.length;
    while (prefix < shortestLength &&
        previous.codeUnitAt(prefix) == next.codeUnitAt(prefix)) {
      prefix++;
    }

    var suffix = 0;
    final remainingPrevious = previous.length - prefix;
    final remainingNext = next.length - prefix;
    while (suffix < remainingPrevious &&
        suffix < remainingNext &&
        previous.codeUnitAt(previous.length - suffix - 1) ==
            next.codeUnitAt(next.length - suffix - 1)) {
      suffix++;
    }

    final previousEnd = previous.length - suffix;
    final nextEnd = next.length - suffix;
    return TextDelta(
      index: prefix,
      deleteLength: previousEnd - prefix,
      insertText: next.substring(prefix, nextEnd),
    );
  }
}
