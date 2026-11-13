shader_type spatial;
render_mode cull_disabled, world_vertex_coords;
// Distant trees: one flat card per tree that turns to face the camera. NoiseTerrain bakes a
// side view of the tree mesh into card_texture at start-up, so cards look like your model;
// without a bake (no display, or bake failed) a conifer shape is cut out in the shader.
// Fades by distance with tree_fade.gdshaderinc; hidden up close where the model is drawn.

#include "tree_fade.gdshaderinc"
#include "tree_fresh.gdshaderinc"

uniform vec3 foliage_color : source_color = vec3(0.09, 0.21, 0.06);
uniform vec3 foliage_top_color : source_color = vec3(0.16, 0.32, 0.09);
uniform float width = 0.55; // Card width as a fraction of the model's unit height.
uniform float card_height = 1.0; // Card height as a fraction of the model's unit height.
uniform sampler2D card_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform bool use_card_texture = false;

varying flat float tint;
varying flat float thin;
varying flat float share;

void vertex() {
	vec3 base = MODEL_MATRIX[3].xyz;
	float tall = length(MODEL_MATRIX[1].xyz);
	float m = tree_metric(base);
	thin = tree_thin(m, INSTANCE_CUSTOM.x) * tree_fresh(INSTANCE_CUSTOM.x);
	share = tree_model_share(m);
	tint = 0.75 + 0.5 * INSTANCE_CUSTOM.y;
	if (thin <= 0.0 || share >= 1.0) {
		VERTEX = base; // Hidden: collapse to a point so nothing is drawn.
	} else {
		tall *= tree_grow(m) * tree_fade_scale(thin);
		vec3 to_camera = CAMERA_POSITION_WORLD - base;
		to_camera.y = 0.0;
		to_camera = normalize(to_camera + vec3(0.0001, 0.0, 0.0));
		vec3 right = vec3(to_camera.z, 0.0, -to_camera.x);
		VERTEX = base + right * (UV.x - 0.5) * width * tall + vec3(0.0, (1.0 - UV.y) * card_height * tall, 0.0);
		NORMAL = normalize(to_camera * 0.5 + vec3(0.0, 1.0, 0.0));
	}
}

void fragment() {
	// The card takes exactly the pixels the model gives up, so the swap is a dissolve.
	if (tree_dither(FRAGCOORD.xy) < share || tree_dither(FRAGCOORD.yx + 7.0) >= tree_fade_cover(thin)) {
		discard;
	}
	vec3 base;
	if (use_card_texture) {
		vec4 t = texture(card_texture, UV);
		// Sharpen the alpha edge so distant (mipmapped) cards keep their shape.
		float a = (t.a - 0.5) / max(fwidth(t.a), 0.0001) + 0.5;
		if (a < 0.5) {
			discard;
		}
		base = t.rgb;
	} else {
		float y = 1.0 - UV.y;
		float x = abs(UV.x - 0.5) * 2.0;
		float tiers = 0.75 + 0.25 * fract(y * 4.0);
		float half_width = y < 0.1 ? 0.1 : (1.0 - y) * 1.05 * tiers;
		if (x > half_width) {
			discard;
		}
		base = mix(foliage_color, foliage_top_color, y);
	}
	ALBEDO = tree_fade_colour(base * tint, thin);
	ROUGHNESS = 0.9;
	SPECULAR = 0.1;
}
