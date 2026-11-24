// Low-poly spectators drawn as one MultiMesh per group. Each instance's colour is its shirt.
// UV.x tags the body parts: 1 shirt, 0.5 skin, 0.25 hair, 0 trousers. UV.y marks the hands,
// which wave. A per-person random phase comes from where they stand.
//
// Idle, people bob and sway a little; every so often a Mexican wave rolls across the whole
// arena; when a car flies past they jump with their arms up. Now and then someone takes a
// photo, and the phone's flash pops (more often when there is something to see).
shader_type spatial;
render_mode cull_back;

// 0 when nothing is happening, 1 when a car is flying past.
uniform float excite = 0.0;

varying vec3 tint;
varying float person;
varying float hands;

float hash(float n) {
	return fract(sin(n) * 43758.5453);
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float random = fract(sin(dot(origin.xz, vec2(12.9898, 78.233))) * 43758.5453);
	float phase = random * 6.2831;
	float speed = mix(2.5, 10.0, excite);

	// The Mexican wave: on for a while, off for longer, sweeping east across every stand.
	float season = smoothstep(0.35, 0.6, sin(TIME * 0.11 + 0.8));
	float crest = smoothstep(0.86, 1.0, sin(TIME * 2.1 - origin.x * 0.16 - origin.z * 0.03)) * season;
	float up = max(excite, crest);

	VERTEX.y += max(0.0, sin(TIME * speed + phase)) * mix(0.04, 0.32, excite) + crest * 0.38;
	// Arms: a lazy wave when idle, straight up when cheering.
	VERTEX.y += UV.y * (sin(TIME * speed * 1.4 + phase * 2.0) * mix(0.03, 0.18, excite) + up * 0.32);
	// A gentle sway from the ankles, so a stand never looks frozen.
	VERTEX.x += sin(TIME * 1.3 + phase) * 0.035 * VERTEX.y;

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
	person = random;
	hands = UV.y;
}

void fragment() {
	ALBEDO = tint;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
	// A phone camera flash at the raised hands: each person gets a roll of the dice eight
	// times a second.
	// Kept small: sin() of a large number is noise on phone GPUs, but not the useful kind.
	float slot = mod(floor(TIME * 8.0), 251.0);
	float chance = mix(0.9975, 0.985, excite);
	float flash = step(chance, hash(slot * 1.31 + person * 917.0)) * smoothstep(0.85, 1.0, hands);
	EMISSION = vec3(3.2, 3.1, 2.9) * flash;
}
