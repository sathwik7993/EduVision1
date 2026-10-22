/// String tools shared by the recognizers.
abstract final class TextNormalizer {
  /// Lowercase, strip punctuation, collapse whitespace. Used for label
  /// matching so "Registered  No.:" and "REGISTERED NO" compare equal.
  static String normalizeLabel(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Levenshtein distance, capped for speed -- labels are short.
  static int editDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    var previous = List<int>.generate(b.length + 1, (i) => i);
    var current = List<int>.filled(b.length + 1, 0);

    for (var i = 0; i < a.length; i++) {
      current[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
        current[j + 1] = [
          current[j] + 1,
          previous[j + 1] + 1,
          previous[j] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[b.length];
  }

  /// 0..1 similarity, tolerant of the single-character errors OCR produces.
  static double similarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1;
    final longest = a.length > b.length ? a.length : b.length;
    if (longest == 0) return 1;
    return 1 - editDistance(a, b) / longest;
  }

  /// Characters OCR routinely swaps when it does not know a glyph must be a
  /// digit. Applied only where the surrounding context guarantees a number.
  static const _toDigit = {
    'o': '0', 'O': '0', 'D': '0', 'Q': '0', '()': '0',
    'i': '1', 'I': '1', 'l': '1', 'L': '1', '|': '1', '!': '1',
    'z': '2', 'Z': '2',
    'e': '3', 'E': '3',
    'A': '4', 'h': '4',
    's': '5', 'S': '5',
    'G': '6', 'b': '6',
    'T': '7', 't': '7', '?': '7',
    'B': '8', 'R': '8',
    'g': '9', 'q': '9',
  };

  /// Force a token to digits, repairing known confusions. Returns null if the
  /// token still is not fully numeric afterwards -- better to report "not
  /// found" than to invent a mark.
  static String? coerceToDigits(String token) {
    final buffer = StringBuffer();
    for (final char in token.trim().split('')) {
      if (RegExp(r'\d').hasMatch(char)) {
        buffer.write(char);
      } else if (_toDigit.containsKey(char)) {
        buffer.write(_toDigit[char]);
      } else if (char == ' ' || char == '.' || char == ',') {
        continue;
      } else {
        return null;
      }
    }
    final out = buffer.toString();
    return out.isEmpty ? null : out;
  }

  /// How many characters had to be repaired, as a fraction. Feeds confidence:
  /// a mark we had to rewrite three glyphs to obtain should not be trusted.
  static double repairRatio(String original, String repaired) {
    final a = original.replaceAll(RegExp(r'[\s.,]'), '');
    if (a.isEmpty) return 1;
    var changed = 0;
    for (var i = 0; i < a.length && i < repaired.length; i++) {
      if (a[i] != repaired[i]) changed++;
    }
    return changed / a.length;
  }

  /// Clean up a candidate registration number: strip separators OCR inserts,
  /// uppercase, and drop anything non-alphanumeric.
  static String cleanRegistration(String token) {
    return token
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }
}
