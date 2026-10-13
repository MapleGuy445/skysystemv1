using Sandbox;
using Sandbox.Rendering;
using System;
using System.Collections.Generic;

// ============================================================================
//  SkyCloudSystem  -  Phase 3 (sky) + Phase 4 (cloud lighting)
//
//  Conventions
//    * s&box units are inches. Cloud math in the shader is METERS, atmosphere
//      math is KILOMETERS. Everything is converted here.
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
	Density = 2,        // accumulated cloud opacity only
	SkyMask = 3         // magenta = pixels treated as sky (no geometry)
}

public sealed class CloudLayerSettings
{
	[Property] public bool Enabled { get; set; } = true;

	[Property, Range( 0, 20000 )] public float BottomMeters { get; set; } = 1500f;
	[Property, Range( 0, 20000 )] public float TopMeters { get; set; } = 3000f;

	[Property, Range( 0, 1 )] public float Coverage { get; set; } = 0.5f;
	[Property, Range( 0, 2 )] public float Density { get; set; } = 1f;

	// ---- Vertical structure ----

	/// <summary>Density profile over each cloud's height. 0 = stratus (flat sheet), 0.5 = cumulus (rounded top), 1 = cumulonimbus (full column, flat top).</summary>
	[Property, Range( 0, 1 )] public float CloudType { get; set; } = 0.5f;

	/// <summary>
	/// How much cloud tops vary. 0 = every cloud fills the whole layer height (old behaviour).
	/// 1 = tops range from ~12% of the layer (small puffs) up to the layer top (towers).
	/// Bases always sit on the layer bottom. Use a tall layer (several km) for towering clouds.
	/// </summary>
	[Property, Range( 0, 1 )] public float HeightVariation { get; set; } = 0f;

	/// <summary>How much the tallest clouds spread out into an anvil near the layer top.</summary>
	[Property, Range( 0, 1 )] public float Anvil { get; set; } = 0f;

	// ---- Noise scales: "tiles per km" = how many times the texture repeats per kilometer ----

	/// <summary>Base cloud form. 0.12 = the shape texture repeats every ~8 km.</summary>
	[Property, Range( 0.01f, 2 )] public float ShapeTilesPerKm { get; set; } = 0.12f;

	/// <summary>Edge erosion. 2.5 = the detail texture repeats every 400 m.</summary>
	[Property, Range( 0.1f, 10 )] public float DetailTilesPerKm { get; set; } = 2.5f;

	/// <summary>Weather map. 0.02 = repeats every 50 km.</summary>
	[Property, Range( 0.002f, 0.5f )] public float WeatherTilesPerKm { get; set; } = 0.02f;

	/// <summary>How strongly the weather map pushes coverage up and down.</summary>
	[Property, Range( 0, 1 )] public float WeatherInfluence { get; set; } = 0.8f;

	/// <summary>How much the detail noise eats away the cloud edges.</summary>
	[Property, Range( 0, 1 )] public float DetailStrength { get; set; } = 0.6f;

	[Property, Range( 0, 360 )] public float WindDirectionDegrees { get; set; } = 0f;
	[Property, Range( 0, 100 )] public float WindSpeed { get; set; } = 5f; // m/s

	// Accumulated on the C# side so the shader never multiplies large time values.
	internal Vector2 WindOffset;
}

/// <summary>
/// GPU layout of one layer. Must match "struct CloudLayer" in cloud_density.hlsl
/// (four float4s, 64 bytes).
/// </summary>
struct CloudLayerGpu
{
	public Vector4 Range;  // x bottom (m), y top (m), z coverage, w density
	public Vector4 Params; // x shape freq (1/m), y/z wind offset (m), w detail strength
	public Vector4 Noise;  // x detail freq (1/m), y weather freq (1/m), z weather influence, w reserved
	public Vector4 Shape;  // x cloud type, y height variation, z anvil, w reserved
}

/// <summary>
/// CPU copy of the shader's atmosphere constants. Used to work out how the
/// atmosphere tints sunlight at the camera's altitude, so cloud lighting, scene
/// light colour and ambient all agree with the sky.
/// </summary>
static class AtmosphereCpu
{
	const double PlanetR = 6371.0;
	const double TopR = 6471.0;
	const double HRay = 8.0;
	const double HMie = 1.2;

	static readonly double[] BetaR = { 5.8e-3, 13.5e-3, 33.1e-3 };
	const double BetaMExt = 21e-3 * 1.1;
	static readonly double[] BetaO = { 0.65e-3, 1.881e-3, 0.085e-3 };

