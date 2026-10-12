using Sandbox;
using Sandbox.Rendering;
using System;
using System.Collections.Generic;

// ============================================================================
//  SkyCloudSystem  -  Phase 1 (flat slab clouds, multi-layer, any camera position)
//
//  Conventions
//    * s&box units are inches. The shader works in METERS, so everything that
//      crosses to the shader is converted here (1 unit = 0.0254 m).
//    * World Z is up. Layer altitudes are meters above GroundLevel.
//    * Layers must not overlap in altitude (the shader assumes disjoint slabs).
//
//  Every spot that depends on an s&box API I could not verify is marked
//  "API CHECK".
// ============================================================================

public enum CloudQuality
{
	Low,
	Medium,
	High,
	Ultra
}

public enum CloudDebugView
{
	Off = 0,
	LayerIntervals = 1, // R/G/B = layer 0/1/2 march interval thickness
	Density = 2         // accumulated opacity only
}

public sealed class CloudLayerSettings
{
	[Property] public bool Enabled { get; set; } = true;

	[Property, Range( 0, 20000 )] public float BottomMeters { get; set; } = 1500f;
	[Property, Range( 0, 20000 )] public float TopMeters { get; set; } = 3000f;

	[Property, Range( 0, 1 )] public float Coverage { get; set; } = 0.5f;
	[Property, Range( 0, 2 )] public float Density { get; set; } = 1f;

	/// <summary>Noise cycles per kilometer (placeholder noise; later maps to the baked texture period).</summary>
	[Property, Range( 0.05f, 10 )] public float NoiseScalePerKm { get; set; } = 1f;

	[Property, Range( 0, 360 )] public float WindDirectionDegrees { get; set; } = 0f;
	[Property, Range( 0, 100 )] public float WindSpeed { get; set; } = 5f; // m/s

	// Accumulated on the C# side so the shader never multiplies large time values.
	internal Vector2 WindOffset;
}

[Icon( "cloud" )]
public sealed class SkyCloudSystem : BasePostProcess<SkyCloudSystem>
{
	const float InchToMeter = 0.0254f;
	const int MaxLayers = 3;

	// ---- Scene links ------------------------------------------------------

	/// <summary>API CHECK: DirectionalLight and its LightColor property.</summary>
	[Property] public DirectionalLight Sun { get; set; }

	// ---- Quality / limits -------------------------------------------------

	[Property] public CloudQuality Quality { get; set; } = CloudQuality.High;
	[Property, Range( 5, 200 )] public float MaxCloudDistanceKm { get; set; } = 40f;

	// ---- World ------------------------------------------------------------

	/// <summary>World Z (in s&box units) that layer altitudes are measured from.</summary>
	[Property] public float GroundLevel { get; set; } = 0f;

	// ---- Placeholder lighting (replaced in Phase 3/4) ---------------------

	[Property] public Color SunColor { get; set; } = new Color( 1f, 0.95f, 0.85f );
	[Property] public Color AmbientColor { get; set; } = new Color( 0.35f, 0.45f, 0.65f );
	[Property, Range( 0, 10 )] public float SunIntensity { get; set; } = 1.5f;
	[Property, Range( 0.001f, 0.2f )] public float ExtinctionPerMeter { get; set; } = 0.03f;

	// ---- Layers -----------------------------------------------------------

	[Property]
	public List<CloudLayerSettings> Layers { get; set; } = new()
	{
		new CloudLayerSettings { BottomMeters = 1200, TopMeters = 2400, Coverage = 0.55f, NoiseScalePerKm = 1.5f },
		new CloudLayerSettings { BottomMeters = 3500, TopMeters = 5500, Coverage = 0.4f, NoiseScalePerKm = 0.8f },
	};

	// ---- Debug ------------------------------------------------------------

	[Property] public CloudDebugView DebugView { get; set; } = CloudDebugView.Off;

	// ---- Internals --------------------------------------------------------

	Material _material; // cached, created lazily

	static int StepsFor( CloudQuality q ) => q switch
	{
		CloudQuality.Low => 16,
		CloudQuality.Medium => 32,
		CloudQuality.High => 64,
		CloudQuality.Ultra => 96,
		_ => 64
	};

	protected override void OnUpdate()
	{
		base.OnUpdate();

		// Advance wind. The sample position is shifted by this offset, so the
		// clouds move WITH the wind direction when the offset moves AGAINST it.
		foreach ( var layer in Layers )
		{
			if ( layer is null ) continue;
			float rad = layer.WindDirectionDegrees * MathF.PI / 180f;
			var dir = new Vector2( MathF.Cos( rad ), MathF.Sin( rad ) );
			layer.WindOffset -= dir * layer.WindSpeed * Time.Delta;

			// Keep the offset bounded for float precision. Phase 2: wrap at the
			// baked noise period instead so the wrap is seamless.
			layer.WindOffset = new Vector2( layer.WindOffset.x % 100000f, layer.WindOffset.y % 100000f );
		}
	}

	public override void Render()
	{
		_material ??= Material.FromShader( "sky_clouds.shader" );

		// --- Sun ---
		// A directional light shines along its Forward vector, so the
		// direction TOWARD the sun is the negative.
		Vector3 sunDir = Sun is not null ? -Sun.WorldRotation.Forward : new Vector3( 0.3f, 0.2f, 0.8f ).Normal;
		Color sunCol = Sun is not null ? Sun.LightColor : SunColor;

		Attributes.Set( "sun_dir", sunDir );
		Attributes.Set( "sun_color", new Vector3( sunCol.r, sunCol.g, sunCol.b ) * SunIntensity );
		Attributes.Set( "ambient_color", new Vector3( AmbientColor.r, AmbientColor.g, AmbientColor.b ) );

		// --- World / limits (all in meters) ---
		Attributes.Set( "ground_z", GroundLevel * InchToMeter );
		Attributes.Set( "max_cloud_distance", MaxCloudDistanceKm * 1000f );
		Attributes.Set( "extinction", ExtinctionPerMeter );

		// API CHECK: how to get the main camera's far clip from inside a post process.
		// The shader uses this to decide "this pixel is sky" (depth at far plane).
		float zFar = Scene?.Camera?.ZFar ?? 10000f;
		Attributes.Set( "far_distance", zFar * InchToMeter );

		// --- Quality / debug ---
		Attributes.Set( "step_count", (float)StepsFor( Quality ) );
		Attributes.Set( "debug_mode", (float)(int)DebugView );

		// --- Layers: packed into two float4 per layer (avoids relying on array attributes) ---
		for ( int i = 0; i < MaxLayers; i++ )
		{
			CloudLayerSettings l = i < Layers.Count ? Layers[i] : null;
			bool active = l is not null && l.Enabled && l.TopMeters > l.BottomMeters;

			// range:  x = bottom (m), y = top (m), z = coverage, w = density
			Attributes.Set( $"layer{i}_range", active
				? new Vector4( l.BottomMeters, l.TopMeters, l.Coverage, l.Density )
				: new Vector4( 0, 0, 0, 0 ) );

			// params: x = noise frequency (1/m), y/z = wind offset (m), w = reserved
			Attributes.Set( $"layer{i}_params", active
				? new Vector4( l.NoiseScalePerKm / 1000f, l.WindOffset.x, l.WindOffset.y, 0 )
				: new Vector4( 1, 0, 0, 0 ) );
		}

		var shader = _material;
		var blit = BlitMode.WithBackbuffer( shader, Stage.AfterPostProcess, 200, false );
		Blit( blit, "sky_clouds" );
	}
}
