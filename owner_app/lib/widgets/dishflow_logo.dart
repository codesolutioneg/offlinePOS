import 'package:flutter/material.dart';

import 'dishflow_brand.dart';

/// Boot splash — same mark the till uses.
class DishflowLogoMark extends StatelessWidget {
  const DishflowLogoMark({
    super.key,
    this.width = 220,
    this.animate = true,
    this.tone = DishflowLogoTone.light,
  });

  final double width;
  final bool animate;
  final DishflowLogoTone tone;

  @override
  Widget build(BuildContext context) {
    final height = (width * 0.22).clamp(40.0, 64.0);
    return DishflowBrandMark(
      height: height,
      showSubtitle: true,
      onDark: tone == DishflowLogoTone.dark,
    );
  }
}

enum DishflowLogoTone { light, dark }