	/// <summary>Per-channel transmittance of sunlight at a given altitude (km) and sun elevation (sine of the angle).</summary>
	public static Vector3 SunTransmittance( double altKm, double sinElev )
	{
		double ce = Math.Sqrt( Math.Max( 0.0, 1.0 - sinElev * sinElev ) );
		double oz = PlanetR + altKm;

		// Ray origin (0, oz), direction (ce, sinElev) in the vertical plane.
		double b = oz * sinElev;
		double q2 = oz * oz - b * b;

		// Planet blocks the sun.
		if ( b < 0.0 && q2 < PlanetR * PlanetR )
			return Vector3.Zero;

		double tTop = -b + Math.Sqrt( Math.Max( TopR * TopR - q2, 0.0 ) );

		const int N = 32;
		double ds = tTop / N;
		double odR = 0, odM = 0, odO = 0;

		for ( int i = 0; i < N; i++ )
		{
			double t = (i + 0.5) * ds;
			double px = ce * t;
			double pz = oz + sinElev * t;
			double h = Math.Max( Math.Sqrt( px * px + pz * pz ) - PlanetR, 0.0 );

			odR += Math.Exp( -h / HRay ) * ds;
			odM += Math.Exp( -h / HMie ) * ds;
			odO += Math.Max( 0.0, 1.0 - Math.Abs( h - 25.0 ) / 15.0 ) * ds;
		}

		float r = (float)Math.Exp( -(BetaR[0] * odR + BetaMExt * odM + BetaO[0] * odO) );
		float g = (float)Math.Exp( -(BetaR[1] * odR + BetaMExt * odM + BetaO[1] * odO) );
		float bl = (float)Math.Exp( -(BetaR[2] * odR + BetaMExt * odM + BetaO[2] * odO) );
		return new Vector3( r, g, bl );
	}
}

[Icon( "cloud" )]
public sealed class SkyCloudSystem : BasePostProcess<SkyCloudSystem>
{
	const float InchToMeter = 0.0254f;
	// Layers go to the shader as one StructuredBuffer (CloudLayers) plus a count.
	// Must match MAX_LAYERS in sky_clouds.shader.
	const int MaxLayers = 8;

	// ---- Sun & time -------------------------------------------------------

	/// <summary>API CHECK: DirectionalLight. Its rotation is driven when DriveSun is on.</summary>
	[Property, Group( "Sun & Time" )] public DirectionalLight Sun { get; set; }

	/// <summary>API CHECK: AmbientLight and its Color property. Optional.</summary>
	[Property, Group( "Sun & Time" )] public AmbientLight Ambient { get; set; }

	/// <summary>On: this component moves the sun from TimeOfDay. Off: it reads the sun's current rotation.</summary>
	[Property, Group( "Sun & Time" )] public bool DriveSun { get; set; } = true;

	[Property, Group( "Sun & Time" ), Range( 0, 24 )] public float TimeOfDay { get; set; } = 10f;

	/// <summary>Real seconds for a full 24 h cycle. 0 = time stands still.</summary>
	[Property, Group( "Sun & Time" )] public float DayLengthSeconds { get; set; } = 0f;

	/// <summary>Compass direction (degrees, in the XY plane) the sun rises toward.</summary>
	[Property, Group( "Sun & Time" ), Range( 0, 360 )] public float SunAzimuth { get; set; } = 90f;

	/// <summary>Sun height at noon. 90 = straight overhead; lower = higher latitude / winter.</summary>
	[Property, Group( "Sun & Time" ), Range( 5, 90 )] public float MaxSunElevation { get; set; } = 70f;

	/// <summary>Write the atmosphere-tinted sun colour into the scene's DirectionalLight, and ambient into AmbientLight.</summary>
	[Property, Group( "Sun & Time" )] public bool SyncSceneLights { get; set; } = true;

	/// <summary>Multiplier on the colour written to the scene DirectionalLight.</summary>
	[Property, Group( "Sun & Time" ), Range( 0, 10 )] public float SceneSunIntensity { get; set; } = 1f;

	// ---- Sky --------------------------------------------------------------

	/// <summary>Off: keep the engine's own sky and only draw clouds.</summary>
	[Property, Group( "Sky" )] public bool ReplaceSky { get; set; } = true;

