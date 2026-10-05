extends SceneTree
## EdenInventoryLayout without the game: syncing to counts (new items onto the hotbar, gains topping up stacks,
## spending from the smallest stack), moving stacks with the pointer (pick, half, merge, swap, drop one, put back),
## hotbar shortcuts (one slot per item), a held stack counting towards the total, overflow when the backpack is full,
## and saving: a tampered file can't add items.
##   godot --headless --path demo_eden -s res://addons/eden_inventory/_inventory_test.gd

const DIRT := 0
const STONE := 1
const WOOD := 5

var ok := true


func _initialize() -> void:
	EdenInventoryLayout.save_path = "user://_inventory_test_default.cfg"
	var lay := EdenInventoryLayout.new(6)

	# First sync: every item gets a stack and the hotbar fills in item order, as the old fixed hotbar was
	var counts: Array[int] = [12, 3, 0, 0, 0, 40]
	lay.sync(counts)
	_check(lay.total(DIRT) == 12 and lay.total(STONE) == 3 and lay.total(WOOD) == 40, "stacks add up to the counts")
	_check(lay.hotbar[0] == DIRT and lay.hotbar[1] == STONE and lay.hotbar[2] == WOOD and lay.hotbar[3] == -1,
			"new items go onto the hotbar (%s)" % lay.hotbar)

	# Gains top up the existing stack; a stack holds STACK at most
	counts[DIRT] = 1500
	lay.sync(counts)
	_check(lay.amounts[0] == EdenInventoryLayout.STACK and lay.total(DIRT) == 1500, "gains top up, then a new stack")

	# Spending takes from the smallest stack
	counts[DIRT] = 1490
	lay.sync(counts)
	_check(lay.amounts[0] == EdenInventoryLayout.STACK and lay.total(DIRT) == 1490, "spending leaves the full stack alone")

	# Pick up half the wood, drop one, put it on an empty slot
	var wood_slot := lay.items.find(WOOD)
	lay.pick(wood_slot, true)
	_check(lay.held_item == WOOD and lay.held_amount == 20 and lay.amounts[wood_slot] == 20, "right-click picks up half")
	_check(lay.total(WOOD) == 40, "the held stack still counts")
	lay.sync(counts)
	_check(lay.total(WOOD) == 40, "a sync while holding doesn't duplicate it")
	var empty := lay.items.find(-1)
	lay.drop(empty, true)
	_check(lay.items[empty] == WOOD and lay.amounts[empty] == 1 and lay.held_amount == 19, "drop one")
	lay.drop(empty)
	_check(lay.amounts[empty] == 20 and lay.held_item == -1, "drop the rest onto the same item")

	# Swap: holding wood, drop onto the stone stack -> now holding the stone
	lay.pick(empty)
	var stone_slot := lay.items.find(STONE)
	lay.drop(stone_slot)
	_check(lay.items[stone_slot] == WOOD and lay.held_item == STONE and lay.held_amount == 3, "drop onto another item swaps")
	lay.return_held()
	_check(lay.held_item == -1 and lay.total(STONE) == 3 and lay.total(WOOD) == 40, "put back")

	# Spending while holding: the slots go first, the held stack last
	lay.pick(lay.items.find(STONE))
	counts[STONE] = 1
	lay.sync(counts)
	_check(lay.held_amount == 1 and lay.total(STONE) == 1, "spending can come out of the held stack")
	lay.return_held()

	# Hotbar shortcuts: one slot per item
	lay.assign(5, DIRT)
	_check(lay.hotbar[5] == DIRT and lay.hotbar[0] == -1, "assigning moves the shortcut")
	lay.assign(5, -1)
	_check(lay.hotbar[5] == -1, "and can clear it")
	counts[DIRT] += 10
	lay.sync(counts)
	_check(lay.hotbar.find(DIRT) < 0, "a shortcut removed while you have some stays removed")
	# Run out of something with no shortcut: picked up again, it's new and goes onto the hotbar
	counts[DIRT] = 0
	lay.sync(counts)
	counts[DIRT] = 5
	lay.sync(counts)
	_check(lay.hotbar[0] == DIRT, "run out, picked up again: back on the hotbar (%s)" % lay.hotbar)
	# Run out of something with a shortcut: the shortcut stays put (greyed) and isn't doubled
	var wood_hot := lay.hotbar.find(WOOD)
	counts[WOOD] = 0
	lay.sync(counts)
	_check(lay.hotbar[wood_hot] == WOOD, "run out: its shortcut stays")
	counts[WOOD] = 40
	lay.sync(counts)
	_check(lay.hotbar[wood_hot] == WOOD and lay.hotbar.count(WOOD) == 1, "picked up again: same slot, once")

	# Overflow: a full backpack shows what it can
	var full := EdenInventoryLayout.new(6)
	var lots: Array[int] = [EdenInventoryLayout.STACK * EdenInventoryLayout.SLOTS + 50, 0, 0, 0, 0, 0]
	full.sync(lots)
	_check(full.overflow(DIRT, lots[0]) == 50 and full.items.find(-1) < 0, "overflow when full (%d)" % full.overflow(DIRT, lots[0]))

	# Saving keeps the arrangement; a file claiming more items than the counts changes nothing
	var path := "user://_inventory_test.cfg"
	lay.save_to(path)
	var back := EdenInventoryLayout.new(6)
	back.load_from(path)
	back.sync(counts)
	_check(back.items == lay.items and back.amounts == lay.amounts and back.hotbar == lay.hotbar, "save and load")
	var cfg := ConfigFile.new()
	cfg.load(path)
	var fake: PackedInt32Array = cfg.get_value("layout", "amounts")
	fake[lay.items.find(WOOD)] = 999
	cfg.set_value("layout", "amounts", fake)
	cfg.save(path)
	back.load_from(path)
	back.sync(counts)
	_check(back.total(WOOD) == 40, "a tampered file can't add items (%d wood)" % back.total(WOOD))
	cfg.set_value("layout", "items", "garbage")
	cfg.save(path)
	back.load_from(path)
	back.sync(counts)
	_check(back.total(DIRT) == 5 and back.total(WOOD) == 40, "a broken file falls back to a fresh layout")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	print("INVENTORY_TEST ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _check(cond: bool, msg: String) -> void:
	print("INVENTORY_TEST %s %s" % ["ok  " if cond else "FAIL", msg])
	ok = ok and cond
