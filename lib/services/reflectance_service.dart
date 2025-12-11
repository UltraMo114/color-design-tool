import 'package:colordesign_tool_core/src/models/color_stimulus.dart';
import 'package:colordesign_tool_core/src/common/util.dart' show labToXyz;
import 'package:vector_math/vector_math.dart' show Vector3;

/// Generates synthetic spectral reflectance curves for colors that only carry
/// Lab / XYZ definitions. The implementation ports the Smits (1999) RGB-to-
/// spectrum reconstruction that exists in the Python prototype
/// (`colour.recovery.RGB_to_sd_Smits1999`) and stretches it to a 360-780 nm
/// range with 10 nm spacing so the curves can be embedded into QTX exports.
class ReflectanceService {
  static const int _startWavelengthNm = 360;
  static const int _endWavelengthNm = 780;
  static const int _intervalNm = 10;

  static final List<double> _wavelengths = List<double>.generate(
    ((_endWavelengthNm - _startWavelengthNm) ~/ _intervalNm) + 1,
    (index) => _startWavelengthNm + index * _intervalNm.toDouble(),
  );

  /// Raw Smits (1999) basis data sampled at irregular wavelengths. These values
  /// are ported from `colour.recovery.datasets.smits1999.DATA_SMITS1999`.
  static final Map<String, Map<double, double>> _smitsBasisRaw = {
    'white': {
      380.0: 1.0,
      417.7778: 1.0,
      455.5556: 0.9999,
      493.3333: 0.9993,
      531.1111: 0.9992,
      568.8889: 0.9998,
      606.6667: 1.0,
      644.4444: 1.0,
      682.2222: 1.0,
      720.0: 1.0,
    },
    'cyan': {
      380.0: 0.9710,
      417.7778: 0.9426,
      455.5556: 1.0007,
      493.3333: 1.0007,
      531.1111: 1.0007,
      568.8889: 1.0007,
      606.6667: 0.1564,
      644.4444: 0.0,
      682.2222: 0.0,
      720.0: 0.0,
    },
    'magenta': {
      380.0: 1.0,
      417.7778: 1.0,
      455.5556: 0.9685,
      493.3333: 0.2229,
      531.1111: 0.0,
      568.8889: 0.0458,
      606.6667: 0.8369,
      644.4444: 1.0,
      682.2222: 1.0,
      720.0: 0.9959,
    },
    'yellow': {
      380.0: 0.0001,
      417.7778: 0.0,
      455.5556: 0.1088,
      493.3333: 0.6651,
      531.1111: 1.0,
      568.8889: 1.0,
      606.6667: 0.9996,
      644.4444: 0.9586,
      682.2222: 0.9685,
      720.0: 0.9840,
    },
    'red': {
      380.0: 0.1012,
      417.7778: 0.0515,
      455.5556: 0.0,
      493.3333: 0.0,
      531.1111: 0.0,
      568.8889: 0.0,
      606.6667: 0.8325,
      644.4444: 1.0149,
      682.2222: 1.0149,
      720.0: 1.0149,
    },
    'green': {
      380.0: 0.0,
      417.7778: 0.0,
      455.5556: 0.0273,
      493.3333: 0.7937,
      531.1111: 1.0,
      568.8889: 0.9418,
      606.6667: 0.1719,
      644.4444: 0.0,
      682.2222: 0.0,
      720.0: 0.0025,
    },
    'blue': {
      380.0: 1.0,
      417.7778: 1.0,
      455.5556: 0.8916,
      493.3333: 0.3323,
      531.1111: 0.0,
      568.8889: 0.0,
      606.6667: 0.0003,
      644.4444: 0.0369,
      682.2222: 0.0483,
      720.0: 0.0496,
    },
  };

  static final Map<String, List<double>> _smitsBasis = _buildSampledBasis(
    _smitsBasisRaw,
  );

  /// Returns a clone of [stimulus] whose [SourceInfo.spectral_curve] contains
  /// a synthetic reflectance. Existing spectral curves are preserved as-is.
  ColorStimulus ensureSpectralData(ColorStimulus stimulus) {
    if (stimulus.source.spectral_curve != null) {
      return stimulus;
    }
    final spectral = generateSpectralData(stimulus);
    final source = SourceInfo(
      type: stimulus.source.type,
      origin_identifier: stimulus.source.origin_identifier,
      s_name: stimulus.source.s_name,
      spectral_curve: spectral,
    );
    return ColorStimulus(
      id: stimulus.id,
      u_name: stimulus.u_name,
      source: source,
      scientific_core: stimulus.scientific_core,
      metadata: Map<String, dynamic>.from(stimulus.metadata),
      appearance: stimulus.appearance,
      display_representations: Map<String, DisplayRepresentation>.from(
        stimulus.display_representations,
      ),
    );
  }

