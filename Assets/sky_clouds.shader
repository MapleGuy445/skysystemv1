MODES
{
    Depth();
    Forward();
}

COMMON
{
    #include "postprocess/shared.hlsl"
}

struct VertexInput
{
    float3 vPositionOs : POSITION < Semantic(PosXyz); > ;
};

struct PixelInput
{
	#include "common/pixelinput.hlsl"
};

VS
{
    PixelInput MainVs(VertexInput i)
    {
        PixelInput o;
        o.vPositionPs = float4(i.vPositionOs.xy, 0.0f, 1.0f);
        return o;
    }
}

PS
{
    #include "common/pixel.hlsl"
    #include "postprocess/common.hlsl"
    #include "postprocess/functions.hlsl"

    // ------------------------------------------------------------------
    // Inputs. Cloud distances are METERS, atmosphere math is KILOMETERS.
    // All set by SkyCloudSystem.cs.
    // ------------------------------------------------------------------
    Texture2D colorBuffer < Attribute("ColorBuffer"); SrgbRead(true); > ;

    // Sun / moon
    float3 sun_dir          < Attribute("sun_dir"); > ;           // direction TOWARD the sun
    float3 sun_color        < Attribute("sun_color"); > ;         // cloud direct light (tinted by atmosphere, includes intensity)
    float3 ambient_top      < Attribute("ambient_top"); > ;
    float3 ambient_bottom   < Attribute("ambient_bottom"); > ;
    float  sun_disk_cos     < Attribute("sun_disk_cos"); > ;
    float3 moon_dir         < Attribute("moon_dir"); > ;
    float  moon_disk_cos    < Attribute("moon_disk_cos"); > ;

    // Sky
    float  sky_enabled       < Attribute("sky_enabled"); > ;
    float  sky_sun_intensity < Attribute("sky_sun_intensity"); > ;
    float  sky_exposure      < Attribute("sky_exposure"); > ;
    float  cloud_exposure    < Attribute("cloud_exposure"); > ;
    float  aerial_strength   < Attribute("aerial_strength"); > ;
    float3 ground_albedo     < Attribute("ground_albedo"); > ;
    float  star_brightness   < Attribute("star_brightness"); > ;
    float  star_angle        < Attribute("star_angle"); > ;

    // World / clouds
    float ground_z           < Attribute("ground_z"); > ;
    float max_cloud_distance < Attribute("max_cloud_distance"); > ;
    float far_distance       < Attribute("far_distance"); > ;
    float extinction         < Attribute("extinction"); > ;

    // Quality / debug
    float step_count   < Attribute("step_count"); > ;
    float light_steps  < Attribute("light_steps"); > ;
    float sky_steps    < Attribute("sky_steps"); > ;
    float debug_mode   < Attribute("debug_mode"); > ;

    // x = bottom, y = top, z = coverage, w = density
    float4 layer0_range  < Attribute("layer0_range"); > ;
    float4 layer1_range  < Attribute("layer1_range"); > ;
    float4 layer2_range  < Attribute("layer2_range"); > ;
    // x = shape freq (1/m), y/z = wind offset (m), w = detail strength
    float4 layer0_params < Attribute("layer0_params"); > ;
    float4 layer1_params < Attribute("layer1_params"); > ;
    float4 layer2_params < Attribute("layer2_params"); > ;

    static const float INCH_TO_M  = 0.0254;
    static const int   MAX_LAYERS = 3;
    static const int   MAX_STEPS  = 128;
    static const float PI_F       = 3.14159265;

    // Cloud density (declares the noise textures and layerN_noise attributes).
    #include "cloud_density.hlsl"

    // ------------------------------------------------------------------
    // Hashing (integer PCG: stable across GPUs) - used by the stars
    // ------------------------------------------------------------------
    uint3 pcg3d(uint3 v)
    {
        v = v * 1664525u + 1013904223u;
        v.x += v.y * v.z;
        v.y += v.z * v.x;
        v.z += v.x * v.y;
        v ^= (v >> 16u);
        v.x += v.y * v.z;
        v.y += v.z * v.x;
        v.z += v.x * v.y;
        return v;
    }

    // Interleaved gradient noise (cheap per-pixel jitter; Phase 5 swaps in blue noise + frame index).
    float InterleavedGradientNoise(float2 px)
    {
        return frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
    }

    // ==================================================================
    //  ATMOSPHERE (single scattering, virtual spherical planet, km)
    //  Camera sits at (0, 0, R + altitude); world Z is up.
    //  Phase 9 can replace this with LUTs without touching the callers.
    // ==================================================================
    static const float  PLANET_R = 6371.0;
    static const float  ATMO_H   = 100.0;
    static const float  ATMO_R   = PLANET_R + ATMO_H;
    static const float  H_RAY    = 8.0;
    static const float  H_MIE    = 1.2;
    // Vector constants are macros: the s&box HLSL parser rejects global
    // "static const float3 X = float3(...)" declarations.
    #define BETA_R float3(0.0058, 0.0135, 0.0331)
    static const float  BETA_M   = 0.021;
    #define BETA_O float3(0.00065, 0.001881, 0.000085)

    float PhaseRayleigh(float mu)
    {
        return 3.0 / (16.0 * PI_F) * (1.0 + mu * mu);
    }

    float PhaseMie(float mu, float g)
    {
        float g2 = g * g;
        return 3.0 / (8.0 * PI_F) * ((1.0 - g2) * (1.0 + mu * mu))
             / ((2.0 + g2) * pow(max(1.0 + g2 - 2.0 * g * mu, 0.001), 1.5));
    }

    // Ray vs sphere centered at the origin. Cancellation-safe form.
    // Returns (tNear, tFar) or (-1,-1) on a miss.
    float2 AtmoSphereHit(float3 o, float3 d, float r)
    {
        float b = dot(o, d);
        float3 qc = o - b * d;
        float ql = length(qc);
        float h2 = (r - ql) * (r + ql);
        if (h2 < 0.0)
            return float2(-1.0, -1.0);
        float h = sqrt(h2);
        return float2(-b - h, -b + h);
    }

    // Optical depth from P toward the sun. Returns false if the planet blocks the sun.
    bool AtmoLightDepth(float3 P, float3 sun, out float3 tau)
    {
        tau = float3(0.0, 0.0, 0.0);

        float2 pl = AtmoSphereHit(P, sun, PLANET_R);
        if (pl.x > 0.0)
            return false;

        float2 top = AtmoSphereHit(P, sun, ATMO_R);
        float len = max(top.y, 0.0);
        float ds = len / 4.0;

        float odR = 0.0, odM = 0.0, odO = 0.0;
        [unroll] for (int j = 0; j < 4; j++)
        {
            float h = max(length(P + sun * ((j + 0.5) * ds)) - PLANET_R, 0.0);
            odR += exp(-h / H_RAY) * ds;
            odM += exp(-h / H_MIE) * ds;
            odO += max(0.0, 1.0 - abs(h - 25.0) / 15.0) * ds;
        }

        tau = BETA_R * odR + BETA_M * 1.1 * odM + BETA_O * odO;
        return true;
    }

    // In-scattered radiance along a view ray of length tmax (km), plus the
    // transmittance of that segment.
    float3 AtmoInscatter(float3 p0, float3 rd, float tmax, int steps, float jitter,
                         float3 sun, float sunIntensity, out float3 transmittance)
    {
        float ds = tmax / steps;
        float odR = 0.0, odM = 0.0, odO = 0.0;
        float3 sumR = float3(0.0, 0.0, 0.0);
        float3 sumM = float3(0.0, 0.0, 0.0);

        [loop] for (int i = 0; i < steps; i++)
        {
            float t = (i + jitter) * ds;
            float3 P = p0 + rd * t;
            float h = max(length(P) - PLANET_R, 0.0);

            float dR = exp(-h / H_RAY) * ds;
            float dM = exp(-h / H_MIE) * ds;
            float dO = max(0.0, 1.0 - abs(h - 25.0) / 15.0) * ds;
            odR += dR; odM += dM; odO += dO;

            float3 tauL;
            if (AtmoLightDepth(P, sun, tauL))
            {
                float3 tau = BETA_R * odR + BETA_M * 1.1 * odM + BETA_O * odO + tauL;
                float3 att = exp(-tau);
                sumR += dR * att;
                sumM += dM * att;
            }
        }

        transmittance = exp(-(BETA_R * odR + BETA_M * 1.1 * odM + BETA_O * odO));

        float mu = dot(rd, sun);
        return sunIntensity * (sumR * BETA_R * PhaseRayleigh(mu) + sumM * BETA_M * PhaseMie(mu, 0.76));
    }

    // ------------------------------------------------------------------
    // Stars: procedural 3D hash grid, rotated with time of day.
    // ------------------------------------------------------------------
    float3 Stars(float3 rd)
    {
        float3 axis = normalize(float3(0.0, 0.45, 0.89));
        float cA = cos(star_angle);
        float sA = sin(star_angle);
        float3 v = rd * cA + cross(axis, rd) * sA + axis * dot(axis, rd) * (1.0 - cA);

        float3 p = v * 110.0;
        float3 cell = floor(p);
        uint3 h = pcg3d(asuint((int3)cell));

        float rnd = float(h.x) * (1.0 / 4294967295.0);
        if (rnd < 0.985)
            return float3(0.0, 0.0, 0.0);

        // Star position stays inside its own cell (offset 0.35..0.65, radius <= 0.35).
        float3 off = 0.35 + 0.3 * float3(float(h.y & 65535u), float(h.y >> 16u), float(h.z & 65535u)) / 65535.0;
        float d = length(p - (cell + off));

        float bright = float(h.z >> 16u) / 65535.0;
        float size = 0.2 + 0.15 * bright;
        float s = saturate(1.0 - d / size);
        s *= s;

        float temp = float((h.x >> 3u) & 255u) / 255.0;
        float3 col = lerp(float3(1.0, 0.75, 0.55), float3(0.65, 0.78, 1.0), temp);
        float twinkle = 0.85 + 0.15 * sin(g_flTime * 2.5 + bright * 40.0);

        return col * s * (0.4 + 2.6 * bright * bright) * twinkle * 3.0;
    }

    // ------------------------------------------------------------------
    // Sky for pixels with no geometry. Output is tone-mapped (display range).
    // ------------------------------------------------------------------
    float3 RenderSky(float3 p0, float3 rd, float jitter, int steps)
    {
        float2 pl = AtmoSphereHit(p0, rd, PLANET_R);
        float2 top = AtmoSphereHit(p0, rd, ATMO_R);
        bool hitsGround = pl.x > 0.0;
        float tmax = hitsGround ? pl.x : max(top.y, 0.01);

        float3 viewT;
        float3 ins = AtmoInscatter(p0, rd, tmax, steps, jitter, sun_dir, sky_sun_intensity, viewT);
        float3 hdr = ins;

        if (hitsGround)
        {
            // Fallback ground below the horizon (e.g. beyond the end of the terrain).
            hdr += ground_albedo * (sun_color * saturate(sun_dir.z) * 0.3183 + ambient_bottom) * viewT;
        }
        else
        {
            // Stars fade out as the sky brightens (twilight and daytime handled for free).
            float lum = dot(ins, float3(0.3333, 0.3333, 0.3333));
            float night = exp(-lum * sky_exposure * 25.0);

            float cs = dot(rd, sun_dir);
            float disk = smoothstep(sun_disk_cos, lerp(sun_disk_cos, 1.0, 0.3), cs);
            hdr += viewT * sky_sun_intensity * 6.0 * disk;

            float cm = dot(rd, moon_dir);
            float mdisk = smoothstep(moon_disk_cos, lerp(moon_disk_cos, 1.0, 0.3), cm);
            hdr += float3(0.8, 0.85, 0.95) * 1.2 * mdisk * viewT * lerp(0.15, 1.0, night);

            hdr += Stars(rd) * star_brightness * night * viewT * (1.0 - mdisk);
            hdr += float3(0.002, 0.004, 0.010) * night; // faint night glow
        }

        return 1.0 - exp(-hdr * sky_exposure);
    }

    // ------------------------------------------------------------------
    // Cloud helpers
    // ------------------------------------------------------------------
    float CloudHG(float cosTheta, float g)
    {
        float g2 = g * g;
        return (1.0 - g2) / (4.0 * PI_F * pow(max(1.0 + g2 - 2.0 * g * cosTheta, 0.001), 1.5));
    }

    // Dual-lobe phase (forward + weak backward), normalized so isotropic == 1.
    // 'c' shrinks the eccentricity for higher multiple-scattering octaves.
    float CloudDualPhase(float cosTheta, float c)
    {
        return 4.0 * PI_F * (0.7 * CloudHG(cosTheta, 0.6 * c) + 0.3 * CloudHG(cosTheta, -0.25 * c));
    }

    // Ray vs horizontal slab [h0, h1] (absolute Z). Returns (tNear, tFar), or
    // (-1,-1) on a miss. Handles camera below / inside / above and near-horizontal rays.
    float2 SlabInterval(float oz, float dz, float h0, float h1, float maxT)
    {
        if (abs(dz) < 0.0001)
        {
            return (oz >= h0 && oz <= h1) ? float2(0.0, maxT) : float2(-1.0, -1.0);
        }

        float ta = (h0 - oz) / dz;
        float tb = (h1 - oz) / dz;

        float tn = max(min(ta, tb), 0.0);
        float tf = min(max(ta, tb), maxT);

        return (tf > tn) ? float2(tn, tf) : float2(-1.0, -1.0);
    }

    // Light reaching a point inside a cloud: sun-ward light march, multi-scatter
    // approximation, powder term, plus height-graded ambient.
    float3 CloudLighting(float3 pos, float4 range, float4 prm, float4 nz,
                         float hFrac, float cosSun, float localDens, int lightSteps)
    {
        float thickness = max(range.y - range.x, 1.0);

        // Low sun means the light path crosses the slab at a shallow angle, so
        // stretch the steps to still reach the cloud edge.
        float sunElev = clamp(sun_dir.z, 0.2, 1.0);
        float baseStep = thickness * 0.08 / sunElev;

        float tau = 0.0;
        float dist = 0.0;
        [loop] for (int k = 0; k < 8; k++)
        {
            if (k >= lightSteps) break;
            float dl = baseStep * (1.0 + k); // steps grow with distance
            float3 lp = pos + sun_dir * (dist + 0.5 * dl);
            tau += SampleDensityLight(lp, range, prm, nz) * extinction * dl;
            dist += dl;
        }

        // Multiple-scattering approximation: three octaves, each with weaker
        // extinction, weaker contribution and a rounder phase function.
        float scatter = 0.0;
        float a = 1.0, b = 1.0, c = 1.0;
        [unroll] for (int n = 0; n < 3; n++)
        {
            scatter += b * CloudDualPhase(cosSun, c) * exp(-tau * a);
            a *= 0.5; b *= 0.5; c *= 0.5;
        }

        // Powder: dark edges on sun-facing sides. Fades out when looking toward
        // the sun (backlit), where it would wrongly darken the silver lining.
        float powder = 1.0 - exp(-localDens * extinction * 240.0);
        float powderWeight = saturate((1.0 - cosSun) * 0.5) * 0.7;
        float direct = scatter * lerp(1.0, powder, powderWeight);

        float3 ambient = lerp(ambient_bottom, ambient_top, hFrac) * lerp(0.5, 1.0, hFrac);

        return sun_color * direct + ambient;
    }

    // ------------------------------------------------------------------
    float4 MainPs(PixelInput i) : SV_Target0
    {
        float2 uv = i.vPositionSs.xy / g_vRenderTargetSize.xy;
        float4 color = colorBuffer.SampleLevel(g_sBilinearMirror, uv, 0);

        // API CHECK: GetWorldPosition on far-plane (sky) pixels.
        float3 worldPos = Depth::GetWorldPosition(i.vPositionSs.xy);

        float3 roWs = g_vCameraPositionWs;
        float3 rd = normalize(worldPos - roWs);
        float3 ro = roWs * INCH_TO_M; // meters

        // ---- Sky-pixel path: depth at the far plane == infinite distance ----
        float sceneDist = length(worldPos - roWs) * INCH_TO_M;
        bool isSky = sceneDist >= far_distance * 0.99;
        float maxT = isSky ? max_cloud_distance : min(sceneDist, max_cloud_distance);

        if (debug_mode > 2.5)
            return float4(isSky ? float3(1.0, 0.0, 1.0) : color.rgb * 0.5, 1.0);

        float jitter = InterleavedGradientNoise(i.vPositionSs.xy);

        // ---- Atmosphere frame ----
        float camAltKm = clamp((ro.z - ground_z) * 0.001, 0.0005, 80.0);
        float3 p0 = float3(0.0, 0.0, PLANET_R + camAltKm);
        int skySteps = clamp((int)sky_steps, 4, 32);
        int lightSteps = clamp((int)light_steps, 1, 8);

        // ---- Background: our sky for empty pixels, aerial perspective on geometry ----
        float3 bg = color.rgb;
        if (isSky)
        {
            if (sky_enabled > 0.5)
                bg = RenderSky(p0, rd, jitter, skySteps);
        }
        else if (aerial_strength > 0.001 && sceneDist > 100.0)
        {
            float3 Ta;
            float3 insA = AtmoInscatter(p0, rd, sceneDist * 0.001, max(skySteps / 2, 4), jitter, sun_dir, sky_sun_intensity, Ta);
            float3 insATM = 1.0 - exp(-insA * sky_exposure);
            bg = lerp(color.rgb, color.rgb * Ta + insATM, aerial_strength);
        }

        // ---- Per-layer march intervals ----
        float4 R[MAX_LAYERS];
        float4 P[MAX_LAYERS];
        float4 N[MAX_LAYERS];
        R[0] = layer0_range;  R[1] = layer1_range;  R[2] = layer2_range;
        P[0] = layer0_params; P[1] = layer1_params; P[2] = layer2_params;
        N[0] = layer0_noise;  N[1] = layer1_noise;  N[2] = layer2_noise;

        float2 iv[MAX_LAYERS];
        float3 dbg = float3(0.0, 0.0, 0.0);

        [unroll] for (int k = 0; k < MAX_LAYERS; k++)
        {
            bool valid = R[k].y > R[k].x && R[k].w > 0.0 && R[k].z > 0.0;
            iv[k] = valid
                ? SlabInterval(ro.z, rd.z, ground_z + R[k].x, ground_z + R[k].y, maxT)
                : float2(-1.0, -1.0);

            if (iv[k].y > iv[k].x)
                dbg[k] = saturate((iv[k].y - iv[k].x) / 4000.0) * 0.8 + 0.2;
        }

        if (debug_mode > 0.5 && debug_mode < 1.5)
            return float4(bg * 0.3 + dbg, 1.0);

        // ---- Sort layers by entry distance (invalid last) ----
        int order[MAX_LAYERS];
        order[0] = 0; order[1] = 1; order[2] = 2;
        float key[MAX_LAYERS];
        [unroll] for (int a = 0; a < MAX_LAYERS; a++)
            key[a] = (iv[a].y > iv[a].x) ? iv[a].x : 1000000000.0;

        // 3-element sorting network: (0,1) (1,2) (0,1)
        if (key[order[0]] > key[order[1]]) { int t = order[0]; order[0] = order[1]; order[1] = t; }
        if (key[order[1]] > key[order[2]]) { int t = order[1]; order[1] = order[2]; order[2] = t; }
        if (key[order[0]] > key[order[1]]) { int t = order[0]; order[0] = order[1]; order[1] = t; }

        // ---- March, front to back, one shared transmittance ----
        int steps = clamp((int)step_count, 1, MAX_STEPS);

        float transmittance = 1.0;
        float3 scatter = float3(0.0, 0.0, 0.0);
        float cosSun = dot(rd, sun_dir);

        // Transmittance-weighted mean distance of the cloud contribution,
        // used afterwards to apply aerial perspective to the clouds.
        float weightSum = 0.0;
        float distSum = 0.0;

        [loop] for (int s = 0; s < MAX_LAYERS; s++)
        {
            int layer = order[s];
            float2 t = iv[layer];
            if (t.y <= t.x) continue;

            float D = t.y - t.x;
            float thickness = R[layer].y - R[layer].x;

            // Uniform steps for rays that cross the slab; steps bunch up near
            // the camera for long near-horizontal rays (exponent 1 -> 2).
            float expo = lerp(1.0, 2.0, saturate(D / (thickness * 8.0)));

            [loop] for (int j = 0; j < MAX_STEPS; j++)
            {
                if (j >= steps) break;

                float u0 = (float)j / steps;
                float u1 = (float)(j + 1) / steps;
                float uS = ((float)j + jitter) / steps;

                float tS = t.x + D * pow(uS, expo);
                float dt = D * (pow(u1, expo) - pow(u0, expo));

                float3 pos = ro + rd * tS;
                float dens = SampleDensity(pos, R[layer], P[layer], N[layer]);

                // Fade toward the distance cap so the cutoff is invisible.
                dens *= 1.0 - smoothstep(0.6 * max_cloud_distance, max_cloud_distance, tS);

                if (dens > 0.001)
                {
                    float sigma = dens * extinction;
                    float stepT = exp(-sigma * dt);
                    float w = transmittance * (1.0 - stepT);

                    // Skip the (expensive) light march for negligible contributions.
                    if (w > 0.0005)
                    {
                        float hFrac = saturate((pos.z - ground_z - R[layer].x) / thickness);
                        float3 lighting = CloudLighting(pos, R[layer], P[layer], N[layer], hFrac, cosSun, dens, lightSteps);

                        scatter += w * lighting;
                        weightSum += w;
                        distSum += w * tS;
                    }

                    transmittance *= stepT;
                    if (transmittance < 0.01) break;
                }
            }

            if (transmittance < 0.01) break;
        }

        float alpha = 1.0 - transmittance;

        if (debug_mode > 1.5 && debug_mode < 2.5)
            return float4(alpha.xxx, 1.0);

        // ---- Cloud colour: tone-map, then aerial perspective at the cloud distance ----
        float3 cloudRad = 1.0 - exp(-scatter * cloud_exposure);

        if (alpha > 0.003 && weightSum > 0.0 && aerial_strength > 0.001)
        {
            float avgKm = max((distSum / weightSum) * 0.001, 0.01);
            float3 Tc;
            float3 insC = AtmoInscatter(p0, rd, avgKm, max(skySteps / 2, 4), jitter, sun_dir, sky_sun_intensity, Tc);
            float3 insCTM = 1.0 - exp(-insC * sky_exposure);
            cloudRad = lerp(cloudRad, cloudRad * Tc + alpha * insCTM, aerial_strength);
        }

        float3 finalColor = bg * transmittance + cloudRad;
        return float4(finalColor, 1.0);
    }
}
