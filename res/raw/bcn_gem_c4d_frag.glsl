#version 300 es
// Shaded in mediump. Mali runs fp16 at roughly twice the rate of fp32, and almost
// everything here is a direction, a weight or a colour: unit vectors, spectral
// weights that fall to nothing well inside half's range, and environment samples
// bounded by uEnvExposure. The dispersion loop is the renderer's hot path and it is
// made entirely of those.
//
// What stays highp is anything carrying world-space position. Thickness is the
// difference of two points, so quantising them quantises the absorption that gives
// the stone its colour, and the G-buffer sampler is read for exactly that.
precision mediump float;
precision highp sampler2D;

in highp vec3 vWorldPosition;
in vec3 vWorldNormal;
in highp vec3 vObjectPosition;

out vec4 fragColor;

uniform samplerCube uEnv;
uniform highp sampler2D uBackPosition;
uniform highp sampler2D uBackNormal;
uniform sampler2D uGlyph;

uniform highp mat4  uModel;
uniform highp mat4  uViewProjection;
uniform highp vec3  uCameraPosition;
uniform highp vec2  uViewport;
uniform float uMaxLevel;
uniform float uExposure;

// WEB: normalises an arbitrary HDR map onto the radiance the shader was tuned
// against, so swapping environments changes the distribution of light and not
// the overall level.
uniform float uEnvExposure;

uniform float uIOR;
uniform float uDispersion;
uniform float uRoughness;
uniform float uRefractionBlur;

uniform float uTransmission;
uniform float uReflection;
uniform float uVolumeDensity;
uniform float uSpectrum;

uniform float uEdgeLight;
uniform float uTintHue;
uniform float uTintStrength;

uniform float uGrainBlur;
uniform float uSimplexBump;
uniform float uSimplexScale;
uniform float uGrainScale;

uniform float uDispersionMix;
uniform float uDispersionSmoothness;
uniform float uFresnelStrength;

uniform float uInternalBounces;
uniform float uEdgeDispersionAngle;
uniform vec2  uEnvRotation;          // (cos, sin) about Y

uniform float uGlyphEnabled;
uniform float uGlyphOpacity;
uniform float uGlyphScale;
uniform float uGlyphRefractionX;
uniform float uGlyphRefractionY;
uniform float uGlyphChromatic;
uniform float uGlyphBehind;
uniform float uGlyphPositionY;

uniform vec3  uInverseVariance;
uniform vec3  uWeightRatioStep;

uniform float uShadowLift;
uniform float uShadowKnee;

// Applied to every environment sample, before the optical paths split — so a
// refracted shadow can still pick up spectral and body colour on the way out.
// Distinct from uShadowLift, which floors the shaded result after tone mapping.
uniform float uRefractionShadowLift;
uniform float uRefractionShadowKnee;

const float PI = 3.14159265359;
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

float saturate1(float x) { return clamp(x, 0.0, 1.0); }
vec3 saturate3(vec3 v) { return clamp(v, 0.0, 1.0); }

vec3 rotateEnvironment(vec3 d) {
    return vec3(uEnvRotation.x * d.x - uEnvRotation.y * d.z,
                d.y,
                uEnvRotation.y * d.x + uEnvRotation.x * d.z);
}

vec3 sampleEnvironment(vec3 direction, float mipLevel) {
    // The 0.9 is Metal's logicalToPhysicalLOD: the material's levels are
    // authored against a logical chain slightly shorter than the real one.
    const float logicalToPhysicalLOD = 0.9;
    return textureLod(uEnv, rotateEnvironment(direction),
                      mipLevel * logicalToPhysicalLOD).rgb * uEnvExposure;
}

vec3 liftEnvironmentShadows(vec3 color) {
    if (uRefractionShadowLift <= 0.0) {
        return color;
    }
    // A floor higher than two thirds of the knee makes the smoothstep toe
    // non-monotonic. Deriving it from a normalized amount keeps every slider
    // combination safely below that limit, so brighter cubemap values can
    // never become darker than values below them.
    float knee = max(uRefractionShadowKnee, 0.001);
    float blackFloor = saturate1(uRefractionShadowLift) * knee * 0.65;
    float luma = dot(color, LUMA);
    float shadowWeight = 1.0 - smoothstep(0.0, knee, luma);
    return color + blackFloor * shadowWeight;
}

