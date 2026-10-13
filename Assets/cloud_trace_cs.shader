// ============================================================================
//  cloud_trace_cs  -  Phase 5: reduced-resolution cloud march
//
//  One thread per low-res texel. Runs the same MarchClouds() as the full-res
//  path (cloud_common.hlsl) for the full-res pixel at the texel's center and
//  writes rgb = cloud colour (premultiplied, aerial perspective applied),
//  a = transmittance. sky_clouds.shader composites it with bg * a + rgb.
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

    RWTexture2D<float4> CloudOut < Attribute("CloudOut"); > ;
    float2 cloud_size < Attribute("cloud_size"); > ;   // low-res target size (pixels)

    [numthreads(8, 8, 1)]
    void MainCs(uint3 id : SV_DispatchThreadID)
    {
        if (id.x >= (uint)cloud_size.x || id.y >= (uint)cloud_size.y)
            return;

        // Full-res pixel at this texel's center. Sample the depth at an actual
        // full-res pixel center so the sky/geometry decision uses one real
        // depth value (depth-aware upsampling handles edges later).
        float2 scale = g_vViewportSize / cloud_size;
        float2 fullPx = floor((float2(id.xy) + 0.5) * scale) + 0.5;

        CloudRay r = MakeCloudRay(fullPx);
        float jitter = InterleavedGradientNoise(float2(id.xy));

        CloudOut[id.xy] = MarchClouds(r, jitter);
    }
}
