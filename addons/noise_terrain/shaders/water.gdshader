shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_never;
// One flat sheet at sea level that follows the camera. Shallow water is clear and
// turquoise, deep water dark blue, read from how far the ground is behind the surface.

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D wave_normal : repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec2 origin_wrap = vec2(0.0);
uniform vec3 shallow_color : source_color = vec3(0.10, 0.46, 0.46);
uniform vec3 deep_color : source_color = vec3(0.02, 0.11, 0.24);
uniform float clear_depth = 30.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float depth = texture(depth_texture, SCREEN_UV).r;
	// The two renderers store depth differently, so each gets its own conversion.
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 behind = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	behind.xyz /= behind.w;
	float through = max(VERTEX.z - behind.z, 0.0); // Metres of water the view passes through.
	float d = clamp(through / clear_depth, 0.0, 1.0);

	vec2 uv = world_pos.xz + origin_wrap;
	vec3 w1 = texture(wave_normal, uv / 32.0 + TIME * vec2(0.012, 0.007)).rgb * 2.0 - 1.0;
	vec3 w2 = texture(wave_normal, uv / 128.0 - TIME * vec2(0.006, 0.009)).rgb * 2.0 - 1.0;
	float ripple = 0.25 * smoothstep(6000.0, 100.0, length(VERTEX));
	vec3 n = normalize(vec3((w1.x + w2.x) * ripple, 1.0, (w1.y + w2.y) * ripple));

	ALBEDO = mix(shallow_color, deep_color, sqrt(d));
	ALPHA = mix(0.25, 0.97, smoothstep(0.0, 0.5, d));
	ROUGHNESS = 0.07;
	SPECULAR = 0.6;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
}