	[Property, Group( "Sky" )] public Color SunColor { get; set; } = new Color( 1f, 0.96f, 0.88f );
	[Property, Group( "Sky" ), Range( 1, 80 )] public float SkySunIntensity { get; set; } = 22f;
	[Property, Group( "Sky" ), Range( 0.2f, 8 )] public float SkyExposure { get; set; } = 2f;
	[Property, Group( "Sky" ), Range( 0, 1 )] public float AerialPerspective { get; set; } = 1f;
	[Property, Group( "Sky" )] public Color GroundAlbedo { get; set; } = new Color( 0.25f, 0.25f, 0.22f );
	[Property, Group( "Sky" ), Range( 0, 4 )] public float StarBrightness { get; set; } = 1f;
	[Property, Group( "Sky" ), Range( 0.1f, 3 )] public float SunDiskDegrees { get; set; } = 0.8f;
	[Property, Group( "Sky" ), Range( 0.1f, 5 )] public float MoonDiskDegrees { get; set; } = 1.2f;

	/// <summary>Below the horizon: how many degrees the horizon haze takes to fade into the (GroundAlbedo) ground. 90 = haze all the way down.</summary>
	[Property, Group( "Sky" ), Range( 0.5f, 90 )] public float HorizonFadeDegrees { get; set; } = 15f;

	// ---- Quality / limits -------------------------------------------------

	[Property, Group( "Quality" )] public CloudQuality Quality { get; set; } = CloudQuality.High;
	[Property, Group( "Quality" ), Range( 5, 200 )] public float MaxCloudDistanceKm { get; set; } = 40f;

	// ---- World ------------------------------------------------------------

	/// <summary>World Z (in s&box units) that layer altitudes are measured from.</summary>
	[Property, Group( "World" )] public float GroundLevel { get; set; } = 0f;

	// ---- Cloud lighting ---------------------------------------------------

	/// <summary>Strength of direct sunlight on clouds.</summary>
	[Property, Group( "Cloud Lighting" ), Range( 0, 10 )] public float SunIntensity { get; set; } = 1.5f;
	[Property, Group( "Cloud Lighting" ), Range( 0, 4 )] public float AmbientIntensity { get; set; } = 1f;
	[Property, Group( "Cloud Lighting" ), Range( 0.05f, 4 )] public float CloudExposure { get; set; } = 0.6f;
	[Property, Group( "Cloud Lighting" ), Range( 0.001f, 0.2f )] public float ExtinctionPerMeter { get; set; } = 0.015f;

	// ---- Layers -----------------------------------------------------------

	[Property, Group( "Layers" )]
	public List<CloudLayerSettings> Layers { get; set; } = new()
	{
		// Convective layer: flat bases at 1.2 km, mostly small cumulus, occasional towers with anvils up to 6.5 km.
		new CloudLayerSettings { BottomMeters = 1200, TopMeters = 6500, Coverage = 0.35f, ShapeTilesPerKm = 0.12f,
			CloudType = 0.6f, HeightVariation = 0.85f, Anvil = 0.5f },
		// Mid deck: thin altocumulus / altostratus above the towers.
		new CloudLayerSettings { BottomMeters = 7000, TopMeters = 7800, Coverage = 0.25f, ShapeTilesPerKm = 0.08f,
			CloudType = 0.25f },
	};

	// ---- Debug ------------------------------------------------------------

	[Property, Group( "Debug" )] public CloudDebugView DebugView { get; set; } = CloudDebugView.Off;

	// ---- Internals --------------------------------------------------------

	Material _material; // cached, created lazily

	GpuBuffer<CloudLayerGpu> _layerBuffer;
	readonly CloudLayerGpu[] _layerData = new CloudLayerGpu[MaxLayers];
	readonly List<CloudLayerSettings> _activeLayers = new();

	Texture _shapeNoise;
	Texture _detailNoise;
	Texture _weatherMap;
	int _bakedShapeSize;

	// Per-frame atmosphere state (computed in OnUpdate, consumed in Render)
	Vector3 _sunDir = new Vector3( 0.3f, 0.2f, 0.8f ).Normal;
	Vector3 _moonDir = new Vector3( -0.3f, -0.2f, -0.8f ).Normal;
	Vector3 _sunLight = Vector3.One;     // base colour * transmittance * SunIntensity (for clouds)
	Vector3 _ambientTop = new Vector3( 0.3f, 0.45f, 0.8f );
	Vector3 _ambientBottom = new Vector3( 0.1f, 0.12f, 0.15f );