vec3 sampleMicrofacetReflection(vec3 normal, vec3 viewDirection) {
    vec3 perfect = reflect(-viewDirection, normal);
    if (uRoughness < 0.002) {
        return liftEnvironmentShadows(sampleEnvironment(perfect, 0.0));
    }

    vec2 ringDirections[4];
    ringDirections[0] = vec2(1.0, 0.0);
    ringDirections[1] = vec2(0.0, 1.0);
    ringDirections[2] = vec2(-1.0, 0.0);
    ringDirections[3] = vec2(0.0, -1.0);

    vec3 radiance = vec3(0.0);
    float residualLevel = uRoughness * uMaxLevel * 0.22;
    float nDotV = max(dot(normal, viewDirection), 0.0001);
    float alpha = max(uRoughness * uRoughness, 0.0001);
    float alpha2 = alpha * alpha;
    vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(up, normal));
    vec3 bitangent = cross(normal, tangent);
    float ringCos = inversesqrt(1.0 + alpha2);
    float ringSin = sqrt(max(1.0 - ringCos * ringCos, 0.0));

    for (int index = 0; index < 5; ++index) {
        vec3 halfVector = normal;
        if (index > 0) {
            vec2 ring = ringDirections[index - 1];
            halfVector = tangent * (ring.x * ringSin)
                       + bitangent * (ring.y * ringSin)
                       + normal * ringCos;
        }
        vec3 reflected = 2.0 * dot(viewDirection, halfVector) * halfVector - viewDirection;
        float nDotL = saturate1(dot(normal, reflected));
        float nDotH = saturate1(dot(normal, halfVector));
        float vDotH = saturate1(dot(viewDirection, halfVector));
        if (nDotL > 0.0 && vDotH > 0.0) {
            float gv = (2.0 * nDotV) /
                (nDotV + sqrt(alpha2 + (1.0 - alpha2) * nDotV * nDotV));
            float gl = (2.0 * nDotL) /
                (nDotL + sqrt(alpha2 + (1.0 - alpha2) * nDotL * nDotL));
            float weight = gv * gl * vDotH / max(nDotV * nDotH, 0.0001);
            radiance += liftEnvironmentShadows(
                sampleEnvironment(reflected, residualLevel)
            ) * weight;
        }
    }
    return radiance / 5.0;
}

vec3 refractedExitDirection(vec3 incident, vec3 frontNormal, vec3 backNormal,
                            float ior, int bounces) {
    vec3 internalRay = refract(incident, frontNormal, 1.0 / ior);
    if (dot(internalRay, internalRay) < 0.0001) {
        internalRay = reflect(incident, frontNormal);
    }
    // Each count is one round trip between the back and front facets. The two
    // captured normals stand in for extra internal paths without more texture
    // reads.
    for (int bounce = 0; bounce < 4; ++bounce) {
        if (bounce >= bounces) break;
        internalRay = reflect(internalRay, -backNormal);
        internalRay = reflect(internalRay, frontNormal);
    }
    vec3 exitRay = refract(internalRay, -backNormal, ior);
    if (dot(exitRay, exitRay) < 0.0001) {
        // One reflected bounce keeps total internal reflection bright without
        // turning this into a path tracer.
        vec3 internalReflection = reflect(internalRay, -backNormal);
        exitRay = normalize(mix(internalReflection, reflect(incident, frontNormal), 0.24));
    }
    return normalize(exitRay);
}

float wavelengthIOROffset(float wavelength, float dispersion) {
    float position = (550.0 - wavelength) / 120.0;
    return dispersion * (0.010 * position + 0.015 * max(position, 0.0) * position);
}

vec3 acesToneMap(vec3 color) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate3((color * (a * color + b)) / (color * (c * color + d) + e));
}

vec3 hueToRGB(float hue) {
    vec3 wave = abs(fract(hue + vec3(0.0, 0.6666667, 0.3333333)) * 6.0 - 3.0);
    return saturate3(wave - 1.0);
}

vec3 simplexGradientVector(vec3 latticePoint) {
    vec3 value = fract(latticePoint * vec3(0.1031, 0.1030, 0.0973));
    value += dot(value, value.yxz + 33.33);
    value = fract((value.xxy + value.yxx) * value.zyx) * 2.0 - 1.0;
    return value * inversesqrt(max(dot(value, value), 0.0001));
}

