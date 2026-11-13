shader_type spatial;
// Colours the ground from height, slope and the climate values stored per vertex
// (COLOR.r = moisture, COLOR.g = forest cover), and adds the cloud shadows.
// Where there is forest, the ground gets a darker forest-floor tint at every distance, and
// takes on the canopy colour as the trees thin out with distance (see tree_fade.gdshaderinc).

#include "clouds.gdshaderinc"
#include "tree_fade.gdshaderinc"

uniform sampler2D detail_noise : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D detail_normal : repeat_enable, filter_linear_mipmap_anisotropic;
uniform float sea_level = 0.0;
uniform float snow_line = 1650.0;
uniform vec3 sun_direction = vec3(0.3, 0.8, 0.3); // Towards the sun.
uniform float cloud_shadow_strength : hint_range(0.0, 1.0) = 0.65;

uniform vec3 desert_color_a : source_color = vec3(0.80, 0.52, 0.33);
uniform vec3 desert_color_b : source_color = vec3(0.87, 0.68, 0.45);
uniform vec3 beach_color : source_color = vec3(0.84, 0.78, 0.60);
uniform vec3 grass_dry_color : source_color = vec3(0.50, 0.47, 0.25);
uniform vec3 grass_lush_color : source_color = vec3(0.24, 0.40, 0.13);
uniform vec3 forest_color : source_color = vec3(0.09, 0.19, 0.07); // Canopy seen from afar.
uniform float forest_floor_strength : hint_range(0.0, 1.0) = 0.85;
uniform vec3 rock_color : source_color = vec3(0.36, 0.33, 0.30);
uniform vec3 rock_dry_color : source_color = vec3(0.55, 0.33, 0.22);
uniform vec3 snow_color : source_color = vec3(0.93, 0.95, 0.98);

varying vec3 world_pos;
varying vec3 world_normal;
varying float sun_shade;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = MODEL_NORMAL_MATRIX * NORMAL;
}

void fragment() {
	vec3 n = normalize(world_normal);
	vec2 xz = world_pos.xz;
	float dist = length(VERTEX);
	float n_fine = texture(detail_noise, xz / 16.0).r;
	float n_mid = texture(detail_noise, xz / 128.0).r;
	float n_big = texture(detail_noise, xz / 1024.0).r;

	// Fine bumps close to the camera.
	vec3 bump = texture(detail_normal, xz / 32.0).rgb * 2.0 - 1.0;
	n = normalize(n + vec3(bump.x, 0.0, bump.y) * 0.35 * smoothstep(500.0, 30.0, dist));

	float h = world_pos.y;
	float slope = 1.0 - n.y;
	float moist = COLOR.r + (n_big - 0.5) * 0.12;
	float forest = COLOR.g;

	vec3 sand = mix(desert_color_a, desert_color_b, n_big);
	vec3 grass = mix(grass_dry_color, grass_lush_color, smoothstep(0.4, 0.75, moist)) * (0.8 + 0.4 * n_mid);
	vec3 colour = mix(sand, grass, smoothstep(0.34, 0.46, moist));
	// Forest: the same weighting the trees are placed with, so tint and trees match.
	float trees_here = pow(clamp(forest, 0.0, 1.0), 0.6);
	colour = mix(colour, forest_floor_color * (0.75 + 0.5 * n_mid), trees_here * forest_floor_strength);
	float canopy = trees_here * (1.0 - tree_drawn_share(tree_metric(world_pos)));
	colour = mix(colour, forest_color * (0.7 + 0.6 * n_mid), canopy * 0.9);
	colour = mix(colour, beach_color, smoothstep(sea_level + 6.0, sea_level + 1.5, h + (n_mid - 0.5) * 3.0));

	vec3 rock = mix(rock_dry_color, rock_color, smoothstep(0.3, 0.5, moist)) * (0.65 + 0.7 * n_fine * n_mid * 2.0);
	colour = mix(colour, rock, smoothstep(0.2, 0.38, slope + (n_mid - 0.5) * 0.14));

	float snow = smoothstep(snow_line - 200.0, snow_line + 200.0, h + (n_big - 0.5) * 500.0) * smoothstep(0.55, 0.3, slope + (n_mid - 0.5) * 0.2);
	colour = mix(colour, snow_color, snow);
	colour *= mix(1.0, 0.55, smoothstep(sea_level, sea_level - 5.0, h)); // Wet ground under water.

	ALBEDO = colour;
	ROUGHNESS = mix(0.95, 0.55, snow);
	SPECULAR = 0.2;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	vec3 world = world_pos + vec3(world_origin.x, 0.0, world_origin.y);
	sun_shade = 1.0 - cloud_shadow_strength * cloud_shadow_at(world, normalize(sun_direction), TIME);
}

void light() {
	float shade = LIGHT_IS_DIRECTIONAL ? sun_shade : 1.0;
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI * shade;
}
