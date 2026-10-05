extends Node
## EdenInventory (autoload, added by the Eden Inventory plugin): gives the local player a standard inventory. An
## EdenMiner joining the tree is told to leave its hotbar and inventory to us (external_ui, before its setup()), and
## once it is set up it gets an EdenInventoryUI.


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node is EdenMiner:
		node.external_ui = true
		_attach.call_deferred(node)


# (deferred: EdenPlayer calls the miner's setup() right after adding it)
func _attach(miner: EdenMiner) -> void:
	if not is_instance_valid(miner) or not (miner.get_parent() is EdenPlayer):
		return
	var ui := EdenInventoryUI.new()
	ui.name = "Inventory"
	miner.add_child(ui)
	ui.setup(miner.get_parent(), miner)