void addSimplexCorner(vec3 offset, vec3 latticePoint,
                      inout float value, inout vec3 gradient) {
    float attenuation = 0.6 - dot(offset, offset);
    if (attenuation <= 0.0) return;
    vec3 cornerGradient = simplexGradientVector(latticePoint);
    float projection = dot(cornerGradient, offset);
    float a2 = attenuation * attenuation;
    float a3 = a2 * attenuation;
    float a4 = a2 * a2;
    value += a4 * projection;
    gradient += a4 * cornerGradient - 8.0 * a3 * projection * offset;
}

void simplexNoiseAndGradient(highp vec3 position, out float outValue, out vec3 outGradient) {
    const float skew = 1.0 / 3.0;
    const float unskew = 1.0 / 6.0;
    vec3 lattice = floor(position + dot(position, vec3(skew)));
    vec3 firstOffset = position - lattice + dot(lattice, vec3(unskew));
    vec3 ordering = step(firstOffset.yzx, firstOffset.xyz);
    vec3 inverseOrdering = 1.0 - ordering;
    vec3 secondCorner = min(ordering, inverseOrdering.zxy);
    vec3 thirdCorner = max(ordering, inverseOrdering.zxy);

    vec3 secondOffset = firstOffset - secondCorner + unskew;
    vec3 thirdOffset = firstOffset - thirdCorner + 2.0 * unskew;
    vec3 fourthOffset = firstOffset - 0.5;

    float value = 0.0;
    vec3 gradient = vec3(0.0);
    addSimplexCorner(firstOffset, lattice, value, gradient);
    addSimplexCorner(secondOffset, lattice + secondCorner, value, gradient);
    addSimplexCorner(thirdOffset, lattice + thirdCorner, value, gradient);
    addSimplexCorner(fourthOffset, lattice + 1.0, value, gradient);
    outValue = value * 32.0;
    outGradient = gradient * 32.0;
}

float grainHash(highp vec2 cell) {
    highp vec3 value = fract(vec3(cell.x, cell.y, cell.x) * 0.1031);
    value += dot(value, value.yzx + 33.33);
    return fract((value.x + value.y) * value.z);
}

// highp on the coordinate, not the result: the caller passes pixel positions, which exceed the
// 2048 fp16 represents exactly, and the floor below turns that error into whole wrong cells.
float grainNoise(highp vec2 screenPosition, float scale) {
    highp vec2 position = screenPosition * max(scale, 0.01);
    highp vec2 cell = floor(position);
    vec2 blend = fract(position);
    blend = blend * blend * (3.0 - 2.0 * blend);
    float lower = mix(grainHash(cell), grainHash(cell + vec2(1.0, 0.0)), blend.x);
    float upper = mix(grainHash(cell + vec2(0.0, 1.0)),
                      grainHash(cell + vec2(1.0, 1.0)), blend.x);
    return mix(lower, upper, blend.y);
}

// highp throughout: the glyph warp is the difference of two of these, and differencing two
// nearby projected points is exactly where mediump loses the digits that carry the result.
highp vec2 projectedScreenUV(highp vec3 worldPosition) {
    highp vec4 clip = uViewProjection * vec4(worldPosition, 1.0);
    highp float inverseW = 1.0 / max(abs(clip.w), 0.0001);
    highp vec2 ndc = clip.xy * inverseW;
    return vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
}

vec2 glyphTextureUV(highp vec2 screenUV, float glyphScale) {
    highp vec2 glyphPosition = screenUV - 0.5;
    glyphPosition.x *= uViewport.x / uViewport.y;
    const float glyphAspect = 0.902938;
    float glyphHeight = 0.145 * glyphScale;
    vec2 glyphUV = vec2(glyphPosition.x / (glyphHeight * glyphAspect) + 0.5,
                        glyphPosition.y / glyphHeight + 0.5);
    // WEB: no y-flip, where the Metal does glyphUV.y = 1.0 - glyphUV.y.
    //
    // That flip reconciles Core Graphics' y-down raster with Metal's texture
    // origin. GL's t axis runs the other way for the same upload, so carrying
    // the flip across applies it twice and the mark comes out mirrored — which
    // is exactly how it shipped until it was caught on screen.
    return glyphUV;
}

