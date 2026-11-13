// Shared by the sky (to draw the clouds) and the terrain (to draw their shadows),
// so the shadows on the ground always line up with the clouds above.

uniform bool clouds_enabled = true;
uniform sampler2D cloud_noise : repeat_enable, filter_linear_mipmap;
uniform float cloud_scale = 12000.0; // Metres across one tile of the noise.
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.36;
uniform float cloud_softness : hint_range(0.01, 0.5) = 0.14;
uniform float cloud_wisp : hint_range(0.0, 1.0) = 0.6;
uniform float cloud_base = 3400.0;
uniform float cloud_thickness = 500.0;
uniform vec2 cloud_wind = vec2(8.0, 3.0); // Metres per second.
uniform vec2 world_origin = vec2(0.0); // Floating origin offset (x, z).

float cloud_field(vec2 xz, float time) {
	vec2 uv = (xz + cloud_wind * time) / cloud_scale;
	float weather = texture(cloud_noise, uv * 0.11 + 0.37).r; // Big clear and cloudy regions.
	float a = texture(cloud_noise, uv).r;
	float b = texture(cloud_noise, uv * 3.3 + 0.19).r;
	return a * 0.8 + b * 0.2 + (weather - 0.5) * 0.5;
}

// h01: 0 at the cloud base, 1 at the top.
// Returns x = density (0 to 1), y = how deep inside the cloud this point is (0 edge, 1 core).
vec2 cloud_density(vec2 xz, float h01, float time) {
	float f = cloud_field(xz, time);
	// Billows: two slices of the same 2D noise blended by height stand in for 3D noise,
	// so each cloud changes shape as it rises instead of being a straight column.
	float layer = h01 * 3.0;
	vec2 uv = (xz + cloud_wind * time * 1.4) / (cloud_scale * 0.22) + f * 0.5 * cloud_wisp;
	float n0 = texture(cloud_noise, uv + floor(layer) * 0.37).r;
	float n1 = texture(cloud_noise, uv + (floor(layer) + 1.0) * 0.37).r;
	float billow = mix(n0, n1, smoothstep(0.0, 1.0, fract(layer)));
	// Widest just above the flat base, narrowing to a rounded top.
	float threshold = 1.0 - cloud_coverage + h01 * h01 * 0.32 + (billow - 0.5) * 0.3 * cloud_wisp;
	float density = smoothstep(threshold, threshold + cloud_softness, f) * smoothstep(0.0, 0.07, h01);
	return vec2(density, clamp((f - threshold) / 0.14, 0.0, 1.0));
}

// How much cloud sits between a world position and the sun (0 clear, 1 full shadow).
float cloud_shadow_at(vec3 world, vec3 to_sun, float time) {
	float rise = cloud_base + cloud_thickness * 0.3 - world.y;
	if (rise <= 0.0 || !clouds_enabled) {
		return 0.0;
	}
	vec3 p = world + to_sun * (rise / max(to_sun.y, 0.08));
	float threshold = 1.0 - cloud_coverage - 0.03;
	return smoothstep(threshold, threshold + cloud_softness * 0.7, cloud_field(p.xz, time));
}
