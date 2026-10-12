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
    // Inputs (all distances in METERS, set by SkyCloudSystem.cs)
    // ------------------------------------------------------------------
    Texture2D colorBuffer < Attribute("ColorBuffer"); SrgbRead(true); > ;

    float3 sun_dir        < Attribute("sun_dir"); > ;        // direction TOWARD the sun
    float3 sun_color      < Attribute("sun_color"); > ;
    float3 ambient_color  < Attribute("ambient_color"); > ;

    float ground_z           < Attribute("ground_z"); > ;
    float max_cloud_distance < Attribute("max_cloud_distance"); > ;
    float far_distance       < Attribute("far_distance"); > ;
    float extinction         < Attribute("extinction"); > ;
    float step_count         < Attribute("step_count"); > ;
    float debug_mode         < Attribute("debug_mode"); > ;

    // x = bottom, y = top, z = coverage, w = density
    float4 layer0_range  < Attribute("layer0_range"); > ;
    float4 layer1_range  < Attribute("layer1_range"); > ;
    float4 layer2_range  < Attribute("layer2_range"); > ;
    // x = noise freq (1/m), y/z = wind offset (m)
    float4 layer0_params < Attribute("layer0_params"); > ;
    float4 layer1_params < Attribute("layer1_params"); > ;
    float4 layer2_params < Attribute("layer2_params"); > ;

    static const float INCH_TO_M = 0.0254;
    static const int   MAX_LAYERS = 3;
    static const int   MAX_STEPS  = 128;
    static const float PI_F = 3.14159265;

    // ------------------------------------------------------------------
    // PLACEHOLDER NOISE (Phase 2 replaces this with baked 3D textures).
    // Integer PCG hash: stable across GPUs and at large coordinates.
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

    float Hash1(int3 p)
    {
        return float(pcg3d(asuint(p)).x) * (1.0 / 4294967295.0);
    }

    float ValueNoise3D(float3 p)
    {
        float3 ip = floor(p);
        float3 f  = frac(p);
        float3 u  = f * f * (3.0 - 2.0 * f);
        int3 i0 = (int3)ip;

        float n000 = Hash1(i0 + int3(0, 0, 0));
        float n100 = Hash1(i0 + int3(1, 0, 0));
        float n010 = Hash1(i0 + int3(0, 1, 0));
        float n110 = Hash1(i0 + int3(1, 1, 0));
        float n001 = Hash1(i0 + int3(0, 0, 1));
        float n101 = Hash1(i0 + int3(1, 0, 1));
        float n011 = Hash1(i0 + int3(0, 1, 1));
        float n111 = Hash1(i0 + int3(1, 1, 1));

        return lerp(lerp(lerp(n000, n100, u.x), lerp(n010, n110, u.x), u.y),
                    lerp(lerp(n001, n101, u.x), lerp(n011, n111, u.x), u.y), u.z);
    }

    float Fbm3(float3 p)
    {
        float v = 0.0, a = 0.5;
        [unroll] for (int o = 0; o < 3; o++)
        {
            v += a * ValueNoise3D(p);
            p *= 2.02;
            a *= 0.5;
        }
        return v / 0.875; // normalize to ~0..1
    }

    // ------------------------------------------------------------------
    // Geometry
    // ------------------------------------------------------------------

    // Ray vs horizontal slab [h0, h1] (absolute Z). Returns (tNear, tFar), or
    // (-1,-1) if the ray misses within maxT. Handles camera below / inside /
    // above the slab and near-horizontal rays (no division by ~0).
    float2 SlabInterval(float oz, float dz, float h0, float h1, float maxT)
    {
        if (abs(dz) < 1e-4)
        {
            return (oz >= h0 && oz <= h1) ? float2(0.0, maxT) : float2(-1.0, -1.0);
        }

        float ta = (h0 - oz) / dz;
        float tb = (h1 - oz) / dz;

        float tn = max(min(ta, tb), 0.0);
        float tf = min(max(ta, tb), maxT);

        return (tf > tn) ? float2(tn, tf) : float2(-1.0, -1.0);
    }

    // ------------------------------------------------------------------
    // Cloud density for one layer at a world position (meters)
    // ------------------------------------------------------------------
    float SampleDensity(float3 pos, float4 range, float4 prm)
    {
        float h = (pos.z - ground_z - range.x) / max(range.y - range.x, 1e-3);

        // Height gradient: soft bottom, rounded top (cumulus-like).
        float grad = smoothstep(0.0, 0.15, h) * (1.0 - smoothstep(0.5, 1.0, h));

        float3 p = float3(pos.xy + prm.yz, pos.z) * prm.x;
        float n = Fbm3(p);

        float cov = range.z;
        float d = saturate((n - (1.0 - cov)) / max(cov, 1e-3));

        return d * grad * range.w;
    }

    // ------------------------------------------------------------------
    // Lighting helpers
    // ------------------------------------------------------------------

    // Dual-lobe phase, normalized so isotropic scattering == 1.
    float CloudPhase(float cosTheta)
    {
        return 4.0 * PI_F * (0.7 * HenyeyGreenstein(cosTheta, 0.5) + 0.3 * HenyeyGreenstein(cosTheta, -0.3));
    }

    // Interleaved gradient noise (cheap per-pixel jitter; Phase 5 swaps in blue noise + frame index).
    float InterleavedGradientNoise(float2 px)
    {
        return frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
    }

    // ------------------------------------------------------------------
    float4 MainPs(PixelInput i) : SV_Target0
    {
        float2 uv = i.vPositionSs.xy / g_vRenderTargetSize.xy;
        float4 color = colorBuffer.SampleLevel(g_sBilinearMirror, uv, 0);

        // API CHECK: GetWorldPosition on far-plane (sky) pixels. If it returns
        // garbage there, switch to a depth read and build the ray from the
        // inverse view-projection instead.
        float3 worldPos = Depth::GetWorldPosition(i.vPositionSs.xy);

        float3 roWs = g_vCameraPositionWs;
        float3 rd = normalize(worldPos - roWs);
        float3 ro = roWs * INCH_TO_M; // meters

        // ---- Sky-pixel path: depth at the far plane == infinite distance ----
        float sceneDist = length(worldPos - roWs) * INCH_TO_M;
        bool isSky = sceneDist >= far_distance * 0.99;
        float maxT = isSky ? max_cloud_distance : min(sceneDist, max_cloud_distance);

        // ---- Per-layer march intervals ----
        float4 R[MAX_LAYERS];
        float4 P[MAX_LAYERS];
        R[0] = layer0_range;  R[1] = layer1_range;  R[2] = layer2_range;
        P[0] = layer0_params; P[1] = layer1_params; P[2] = layer2_params;

        float2 iv[MAX_LAYERS];
        float3 dbg = float3(0, 0, 0);

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
            return float4(color.rgb * 0.3 + dbg, 1.0);

        // ---- Sort layers by entry distance (invalid last) ----
        int order[MAX_LAYERS] = { 0, 1, 2 };
        float key[MAX_LAYERS];
        [unroll] for (int a = 0; a < MAX_LAYERS; a++)
            key[a] = (iv[a].y > iv[a].x) ? iv[a].x : 1e30;

        // 3-element sorting network: (0,1) (1,2) (0,1)
        if (key[order[0]] > key[order[1]]) { int t = order[0]; order[0] = order[1]; order[1] = t; }
        if (key[order[1]] > key[order[2]]) { int t = order[1]; order[1] = order[2]; order[2] = t; }
        if (key[order[0]] > key[order[1]]) { int t = order[0]; order[0] = order[1]; order[1] = t; }

        // ---- March, front to back, one shared transmittance ----
        float jitter = InterleavedGradientNoise(i.vPositionSs.xy);
        int steps = clamp((int)step_count, 1, MAX_STEPS);

        float transmittance = 1.0;
        float3 scatter = float3(0, 0, 0);
        float cosSun = dot(rd, sun_dir);
        float phase = CloudPhase(cosSun);

        [loop] for (int s = 0; s < MAX_LAYERS; s++)
        {
            int layer = order[s];
            float2 t = iv[layer];
            if (t.y <= t.x) continue;

            float D = t.y - t.x;
            float thickness = R[layer].y - R[layer].x;

            // Steps are uniform for rays that cross the slab, and bunch up near
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
                float dens = SampleDensity(pos, R[layer], P[layer]);

                // Fade toward the distance cap so the cutoff is invisible.
                dens *= 1.0 - smoothstep(0.6 * max_cloud_distance, max_cloud_distance, tS);

                if (dens > 0.001)
                {
                    float sigma = dens * extinction;
                    float stepT = exp(-sigma * dt);

                    // Placeholder lighting: bright tops, dark bases (Phase 4 replaces with a light march).
                    float hFrac = saturate((pos.z - ground_z - R[layer].x) / thickness);
                    float lit = lerp(0.3, 1.0, hFrac);
                    float3 light = sun_color * lit * (0.4 + 0.6 * phase) + ambient_color * lerp(0.6, 1.0, hFrac);

                    scatter += transmittance * (1.0 - stepT) * light;
                    transmittance *= stepT;

                    if (transmittance < 0.01) break;
                }
            }

            if (transmittance < 0.01) break;
        }

        if (debug_mode > 1.5)
            return float4((1.0 - transmittance).xxx, 1.0);

        float3 finalColor = color.rgb * transmittance + scatter;
        return float4(finalColor, 1.0);
    }
}
