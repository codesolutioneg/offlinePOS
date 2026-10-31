/// Code 128 set B, as an SVG the cheque page can drop over the artwork.
String code128Svg(String text, {double module = 2, double barHeight = 64}) {
  if (text.isEmpty) return '';
  const patterns = <String>[
    '212222', '222122', '222221', '121223', '121322', '131222', '122213', '122312', '132212', '221213',
    '221312', '231212', '112232', '122132', '122231', '113222', '123122', '123221', '223211', '221132',
    '221231', '213212', '223112', '312131', '311222', '321122', '321221', '312212', '322112', '322211',
    '212123', '212321', '232121', '111323', '131123', '131321', '112313', '132113', '132311', '211313',
    '231113', '231311', '112133', '112331', '132131', '113123', '113321', '133121', '313121', '211331',
    '231131', '213113', '213311', '213131', '311123', '311321', '331121', '312113', '312311', '332111',
    '314111', '221411', '431111', '111224', '111422', '121124', '121421', '141122', '141221', '112214',
    '112412', '122114', '122411', '142112', '142211', '241211', '221114', '413111', '241112', '134111',
    '111242', '121142', '121241', '114212', '124112', '124211', '411212', '421112', '421211', '212141',
    '214121', '412121', '111143', '111341', '131141', '114113', '114311', '411113', '411311', '113141',
    '114131', '311141', '411131', '211412', '211214', '211232', '2331112',
  ];
  final values = <int>[104];
  for (final unit in text.codeUnits) {
    if (unit < 32 || unit > 126) return '';
    values.add(unit - 32);
  }
  var sum = values.first;
  for (var i = 1; i < values.length; i++) {
    sum += values[i] * i;
  }
  values.add(sum % 103);
  values.add(106);

  final bars = StringBuffer();
  var x = module * 10;
  for (final value in values) {
    final widths = patterns[value];
    var bar = true;
    for (final ch in widths.codeUnits) {
      final w = (ch - 48) * module;
      if (bar) {
        bars.write(
          '<rect x="${x.toStringAsFixed(1)}" y="0" width="${w.toStringAsFixed(1)}" height="$barHeight" fill="#111"/>',
        );
      }
      x += w;
      bar = !bar;
    }
  }
  x += module * 10;
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $x $barHeight" width="100%" height="$barHeight">$bars</svg>';
}
