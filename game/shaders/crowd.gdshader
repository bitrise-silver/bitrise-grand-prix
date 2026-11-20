// Low-poly spectators drawn as one MultiMesh per group. Each instance's colour is its shirt.
// UV.x tags the body parts: 1 shirt, 0.5 skin, 0.25 hair, 0 trousers. UV.y marks the hands,
// which wave. A per-person random phase comes from where they stand.
shader_type spatial;
render_mode cull_back;

// 0 when nothing is happening, 1 when a car is flying past.
uniform float excite = 0.0;

varying vec3 tint;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float random = fract(sin(dot(origin.xz, vec2(12.9898, 78.233))) * 43758.5453);
	float phase = random * 6.2831;
	float speed = mix(2.5, 10.0, excite);
	VERTEX.y += max(0.0, sin(TIME * speed + phase)) * mix(0.04, 0.3, excite);
	VERTEX.y += UV.y * sin(TIME * speed * 1.4 + phase * 2.0) * mix(0.03, 0.22, excite);

	vec3 skin = mix(vec3(0.96, 0.78, 0.64), vec3(0.42, 0.27, 0.19), fract(random * 7.13));
	if (UV.x > 0.75) {
		tint = COLOR.rgb;
	} else if (UV.x > 0.4) {
		tint = skin;
	} else if (UV.x > 0.15) {
		tint = mix(vec3(0.23, 0.16, 0.12), vec3(0.85, 0.7, 0.4), step(0.8, fract(random * 3.7)));
	} else {
		tint = mix(vec3(0.17, 0.2, 0.31), vec3(0.3, 0.28, 0.32), step(0.6, fract(random * 5.3)));
	}
}

void fragment() {
	ALBEDO = tint;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
}
