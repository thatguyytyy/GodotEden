extends SceneTree
## Is GodotSteam in this engine build, and does Steam start? (Steam must be running and logged in for the second.)
##   godot --headless --path demo_eden -s res://multiplayer/_steam_check.gd


func _initialize() -> void:
	print("STEAM_CHECK class %s  singleton %s" % [ClassDB.class_exists("Steam"), Engine.has_singleton("Steam")])
	quit()
