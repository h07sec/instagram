#version 300 es
precision highp float;

in vec3 vWorldPosition;
in vec3 vWorldNormal;
in vec3 vObjectPosition;

layout(location = 0) out vec4 oPosition;
layout(location = 1) out vec4 oNormal;

void main() {
    oPosition = vec4(vWorldPosition, 1.0);
    oNormal = vec4(normalize(vWorldNormal), 1.0);
}