  /// Generates a [SpectralData] entry for the provided [ColorStimulus].
  SpectralData generateSpectralData(ColorStimulus stimulus) {
    final xyz = _extractXyz(stimulus);
    final rgb = _xyzToLinearSrgb(xyz);
    final clipped = Vector3(
      rgb.x.clamp(0.0, 1.0),
      rgb.y.clamp(0.0, 1.0),
      rgb.z.clamp(0.0, 1.0),
    );
    final reflectance = _composeSpectrum(clipped);
    final reflectancePercent = reflectance
        .map((value) => (value * 100.0).clamp(0.0, 100.0))
        .toList(growable: false);
    return SpectralData(
      points_count: reflectancePercent.length,
      interval_nm: _intervalNm,
      start_wavelength_nm: _startWavelengthNm,
      reflectance_values: reflectancePercent,
    );
  }

  Vector3 _extractXyz(ColorStimulus stimulus) {
    final xyz = stimulus.scientific_core.xyz_value;
    if (xyz.length >= 3) {
      return Vector3(xyz[0], xyz[1], xyz[2]);
    }
    final lab = stimulus.appearance?.lab_value;
    final white = stimulus.scientific_core.reference_white_xyz;
    if (lab == null || white.length < 3) {
      throw StateError('ColorStimulus is missing XYZ and Lab data.');
    }
    return labToXyz(
      Vector3(lab[0], lab[1], lab[2]),
      Vector3(white[0], white[1], white[2]),
    );
  }

  Vector3 _xyzToLinearSrgb(Vector3 xyz) {
    final x = xyz.x / 100.0;
    final y = xyz.y / 100.0;
    final z = xyz.z / 100.0;
    final r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
    final g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
    final b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;
    return Vector3(r, g, b);
  }

  List<double> _composeSpectrum(Vector3 rgb) {
    final r = rgb.x;
    final g = rgb.y;
    final b = rgb.z;
    final result = List<double>.filled(_wavelengths.length, 0.0);
    void accumulate(String key, double scale) {
      if (scale <= 0) return;
      final basis = _smitsBasis[key]!;
      for (var i = 0; i < result.length; i++) {
        result[i] += basis[i] * scale;
      }
    }

    if (r <= g && r <= b) {
      accumulate('white', r);
      if (g <= b) {
        accumulate('cyan', g - r);
        accumulate('blue', b - g);
      } else {
        accumulate('cyan', b - r);
        accumulate('green', g - b);
      }
    } else if (g <= r && g <= b) {
      accumulate('white', g);
      if (r <= b) {
        accumulate('magenta', r - g);
        accumulate('blue', b - r);
      } else {
        accumulate('magenta', b - g);
        accumulate('red', r - b);
      }
    } else {
      accumulate('white', b);
      if (r <= g) {
        accumulate('yellow', r - b);
        accumulate('green', g - r);
      } else {
        accumulate('yellow', g - b);
        accumulate('red', r - g);
      }
    }

    for (var i = 0; i < result.length; i++) {
      result[i] = result[i].clamp(0.0, 1.2);
    }
    return result;
  }

  static Map<String, List<double>> _buildSampledBasis(
    Map<String, Map<double, double>> raw,
  ) {
    final sampled = <String, List<double>>{};
    raw.forEach((name, curve) {
      final wavelengths = curve.keys.toList()..sort();
      final values = wavelengths.map((w) => curve[w]!).toList();
      sampled[name] = _wavelengths
          .map((wl) => _interpolate(wavelengths, values, wl))
          .toList(growable: false);
    });
    return sampled;
  }

  static double _interpolate(List<double> xs, List<double> ys, double target) {
    if (target <= xs.first) return ys.first;
    if (target >= xs.last) return ys.last;
    for (var i = 0; i < xs.length - 1; i++) {
      final x0 = xs[i];
      final x1 = xs[i + 1];
      if (target >= x0 && target <= x1) {
        final t = (target - x0) / (x1 - x0);
        return ys[i] * (1 - t) + ys[i + 1] * t;
      }
    }
    return ys.last;
  }
}
