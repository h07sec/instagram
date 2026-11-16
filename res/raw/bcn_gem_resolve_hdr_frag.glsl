#version 300 es
// resolve_hdr.frag
//
// Android-only, hand-written -- unlike bcn_gem_resolve_frag.glsl this is NOT
// emitted by export_portkit.mjs, the web build having no equivalent.
//
// The surface composites under a ColorMatrix that multiplies RGB and leaves
// alpha alone. That indiscriminate multiply is what carries the field past SDR
// white, so the stone is divided by the same factor here and lands back where
// it started, leaving the field as the only thing lifted. The division goes
// after the transfer curve: the matrix runs on encoded values, so attenuating
// linear light would not cancel.

precision highp float;

in vec2 vUv;
out vec4 fragColor;

uniform sampler2D uSource;    // stone, reflection and the field behind them
uniform sampler2D uSparkle;   // front of the field, additive, premultiplied
uniform vec2 uTexel;          // 1 / source resolution
uniform float uInvBoost;      // 1 / the layer paint's multiplier

vec3 linear_to_srgb(vec3 c) {
    vec3 lo = c * 12.92;
    vec3 hi = 1.055 * pow(max(c, vec3(1e-8)), vec3(1.0 / 2.4)) - 0.055;
    return mix(lo, hi, step(vec3(0.0031308), c));
}

vec4 box(sampler2D tex) {
    return 0.25 * (texture(tex, vUv + uTexel * vec2(-0.5, -0.5))
                 + texture(tex, vUv + uTexel * vec2( 0.5, -0.5))
                 + texture(tex, vUv + uTexel * vec2(-0.5,  0.5))
                 + texture(tex, vUv + uTexel * vec2( 0.5,  0.5)));
}

// Attenuating before an 8-bit write costs the stone about a bit and a third,
// which is enough to band a gradient this smooth.
float dither(vec2 p) {
    float a = fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
    float b = fract(sin(dot(p + 1.0, vec2(12.9898, 78.233))) * 43758.5453);
    return (a + b) - 1.0;
}

void main() {
    vec4 c = box(uSource);
    vec4 s = box(uSparkle);

    // Encode the *unpremultiplied* colour, then re-premultiply: the transfer
    // curve is non-linear, so encoding a premultiplied value bakes the alpha
    // into the gamma and haloes every edge.
    float a = c.a;
    vec3 straight = a > 1e-5 ? c.rgb / a : vec3(0.0);
    vec3 base = linear_to_srgb(straight) * a * uInvBoost;
    base += dither(gl_FragCoord.xy) * (1.0 / 255.0);

    // Additive light, so encoded on its own and added. Nothing underneath it to
    // have been blended with, hence no unpremultiply.
    vec3 field = linear_to_srgb(s.rgb);

    // The field must carry its own alpha, and this is load-bearing: a
    // ColorMatrix runs on unpremultiplied colour, so at alpha zero the boost
    // returns zero and *erases* the particle rather than dimming it. Handing up
    // the scene's alpha alone clips the field to the stone's silhouette.
    fragColor = vec4(max(base, vec3(0.0)) + field, clamp(a + s.a, 0.0, 1.0));
}
