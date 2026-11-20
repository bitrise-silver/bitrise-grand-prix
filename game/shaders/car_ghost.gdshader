// The see-through version of car_paint.gdshader, for other players' cars on a phone.
shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_always;

uniform sampler2D colormap : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 paint : source_color = vec3(0.573, 0.278, 0.761);
uniform float opacity = 0.5;

void fragment() {
	vec3 base = texture(colormap, UV).rgb;
	if (UV.x > 0.375 && UV.x < 0.5 && UV.y > 0.25 && UV.y < 0.5) {
		base = paint * mix(1.12, 0.62, clamp((UV.y - 0.25) * 4.0, 0.0, 1.0));
	}
	ALBEDO = base;
	ROUGHNESS = 0.38;
	ALPHA = opacity;
}
