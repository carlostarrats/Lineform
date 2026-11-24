// The AI drawer's progressive blur behind the options card (Mac and iPhone): clear at the top,
// blurrier toward the bottom. One-dimensional Gaussian pass along `direction`; SwiftUI applies
// it twice (horizontal, then vertical). Positions and radii are in points.
//
// The ramp follows the approved mockup's four bands (0.8, 2, 4 and 7.2 pt, starting about 10 %
// down), as one smooth curve: sigma(t) for t = y / height.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

static float lineformBlurSigma(float t, float maxSigma) {
    // (0.10, 0), (0.30, 0.11), (0.50, 0.28), (0.70, 0.56), (0.85, 1.0) of maxSigma
    float f;
    if (t < 0.10) f = 0.0;
    else if (t < 0.30) f = mix(0.0, 0.11, (t - 0.10) / 0.20);
    else if (t < 0.50) f = mix(0.11, 0.28, (t - 0.30) / 0.20);
    else if (t < 0.70) f = mix(0.28, 0.56, (t - 0.50) / 0.20);
    else if (t < 0.85) f = mix(0.56, 1.0, (t - 0.70) / 0.15);
    else f = 1.0;
    return f * maxSigma;
}

[[ stitchable ]] half4 lineformProgressiveBlur(float2 position, SwiftUI::Layer layer, float height,
                                               float maxSigma, float2 direction) {
    float t = clamp(position.y / max(height, 1.0), 0.0, 1.0);
    float sigma = lineformBlurSigma(t, maxSigma);
    if (sigma < 0.2) {
        return layer.sample(position);
    }
    // 2.5 sigma either side, never beyond the 22 pt the modifier declares.
    float reach = min(sigma * 2.5, 21.0);
    const int taps = 10;
    half4 sum = half4(0.0);
    float total = 0.0;
    for (int i = -taps; i <= taps; i++) {
        float offset = float(i) / float(taps) * reach;
        float weight = exp(-0.5 * (offset * offset) / (sigma * sigma));
        sum += layer.sample(position + direction * offset) * half(weight);
        total += weight;
    }
    return sum / half(total);
}
