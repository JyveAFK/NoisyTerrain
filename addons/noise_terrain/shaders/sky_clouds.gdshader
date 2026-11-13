shader_type sky;
// Fast cloud ceiling: a few steps through one flat slab of 2D noise, drawn in the sky
// pass (so only on pixels no terrain covers). No 3D textures, no compositor pass, no baking.
// It is a ceiling only: fine from below, fades out as the camera climbs to the base.

#include "clouds.gdshaderinc"

uniform vec3 zenith_color : source_color = vec3(0.13, 0.33, 0.72);
uniform vec3 horizon_color : source_color = vec3(0.74, 0.83, 0.92);
uniform vec3 ground_color : source_color = vec3(0.45, 0.5, 0.55);
uniform vec3 cloud_lit_color : source_color = vec3(1.0, 0.98, 0.95);
uniform vec3 cloud_shade_color : source_color = vec3(0.5, 0.56, 0.68);
uniform float cloud_far = 70000.0; // Clouds fade into haze by this distance.
uniform int cloud_steps : hint_range(4, 48) = 16;
uniform float cloud_extinction = 0.012;
uniform float cloud_dither : hint_range(0.0, 1.0) = 0.35;

vec3 base_sky(vec3 dir, vec3 sun, vec3 sun_color) {
	vec3 c = mix(horizon_color, zenith_color, pow(clamp(dir.y, 0.0, 1.0), 0.45));
	c = mix(c, ground_color, smoothstep(0.0, -0.25, dir.y));
	float d = max(dot(dir, sun), 0.0);
	c += sun_color * (pow(d, 1500.0) * 12.0 + pow(d, 12.0) * 0.12);
	return c;
}

// time is passed in: the Compatibility renderer only offers TIME inside sky() itself.
vec4 clouds(vec3 ro, vec3 rd, vec3 sun, vec3 sun_color, vec2 pixel, float time) {
	if (!clouds_enabled || rd.y < 0.004 || ro.y > cloud_base - 20.0) {
		return vec4(0.0);
	}
	float t0 = (cloud_base - ro.y) / rd.y;
	if (t0 > cloud_far) {
		return vec4(0.0);
	}
	float t1 = (cloud_base + cloud_thickness - ro.y) / rd.y;
	float dt = (t1 - t0) / float(cloud_steps);
	// A small per-pixel offset softens the layering from the low step count.
	float jitter = 0.5 + cloud_dither * (fract(sin(dot(pixel, vec2(12.9898, 78.233))) * 43758.5453) - 0.5);
	vec2 sun_step = normalize(sun.xz + vec2(0.0001)) * cloud_scale * 0.035;
	float transmit = 1.0;
	vec3 colour = vec3(0.0);
	for (int i = 0; i < cloud_steps; i++) {
		float h01 = (float(i) + jitter) / float(cloud_steps);
		vec3 p = ro + rd * (t0 + (float(i) + jitter) * dt);
		vec2 d = cloud_density(p.xz, h01, time);
		if (d.x > 0.01) {
			// Grey bellies and bright edges, plus one extra sample towards the sun so the
			// sunward side of each cloud is lit and the far side shaded.
			float sunward = cloud_density(p.xz + sun_step, h01, time).y;
			float light = clamp(1.0 - d.y * 0.85 + (d.y - sunward) * 1.5, 0.0, 1.0) * mix(0.55, 1.0, h01);
			vec3 c = mix(cloud_shade_color, cloud_lit_color * min(sun_color, vec3(1.0)), light);
			float a = 1.0 - exp(-d.x * dt * cloud_extinction);
			colour += transmit * a * c;
			transmit *= 1.0 - a;
			if (transmit < 0.02) {
				break;
			}
		}
	}
	float alpha = 1.0 - transmit;
	if (alpha < 0.001) {
		return vec4(0.0);
	}
	colour /= alpha;
	colour = mix(colour, horizon_color, 1.0 - exp(-t0 / (cloud_far * 0.4))); // Distant clouds sink into the haze.
	alpha *= smoothstep(cloud_far, cloud_far * 0.6, t0);
	alpha *= smoothstep(cloud_base - 20.0, cloud_base - 400.0, ro.y); // Fade as the camera reaches the base.
	return vec4(colour, alpha);
}

void sky() {
	vec3 sun = LIGHT0_ENABLED ? LIGHT0_DIRECTION : vec3(0.3, 0.8, 0.3);
	vec3 sun_color = LIGHT0_ENABLED ? LIGHT0_COLOR * min(LIGHT0_ENERGY, 1.5) : vec3(1.0);
	vec3 sky_color = base_sky(EYEDIR, sun, sun_color);
	if (AT_CUBEMAP_PASS) {
		COLOR = sky_color; // Ambient light does not need the clouds.
	} else {
		vec4 c = clouds(POSITION + vec3(world_origin.x, 0.0, world_origin.y), EYEDIR, sun, sun_color, FRAGCOORD.xy, TIME);
		COLOR = mix(sky_color, c.rgb, c.a);
	}
}
