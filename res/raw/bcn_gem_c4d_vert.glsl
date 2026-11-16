#version 300 es
precision highp float;

layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aNormal;

uniform mat4 uModel;
uniform mat4 uViewProjection;

out vec3 vWorldPosition;
out vec3 vWorldNormal;
out vec3 vObjectPosition;

void main() {
    vec4 world = uModel * vec4(aPosition, 1.0);
    gl_Position = uViewProjection * world;
    vWorldPosition = world.xyz;
    // uModel carries only rotation and a uniform scale, so the inverse
    // transpose reduces to the matrix itself.
    vWorldNormal = normalize((uModel * vec4(aNormal, 0.0)).xyz);
    vObjectPosition = aPosition;
}
