@tool
extends EditorPlugin
## Eden Inventory. Turning the plugin on adds the EdenInventory autoload, which gives the player a standard inventory
## and hotbar (README.md); turning it off removes it, and EdenMiner's own hotbar and Tab list are back as they were.

const AUTOLOAD := "EdenInventory"


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD, "res://addons/eden_inventory/eden_inventory.gd")


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD)
