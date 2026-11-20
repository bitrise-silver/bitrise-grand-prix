// Kenney's car models sample one shared palette texture. This repaints the body cell of that
// palette in the driver's colour, keeping the palette's light-to-dark shading.
shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque;

uniform sampler2D colormap : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 paint : source_color = vec3(0.573, 0.278, 0.761);

void fragment() {
	vec3 base = texture(colormap, UV).rgb;
	// The body colour lives in the fourth cell pair of the palette's second row.
	if (UV.x > 0.375 && UV.x < 0.5 && UV.y > 0.25 && UV.y < 0.5) {
		base = paint * mix(1.12, 0.62, clamp((UV.y - 0.25) * 4.0, 0.0, 1.0));
	}
	ALBEDO = base;
	ROUGHNESS = 0.38;
	SPECULAR = 0.65;
}