/// clamp_to_zero on the Metal sampler: outside 0..1 the glyph contributes
/// nothing. WebGL has no such wrap mode, so it is done in the lookup.
float sampleGlyph(vec2 uv, float bias) {
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 0.0;
    return texture(uGlyph, uv, bias).r;
}

void main() {
    highp vec3 viewDirection = normalize(uCameraPosition - vWorldPosition);
    vec3 incident = -viewDirection;
    vec3 frontNormal = normalize(vWorldNormal);
    if (dot(frontNormal, viewDirection) < 0.0) frontNormal = -frontNormal;

    // WEB: the G-buffer was rendered in this same bottom-left space, so this
    // fetch uses gl_FragCoord directly. Everything below that stands in for
    // Metal's top-left [[position]] uses fragPixel instead.
    ivec2 texel = ivec2(gl_FragCoord.xy);
    highp vec4 backPositionSample = texelFetch(uBackPosition, texel, 0);
    highp vec4 backNormalSample = texelFetch(uBackNormal, texel, 0);
    // highp: fp16 represents integers exactly only to 2048, and this surface is taller than
    // that, so a mediump pixel coordinate quantises over most of the screen. It feeds the
    // grain, the glyph's screen UV and the dither, all of which would band visibly.
    //
    // Qualifying it here is not enough on its own — a precision qualifier does not survive being
    // passed into a parameter declared at a lower one — so `grainNoise`, `grainHash` and
    // `glyphTextureUV` take highp coordinates too, and `screenUV` holds the divide at highp.
    highp vec2 fragPixel = vec2(gl_FragCoord.x, uViewport.y - gl_FragCoord.y);

    highp vec3 backPosition = backPositionSample.xyz;
    vec3 backNormal = normalize(backNormalSample.xyz);
    highp float thickness = distance(vWorldPosition, backPosition);
    bool validBackSurface = backPositionSample.w > 0.5 && thickness > 0.001;
    if (!validBackSurface) {
        backNormal = -frontNormal;
        thickness = 1.25;
    } else if (dot(backNormal, viewDirection) > 0.0) {
        backNormal = -backNormal;
    }
    thickness = clamp(thickness, 0.15, 2.75);

    int internalBounces = int(clamp(floor(uInternalBounces + 0.5), 0.0, 4.0));

    // The broad simplex bump bends every refracted path, including the glyph,
    // and leaves the reflection normal and the silhouette untouched.
    vec3 refractionFrontNormal = frontNormal;
    if (uSimplexBump > 0.0001 && (uTransmission > 0.0001 || uGlyphEnabled > 0.5)) {
        float noiseValue;
        vec3 noiseGradient;
        simplexNoiseAndGradient(vObjectPosition * uSimplexScale + vec3(11.7, 4.3, 19.1),
                                noiseValue, noiseGradient);
        vec3 objectGradient = noiseGradient * uSimplexScale;
        vec3 worldGradient = (uModel * vec4(objectGradient, 0.0)).xyz;
        vec3 tangentGradient = worldGradient - frontNormal * dot(worldGradient, frontNormal);
        float gradientLength = length(tangentGradient);
        if (gradientLength > 2.0) tangentGradient *= 2.0 / gradientLength;
        float bumpSlope = uSimplexBump * uSimplexBump * 0.11;
        refractionFrontNormal = normalize(frontNormal - tangentGradient * bumpSlope);
    }

    float baseTransmissionLevel = min(uRefractionBlur * (uMaxLevel + thickness * 3.5),
                                      uMaxLevel);
    vec3 transmission = vec3(0.0);
    float fresnel;

    if (uTransmission > 0.0001) {
        float grain = 0.5;
        if (uGrainBlur > 0.0001 && uDispersionMix > 0.0001) {
            grain = grainNoise(fragPixel, uGrainScale);
        }
        bool spectralDispersion = uDispersion > 0.0001 && uDispersionMix > 0.0001;
        float localDispersionMix = spectralDispersion
            ? saturate1(uDispersionMix * (1.0 + (grain - 0.5) * uGrainBlur * 0.45))
            : 0.0;

        vec3 neutralTransmission = vec3(0.0);
        if (!spectralDispersion || localDispersionMix < 1.0) {
            vec3 neutralExit = refractedExitDirection(
                incident, refractionFrontNormal, backNormal, uIOR, internalBounces);
            neutralTransmission = liftEnvironmentShadows(
                sampleEnvironment(neutralExit, baseTransmissionLevel)
            );
            transmission = neutralTransmission;
        }

        if (spectralDispersion) {
            float spectralLevel = min(
                baseTransmissionLevel
                    + uDispersionSmoothness * uMaxLevel * 0.16
                    + uGrainBlur * mix(0.15, 1.0, grain) * uMaxLevel * 0.10,
                uMaxLevel);
            float incidenceAngle = acos(saturate1(dot(frontNormal, viewDirection)));
            float edgeFactor = smoothstep(uEdgeDispersionAngle, 1.5707963, incidenceAngle);
            float edgeAmplification = 1.0 + edgeFactor * (1.50 + 0.28 * float(internalBounces));
            float effectiveDispersion = uDispersion * edgeAmplification;

            // Stratified wavelengths, advanced by recurrence so the loop costs
            // six exponentials rather than three per sample. Must stay equal to
            // SPECTRAL_SAMPLE_COUNT in GemMaterial.kt, which seeds that
            // recurrence: a count that disagrees integrates the wrong curve.
            const int spectralSampleCount = 8;
            const float wavelengthSpan = 220.0;
            const float wavelengthStep = wavelengthSpan / float(spectralSampleCount);
            float wavelengthJitter = (grain - 0.5) * wavelengthStep * uGrainBlur * 1.5;
            float firstWavelength = 430.0 + 0.5 * wavelengthStep + wavelengthJitter;
            vec3 wavelengthDelta = vec3(firstWavelength) - vec3(610.0, 545.0, 455.0);
            float wavelengthStepSquared = wavelengthStep * wavelengthStep;
            vec3 weight = exp(-0.5 * wavelengthDelta * wavelengthDelta * uInverseVariance);
            vec3 weightRatio = exp(
                -(wavelengthStep * wavelengthDelta + 0.5 * wavelengthStepSquared)
                * uInverseVariance);
            vec3 spectralTransmission = vec3(0.0);
            vec3 spectralWeight = vec3(0.0);
            for (int sampleIndex = 0; sampleIndex < spectralSampleCount; ++sampleIndex) {
                float wavelength = firstWavelength + float(sampleIndex) * wavelengthStep;
                float spectralIOR = clamp(
                    uIOR + wavelengthIOROffset(wavelength, effectiveDispersion), 1.001, 3.0);
                vec3 exitDirection = refractedExitDirection(
                    incident, refractionFrontNormal, backNormal, spectralIOR, internalBounces);
                vec3 environmentSample = liftEnvironmentShadows(
                    sampleEnvironment(exitDirection, spectralLevel)
                );
                float energy = dot(environmentSample, LUMA);
                spectralTransmission += energy * weight;
                spectralWeight += weight;
                weight *= weightRatio;
                weightRatio *= uWeightRatioStep;
            }
            spectralTransmission /= max(spectralWeight, vec3(0.0001));

            transmission = localDispersionMix >= 1.0
                ? spectralTransmission
                : mix(neutralTransmission, spectralTransmission, localDispersionMix);
            float transmissionLuma = dot(transmission, LUMA);
            float chromaGain = uSpectrum <= 1.0 ? uSpectrum : 1.0 + (uSpectrum - 1.0) * 0.60;
            transmission = max(vec3(0.0), mix(vec3(transmissionLuma), transmission, chromaGain));
        }

        vec3 tintColor = hueToRGB(fract(uTintHue));
        vec3 absorptionCoefficient = vec3(0.10) + (1.0 - tintColor) * uTintStrength * 1.20;
        vec3 absorption = exp(-absorptionCoefficient * uVolumeDensity * thickness);
        transmission *= absorption * uTransmission;
    }

    vec3 reflection = vec3(0.0);
    if (uReflection > 0.0001 || uEdgeLight > 0.0001) {
        reflection = sampleMicrofacetReflection(frontNormal, viewDirection);
    }

    float f0Ratio = (uIOR - 1.0) / (uIOR + 1.0);
    float physicalF0 = f0Ratio * f0Ratio;
    float facing = saturate1(dot(frontNormal, viewDirection));
    float inverseFacing = 1.0 - facing;
    float inverseFacingSquared = inverseFacing * inverseFacing;
    float inverseFacingFifth = inverseFacingSquared * inverseFacingSquared * inverseFacing;
    fresnel = saturate1((physicalF0 + (1.0 - physicalF0) * inverseFacingFifth) * uFresnelStrength);

    vec3 color = reflection * fresnel * uReflection + transmission * (1.0 - fresnel);
    float rim = inverseFacingSquared * inverseFacing;
    color += reflection * rim * uEdgeLight;

    if (uGlyphEnabled > 0.5 && uGlyphOpacity > 0.0001) {
        highp vec2 screenUV = fragPixel / uViewport;
        vec3 glyphRay;
        float glyphPathLength;
        if (uGlyphBehind > 0.5) {
            glyphRay = refractedExitDirection(
                incident, refractionFrontNormal, backNormal, uIOR, internalBounces);
            glyphPathLength = thickness;
        } else {
            glyphRay = refract(incident, refractionFrontNormal, 1.0 / uIOR);
            if (dot(glyphRay, glyphRay) < 0.0001) {
                glyphRay = reflect(incident, refractionFrontNormal);
            }
            glyphRay = normalize(glyphRay);
            glyphPathLength = thickness * 0.5;
        }

        highp vec2 incidentScreenEnd =
            projectedScreenUV(vWorldPosition + incident * glyphPathLength);
        highp vec2 refractedScreenEnd =
            projectedScreenUV(vWorldPosition + glyphRay * glyphPathLength);
        vec2 directionalWarp = clamp(refractedScreenEnd - incidentScreenEnd,
                                     vec2(-0.35), vec2(0.35));
        vec2 glyphWarp = directionalWarp * vec2(uGlyphRefractionX, uGlyphRefractionY);
        highp vec2 glyphScreenUV = screenUV + glyphWarp;
        glyphScreenUV.y -= uGlyphPositionY;

        vec2 dispersionAxis = glyphWarp;
        if (dot(dispersionAxis, dispersionAxis) < 0.0000001) dispersionAxis = directionalWarp;
        if (dot(dispersionAxis, dispersionAxis) < 0.0000001) dispersionAxis = vec2(1.0, 0.0);
        dispersionAxis = normalize(dispersionAxis);
        vec2 chromaticScreenOffset = dispersionAxis * uGlyphChromatic / uViewport;
        float glyphMipBias = uRefractionBlur * 1.5;

        vec2 centerGlyphUV = glyphTextureUV(glyphScreenUV, uGlyphScale);
        vec2 redGlyphUV = glyphTextureUV(glyphScreenUV - chromaticScreenOffset, uGlyphScale);
        vec2 blueGlyphUV = glyphTextureUV(glyphScreenUV + chromaticScreenOffset, uGlyphScale);

        vec3 glyphMask = vec3(0.0);
        if (uGlyphChromatic > 0.001) {
            glyphMask = vec3(sampleGlyph(redGlyphUV, glyphMipBias),
                             sampleGlyph(centerGlyphUV, glyphMipBias),
                             sampleGlyph(blueGlyphUV, glyphMipBias));
        } else {
            glyphMask = vec3(sampleGlyph(centerGlyphUV, glyphMipBias));
        }

        float glassVisibility = uGlyphBehind > 0.5
            ? mix(0.25, 1.0, 1.0 - fresnel) * exp(-uVolumeDensity * thickness * 0.10)
            : mix(0.55, 1.0, 1.0 - fresnel);
        glyphMask *= glassVisibility;
        float glyphCoverage = saturate1(
            max(glyphMask.r, max(glyphMask.g, glyphMask.b)) * min(uGlyphOpacity, 1.0));
        color = color * (1.0 - glyphCoverage) + vec3(2.0) * glyphMask * uGlyphOpacity;
    }

    color = acesToneMap(color * uExposure);

    // Floor under the dead facets, weighted by a shadow knee so the silver and
    // the dispersion keep their contrast. Zero on the award screen.
    if (uShadowLift > 0.0) {
        float luma = dot(color, LUMA);
        float shadowWeight = 1.0 - smoothstep(0.0, max(uShadowKnee, 0.001), luma);
        color = min(vec3(1.0), color + uShadowLift * shadowWeight);
    }

    float displayDither = grainHash(floor(fragPixel) + vec2(37.0, 113.0)) - 0.5;
    color = saturate3(color + displayDither / 255.0);
    fragColor = vec4(color, 1.0);
}