	static int StepsFor( CloudQuality q ) => q switch
	{
		CloudQuality.Low => 16,
		CloudQuality.Medium => 32,
		CloudQuality.High => 64,
		CloudQuality.Ultra => 96,
		_ => 64
	};

	static int LightStepsFor( CloudQuality q ) => q switch
	{
		CloudQuality.Low => 3,
		CloudQuality.Medium => 4,
		CloudQuality.High => 6,
		CloudQuality.Ultra => 8,
		_ => 6
	};

	static int SkyStepsFor( CloudQuality q ) => q switch
	{
		CloudQuality.Low => 8,
		CloudQuality.Medium => 12,
		CloudQuality.High => 16,
		CloudQuality.Ultra => 24,
		_ => 16
	};

	static int ShapeSizeFor( CloudQuality q ) => q >= CloudQuality.High ? 128 : 64;
	static int DetailSizeFor( CloudQuality q ) => q >= CloudQuality.High ? 32 : 16;

	// ---- Small helpers ----------------------------------------------------

	static Vector3 Mul( Vector3 a, Vector3 b ) => new Vector3( a.x * b.x, a.y * b.y, a.z * b.z );
	static Vector3 Rgb( Color c ) => new Vector3( c.r, c.g, c.b );

	static float SmoothStep( float a, float b, float x )
	{
		float t = Math.Clamp( (x - a) / (b - a), 0f, 1f );
		return t * t * (3f - 2f * t);
	}

	// ---- Lifetime ---------------------------------------------------------

	protected override void OnDisabled()
	{
		base.OnDisabled();
		DisposeNoise();
		_layerBuffer?.Dispose();
		_layerBuffer = null;
	}

	void DisposeNoise()
	{
		_shapeNoise?.Dispose();
		_detailNoise?.Dispose();
		_weatherMap?.Dispose();
		_shapeNoise = _detailNoise = _weatherMap = null;
		_bakedShapeSize = 0;
	}

	/// <summary>
	/// Bakes on first use and again if the quality tier changes the texture size.
	/// Runs synchronously (one-time hitch; the time is logged).
	/// </summary>
	void EnsureNoise()
	{
		int shapeSize = ShapeSizeFor( Quality );
		if ( _shapeNoise is not null && _bakedShapeSize == shapeSize )
			return;

		float start = RealTime.Now;

		DisposeNoise();
		_shapeNoise = CloudNoiseBaker.BakeShape( shapeSize );
		_detailNoise = CloudNoiseBaker.BakeDetail( DetailSizeFor( Quality ) );
		_weatherMap = CloudNoiseBaker.BakeWeather( 256 );
		_bakedShapeSize = shapeSize;

		Log.Info( $"Cloud noise baked ({shapeSize}^3 shape) in {(RealTime.Now - start) * 1000f:0} ms" );
	}

	// ---- Sun / atmosphere state ------------------------------------------

	Vector3 SunDirectionFromTime()
	{
		// 6 h = sunrise, 12 h = noon, 18 h = sunset.
		float a = (TimeOfDay - 6f) / 12f * MathF.PI;
		float az = SunAzimuth * MathF.PI / 180f;
		float e = MaxSunElevation * MathF.PI / 180f;

		var h = new Vector3( MathF.Cos( az ), MathF.Sin( az ), 0f );  // rises toward this horizontal direction
		var p = new Vector3( -MathF.Sin( az ), MathF.Cos( az ), 0f ); // perpendicular: the arc leans this way

		return (h * MathF.Cos( a )
			+ p * (MathF.Sin( a ) * MathF.Cos( e ))
			+ new Vector3( 0f, 0f, MathF.Sin( a ) * MathF.Sin( e ) )).Normal;
	}

