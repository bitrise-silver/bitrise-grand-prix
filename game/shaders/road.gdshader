// Purple-tinted asphalt with a little grain and a darker racing line worn into it.
shader_type spatial;
render_mode cull_disabled;

uniform vec3 asphalt : source_color = vec3(0.302, 0.267, 0.353);
uniform vec3 worn : source_color = vec3(0.243, 0.212, 0.290);

varying vec3 world;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// UV.x runs across the road from 0 to 1.
	float line = 1.0 - smoothstep(0.08, 0.3, abs(UV.x - 0.5));
	vec3 color = mix(asphalt, worn, line * 0.55);
	color *= 0.92 + 0.12 * value_noise(world.xz * 0.35);
	color *= 0.97 + 0.06 * hash(floor(world.xz * 6.0));
	ALBEDO = color * COLOR.rgb;
	ROUGHNESS = 0.85;
	SPECULAR = 0.3;
}
