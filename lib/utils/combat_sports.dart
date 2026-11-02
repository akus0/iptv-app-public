final _cardNumber = RegExp(
    r'\b(?:ufc|pfl|bellator|one (?:fight night|friday fights|fc)|cage warriors|lfa|bkfc)\s+\d{1,4}\b',
    caseSensitive: false);

String? combatCardIdentity(String text) {
  final cards = _cardNumber
      .allMatches(text.toLowerCase())
      .map((m) => m[0]!.replaceAll(RegExp(r'\s+'), ' '))
      .toSet();
  return cards.length == 1 ? cards.single : null;
}
