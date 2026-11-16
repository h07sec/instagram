#version 300 es
precision highp float;

in vec2 v_TexCoord;
out vec4 fragColor;

uniform sampler2D u_source;
uniform float u_threshold;
uniform float u_softKnee;
uniform float u_lumWeightR;
uniform float u_lumWeightG;
uniform float u_lumWeightB;

// Not clamp(): clamp(NaN, ...) is undefined in GLSL ES, greaterThan maps NaN to 0.
vec3 clampHDR3(vec3 c) {
    return mix(vec3(0.0), min(c, vec3(65000.0)), greaterThan(c, vec3(0.0)));
}

// min with NaN is undefined, so test positivity first.
float clampAlpha(float a) {
    return a > 0.0 ? min(a, 1.0) : 0.0;
}

void main() {
    vec4 color = texture(u_source, v_TexCoord);
    vec3 sanitizedColor = clampHDR3(color.rgb);
    float luminance = dot(sanitizedColor, vec3(u_lumWeightR, u_lumWeightG, u_lumWeightB));
    float brightness = max(0.0, luminance - u_threshold + u_softKnee);
    brightness = brightness * brightness / (2.0 * u_softKnee + 0.0001);
    fragColor = vec4(clampHDR3(sanitizedColor * brightness), clampAlpha(color.a));
}
