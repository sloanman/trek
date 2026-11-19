-- Realistic 3D Simplex Noise GLSL planet shader matching terrain_gen.py biomes, dual clouds, bump relief & Rayleigh atmosphere

local PlanetRenderer = {}

local shaderCode = [[
extern float u_time;
extern float u_seed;
extern int u_archetype;
extern float u_seaLevel;
extern float u_continentScale;
extern vec3 u_lightDir;
extern float u_pixelSize; // 0.0 for smooth realistic globe, >0 for pixelated
extern float u_rimScale;  // Quad padding ratio (>= 1.0) so outer atmosphere halo renders outside sphere edge

// --- 3D Simplex Noise (Ashima/Gustavson) ---
vec4 permute(vec4 x) { return mod(((x * 34.0) + 1.0) * x, 289.0); }
vec4 taylorInvSqrt(vec4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

float snoise(vec3 v) {
    const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
    const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);

    vec3 i  = floor(v + dot(v, C.yyy));
    vec3 x0 = v - i + dot(i, C.xxx);

    vec3 g = step(x0.yzx, x0.xyz);
    vec3 l = 1.0 - g;
    vec3 i1 = min(g.xyz, l.zxy);
    vec3 i2 = max(g.xyz, l.zxy);

    vec3 x1 = x0 - i1 + C.xxx;
    vec3 x2 = x0 - i2 + C.yyy;
    vec3 x3 = x0 - D.yyy;

    i = mod(i, 289.0);
    vec4 p = permute(permute(permute(
              i.z + vec4(0.0, i1.z, i2.z, 1.0))
            + i.y + vec4(0.0, i1.y, i2.y, 1.0))
            + i.x + vec4(0.0, i1.x, i2.x, 1.0));

    float n_ = 1.0 / 7.0;
    vec3 ns = n_ * D.wyz - D.xzx;

    vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
    vec4 x_ = floor(j * ns.z);
    vec4 y_ = floor(j - 7.0 * x_);

    vec4 x = x_ * ns.x + ns.yyyy;
    vec4 y = y_ * ns.x + ns.yyyy;
    vec4 h = 1.0 - abs(x) - abs(y);

    vec4 b0 = vec4(x.xy, y.xy);
    vec4 b1 = vec4(x.zw, y.zw);

    vec4 s0 = floor(b0) * 2.0 + 1.0;
    vec4 s1 = floor(b1) * 2.0 + 1.0;
    vec4 sh = -step(h, vec4(0.0));

    vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

    vec3 p0 = vec3(a0.xy, h.x);
    vec3 p1 = vec3(a0.zw, h.y);
    vec3 p2 = vec3(a1.xy, h.z);
    vec3 p3 = vec3(a1.zw, h.w);

    vec4 norm = taylorInvSqrt(vec4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));
    p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;

    vec4 m = max(0.6 - vec4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m * m, vec4(dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3)));
}

float turbulence(vec3 p, int octaves, float roughness, float baseFreq, bool useAbs) {
    float val = 0.0;
    float amp = 1.0;
    float freq = baseFreq;
    float totalAmp = 0.0;
    for (int i = 0; i < 4; i++) {
        if (i >= octaves) break;
        float s = snoise(p * freq);
        val += (useAbs ? abs(s) : (s * 0.5 + 0.5)) * amp;
        totalAmp += amp;
        amp *= roughness;
        freq *= 2.0;
    }
    return val / totalAmp;
}

