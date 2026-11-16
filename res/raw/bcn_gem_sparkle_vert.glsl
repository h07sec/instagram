#version 300 es
// sparkle.vert
//
// Ours, not a port-kit export -- the kit has no sparkle pass. Safe to edit here.
//
// One instanced quad per particle. The star and its halo are both produced
// analytically in the fragment shader, so the only per-particle data is a
// centre, a half-extent and a colour.

layout(location = 0) in vec2 aCorner;  // unit quad, -1..1
layout(location = 1) in vec2 aCenter;  // screen px, y down
layout(location = 2) in float aExtent; // half-extent in px, star plus halo
layout(location = 3) in vec4 aColor;   // linear rgb, straight alpha

uniform vec2 uViewport;

out vec2 vCorner;
out vec4 vColor;

void main() {
    vCorner = aCorner;
    vColor = aColor;
    vec2 px = aCenter + aCorner * aExtent;
    // Screen space is y-down; NDC is y-up.
    gl_Position = vec4(px.x / uViewport.x * 2.0 - 1.0,
                       1.0 - px.y / uViewport.y * 2.0,
                       0.0,
                       1.0);
}
