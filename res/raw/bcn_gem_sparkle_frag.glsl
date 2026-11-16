#version 300 es
// sparkle.frag
//
// Ours, not a port-kit export -- the kit has no sparkle pass. Safe to edit here.
//
// The four-point star is a superellipse with an exponent below one:
//
//     |x|^e + |y|^e = 1
//
// which is concave between the points. At 45 degrees the outline sits at
// 0.5^(1/e), so e is chosen to land that on the design's waist -- e = 0.39 for
// a waist of 0.17. That reproduces the shape the Compose version drew with four
// quadratic curves, without any geometry.
//
// The halo is a Gaussian in the same quad, which is why this pass needs no
// blur, no downscaled target and no second copy of the field.

precision highp float;

in vec2 vCorner;
in vec4 vColor;
out vec4 fragColor;

uniform float uStarExponent;
uniform float uCoreFraction;  // star radius as a fraction of the quad half-extent
uniform float uGlowStrength;
uniform float uGlowFalloff;
// Both 1.0 off the HDR path, where this reduces to what it was. See the alpha.
uniform float uGlowGain;   // holds the halo down while the surface is boosted
uniform float uAlphaGain;  // drives the star's coverage toward opaque

void main() {
    vec2 p = vCorner / max(uCoreFraction, 1e-3);
    float d = pow(abs(p.x), uStarExponent) + pow(abs(p.y), uStarExponent);
    // Screen-space derivative, so the edge stays one pixel wide at every size.
    float aa = fwidth(d) + 1e-4;
    float core = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, d);

    float glow = exp(-uGlowFalloff * dot(vCorner, vCorner));

    // Premultiplied, and alpha is what carries the star -- which is why both
    // gains land here rather than on the colour.
    //
    // The halo: alpha clamps, so the core already sits at 1.0 while the halo has
    // room above it. Boosting both lifts only the halo, and a round halo around
    // a star reads as a disc, so it is divided back down by the same factor.
    //
    // The core: a boosted particle composites to `K*a + (1 - a)*background` for
    // granted headroom K, which over a light card is `1 + a*(K - 1)` -- alpha
    // alone decides visibility, and at resting alphas that is white. Hence the
    // drive toward opaque.
    float a =
        clamp(vColor.a * (core * uAlphaGain + glow * uGlowStrength * uGlowGain), 0.0, 1.0);
    fragColor = vec4(vColor.rgb * a, a);
}