vec3 rotateY(vec3 p, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

vec3 rotateX(vec3 p, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return vec3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

// Bounded pseudo-random offset in [-14, 14] so large seeds never lose GLSL float precision
vec3 seedVec(float s) {
    return vec3(
        fract(sin(s * 12.9898 + 1.23) * 43758.5453),
        fract(sin(s * 78.2330 + 4.56) * 43758.5453),
        fract(sin(s * 37.7190 + 7.89) * 43758.5453)
    ) * 28.0 - 14.0;
}

float sampleHeight(vec3 p) {
    float continent = snoise(p * u_continentScale) * 0.5 + 0.5;
    float turb = turbulence(p, 3, 0.52, 2.2, true);
    return clamp(continent * 0.58 + turb * 0.42, 0.0, 1.0);
}

vec4 getBiomeColor(vec3 pos, vec3 seedOffset, out float outHeight) {
    vec3 deepOcean, shallowOcean, beach, swamp, rainforest, forest, plains, desert, taiga, tundra, rock, snow;

    if (u_archetype == 1) { // violet_alien
        deepOcean    = vec3(0.09, 0.04, 0.22);
        shallowOcean = vec3(0.34, 0.12, 0.48);
        beach        = vec3(0.75, 0.41, 0.58);
        swamp        = vec3(0.15, 0.09, 0.30);
        rainforest   = vec3(0.65, 0.10, 0.58);
        forest       = vec3(0.42, 0.14, 0.55);
        plains       = vec3(0.12, 0.60, 0.60);
        desert       = vec3(0.80, 0.40, 0.53);
        taiga        = vec3(0.16, 0.19, 0.40);
        tundra       = vec3(0.45, 0.36, 0.55);
        rock         = vec3(0.32, 0.24, 0.36);
        snow         = vec3(0.96, 0.88, 0.98);
    } else if (u_archetype == 2) { // crimson_waste
        deepOcean    = vec3(0.08, 0.05, 0.06);
        shallowOcean = vec3(0.24, 0.10, 0.12);
        beach        = vec3(0.65, 0.35, 0.22);
        swamp        = vec3(0.28, 0.14, 0.10);
        rainforest   = vec3(0.55, 0.15, 0.12);
        forest       = vec3(0.65, 0.22, 0.15);
        plains       = vec3(0.78, 0.40, 0.22);
        desert       = vec3(0.88, 0.52, 0.28);
        taiga        = vec3(0.42, 0.20, 0.18);
        tundra       = vec3(0.50, 0.38, 0.35);
        rock         = vec3(0.22, 0.18, 0.18);
        snow         = vec3(0.92, 0.80, 0.78);
    } else if (u_archetype == 3) { // toxic_sulfur
        deepOcean    = vec3(0.02, 0.18, 0.18);
        shallowOcean = vec3(0.06, 0.38, 0.36);
        beach        = vec3(0.75, 0.82, 0.30);
        swamp        = vec3(0.20, 0.35, 0.10);
        rainforest   = vec3(0.25, 0.65, 0.15);
        forest       = vec3(0.40, 0.68, 0.18);
        plains       = vec3(0.72, 0.80, 0.24);
        desert       = vec3(0.85, 0.82, 0.35);
        taiga        = vec3(0.18, 0.42, 0.28);
        tundra       = vec3(0.40, 0.52, 0.42);
        rock         = vec3(0.28, 0.32, 0.26);
        snow         = vec3(0.85, 0.98, 0.85);
    } else if (u_archetype == 4) { // frozen_tundra
        deepOcean    = vec3(0.02, 0.08, 0.20);
        shallowOcean = vec3(0.10, 0.28, 0.46);
        beach        = vec3(0.60, 0.72, 0.78);
        swamp        = vec3(0.18, 0.30, 0.35);
        rainforest   = vec3(0.15, 0.42, 0.45);
        forest       = vec3(0.25, 0.50, 0.52);
        plains       = vec3(0.50, 0.68, 0.72);
        desert       = vec3(0.70, 0.78, 0.82);
        taiga        = vec3(0.12, 0.30, 0.34);
        tundra       = vec3(0.45, 0.62, 0.68);
        rock         = vec3(0.25, 0.32, 0.38);
        snow         = vec3(0.92, 0.97, 1.00);
    } else if (u_archetype == 5) { // golden_savanna
        deepOcean    = vec3(0.03, 0.18, 0.22);
        shallowOcean = vec3(0.08, 0.36, 0.42);
        beach        = vec3(0.85, 0.72, 0.45);
        swamp        = vec3(0.35, 0.28, 0.12);
        rainforest   = vec3(0.75, 0.42, 0.10);
        forest       = vec3(0.82, 0.55, 0.15);
        plains       = vec3(0.88, 0.70, 0.22);
        desert       = vec3(0.92, 0.78, 0.40);
        taiga        = vec3(0.45, 0.38, 0.20);
        tundra       = vec3(0.55, 0.50, 0.40);
        rock         = vec3(0.38, 0.30, 0.25);
        snow         = vec3(0.98, 0.95, 0.90);
    } else { // 0: terrestrial
        deepOcean    = vec3(0.04, 0.13, 0.25);
        shallowOcean = vec3(0.16, 0.44, 0.55);
        beach        = vec3(0.80, 0.74, 0.55);
        swamp        = vec3(0.16, 0.24, 0.12);
        rainforest   = vec3(0.04, 0.38, 0.14);
        forest       = vec3(0.18, 0.50, 0.22);
        plains       = vec3(0.52, 0.62, 0.26);
        desert       = vec3(0.84, 0.68, 0.38);
        taiga        = vec3(0.14, 0.28, 0.24);
        tundra       = vec3(0.48, 0.52, 0.48);
        rock         = vec3(0.36, 0.34, 0.33);
        snow         = vec3(0.94, 0.96, 0.98);
    }

    vec3 p = pos + seedOffset;
    float height = sampleHeight(p);
    outHeight = height;
    float beachLevel = u_seaLevel + 0.022;

    if (height < u_seaLevel) {
        float depthFactor = pow(clamp(height / u_seaLevel, 0.0, 1.0), 1.8);
        return vec4(mix(deepOcean, shallowOcean, depthFactor), 1.0); // alpha 1.0 encodes water for specular
    }
    if (height < beachLevel) {
        float t = clamp((height - u_seaLevel) / (beachLevel - u_seaLevel), 0.0, 1.0);
        return vec4(mix(shallowOcean, beach, t), 0.25);
    }

    float landH = (height - beachLevel) / (1.0 - beachLevel);
    float latAbs = abs(pos.y);

    // Independent seeded offsets for temperature and moisture fields
    vec3 tempSeed = seedVec(u_seed + 11.7);
    vec3 moistSeed = seedVec(u_seed + 31.3);
    float tempTurb = turbulence(pos + tempSeed, 2, 0.52, 1.4, false);
    float moistTurb = turbulence(pos + moistSeed, 2, 0.52, 1.8, false);

    float temp = clamp((1.0 - latAbs * 1.15) + (tempTurb - 0.5) * 0.3 - landH * 0.7, 0.0, 1.0);
    float moisture = clamp(moistTurb * 1.15 - landH * 0.25, 0.0, 1.0);

    if (landH > 0.65) {
        float mountainFactor = (landH - 0.65) / 0.35;
        return vec4(mix(rock, snow, clamp(mountainFactor + (1.0 - temp) * 0.4, 0.0, 1.0)), 0.0);
    }
    if (temp < 0.22) {
        vec3 polarBiome = mix(taiga, tundra, clamp(1.0 - moisture, 0.0, 1.0));
        return vec4(mix(polarBiome, snow, clamp((0.22 - temp) / 0.22, 0.0, 1.0)), 0.0);
    }

    vec3 baseCol;
    if (moisture > 0.60) {
        baseCol = mix(rainforest, swamp, clamp(1.0 - landH * 3.0, 0.0, 1.0));
    } else if (moisture > 0.35) {
        baseCol = mix(plains, forest, clamp((moisture - 0.35) / 0.25, 0.0, 1.0));
    } else {
        baseCol = mix(desert, plains, clamp(moisture / 0.35, 0.0, 1.0));
    }

    if (landH > 0.45) {
        baseCol = mix(baseCol, rock, clamp((landH - 0.45) / 0.20, 0.0, 1.0));
    }
    return vec4(baseCol, 0.0);
}

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
    vec2 uv = texture_coords;
    if (u_pixelSize > 0.0) {
        uv = (floor(uv * u_pixelSize) + 0.5) / u_pixelSize;
    }

    // Map quad UV to sphere coordinates where r = 1.0 is planet surface limb
    vec2 p = (uv * 2.0 - 1.0) * u_rimScale;
    float r2 = dot(p, p);
    float r = sqrt(r2);

    vec3 atmoColor = (u_archetype == 1) ? vec3(0.75, 0.38, 1.0)
                   : (u_archetype == 2) ? vec3(1.0, 0.42, 0.26)
                   : (u_archetype == 3) ? vec3(0.65, 0.95, 0.32)
                   : (u_archetype == 4) ? vec3(0.45, 0.82, 1.0)
                   : (u_archetype == 5) ? vec3(1.0, 0.78, 0.38)
                   : vec3(0.36, 0.68, 1.0);

    vec3 lightDir = normalize(u_lightDir);

    // Outer Rayleigh atmospheric glow halo outside planet surface (1.0 < r <= u_rimScale)
    if (r >= 1.0) {
        if (r > u_rimScale) {
            return vec4(0.0);
        }
        vec3 rimNorm = normalize(vec3(p.x, p.y, 0.08));
        float rimLit = 0.16 + 0.84 * smoothstep(-0.35, 0.75, dot(rimNorm, lightDir));
        float falloff = pow(clamp(1.0 - (r - 1.0) / max(0.001, u_rimScale - 1.0), 0.0, 1.0), 2.4);
        return vec4(atmoColor * rimLit, falloff * 0.55 * rimLit) * color;
    }

    float z = sqrt(max(0.0, 1.0 - r2));
    vec3 viewNormal = vec3(p.x, p.y, z);

    // Subtle 18-deg planetary axial tilt so polar ice caps & cloud bands read cleanly in 3D
    vec3 tiltedNormal = rotateX(viewNormal, 0.30);
    vec3 seedOffset = seedVec(u_seed);

    // 1. Rotating terrain surface
    vec3 surfPos = rotateY(tiltedNormal, u_time * 0.14);
    float hCenter = 0.0;
    vec4 biomeInfo = getBiomeColor(surfPos, seedOffset, hCenter);
    vec3 col = biomeInfo.rgb;
    float waterMask = biomeInfo.a;

    // 2. Subtle terrain relief bump-mapping for continents & mountain ranges
    vec3 bumpNormal = viewNormal;
    if (hCenter > u_seaLevel) {
        float eps = 0.025;
        float hx = sampleHeight(surfPos + seedOffset + vec3(eps, 0.0, 0.0));
        float hy = sampleHeight(surfPos + seedOffset + vec3(0.0, eps, 0.0));
        vec3 grad = vec3((hx - hCenter) / eps, (hy - hCenter) / eps, 0.0);
        bumpNormal = normalize(viewNormal - grad * 0.22);
    }

    // 3. Dual cloud layers matching terrain_gen.py tints & independent seeds
    vec3 cloudTint1 = (u_archetype == 1) ? vec3(0.95, 0.85, 1.0)
                    : (u_archetype == 2) ? vec3(1.0, 0.85, 0.78)
                    : (u_archetype == 3) ? vec3(0.88, 0.95, 0.75)
                    : (u_archetype == 4) ? vec3(0.88, 0.94, 1.0)
                    : (u_archetype == 5) ? vec3(1.0, 0.94, 0.88)
                    : vec3(1.0);
    vec3 cloudTint2 = (u_archetype == 1) ? vec3(0.80, 0.95, 1.0)
                    : (u_archetype == 2) ? vec3(1.0, 0.92, 0.88)
                    : (u_archetype == 3) ? vec3(0.92, 0.98, 0.82)
                    : (u_archetype == 4) ? vec3(0.95, 0.98, 1.0)
                    : (u_archetype == 5) ? vec3(1.0, 0.98, 0.92)
                    : vec3(0.94, 0.96, 1.0);

    vec3 cSeed1 = seedVec(u_seed + 47.1);
    vec3 cSeed2 = seedVec(u_seed + 93.7);
    vec3 cloudPos1 = rotateY(tiltedNormal, u_time * 0.21) + cSeed1;
    vec3 cloudPos2 = rotateY(tiltedNormal, u_time * 0.29) + cSeed2;

    float c1 = turbulence(cloudPos1, 3, 0.55, 2.1, false);
    float c2 = turbulence(cloudPos2, 2, 0.45, 3.3, false);
    float a1 = (c1 > 0.52) ? clamp(((c1 - 0.52) / 0.48) * 1.35, 0.0, 0.78) : 0.0;
    float a2 = (c2 > 0.57) ? clamp(((c2 - 0.57) / 0.43) * 1.10, 0.0, 0.58) : 0.0;

    // Subtle cloud drop-shadow cast onto planet surface
    float cs = turbulence(cloudPos1 - lightDir * 0.04, 2, 0.55, 2.1, false);
    float cloudShadow = (cs > 0.53) ? clamp(((cs - 0.53) / 0.47) * 1.1, 0.0, 0.40) : 0.0;
    col *= (1.0 - cloudShadow * 0.40);

    // 4. Realistic spherical terminator lighting + ocean specular glint
    float ndotlSurf = max(dot(bumpNormal, lightDir), 0.0);
    float ndotlGlobe = max(dot(viewNormal, lightDir), 0.0);
    float light = 0.06 + 0.94 * pow(ndotlSurf, 0.82);

    vec3 halfVec = normalize(lightDir + vec3(0.0, 0.0, 1.0));
    float spec = pow(max(dot(viewNormal, halfVec), 0.0), 28.0) * waterMask * 0.42 * (1.0 - max(a1, a2));

    col = col * light + vec3(spec) * atmoColor;

    // Composite lit cloud layers over terrain
    float cloudLight = 0.09 + 0.91 * pow(ndotlGlobe, 0.78);
    col = mix(col, cloudTint1 * cloudLight, a1);
    col = mix(col, cloudTint2 * cloudLight, a2);

    // 5. Atmospheric Fresnel rim scattering + warm/tinted terminator scattering
    float fresnel = pow(1.0 - z, 2.8);
    float twilight = smoothstep(0.0, 0.25, ndotlGlobe) * (1.0 - smoothstep(0.15, 0.55, ndotlGlobe));
    col += atmoColor * fresnel * (0.14 + 0.68 * ndotlGlobe);
    col += atmoColor * twilight * 0.08;

    // Anti-aliased planet edge blending smoothly into outer atmospheric halo
    float edgeAlpha = 1.0 - smoothstep(0.96, 1.0, r);
    float haloAlpha = clamp(1.0 - (r - 1.0) / max(0.001, u_rimScale - 1.0), 0.0, 1.0);
    float finalAlpha = mix(pow(haloAlpha, 2.4) * 0.55, 1.0, edgeAlpha);

    return vec4(col, finalAlpha) * color;
}
]]

