using Sandbox;
using System;

// ============================================================================
//  CloudNoiseBaker  -  Phase 2
//
//  Bakes tileable cloud noise on the CPU and uploads it as textures.
//
//    Shape   3D  RGBA8   R = Perlin-Worley (base form)
//                        G/B/A = Worley fBm at increasing frequency (erosion)
//    Detail  3D  RGBA8   R/G/B = Worley fBm at increasing frequency (wisps)
//    Weather 2D  RGBA8   R = coverage modulation, G = reserved (cloud type)
//
//  Every noise wraps on all axes with an integer period, so textures tile
//  without seams. Sample with a trilinear + WRAP sampler.
//
//  API CHECK: ImageFormat.RGBA8888, Texture.CreateVolume(...).WithData(byte[], int),
//  Texture.Create(w, h, format).WithData(...).
//  System.Threading.Tasks.Parallel is blocked by the s&box whitelist, so this
//  uses Sandbox.Utility.Parallel.For instead. Set UseParallel = false to bake
//  on a single thread if that wrapper ever causes trouble.
// ============================================================================

public static class CloudNoiseBaker
{
	// -USER: Could we make the calculation in parallel on the gpu instead? Not sure if its worth the data passing to the gpu instead of doing it in parallel on the cpu.
	public static bool UseParallel = true;

	// ------------------------------------------------------------------ hashing

	static uint Hash( int x, int y, int z, uint seed )
	{
		unchecked
		{
			uint h = (uint)x * 0x8da6b343u ^ (uint)y * 0xd8163841u ^ (uint)z * 0xcb1ab31fu ^ (seed + 1u) * 0x9e3779b9u;
			h ^= h >> 16; h *= 0x7feb352du;
			h ^= h >> 15; h *= 0x846ca68bu;
			h ^= h >> 16;
			return h;
		}
	}

	static int Wrap( int a, int n )
	{
		int m = a % n;
		return m < 0 ? m + n : m;
	}

	static float Lerp( float a, float b, float t ) => a + (b - a) * t;
	static float Fade( float t ) => t * t * t * (t * (t * 6f - 15f) + 10f);
	static float Saturate( float v ) => v < 0f ? 0f : (v > 1f ? 1f : v);
	static float Remap( float v, float a, float b, float c, float d ) => c + (v - a) / MathF.Max( b - a, 1e-4f ) * (d - c);
	static byte ToByte( float v ) => (byte)(Saturate( v ) * 255f + 0.5f);

	// ------------------------------------------------------------------ Worley

	// Inverted Worley (1 = at a feature point), wraps with 'period' cells.
	// One hash per cell supplies all three feature-point offsets (10 bits each).
	static float Worley( float x, float y, float z, int period, uint seed )
	{
		int ix = (int)MathF.Floor( x );
		int iy = (int)MathF.Floor( y );
		int iz = (int)MathF.Floor( z );
		float fx = x - ix, fy = y - iy, fz = z - iz;

		float minD2 = 8f;
		for ( int dz = -1; dz <= 1; dz++ )
			for ( int dy = -1; dy <= 1; dy++ )
				for ( int dx = -1; dx <= 1; dx++ )
				{
					uint h = Hash( Wrap( ix + dx, period ), Wrap( iy + dy, period ), Wrap( iz + dz, period ), seed );
					float px = dx + (h & 1023u) * (1f / 1023f) - fx;
					float py = dy + ((h >> 10) & 1023u) * (1f / 1023f) - fy;
					float pz = dz + ((h >> 20) & 1023u) * (1f / 1023f) - fz;
					float d2 = px * px + py * py + pz * pz;
					if ( d2 < minD2 ) minD2 = d2;
				}

		return 1f - Saturate( MathF.Sqrt( minD2 ) );
	}

	static readonly float[] FbmWeights = { 0.625f, 0.25f, 0.125f };

	// u,v,w in [0,1). baseFreq = cells across the texture at octave 0 (doubles per octave).
	static float WorleyFbm( float u, float v, float w, int baseFreq, int octaves, uint seed )
	{
		float sum = 0f, wsum = 0f;
		for ( int o = 0; o < octaves; o++ )
		{
			int f = baseFreq << o;
			sum += FbmWeights[o] * Worley( u * f, v * f, w * f, f, seed + (uint)o * 17u );
			wsum += FbmWeights[o];
		}
		return sum / wsum;
	}

	// ------------------------------------------------------------------ Perlin

	static float GradDot( int ix, int iy, int iz, int period, uint seed, float fx, float fy, float fz )
	{
		uint h = Hash( Wrap( ix, period ), Wrap( iy, period ), Wrap( iz, period ), seed );
		float gx = (h & 1023u) * (2f / 1023f) - 1f;
		float gy = ((h >> 10) & 1023u) * (2f / 1023f) - 1f;
		float gz = ((h >> 20) & 1023u) * (2f / 1023f) - 1f;
		return gx * fx + gy * fy + gz * fz;
	}

