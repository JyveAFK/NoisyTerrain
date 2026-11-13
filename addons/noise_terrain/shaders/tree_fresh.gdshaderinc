// Used by the tree shaders only (needs tree_fade.gdshaderinc first).
uniform float tree_clock = 0.0; // Seconds, from NoiseTerrain.

// Set per cell when it first shows: trees ranked at or above fresh_rank are new compared with
// the cell it replaced, and fade in from fresh_time. This covers cells that arrive late
// (very fast flight, slow machines); on time, those trees are already faded out by distance.
instance uniform float fresh_rank = 2.0;
instance uniform float fresh_time = -100.0;

float tree_fresh(float rank) {
	return rank >= fresh_rank ? clamp((tree_clock - fresh_time) / 0.35, 0.0, 1.0) : 1.0;
}
