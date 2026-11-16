#version 300 es
// blit.frag
//
// Ours, not a port-kit export. Safe to edit here.
//
// Resolves the gem's supersampled target into the scene target. This is the
// same 2x2 box average the port kit's resolve.frag does, deliberately *without*
// its sRGB encode: the scene target is linear and gets encoded once at the end,
// so encoding here would apply the transfer curve twice.

precision highp float;

in vec2 vUv;
in float vQuadY;
out vec4 fragColor;

uniform sampler2D uSource;
uniform vec2 uTexel;  // 1 / source resolution
uniform float uAlpha; // entrance fade, applied to the premultiplied result

// Opacity down the quad. The stone is flat at 1; the reflection starts dim where
// it meets the stone and ramps to nothing, which is what stands in for a contact
// shadow.
uniform float uAlphaTop;
uniform float uAlphaBottom;

void main() {
    // Premultiplied throughout, so colour and alpha average together correctly.
    vec4 sum = texture(uSource, vUv + uTexel * vec2(-0.5, -0.5))
             + texture(uSource, vUv + uTexel * vec2( 0.5, -0.5))
             + texture(uSource, vUv + uTexel * vec2(-0.5,  0.5))
             + texture(uSource, vUv + uTexel * vec2( 0.5,  0.5));
    float ramp = mix(uAlphaTop, uAlphaBottom, vQuadY);
    // Premultiplied, so a single multiply fades colour and coverage together.
    fragColor = sum * (0.25 * uAlpha * ramp);
}