	static float Perlin( float x, float y, float z, int period, uint seed )
	{
		int ix = (int)MathF.Floor( x );
		int iy = (int)MathF.Floor( y );
		int iz = (int)MathF.Floor( z );
		float fx = x - ix, fy = y - iy, fz = z - iz;
		float ux = Fade( fx ), uy = Fade( fy ), uz = Fade( fz );

		float n000 = GradDot( ix, iy, iz, period, seed, fx, fy, fz );
		float n100 = GradDot( ix + 1, iy, iz, period, seed, fx - 1, fy, fz );
		float n010 = GradDot( ix, iy + 1, iz, period, seed, fx, fy - 1, fz );
		float n110 = GradDot( ix + 1, iy + 1, iz, period, seed, fx - 1, fy - 1, fz );
		float n001 = GradDot( ix, iy, iz + 1, period, seed, fx, fy, fz - 1 );
		float n101 = GradDot( ix + 1, iy, iz + 1, period, seed, fx - 1, fy, fz - 1 );
		float n011 = GradDot( ix, iy + 1, iz + 1, period, seed, fx, fy - 1, fz - 1 );
		float n111 = GradDot( ix + 1, iy + 1, iz + 1, period, seed, fx - 1, fy - 1, fz - 1 );

		return Lerp(
			Lerp( Lerp( n000, n100, ux ), Lerp( n010, n110, ux ), uy ),
			Lerp( Lerp( n001, n101, ux ), Lerp( n011, n111, ux ), uy ),
			uz );
	}

	// Returns roughly 0..1 (mean ~0.5).
	static float PerlinFbm( float u, float v, float w, int baseFreq, int octaves, uint seed )
	{
		float sum = 0f, amp = 0.5f, norm = 0f;
		for ( int o = 0; o < octaves; o++ )
		{
			int f = baseFreq << o;
			sum += amp * Perlin( u * f, v * f, w * f, f, seed + (uint)o * 31u );
			norm += amp;
			amp *= 0.5f;
		}
		return Saturate( 0.5f + 0.75f * (sum / norm) );
	}

	// ------------------------------------------------------------------ bake helpers

	static void ForSlices( int count, Action<int> body )
	{
		if ( UseParallel ) Sandbox.Utility.Parallel.For( 0, count, body );
		else for ( int i = 0; i < count; i++ ) body( i );
	}

	// ------------------------------------------------------------------ public API

	/// <summary>128 (High/Ultra) or 64 (Low/Medium) cubed.</summary>
	public static Texture BakeShape( int size )
	{
		var data = new byte[size * size * size * 4];

		ForSlices( size, z =>
		{
			float w = (z + 0.5f) / size;
			for ( int y = 0; y < size; y++ )
			{
				float v = (y + 0.5f) / size;
				for ( int x = 0; x < size; x++ )
				{
					float u = (x + 0.5f) / size;

					float g = WorleyFbm( u, v, w, 4, 3, 11u );
					float b = WorleyFbm( u, v, w, 8, 3, 23u );
					float a = WorleyFbm( u, v, w, 16, 3, 37u );
					float p = PerlinFbm( u, v, w, 4, 4, 5u );

					// Perlin-Worley: Perlin remapped by Worley (billowy base form).
					float r = Saturate( Remap( p, g - 1f, 1f, 0f, 1f ) );

					int idx = ((z * size + y) * size + x) * 4;
					data[idx + 0] = ToByte( r );
					data[idx + 1] = ToByte( g );
					data[idx + 2] = ToByte( b );
					data[idx + 3] = ToByte( a );
				}
			}
		} );

		return Texture.CreateVolume( size, size, size, ImageFormat.RGBA8888 )
			.WithName( "cloud_shape_noise" )
			.WithData( data, data.Length )
			.Finish();
	}

	/// <summary>32 (High/Ultra) or 16 (Low/Medium) cubed.</summary>
	public static Texture BakeDetail( int size )
	{
		var data = new byte[size * size * size * 4];

		ForSlices( size, z =>
		{
			float w = (z + 0.5f) / size;
			for ( int y = 0; y < size; y++ )
			{
				float v = (y + 0.5f) / size;
				for ( int x = 0; x < size; x++ )
				{
					float u = (x + 0.5f) / size;

					int idx = ((z * size + y) * size + x) * 4;
					data[idx + 0] = ToByte( WorleyFbm( u, v, w, 2, 3, 51u ) );
					data[idx + 1] = ToByte( WorleyFbm( u, v, w, 4, 3, 63u ) );
					data[idx + 2] = ToByte( WorleyFbm( u, v, w, 8, 2, 77u ) );
					data[idx + 3] = 255;
				}
			}
		} );

		return Texture.CreateVolume( size, size, size, ImageFormat.RGBA8888 )
			.WithName( "cloud_detail_noise" )
			.WithData( data, data.Length )
			.Finish();
	}

	/// <summary>Tileable 2D weather map. R = coverage modulation, G = reserved for cloud type.</summary>
	public static Texture BakeWeather( int size = 256 )
	{
		var data = new byte[size * size * 4];

		ForSlices( size, y =>
		{
			float v = (y + 0.5f) / size;
			for ( int x = 0; x < size; x++ )
			{
				float u = (x + 0.5f) / size;

				// Fixed z slice of a 3D Perlin: tileable in x/y.
				float cov = PerlinFbm( u, v, 0.5f, 4, 4, 71u );
				float typ = PerlinFbm( u, v, 0.5f, 6, 3, 83u );

				// Stretch contrast so the map actually opens and closes gaps.
				cov = Saturate( (cov - 0.5f) * 2.2f + 0.5f );

				int idx = (y * size + x) * 4;
				data[idx + 0] = ToByte( cov );
				data[idx + 1] = ToByte( typ );
				data[idx + 2] = 0;
				data[idx + 3] = 255;
			}
		} );

		return Texture.Create( size, size, ImageFormat.RGBA8888 )
			.WithName( "cloud_weather_map" )
			.WithData( data, data.Length )
			.Finish();
	}
}
