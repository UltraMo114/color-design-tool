package com.example.color_design_tool.camera

import kotlin.math.ln
import kotlin.math.max
import kotlin.math.pow

/**
 * A standalone helper that mirrors the RAW -> XYZ -> sRGB pipeline used by rawpy.
 * This file is intentionally decoupled from the production pipeline so we can validate
 * matrix math and white-balance handling before wiring it into RawRoiProcessor.
 */
object RawpyColorPipelineSandbox {

  private val D50 = doubleArrayOf(0.9642, 1.0, 0.8251)
  private val D65 = doubleArrayOf(0.95047, 1.0, 1.08883)

  data class ChannelSample(
    val red: Double,
    val greenR: Double,
    val greenB: Double,
    val blue: Double,
  ) {
    fun greenAverage(): Double = (greenR + greenB) / 2.0

    fun divideByNeutral(neutral: DoubleArray): ChannelSample {
      val rNeutral = neutral.getOrNull(0)?.takeIf { it != 0.0 } ?: 1.0
      val gNeutral = neutral.getOrNull(1)?.takeIf { it != 0.0 } ?: 1.0
      val bNeutral = neutral.getOrNull(2)?.takeIf { it != 0.0 } ?: 1.0
      return ChannelSample(
        red = red / rNeutral,
        greenR = greenR / gNeutral,
        greenB = greenB / gNeutral,
        blue = blue / bNeutral,
      )
    }

    fun toRgbVector(): DoubleArray = doubleArrayOf(red, greenAverage(), blue)

    fun toCfaVector(): DoubleArray = doubleArrayOf(red, greenR, greenB, blue)
  }

  data class SampleInput(
    val cameraRgb: ChannelSample,
    val asShotNeutral: DoubleArray?,
    val colorMatrix1: DoubleArray?,
    val colorMatrix2: DoubleArray?,
    val referenceIlluminant1: Int?,
    val referenceIlluminant2: Int?,
    val forwardMatrix1: DoubleArray?,
    val forwardMatrix2: DoubleArray?,
  )

  data class PipelineResult(
    val xyz: DoubleArray,
    val srgbLinear: DoubleArray,
    val srgbGamma: DoubleArray,
  )

  /**
   * Computes XYZ/sRGB from the given sample using the same math as rawpy/libraw:
   *   cameraRGB / AsShotNeutral -> ColorMatrix (with interpolation) -> ForwardMatrix
   *   -> XYZ (D50) -> chromatic-adapt to D65 PCS -> sRGB
   */
  fun compute(input: SampleInput): PipelineResult {
    val neutral = input.asShotNeutral ?: doubleArrayOf(1.0, 1.0, 1.0)
    val normalized = input.cameraRgb.divideByNeutral(neutral)
    val colorMatrix = selectMatrix(
      matrix1 = input.colorMatrix1,
      matrix2 = input.colorMatrix2,
      ref1 = input.referenceIlluminant1,
      ref2 = input.referenceIlluminant2,
      weightSource = normalized,
    )
    val xyzCamera = multiplyMatrix(colorMatrix, normalized)
    val xyz = applyForwardMatrix(
      xyzCamera,
      input.forwardMatrix1,
      input.forwardMatrix2,
      input.referenceIlluminant1,
      input.referenceIlluminant2,
    )
    val pcsD65 = adaptWhiteBalance(xyz, D50, D65)
    val srgbLinear = xyzToSrgbLinear(pcsD65)
    val srgbGamma = srgbLinear.gammaEncode()
    return PipelineResult(xyz = pcsD65, srgbLinear = srgbLinear, srgbGamma = srgbGamma)
  }

  private fun selectMatrix(
    matrix1: DoubleArray?,
    matrix2: DoubleArray?,
    ref1: Int?,
    ref2: Int?,
    weightSource: ChannelSample,
  ): DoubleArray {
    val first = matrix1 ?: matrix2
    val second = when {
      matrix1 != null && matrix2 != null -> matrix2
      matrix2 != null -> matrix2
      else -> null
    }
    if (first == null && second == null) {
      return identity3()
    }
    if (second == null || ref1 == null || ref2 == null) {
      return first!!
    }
    val (coolMatrix, warmMatrix) = if (isDaylight(ref1) && !isDaylight(ref2)) {
      first!! to second
    } else if (isDaylight(ref2) && !isDaylight(ref1)) {
      second to first!!
    } else {
      first!! to second
    }
    val weight = estimateDaylightWeight(weightSource)
    return interpolateMatrices(warmMatrix, coolMatrix, weight)
  }

  private fun isDaylight(illuminant: Int): Boolean {
    return when (illuminant) {
      20, 21, 22, 23, 24 -> true // D55..D75, S daylight
      else -> false
    }
  }

  private fun estimateDaylightWeight(sample: ChannelSample): Double {
    val ratio = (sample.red / max(sample.blue, 1e-6))
    val warmRef = ln(2.5)
    val coolRef = ln(0.8)
    return ((ln(ratio) - warmRef) / (coolRef - warmRef)).coerceIn(0.0, 1.0)
  }

