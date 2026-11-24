// Little light bulbs drawn as one MultiMesh per group: start lights, chase lights on the
// gantry and the grandstand, marker lights on the bends, studs along the road edges.
// Each instance's colour is the bulb's colour; its alpha is where the bulb sits in the
// pattern (0..1), so neighbouring bulbs can chase, alternate or twinkle.
shader_type spatial;
render_mode cull_back;

// Pattern cycles per second. 0 holds every bulb steadily lit.
uniform float speed = 1.0;
// Higher makes each flash shorter.
uniform float sharpness = 4.0;
// How bright a lit bulb glows; above 1 it blooms where glow is on.
uniform float energy = 2.5;
// How much an unlit bulb still shows, so the fittings read in daylight.
uniform float dim = 0.12;

varying vec3 tint;
varying float lit;

void vertex() {
	tint = COLOR.rgb;
	if (speed > 0.0) {
		float wave = 0.5 + 0.5 * sin(6.2831853 * (TIME * speed - COLOR.a));
		lit = pow(wave, sharpness);
	} else {
		lit = 1.0;
	}
}

void fragment() {
	ALBEDO = tint * (0.3 + 0.7 * lit);
	EMISSION = tint * mix(dim, 1.0, lit) * energy;
	ROUGHNESS = 0.35;
	SPECULAR = 0.6;
}
