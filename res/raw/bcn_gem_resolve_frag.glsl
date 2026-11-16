#version 300 es
// resolve.frag
//
// Emitted by web/tools/export_portkit.mjs from the shader the web build is
// actually running. Do not hand-edit -- change src/shaders.js and re-export, or
// the two platforms drift.

precision highp float;

in vec2 vUv;
out vec4 fragColor;

uniform sampler2D uSource;
uniform vec2 uTexel;   // 1 / source resolution

vec3 linear_to_srgb(vec3 c) {
    vec3 lo = c * 12.92;
    vec3 hi = 1.055 * pow(max(c, vec3(1e-8)), vec3(1.0 / 2.4)) - 0.055;
    return mix(lo, hi, step(vec3(0.0031308), c));
}

void main() {
    // Box-average the 2x2 block. The source is premultiplied, so colour and
    // alpha average together correctly with no unpremultiply in between.
    vec4 sum = texture(uSource, vUv + uTexel * vec2(-0.5, -0.5))
             + texture(uSource, vUv + uTexel * vec2( 0.5, -0.5))
             + texture(uSource, vUv + uTexel * vec2(-0.5,  0.5))
             + texture(uSource, vUv + uTexel * vec2( 0.5,  0.5));
    vec4 c = sum * 0.25;

    // Encode the *unpremultiplied* colour, then re-premultiply: the transfer
    // curve is non-linear, so encoding a premultiplied value bakes the alpha
    // into the gamma and haloes every edge.
    float a = c.a;
    vec3 straight = a > 1e-5 ? c.rgb / a : vec3(0.0);
    fragColor = vec4(linear_to_srgb(straight) * a, a);
}
