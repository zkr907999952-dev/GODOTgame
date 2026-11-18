shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// Mach disk / shock diamond: bright shock plane plus a faint conical envelope.
uniform vec3 u_color : source_color = vec3(1.0, 0.90, 0.69);
uniform float u_alpha = 0.3;
uniform float u_index = 0.0;

varying vec3 v_pos;

void vertex() {
	v_pos = VERTEX;
}

void fragment() {
	// Mesh is a double-cone (octahedron-like) along Y, later rotated to +Z.
	float along = clamp(v_pos.y * 2.0, -1.0, 1.0);
	float radial = length(v_pos.xz);
	float disk = 1.0 - smoothstep(0.0, 0.16, abs(along));
	float cone = 1.0 - smoothstep(0.02, 0.55, radial + abs(along) * 0.35);
	float ring = smoothstep(0.08, 0.0, abs(radial - (0.22 - abs(along) * 0.18)));
	float a = (disk * 1.15 + cone * 0.45 + ring * 0.80) * u_alpha;
	a *= 1.0 - u_index * 0.10;
	vec3 col = mix(u_color * 1.15, u_color * 2.15, disk);
	ALBEDO = col;
	ALPHA = a;
}
