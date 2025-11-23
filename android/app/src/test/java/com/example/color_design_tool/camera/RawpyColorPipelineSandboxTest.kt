package com.example.color_design_tool.camera

import org.junit.Test

class RawpyColorPipelineSandboxTest {

  @Test
  fun printDemoSample() {
    val result = RawpyColorPipelineSandbox.demoWithSample()
    println("Rawpy sandbox XYZ: ${result.xyz.joinToString()}")
    println("Rawpy sandbox sRGB linear: ${result.srgbLinear.joinToString()}")
    println("Rawpy sandbox sRGB gamma: ${result.srgbGamma.joinToString()}")
  }
}
