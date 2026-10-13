// ============================================================================
//  cloud_trace_cs  -  Phase 5: reduced-resolution cloud march
//
//  One thread per low-res texel. Runs the same MarchClouds() as the full-res
//  path (cloud_common.hlsl) for the full-res pixel at the texel's center and
//  writes:
//    CloudOut       rgb = cloud colour (premultiplied, aerial perspective applied),
//                   a = transmittance
//    CloudDepthOut  transmittance-weighted cloud distance in meters (-1 = none),
//                   used by cloud_temporal_cs to reproject the history.
//
//  Jitter: blue noise (engine textures/dev/blue_noise_256) offset by the frame
//  index along the golden ratio, so successive frames sample evenly spread
//  step offsets that the temporal pass integrates.
//
//  Include pattern copied from the engine's postprocess_standard_dof_cs.shader
//  (system/common alone leave Depth.hlsl's RemapValClamped undefined).
// ============================================================================

MODES
{
    Default();
}

CS
{
    #include "postprocess/shared.hlsl"
    #include "common/classes/Depth.hlsl"
    #include "cloud_common.hlsl"

    RWTexture2D<float4> CloudOut      < Attribute("CloudOut"); > ;
    RWTexture2D<float>  CloudDepthOut < Attribute("CloudDepthOut"); > ;
    Texture2D<float4>   BlueNoise     < Attribute("BlueNoise"); > ;

    float2 cloud_size  < Attribute("cloud_size"); > ;   // low-res target size (pixels)
    float  frame_index < Attribute("frame_index"); > ;  // 0 when temporal accumulation is off
    float  jitter_mode < Attribute("jitter_mode"); > ;  // see MainCs

    [numthreads(8, 8, 1)]
    void MainCs(uint3 id : SV_DispatchThreadID)
    {
        if (id.x >= (uint)cloud_size.x || id.y >= (uint)cloud_size.y)
            return;

        // Full-res screen position of this texel's exact center (continuous,
        // pixel centers at +0.5). It must match what the blit's bilinear upsample
        // and the temporal pass assume: snapping it to a full-res pixel center
        // shifted the result by a quarter texel, which the temporal pass then
        // re-applied every frame (drifting fringes on cloud edges, moving stripes).
        float2 scale = g_vViewportSize / cloud_size;
        float2 fullPx = (float2(id.xy) + 0.5) * scale;

        CloudRay r = MakeCloudRay(fullPx);

        // jitter_mode 0: interleaved gradient noise (the pre-temporal look; used
        //                 when temporal is off),
        //             1: engine blue noise + golden-ratio frame offset,
        //             2: IGN with a per-frame pixel offset (Jimenez' TAA variant),
        //                a texture-free fallback if the blue noise misbehaves.
        float jitter;
        if (jitter_mode > 1.5)
        {
            float2 p = float2(id.xy) + 5.588238 * fmod(frame_index, 64.0);
            jitter = InterleavedGradientNoise(p);
        }
        else if (jitter_mode > 0.5)
        {
            uint bnW, bnH;
            BlueNoise.GetDimensions(bnW, bnH);
            float bn = BlueNoise[id.xy % uint2(max(bnW, 1u), max(bnH, 1u))].r;
            jitter = frac(bn + frame_index * 0.61803398875);
        }
        else
        {
            jitter = InterleavedGradientNoise(float2(id.xy));
        }

        float cloudDist;
        CloudOut[id.xy] = MarchClouds(r, jitter, cloudDist);
        CloudDepthOut[id.xy] = cloudDist;
    }
}
