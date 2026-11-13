shader_type spatial;
render_mode cull_disabled;
// Close-up tree models. NoiseTerrain gives each surface of the tree mesh its own copy of this
// material, filled in from that surface's StandardMaterial3D (colour, texture, vertex colours,
// roughness, UV scale, alpha scissor), so your mesh keeps its look and still fades by distance
// with tree_fade.gdshaderinc, dissolving into the card version further out.

#include "tree_fade.gdshaderinc"
#include "tree_fresh.gdshaderinc"

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_vertex_color = true;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform float alpha_scissor = -1.0; // Below 0 = off.

varying flat float tint;
varying flat float thin;
varying flat float share;

void vertex() {
	vec3 base = MODEL_MATRIX[3].xyz;
	float m = tree_metric(base);
	thin = tree_thin(m, INSTANCE_CUSTOM.x) * tree_fresh(INSTANCE_CUSTOM.x);
	share = tree_model_share(m);
	tint = 0.75 + 0.5 * INSTANCE_CUSTOM.y;
	if (thin <= 0.0 || share <= 0.0) {
		VERTEX = vec3(0.0); // Hidden: collapse to a point so nothing is drawn.
	} else {
		VERTEX *= tree_grow(m) * tree_fade_scale(thin);
	}
}

void fragment() {
	if (tree_dither(FRAGCOORD.xy) >= share || tree_dither(FRAGCOORD.yx + 7.0) >= tree_fade_cover(thin)) {
		discard;
	}
	vec4 tex = texture(albedo_texture, UV * uv_scale + uv_offset);
	if (alpha_scissor >= 0.0 && tex.a * albedo_color.a < alpha_scissor) {
		discard;
	}
	vec3 base = albedo_color.rgb * tex.rgb;
	if (use_vertex_color) {
		base *= COLOR.rgb;
	}
	ALBEDO = tree_fade_colour(base * tint, thin);
	ROUGHNESS = roughness_value;
	SPECULAR = 0.1;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
