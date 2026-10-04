@tool
extends Node
## Editor smoke test for EdenPlanetOcean: open _ocean_editor_probe.tscn with --editor; after a few
## seconds this saves the editor's 3D viewport and prints the ocean's leaf count, then quits.

func _ready() -> void:
	# Only when launched by the test, so opening this scene by hand doesn't close the editor.
	if not Engine.is_editor_hint() or OS.get_environment("OCEAN_PROBE_OUT") == "":
		return
	await get_tree().create_timer(6.0).timeout
	var ocean := get_parent().get_node("VoxelLodTerrain/Ocean") as EdenPlanetOcean
	var mat := ocean.material as ShaderMaterial
	print("EDITOR_PROBE: leaves=%d material=%s shader_chars=%d" % [ocean.get_leaf_count(), mat,
			mat.shader.code.length() if mat and mat.shader else 0])
	# (looked up by name: EditorInterface doesn't exist in exported builds, and this script ships with the world scene)
	var img: Image = Engine.get_singleton("EditorInterface").get_editor_viewport_3d(0).get_texture().get_image()
	img.save_png(OS.get_environment("OCEAN_PROBE_OUT"))
	get_tree().quit()
