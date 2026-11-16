#version 300 es
// blit.vert
//
// Ours, not a port-kit export. Safe to edit here.
//
// Places the gem's own render target as a quad at its slot in the full-screen
// scene target. Four vertices from gl_VertexID, drawn as a triangle strip.

uniform vec4 uRect;      // x, y, width, height in screen px
uniform vec2 uViewport;

// How the quad walks the source. The stone takes (1, -1) + (0, 1), which flips
// y-down screen space against the y-up texture. The reflection takes a positive
// y scale instead, so it climbs the texture as it descends the quad — a mirror.
uniform vec2 uUvScale;
uniform vec2 uUvOffset;

out vec2 vUv;
out float vQuadY; // 0 at the quad's top, 1 at its bottom

void main() {
    vec2 corner = vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1));
    // The position below flips y going from y-down screen space into y-up NDC. The texture is
    // stored y-up too, so the sample has to flip with it or the stone renders inverted -- which is
    // what the caller's scale and offset express, and what the reflection inverts again.
    vUv = corner * uUvScale + uUvOffset;
    vQuadY = corner.y;
    vec2 px = uRect.xy + corner * uRect.zw;
    gl_Position = vec4(px.x / uViewport.x * 2.0 - 1.0,
                       1.0 - px.y / uViewport.y * 2.0,
                       0.0,
                       1.0);
}
