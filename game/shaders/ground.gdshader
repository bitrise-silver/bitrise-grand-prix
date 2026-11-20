// Grass with mowing stripes, darkening as the hills outside the arena rise.
shader_type spatial;
render_mode cull_back;

uniform vec3 grass_a : source_color = vec3(0.300, 0.535, 0.275);
uniform vec3 grass_b : source_color = vec3(0.262, 0.482, 0.243);
uniform vec3 hill : source_color = vec3(0.196, 0.392, 0.231);
uniform float stripe_width = 7.0;

varying vec3 world;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Diagonal bands, like a freshly mown infield.
	float band = fract((world.x * 0.45 + world.z) / (stripe_width * 2.0));
	vec3 color = mix(grass_a, grass_b, smoothstep(0.47, 0.53, band) - smoothstep(0.97, 1.0, band));
	// Soft patches so the grass is not a flat colour.
	color *= 0.93 + 0.14 * value_noise(world.xz * 0.12);
	color = mix(color, hill, clamp(world.y / 12.0, 0.0, 0.75));
	ALBEDO = color;
	ROUGHNESS = 0.95;
	SPECULAR = 0.15;
}