PlanetRenderer.ARCHETYPES = {
    terrestrial = 0,
    violet_alien = 1,
    crimson_waste = 2,
    toxic_sulfur = 3,
    frozen_tundra = 4,
    golden_savanna = 5,
}

function PlanetRenderer.init()
    if PlanetRenderer.shader or not (love and love.graphics and love.image) then
        return
    end
    PlanetRenderer.shader = love.graphics.newShader(shaderCode)
    -- 1x1 white dummy texture so love.graphics.draw supplies clean 0..1 texture_coords
    local imgData = love.image.newImageData(1, 1)
    imgData:setPixel(0, 0, 1, 1, 1, 1)
    PlanetRenderer.quadTex = love.graphics.newImage(imgData)
    PlanetRenderer.quadTex:setFilter("linear", "linear")
end

-- archetype: 0..5 (or use PlanetRenderer.ARCHETYPES[name])
-- pixelSize: 0 for smooth realistic globe, or >0 (e.g. 64) for pixelated look
function PlanetRenderer.draw(x, y, radius, seed, archetype, time, pixelSize)
    if not (love and love.graphics) then return end
    if not PlanetRenderer.shader then
        PlanetRenderer.init()
    end
    local s = PlanetRenderer.shader
    if not s then return end

    local rimScale = 1.16
    local sd = seed or 1337
    local seaLevel = 0.37 + ((sd * 0.6180339) % 1) * 0.08 -- 0.37..0.45 for balanced continents & oceans
    local continentScale = 0.85 + ((sd * 0.381966) % 1) * 0.50

    s:send("u_time", time or 0)
    s:send("u_seed", sd)
    s:send("u_archetype", archetype or 0)
    s:send("u_seaLevel", seaLevel)
    s:send("u_continentScale", continentScale)
    s:send("u_lightDir", { -0.65, -0.35, 0.67 })
    s:send("u_pixelSize", pixelSize or 0.0)
    s:send("u_rimScale", rimScale)

    local drawR = radius * rimScale
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setShader(s)
    love.graphics.draw(PlanetRenderer.quadTex, x - drawR, y - drawR, 0, drawR * 2, drawR * 2)
    love.graphics.setShader()
end

return PlanetRenderer
