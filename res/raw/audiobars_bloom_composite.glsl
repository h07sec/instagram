#version 300 es
precision highp float;

in vec2 v_TexCoord;
out vec4 fragColor;

uniform sampler2D u_original;
uniform sampler2D u_bloom;
uniform float u_bloomIntensity;
uniform float u_shoulder;

// Not clamp(): clamp(NaN, ...) is undefined in GLSL ES, greaterThan maps NaN to 0.
vec3 clampHDR3(vec3 c) {
    return mix(vec3(0.0), min(c, vec3(65000.0)), greaterThan(c, vec3(0.0)));
}

// min with NaN is undefined, so test positivity first.
float clampAlpha(float a) {
    return a > 0.0 ? min(a, 1.0) : 0.0;
}

vec3 linearToSrgb(vec3 c) {
    return vec3(
        c.r <= 0.0031308 ? c.r * 12.92 : 1.055 * pow(c.r, 1.0 / 2.4) - 0.055,
        c.g <= 0.0031308 ? c.g * 12.92 : 1.055 * pow(c.g, 1.0 / 2.4) - 0.055,
        c.b <= 0.0031308 ? c.b * 12.92 : 1.055 * pow(c.b, 1.0 / 2.4) - 0.055
    );
}

void main() {
    vec4 base = texture(u_original, v_TexCoord);
    vec3 result = base.rgb;
    if (u_bloomIntensity != 0.0) {
        result += texture(u_bloom, v_TexCoord).rgb * u_bloomIntensity;
    }
    result = clampHDR3(result);
    result = result / (1.0 + result * u_shoulder);
    // A negative or non-finite u_shoulder makes the divide emit NaN/Inf/negatives,
    // and the clamp() and max() below are undefined for NaN.
    result = clampHDR3(result);
    result = clamp(result, 0.0, 1.0);
    result = linearToSrgb(result);
    float lum = dot(result, vec3(0.2126, 0.7152, 0.0722));
    float emissiveA = 1.0 - exp(-lum * 0.5);
    float outA = max(clampAlpha(base.a), clampAlpha(emissiveA));
    fragColor = vec4(result, outA);
}