	// -USER: could we do this calculation gpu side? mostly the part where we calculate transmittance. Make it do it for all pixels on screen? Kinda stops us from passing ambient lighting to the other shader unless we just do it in the sky_clouds.shader
	void UpdateAtmosphereState()
	{
		// ---- Time and sun direction ----
		if ( DriveSun )
		{
			if ( DayLengthSeconds > 0.01f )
				TimeOfDay = (TimeOfDay + Time.Delta * 24f / DayLengthSeconds) % 24f;

			_sunDir = SunDirectionFromTime();

			// A directional light shines along its Forward, so look AWAY from the sun.
			// API CHECK: Rotation.LookAt( Vector3 )
			if ( Sun is not null )
				Sun.WorldRotation = Rotation.LookAt( -_sunDir );
		}
		else if ( Sun is not null )
		{
			_sunDir = -Sun.WorldRotation.Forward;
		}

		// Moon sits roughly opposite the sun, nudged so it is not exactly antipodal.
		_moonDir = (-_sunDir + new Vector3( 0.2f, 0.1f, 0.35f )).Normal;

		// ---- Camera altitude ----
		float camZ = Scene?.Camera?.WorldPosition.z ?? GroundLevel;
		double altKm = Math.Clamp( (camZ - GroundLevel) * InchToMeter * 0.001, 0.0005, 80.0 );

		// ---- Sunlight after passing through the atmosphere ----
		float e = _sunDir.z;
		Vector3 transmittance = AtmosphereCpu.SunTransmittance( altKm, e );
		Vector3 sunTinted = Mul( Rgb( SunColor ), transmittance );

		_sunLight = sunTinted * SunIntensity;

		// ---- Ambient: day/night + warm twilight ----
		float dayK = SmoothStep( -0.08f, 0.25f, e );
		float twilight = dayK * (1f - Math.Clamp( MathF.Abs( e ) / 0.25f, 0f, 1f ));

		var night = new Vector3( 0.012f, 0.018f, 0.04f );
		var skyBlue = new Vector3( 0.24f, 0.38f, 0.72f );

		Vector3 ambTop = night
			+ skyBlue * (dayK * (0.5f + 0.5f * Math.Clamp( e * 2f, 0f, 1f )))
			+ new Vector3( 0.22f, 0.10f, 0.06f ) * twilight;

		// Underside of clouds is lit by the ground: albedo * sunlight on the ground.
		Vector3 ambBottom = ambTop * 0.3f
			+ Mul( Rgb( GroundAlbedo ), sunTinted ) * (Math.Clamp( e, 0f, 1f ) * 0.35f);

		_ambientTop = ambTop * AmbientIntensity;
		_ambientBottom = ambBottom * AmbientIntensity;

		// ---- Push the result into the scene's own lighting ----
		// Note: below the horizon the sun light goes black (no moonlight yet).
		if ( SyncSceneLights )
		{
			if ( Sun is not null )
			{
				var c = sunTinted * SceneSunIntensity;
				Sun.LightColor = new Color( c.x, c.y, c.z );
			}

			if ( Ambient is not null )
			{
				// API CHECK: AmbientLight.Color
				Ambient.Color = new Color( _ambientTop.x, _ambientTop.y, _ambientTop.z );
			}
		}
	}

	// ---- Layer upload -----------------------------------------------------

	bool _warnedOverlap;

	/// <summary>
	/// Packs the enabled layers into the GPU buffer, sorted by altitude (lowest
	/// first). The shader relies on that order and on the slabs not overlapping,
	/// so a layer that overlaps the one below it is skipped (with a warning).
	/// Returns how many layers were uploaded.
	/// </summary>
	int UploadLayers()
	{
		_activeLayers.Clear();
		foreach ( var l in Layers )
		{
			if ( l is not null && l.Enabled && l.TopMeters > l.BottomMeters && l.Coverage > 0f && l.Density > 0f )
				_activeLayers.Add( l );
		}
		_activeLayers.Sort( ( a, b ) => a.BottomMeters.CompareTo( b.BottomMeters ) );

		int count = 0;
		float prevTop = float.MinValue;
		foreach ( var l in _activeLayers )
		{
			if ( count >= MaxLayers )
				break;

			if ( l.BottomMeters < prevTop )
			{
				if ( !_warnedOverlap )
				{
					Log.Warning( $"SkyCloudSystem: layer {l.BottomMeters}-{l.TopMeters} m overlaps the layer below it and is skipped. Layers must not overlap in altitude." );
					_warnedOverlap = true;
				}
				continue;
			}
			prevTop = l.TopMeters;

			_layerData[count++] = new CloudLayerGpu
			{
				Range = new Vector4( l.BottomMeters, l.TopMeters, l.Coverage, l.Density ),
				Params = new Vector4( l.ShapeTilesPerKm / 1000f, l.WindOffset.x, l.WindOffset.y, l.DetailStrength ),
				Noise = new Vector4( l.DetailTilesPerKm / 1000f, l.WeatherTilesPerKm / 1000f, l.WeatherInfluence, 0 ),
				Shape = new Vector4( l.CloudType, l.HeightVariation, l.Anvil, 0 ),
			};
		}

		// Unused slots are zeroed; the shader only reads the first 'count'.
		for ( int i = count; i < MaxLayers; i++ )
			_layerData[i] = default;

		// API CHECK: GpuBuffer<T> as a StructuredBuffer attribute in a post process blit.
		_layerBuffer ??= new GpuBuffer<CloudLayerGpu>( MaxLayers );
		_layerBuffer.SetData( _layerData );
		return count;
	}

