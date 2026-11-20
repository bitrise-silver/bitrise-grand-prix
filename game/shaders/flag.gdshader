// A tall feather flag that ripples in the wind. UV.x runs from the pole (0) to the free edge (1),
// UV.y from the top (0) to the bottom (1). An icon tile sits near the top.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D icon : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 base : source_color = vec3(0.573, 0.278, 0.761);
uniform vec3 trim : source_color = vec3(0.965, 0.957, 0.965);
uniform float phase = 0.0;
// Height of the flag divided by its width.
uniform float aspect = 3.0;

void vertex() {
	float wave = sin(TIME * 3.2 + phase + UV.x * 4.5 + UV.y * 1.7);
	VERTEX.z += wave * 0.22 * UV.x;
}

void fragment() {
	vec3 color = base;
	if (UV.x > 0.84) {
		color = trim;
	}
	vec2 icon_uv = vec2((UV.x - 0.1) / 0.66, (UV.y - 0.05) * aspect / 0.66);
	if (icon_uv.x >= 0.0 && icon_uv.x <= 1.0 && icon_uv.y >= 0.0 && icon_uv.y <= 1.0) {
		color = texture(icon, icon_uv).rgb;
	}
	// Faint stripes lower down, so the cloth reads as cloth.
	color *= 0.94 + 0.06 * step(0.5, fract(UV.y * aspect * 1.5));
	ALBEDO = color;
	ROUGHNESS = 0.8;
}
