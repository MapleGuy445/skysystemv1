// ============================================================================
//  cloud_temporal_cs  -  Phase 5: temporal accumulation of the low-res clouds
//
//  Per low-res texel:
//    1. Reproject: where was this cloud last frame? Uses the cloud distance from
//       cloud_trace_cs (-1 = no cloud: direction-only, the sky is at infinity).
//    2. Clamp the history to the current frame's 3x3 neighborhood (mean +- 1.25
//       sigma, widened to include the current value) so stale colour from
//       disocclusion or cloud motion cannot linger as ghosting.
//    3. Blend: temporal_blend of history (default 0.9), less for clouds closer
//       than ~1 km, whose parallax changes quickly when flying through them.
//  Writes the resolved result into the history texture for the next frame
//  (ping-pong in C#); sky_clouds.shader upsamples the same texture.
//
//  Reprojection convention (verified by the Phase 5 spike):
//  ReprojectFromLastFrameSs returns a continuous screen position (pixel centers
//  at +0.5), so prevUv = prevSs.xy * g_vInvViewportSize.
// ============================================================================

MODES
{
    Default();
}

CS
{
    #include "postprocess/shared.hlsl"
    #include "common/classes/Depth.hlsl"
    #include "common_samplers.fxc"   // g_sBilinearClamp
    #include "cloud_common.hlsl"

    Texture2D<float4>   CloudCurrent  < Attribute("CloudCurrent"); > ;
    Texture2D<float>    CloudDepth    < Attribute("CloudDepth"); > ;
    Texture2D<float4>   CloudHistory  < Attribute("CloudHistory"); > ;
    RWTexture2D<float4> CloudResolved < Attribute("CloudResolved"); > ;

    float2 cloud_size     < Attribute("cloud_size"); > ;
    float  temporal_blend < Attribute("temporal_blend"); > ;  // history weight, e.g. 0.9
    float  has_history    < Attribute("has_history"); > ;     // 0 on the first frame / after a reset

    [numthreads(8, 8, 1)]
    void MainCs(uint3 id : SV_DispatchThreadID)
    {
        int2 size = int2(cloud_size);
        int2 px = int2(id.xy);
        if (px.x >= size.x || px.y >= size.y)
            return;

        float4 cur = CloudCurrent[px];

        if (has_history < 0.5)
        {
            CloudResolved[px] = cur;
            return;
        }

        // ---- Neighborhood statistics of the current frame ----
        float4 m1 = float4(0.0, 0.0, 0.0, 0.0);
        float4 m2 = float4(0.0, 0.0, 0.0, 0.0);
        [unroll] for (int y = -1; y <= 1; y++)
        {
            [unroll] for (int x = -1; x <= 1; x++)
            {
                float4 c = CloudCurrent[clamp(px + int2(x, y), int2(0, 0), size - 1)];
                m1 += c;
                m2 += c * c;
            }
        }
        m1 /= 9.0;
        m2 /= 9.0;
        float4 sigma = sqrt(max(m2 - m1 * m1, 0.0));
        float4 lo = min(m1 - 1.25 * sigma, cur);
        float4 hi = max(m1 + 1.25 * sigma, cur);

        // ---- Reproject ----
        float2 scale = g_vViewportSize / cloud_size;
        float2 fullPx = (float2(px) + 0.5) * scale; // texel center, same as cloud_trace_cs
        CloudRay r = MakeCloudRay(fullPx);

        float dist = CloudDepth[px];
        float3 prevSs = dist > 0.0
            ? ReprojectFromLastFrameSs(g_vCameraPositionWs + r.rd * (dist / INCH_TO_M), false)
            : ReprojectFromLastFrameSs(r.worldPos, true);
        float2 prevUv = prevSs.xy * g_vInvViewportSize;

        if (any(prevUv < 0.0) || any(prevUv > 1.0))
        {
            CloudResolved[px] = cur; // came from off screen: no history
            return;
        }

        float4 hist = CloudHistory.SampleLevel(g_sBilinearClamp, prevUv, 0);
        hist = clamp(hist, lo, hi);

        // Trust history less for clouds near the camera (fast parallax).
        float w = temporal_blend;
        if (dist > 0.0)
            w *= lerp(0.6, 1.0, saturate(dist / 1000.0));

        CloudResolved[px] = lerp(cur, hist, w);
    }
}
