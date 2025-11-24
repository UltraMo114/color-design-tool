import 'dart:math' as math;

/// Port of Python calculate_color_metrics from ColorDesignTool/proc/harmony.py
/// Implements WC/HL/AP/CH based on Ou et al. (2018) formulas.
Map<String, double> calculateColorMetrics(List<double> lab1, List<double> lab2) {
  double L1 = lab1[0], a1 = lab1[1], b1 = lab1[2];
  double L2 = lab2[0], a2 = lab2[1], b2 = lab2[2];

  Map<String, double> _single(List<double> lab) {
    final L = lab[0], a = lab[1], b = lab[2];
    final C = math.sqrt(a * a + b * b);
    final hRad = math.atan2(b, a);
    final hDeg = (hRad * 180.0 / math.pi + 360.0) % 360.0;

    final wc = -0.89 + 0.052 * C *
        (math.cos(_deg(hDeg - 50)) + 0.16 * math.cos(_deg(2 * hDeg - 350)));
    final hl = 3.8 - 0.07 * L;
    final ap = -3.4 + 0.067 * math.sqrt(
        (L - 50) * (L - 50) + (1.93 * a + 1) * (1.93 * a + 1) + (1.05 * b - 9) * (1.05 * b - 9));

    return {
      'wc': wc,
      'hl': hl,
      'ap': ap,
      'C': C,
      'h': hDeg,
    };
  }

  final e1 = _single([L1, a1, b1]);
  final e2 = _single([L2, a2, b2]);

  final wcPair = (e1['wc']! + e2['wc']!) / 2.0;
  final hlPair = (e1['hl']! + e2['hl']!) / 2.0;
  final apPair = (e1['ap']! + e2['ap']!) / 2.0;

  final deltaL = (L1 - L2).abs();
  final deltaC = (e1['C']! - e2['C']!).abs();
  final dh = (e1['h']! - e2['h']!).abs();
  final deltaH = dh <= 180 ? dh : 360 - dh;
  final Lsum = L1 + L2;

  final chDeltaH = -0.7 * _tanh(-0.7 + 0.04 * deltaH);
  final chDeltaC = -0.3 * _tanh(-1.1 + 0.05 * deltaC);
  final chDeltaL = 0.4 * _tanh(-0.8 + 0.05 * deltaL);
  final chLsum = 0.3 + 0.6 * _tanh(-4.2 + 0.028 * Lsum);
  final ch = chDeltaH + chDeltaC + chDeltaL + chLsum;

  return {
    'WC': wcPair,
    'HL': hlPair,
    'AP': apPair,
    'CH': ch,
  };
}

double _deg(double x) => x * math.pi / 180.0;

// Dart's dart:math doesn't include tanh; implement via exp.
double _tanh(double x) {
  final e2x = math.exp(2 * x);
  return (e2x - 1) / (e2x + 1);
}