  private fun interpolateMatrices(
    warmMatrix: DoubleArray,
    coolMatrix: DoubleArray,
    daylightWeight: Double,
  ): DoubleArray {
    val size = minOf(warmMatrix.size, coolMatrix.size)
    val result = DoubleArray(size)
    for (i in 0 until size) {
      result[i] = warmMatrix[i] * (1.0 - daylightWeight) + coolMatrix[i] * daylightWeight
    }
    return result
  }

  private fun multiplyMatrix(matrix: DoubleArray, sample: ChannelSample): DoubleArray {
    return when {
      matrix.size >= 12 -> multiply3x4(matrix, sample.toCfaVector())
      matrix.size >= 9 -> multiply3x3(matrix, sample.toRgbVector())
      else -> doubleArrayOf(sample.red, sample.greenAverage(), sample.blue)
    }
  }

  private fun multiply3x3(matrix: DoubleArray, vector: DoubleArray): DoubleArray {
    val x = matrix[0] * vector[0] + matrix[1] * vector[1] + matrix[2] * vector[2]
    val y = matrix[3] * vector[0] + matrix[4] * vector[1] + matrix[5] * vector[2]
    val z = matrix[6] * vector[0] + matrix[7] * vector[1] + matrix[8] * vector[2]
    return doubleArrayOf(x, y, z)
  }

  private fun multiply3x4(matrix: DoubleArray, vector: DoubleArray): DoubleArray {
    val x = matrix[0] * vector[0] + matrix[1] * vector[1] + matrix[2] * vector[2] + matrix[3] * vector[3]
    val y = matrix[4] * vector[0] + matrix[5] * vector[1] + matrix[6] * vector[2] + matrix[7] * vector[3]
    val z = matrix[8] * vector[0] + matrix[9] * vector[1] + matrix[10] * vector[2] + matrix[11] * vector[3]
    return doubleArrayOf(x, y, z)
  }

  private fun applyForwardMatrix(
    xyz: DoubleArray,
    forwardMatrix1: DoubleArray?,
    forwardMatrix2: DoubleArray?,
    ref1: Int?,
    ref2: Int?,
  ): DoubleArray {
    val matrix = selectMatrix(
      matrix1 = forwardMatrix1,
      matrix2 = forwardMatrix2,
      ref1 = ref1,
      ref2 = ref2,
      weightSource = ChannelSample(xyz[0], xyz[1], xyz[1], xyz[2]),
    )
    return if (matrix.size >= 9) multiply3x3(matrix, xyz) else xyz
  }

  private fun adaptWhiteBalance(
    xyz: DoubleArray,
    sourceWhite: DoubleArray,
    targetWhite: DoubleArray,
  ): DoubleArray {
    if (xyz.size < 3) return xyz
    val m = doubleArrayOf(
      0.8951, 0.2664, -0.1614,
      -0.7502, 1.7135, 0.0367,
      0.0389, -0.0685, 1.0296,
    )
    val mInv = doubleArrayOf(
      0.9869929, -0.1470543, 0.1599627,
      0.4323053, 0.5183603, 0.0492912,
      -0.0085287, 0.0400428, 0.9684867,
    )
    fun multiply3(mat: DoubleArray, vec: DoubleArray): DoubleArray {
      val x = mat[0] * vec[0] + mat[1] * vec[1] + mat[2] * vec[2]
      val y = mat[3] * vec[0] + mat[4] * vec[1] + mat[5] * vec[2]
      val z = mat[6] * vec[0] + mat[7] * vec[1] + mat[8] * vec[2]
      return doubleArrayOf(x, y, z)
    }
    val srcCone = multiply3(m, sourceWhite)
    val dstCone = multiply3(m, targetWhite)
    val scale = doubleArrayOf(
      dstCone[0] / srcCone[0],
      dstCone[1] / srcCone[1],
      dstCone[2] / srcCone[2],
    )
    val cone = multiply3(m, xyz)
    val adaptedCone = doubleArrayOf(
      cone[0] * scale[0],
      cone[1] * scale[1],
      cone[2] * scale[2],
    )
    return multiply3(mInv, adaptedCone)
  }

  private fun xyzToSrgbLinear(xyz: DoubleArray): DoubleArray {
    val x = xyz[0]
    val y = xyz[1]
    val z = xyz[2]
    val r = 3.2406 * x - 1.5372 * y - 0.4986 * z
    val g = -0.9689 * x + 1.8758 * y + 0.0415 * z
    val b = 0.0557 * x - 0.2040 * y + 1.0570 * z
    return doubleArrayOf(r, g, b)
  }

  private fun DoubleArray.gammaEncode(): DoubleArray {
    return DoubleArray(size) { index ->
      val v = this[index]
      when {
        v <= 0.0 -> 0.0
        v < 0.0031308 -> 12.92 * v
        else -> 1.055 * v.pow(1.0 / 2.4) - 0.055
      }
    }
  }

  private fun identity3(): DoubleArray = doubleArrayOf(
    1.0, 0.0, 0.0,
    0.0, 1.0, 0.0,
    0.0, 0.0, 1.0,
  )

}
