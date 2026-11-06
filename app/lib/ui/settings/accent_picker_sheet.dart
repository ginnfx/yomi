import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/appearance_controller.dart';
import '../theme.dart';

/// Lets you pick any accent colour by hue and strength, with a live preview.
Future<void> pickCustomAccent(BuildContext context) {
  final appearance = context.read<AppearanceController>();
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider.value(
      value: appearance,
      child: _AccentPicker(start: appearance.palette.accent),
    ),
  );
}

class _AccentPicker extends StatefulWidget {
  const _AccentPicker({required this.start});

  final Color start;

  @override
  State<_AccentPicker> createState() => _AccentPickerState();
}

class _AccentPickerState extends State<_AccentPicker> {
  late HSVColor _color = HSVColor.fromColor(widget.start);

  @override
  Widget build(BuildContext context) {
    final color = _color.toColor();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          kPagePadding,
          0,
          kPagePadding,
          kPagePadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Custom colour', style: yomiText(20, weight: FontWeight.w800)),
            const SizedBox(height: YomiSpace.l),
            Center(
              child: AnimatedContainer(
                duration: context.motion(YomiMotion.quick),
                width: 72,
                height: 72,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
            ),
            const SizedBox(height: YomiSpace.l),
            Text('Colour', style: yomiText(14, weight: FontWeight.w700)),
            _HueTrack(
              hue: _color.hue,
              onChanged: (hue) => setState(() => _color = _color.withHue(hue)),
            ),
            Text('Strength', style: yomiText(14, weight: FontWeight.w700)),
            Slider(
              value: _color.saturation,
              min: 0.2,
              max: 1,
              activeColor: color,
              onChanged: (value) =>
                  setState(() => _color = _color.withSaturation(value)),
            ),
            Text('Brightness', style: yomiText(14, weight: FontWeight.w700)),
            Slider(
              value: _color.value,
              min: 0.4,
              max: 1,
              activeColor: color,
              onChanged: (value) =>
                  setState(() => _color = _color.withValue(value)),
            ),
            const SizedBox(height: YomiSpace.s),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  await context.read<AppearanceController>().setCustomAccent(
                    color,
                  );
                  navigator.pop();
                },
                child: const Text('Use this colour'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A slider over a rainbow, for choosing the hue.
class _HueTrack extends StatelessWidget {
  const _HueTrack({required this.hue, required this.onChanged});

  final double hue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      Container(
        height: 10,
        margin: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(YomiRadius.pill),
          gradient: LinearGradient(
            colors: [
              for (var h = 0; h <= 360; h += 60)
                HSVColor.fromAHSV(1, h.toDouble(), 0.8, 1).toColor(),
            ],
          ),
        ),
      ),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: Colors.transparent,
          inactiveTrackColor: Colors.transparent,
        ),
        child: Slider(value: hue, max: 360, onChanged: onChanged),
      ),
    ],
  );
}
