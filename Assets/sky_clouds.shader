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
    // Shared attributes, atmosphere and cloud march (also used by the
    // cloud_trace_cs compute pass). All set by SkyCloudSystem.cs.
    // ------------------------------------------------------------------
    #include "cloud_common.hlsl"

    Texture2D colorBuffer < Attribute("ColorBuffer"); SrgbRead(true); > ;

    // Reduced-resolution clouds from cloud_trace_cs: rgb = cloud colour
    // (premultiplied, aerial perspective applied), a = transmittance.
    Texture2D CloudTex     < Attribute("CloudTex"); > ;
    float     cloud_lowres < Attribute("cloud_lowres"); > ;   // 1 = use CloudTex, 0 = march here at full res

    // Sky-view LUT from sky_lut_cs: rgb = HDR sky (no disk/moon/stars),
    // trans rgb = view transmittance. Indexed by SkyLutUv (cloud_common.hlsl).
    Texture2D SkyLut      < Attribute("SkyLut"); > ;
    Texture2D SkyLutTrans < Attribute("SkyLutTrans"); > ;
    SamplerState sSkyLut  < Filter( MIN_MAG_MIP_LINEAR ); AddressU( WRAP ); AddressV( CLAMP ); > ;

    // Night sky
    float star_density < Attribute("star_density"); > ;
    float star_size    < Attribute("star_size"); > ;    // multiplier on the ~1 px star radius
    float milky_way    < Attribute("milky_way"); > ;

    // Galactic frame, fixed to the stars (rotates with them). Macros because
    // the s&box HLSL parser rejects global static const float3. GAL_CENTER must
    // stay roughly perpendicular to GAL_NORMAL.
    #define GAL_NORMAL normalize(float3(0.35, -0.55, 0.76))
    #define GAL_CENTER normalize(float3(0.83, 0.55, 0.02))

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

    // Direction in the star frame: the sky turns with the time of day.
    float3 CelestialDir(float3 rd)
    {
        float3 axis = normalize(float3(0.0, 0.45, 0.89));
        float cA = cos(star_angle);
        float sA = sin(star_angle);
        return rd * cA + cross(axis, rd) * sA + axis * dot(axis, rd) * (1.0 - cA);
    }

    // Milky Way band weight (1 on the galactic plane) and core weight (toward
    // the galactic center, where the band is wider and warmer).
    float GalacticBand(float3 v, out float core)
    {
        float b = dot(v, GAL_NORMAL);
        core = pow(saturate(dot(v, GAL_CENTER) * 0.5 + 0.5), 6.0);
        float w = 0.10 + 0.10 * core;
        return exp(-(b * b) / (w * w));
    }

    // One layer of stars on a 3D hash grid with 'cells' cells per unit.
    //   prob    chance that a cell holds a star
    //   sizePx  star radius in PIXELS (times star_size). Real stars are points,
    //           so they are drawn about one pixel wide at any resolution or FOV;
    //           brightness alone tells them apart. (A fixed angular size made
    //           bright stars multi-pixel discs that tone-mapped to washed-out blobs.)
    //   glow    strength of a small soft halo, 3x the star radius (bright stars)
    float3 StarLayer(float3 v, float cells, float prob, float sizePx, float gain, float glow, float pixAng, uint seed)
    {
        float3 p = v * cells;
        float3 cell = floor(p);
        uint3 h = pcg3d(asuint((int3)cell) + seed);

        float rnd = float(h.x & 16777215u) / 16777215.0;
        if (rnd > prob)
            return float3(0.0, 0.0, 0.0);

        // Star stays inside its cell (offset 0.3..0.7) so the cell edge does not clip it.
        float3 off = 0.3 + 0.4 * float3(float(h.y & 65535u), float(h.y >> 16u), float(h.z & 65535u)) / 65535.0;
        float d = length(p - (cell + off)) / cells; // ~angular distance (radians)

        float bright = float(h.z >> 16u) / 65535.0;
        bright = bright * bright * bright; // many faint stars, few bright ones

        float r = max(pixAng * sizePx * star_size, 0.00001);
        float s = exp(-(d * d) / (r * r));
        s += glow * bright * exp(-(d * d) / (9.0 * r * r));

        float temp = float((h.x >> 24u) & 255u) / 255.0;
        float3 col = lerp(float3(1.0, 0.72, 0.5), float3(0.7, 0.8, 1.0), temp);
        float twinkle = 0.85 + 0.15 * sin(g_flTime * 2.5 + bright * 40.0 + temp * 17.0);

        return col * s * (0.15 + bright) * gain * twinkle;
    }

    // Milky Way: mottled glow from the baked cloud shape noise (3D, tileable),
    // dark dust lanes along the middle of the band, faint colored nebulae.
    float3 MilkyWay(float3 v, float band, float core)
    {
        float4 n1 = shapeNoise.SampleLevel(sCloudNoise, v * 0.9 + 0.31, 0);
        float4 n2 = shapeNoise.SampleLevel(sCloudNoise, v * 2.7 + 0.73, 0);

        float glow = band * (0.35 + 0.65 * n1.r) * (0.6 + 0.4 * n2.g);

        float b = dot(v, GAL_NORMAL);
        float lane = smoothstep(0.55, 0.8, n2.r) * exp(-(b * b) / 0.0025);
        float dust = saturate(lane * 0.85 + smoothstep(0.6, 0.85, n1.b) * band * 0.5);
        glow *= 1.0 - dust;

        float3 col = lerp(float3(0.6, 0.7, 1.0), float3(1.0, 0.86, 0.68), core);
        float3 mw = col * glow * (0.35 + 1.6 * core);

        float neb = smoothstep(0.62, 0.9, n2.a) * band * (1.0 - dust);
        mw += neb * lerp(float3(0.9, 0.25, 0.4), float3(0.3, 0.6, 0.9), n1.g) * 0.6;

        return mw * 0.06;
    }

    // Stars + Milky Way for a view direction (HDR, before night fade and transmittance).
    float3 NightSky(float3 rd, float pixAng)
    {
        float3 v = CelestialDir(rd);
        float core;
        float band = GalacticBand(v, core);

        // More stars toward the galactic plane.
        float dens = star_density * (0.7 + 1.5 * band);

        float3 stars = StarLayer(v, 200.0, 0.10 * dens, 0.55, 0.35, 0.0, pixAng, 0u)
                     + StarLayer(v, 90.0, 0.07 * dens, 0.65, 1.0, 0.0, pixAng, 7919u)
                     + StarLayer(v, 35.0, 0.05 * star_density, 0.8, 3.0, 0.12, pixAng, 104729u);

        return stars * star_brightness + MilkyWay(v, band, core) * milky_way;
    }

    // ------------------------------------------------------------------
    // Sky for pixels with no geometry, from the sky-view LUT plus the sharp
    // full-res parts (sun disk, moon, night sky). Output is tone-mapped.
    // ------------------------------------------------------------------
    float3 RenderSky(float3 rd, float camAltKm, float pixAng)
    {
        float2 luv = SkyLutUv(rd, SkyHorizonElevation(camAltKm));
        float3 hdr = SkyLut.SampleLevel(sSkyLut, luv, 0).rgb;

        if (GroundDistance(camAltKm, rd.z) < 0.0)
        {
            float3 viewT = SkyLutTrans.SampleLevel(sSkyLut, luv, 0).rgb;

            // Night sky fades out as the sky brightens (twilight and daytime handled for free).
            float lum = dot(hdr, float3(0.3333, 0.3333, 0.3333));
            float night = exp(-lum * sky_exposure * 25.0);

            float cs = dot(rd, sun_dir);
            float disk = smoothstep(sun_disk_cos, lerp(sun_disk_cos, 1.0, 0.3), cs);
            hdr += viewT * sky_sun_intensity * 6.0 * disk;

            float cm = dot(rd, moon_dir);
            float mdisk = smoothstep(moon_disk_cos, lerp(moon_disk_cos, 1.0, 0.3), cm);
            hdr += float3(0.8, 0.85, 0.95) * 1.2 * mdisk * viewT * lerp(0.15, 1.0, night);

            if (night > 0.002)
                hdr += NightSky(rd, pixAng) * night * viewT * (1.0 - mdisk);

            hdr += float3(0.002, 0.004, 0.010) * night; // faint night glow
        }

        return 1.0 - exp(-hdr * sky_exposure);
    }

    // ------------------------------------------------------------------
    float4 MainPs(PixelInput i) : SV_Target0
    {
        float2 uv = i.vPositionSs.xy / g_vRenderTargetSize.xy;
        float4 color = colorBuffer.SampleLevel(g_sBilinearMirror, uv, 0);

        CloudRay r = MakeCloudRay(i.vPositionSs.xy);

        // Angular size of this pixel (for star sizing). Taken before any branch
        // so the derivatives are valid.
        float pixAng = max(length(ddx(r.rd)), length(ddy(r.rd)));

        if (debug_mode > 2.5)
            return float4(r.isSky ? float3(1.0, 0.0, 1.0) : color.rgb * 0.5, 1.0);

        float jitter = InterleavedGradientNoise(i.vPositionSs.xy);

        // ---- Atmosphere frame ----
        float camAltKm = clamp((r.ro.z - ground_z) * 0.001, 0.0005, 80.0);
        float3 p0 = float3(0.0, 0.0, PLANET_R + camAltKm);
        int skySteps = clamp((int)sky_steps, 4, 32);

        // ---- Background: our sky for empty pixels, aerial perspective on geometry ----
        float3 bg = color.rgb;
        if (r.isSky)
        {
            if (sky_enabled > 0.5)
                bg = RenderSky(r.rd, camAltKm, pixAng);
        }
        else if (aerial_strength > 0.001 && r.sceneDist > 100.0)
        {
            float3 Ta;
            float3 insA = AtmoInscatter(p0, r.rd, r.sceneDist * 0.001, max(skySteps / 2, 4), jitter, sun_dir, sky_sun_intensity, Ta);
            float3 insATM = 1.0 - exp(-insA * sky_exposure);
            bg = lerp(color.rgb, color.rgb * Ta + insATM, aerial_strength);
        }

        if (debug_mode > 0.5 && debug_mode < 1.5)
            return float4(bg * 0.3 + CloudLayerIntervals(r), 1.0);

        // ---- Clouds: reduced-res trace (bilinear upsample) or full-res march ----
        // TODO Phase 5: depth-aware upsample (bilinear can leak at geometry edges).
        float4 clouds;
        if (cloud_lowres > 0.5)
            clouds = CloudTex.SampleLevel(g_sBilinearMirror, uv, 0);
        else
            clouds = MarchClouds(r, jitter);

        if (debug_mode > 1.5 && debug_mode < 2.5)
            return float4((1.0 - clouds.a).xxx, 1.0);

        return float4(bg * clouds.a + clouds.rgb, 1.0);
    }
}
