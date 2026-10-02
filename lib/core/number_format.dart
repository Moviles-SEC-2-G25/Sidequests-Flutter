/// 1234 -> "1.234" (Spanish thousands separator) without pulling in intl.
String formatThousands(int value) => value.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (_) => '.',
);
