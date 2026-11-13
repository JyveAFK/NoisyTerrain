// Shared by the tree model and tree card shaders, so both agree exactly on which trees show,
// and by the terrain shader, so the ground takes over the forest colour as trees thin out.
// NoiseTerrain.tree_weights() in GDScript mirrors this maths; keep the two in step.
//
// Every tree is a fixed thing in the world: coarser cells hold a subset of the same trees.
// Each tree carries a rank (0 to 1) in INSTANCE_CUSTOM.x. The further away, the fewer ranks
// are kept, so trees thin out gradually by distance instead of per cell, and the trees a
// coarse cell drops are already faded out before that cell swaps in.

uniform vec3 lod_center = vec3(0.0); // The point the terrain detail follows (scene space).
uniform float lod_altitude = 0.0; // Its height above ground x 0.6, as the cell picker uses.
uniform float density_distance = 200.0; // All trees show inside this; see tree_keep().
uniform float model_fade_start = 500.0; // Models dissolve into cards between these two.
uniform float model_fade_end = 700.0;
uniform float far_fade_start = 2300.0; // All trees fade out between these two.
uniform float far_fade_end = 3000.0;
uniform float grow_rate = 0.25; // Distant trees grow a little to make up for being fewer.
uniform vec3 forest_floor_color : source_color = vec3(0.14, 0.18, 0.08); // Ground under trees; fading trees start this colour.

float tree_metric(vec3 world_base) {
	vec2 d = world_base.xz - lod_center.xz;
	return sqrt(dot(d, d) + lod_altitude * lod_altitude);
}

// Share of trees kept at this distance. It follows the cells: inside density_distance all
// trees; each doubling of distance keeps a quarter as many. The drop is ramped over the
// second part of each doubling, and finishes before the coarser cell that holds only that
// quarter can swap in, so the trees it lacks are already gone.
float tree_keep(float m) {
	float u = log2(max(m, 1.0) / density_distance);
	if (u <= 0.0) {
		return 1.0;
	}
	float k = floor(u);
	return exp2(-2.0 * (k + smoothstep(0.35, 1.0, u - k)));
}

// 1 = fully shown, 0 = gone. Each tree fades while the kept share drops from 4x its rank
// to its rank, which spreads each fade over most of one ramp.
float tree_thin(float m, float rank) {
	float near_far = 1.0 - smoothstep(far_fade_start, far_fade_end, m);
	return (1.0 - smoothstep(0.25, 1.0, rank / tree_keep(m))) * near_far;
}

// Share of the forest still drawn as trees at this distance (1 close in, falling with
// distance, 0 past the far fade). The terrain paints the rest as canopy colour.
float tree_drawn_share(float m) {
	return tree_keep(m) * (1.0 - smoothstep(far_fade_start, far_fade_end, m));
}

// 1 = draw as a model, 0 = draw as a card, in between = dissolving from one to the other.
float tree_model_share(float m) {
	return 1.0 - smoothstep(model_fade_start, model_fade_end, m);
}

// How a tree fades in: it starts a little short and the colour of the forest floor (so it
// sits into the ground tint), then darkens to its own colour as it reaches full height.
// The screen-door dissolve covers the first part, while the tree is still mostly floor colour,
// so it is spread out (gentle at high speed) without looking speckled.
float tree_fade_scale(float thin) {
	return mix(0.7, 1.0, thin);
}

float tree_fade_cover(float thin) {
	return smoothstep(0.0, 0.6, thin);
}

vec3 tree_fade_colour(vec3 albedo, float thin) {
	return mix(forest_floor_color, albedo, smoothstep(0.0, 0.85, thin));
}

float tree_grow(float m) {
	return 1.0 + grow_rate * log2(max(m / density_distance, 1.0));
}

// A fixed screen-space pattern for dissolving (interleaved gradient noise).
float tree_dither(vec2 pixel) {
	return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}
