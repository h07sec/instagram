#version 300 es
// resolve.vert
//
// Emitted by web/tools/export_portkit.mjs from the shader the web build is
// actually running. Do not hand-edit -- change src/shaders.js and re-export, or
// the two platforms drift.

out vec2 vUv;
void main() {
    // Fullscreen triangle from gl_VertexID -- no buffers needed.
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    vUv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