	// ---- Update / render --------------------------------------------------

	protected override void OnUpdate()
	{
		base.OnUpdate();

		EnsureNoise();
		UpdateAtmosphereState();

		// Advance wind. The sample position is shifted by this offset, so the
		// clouds move WITH the wind direction when the offset moves AGAINST it.
		foreach ( var layer in Layers )
		{
			if ( layer is null ) continue;
			float rad = layer.WindDirectionDegrees * MathF.PI / 180f;
			var dir = new Vector2( MathF.Cos( rad ), MathF.Sin( rad ) );
			layer.WindOffset -= dir * layer.WindSpeed * Time.Delta;
		}
	}

	public override void Render()
	{
		// Nothing to draw until the noise exists (avoids a black/garbage frame).
		if ( _shapeNoise is null || _detailNoise is null || _weatherMap is null )
			return;

		_material ??= Material.FromShader( "sky_clouds.shader" );

		// --- Sun / moon ---
		Attributes.Set( "sun_dir", _sunDir );
		Attributes.Set( "sun_color", _sunLight );
		Attributes.Set( "ambient_top", _ambientTop );
		Attributes.Set( "ambient_bottom", _ambientBottom );
		Attributes.Set( "sun_disk_cos", MathF.Cos( SunDiskDegrees * MathF.PI / 180f ) );
		Attributes.Set( "moon_dir", _moonDir );
		Attributes.Set( "moon_disk_cos", MathF.Cos( MoonDiskDegrees * MathF.PI / 180f ) );

		// --- Sky ---
		Attributes.Set( "sky_enabled", ReplaceSky ? 1f : 0f );
		Attributes.Set( "sky_sun_intensity", SkySunIntensity );
		Attributes.Set( "sky_exposure", SkyExposure );
		Attributes.Set( "cloud_exposure", CloudExposure );
		Attributes.Set( "aerial_strength", AerialPerspective );
		Attributes.Set( "ground_albedo", Rgb( GroundAlbedo ) );
		Attributes.Set( "star_brightness", StarBrightness );
		Attributes.Set( "star_angle", TimeOfDay / 24f * MathF.PI * 2f );
		Attributes.Set( "horizon_fade", MathF.Sin( HorizonFadeDegrees * MathF.PI / 180f ) );

		// --- World / limits (all in meters) ---
		Attributes.Set( "ground_z", GroundLevel * InchToMeter );
		Attributes.Set( "max_cloud_distance", MaxCloudDistanceKm * 1000f );
		Attributes.Set( "extinction", ExtinctionPerMeter );

		// API CHECK: how to get the main camera's far clip from inside a post process.
		// -USER: pretty sure theres a g_ attribute in the shader code to access the near and far plane of the camera (g_flFarPlane).
		float zFar = Scene?.Camera?.ZFar ?? 10000f;
		Attributes.Set( "far_distance", zFar * InchToMeter );

		// --- Quality / debug ---
		Attributes.Set( "step_count", (float)StepsFor( Quality ) );
		Attributes.Set( "light_steps", (float)LightStepsFor( Quality ) );
		Attributes.Set( "sky_steps", (float)SkyStepsFor( Quality ) );
		Attributes.Set( "debug_mode", (float)(int)DebugView );

		// --- Baked noise ---
		// API CHECK: Attributes.Set( string, Texture ) for 2D and 3D textures.
		Attributes.Set( "ShapeNoise", _shapeNoise );
		Attributes.Set( "DetailNoise", _detailNoise );
		Attributes.Set( "WeatherMap", _weatherMap );

		// --- Layers: one structured buffer + count ---
		int layerCount = UploadLayers();
		Attributes.Set( "CloudLayers", _layerBuffer );
		Attributes.Set( "layer_count", (float)layerCount );

		var shader = _material;
		var blit = BlitMode.WithBackbuffer( shader, Stage.AfterPostProcess, 200, false );
		Blit( blit, "sky_clouds" );
	}
}
