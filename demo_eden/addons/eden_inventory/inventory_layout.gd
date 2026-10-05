class_name EdenInventoryLayout
extends RefCounted
## Where the inventory's items sit: SLOTS backpack stacks of up to STACK, a HOTBAR of shortcuts to item types, and
## the stack the pointer is holding while the window is open. No UI here (EdenInventoryUI draws it).
## The item counts (EdenMiner.counts, kept by the server) stay the truth: sync() makes the stacks add up to them,
## topping up / filling slots for items gained and taking from the smallest stacks for items spent. Counts that
## don't fit (a full backpack) are the overflow. Only the arrangement is saved (save_to() / load_from()), so
## editing the file can't create items: load_from() is always followed by a sync() to the real counts.

const SLOTS := 36
const HOTBAR := 9
const STACK := 999
## Where save_to() / load_from() keep the arrangement by default (tests point it elsewhere, so a test run never
## touches the player's own)
static var save_path := "user://eden_inventory.cfg"

var item_count := 0
## Backpack stacks: item per slot (-1 empty) and how many
var items := PackedInt32Array()
var amounts := PackedInt32Array()
## Hotbar: the item type each slot is a shortcut to (-1 none); an item is on one slot at most
var hotbar := PackedInt32Array()
## The stack picked up with the pointer (held_item -1: none) and the slot it came from
var held_item := -1
var held_amount := 0
var held_from := -1
## Item types you have some of. One you didn't (new, or run out of) goes to the first empty hotbar slot when it
## comes in, unless it has a shortcut already; a shortcut removed while you still have some stays removed
var known := {}


func _init(p_item_count: int) -> void:
	item_count = p_item_count
	clear()


func clear() -> void:
	items.resize(SLOTS)
	items.fill(-1)
	amounts.resize(SLOTS)
	amounts.fill(0)
	hotbar.resize(HOTBAR)
	hotbar.fill(-1)
	held_item = -1
	held_amount = 0
	held_from = -1
	known.clear()


## How many of an item the stacks (and the held stack) hold
func total(item: int) -> int:
	var n := held_amount if held_item == item else 0
	for i in SLOTS:
		if items[i] == item:
			n += amounts[i]
	return n


## Makes the stacks add up to counts (EdenMiner.counts). Returns whether anything changed.
func sync(counts: Array) -> bool:
	var changed := false
	for item in mini(counts.size(), item_count):
		var want := int(counts[item])
		var have := total(item)
		if want > have:
			changed = _add(item, want - have) or changed
		elif want < have:
			_remove(item, have - want)
			changed = true
		if want > 0 and not known.has(item):
			known[item] = true
			if hotbar.find(item) < 0 and hotbar.find(-1) >= 0:
				hotbar[hotbar.find(-1)] = item
			changed = true
		elif want == 0 and known.has(item):
			known.erase(item)
			changed = true
	return changed


## Of an item's count, what the full backpack has no room to show
func overflow(item: int, count: int) -> int:
	return maxi(0, count - total(item))


# Tops up the item's stacks in slot order, then fills empty slots. False when nothing fitted.
func _add(item: int, n: int) -> bool:
	var start := n
	for i in SLOTS:
		if n > 0 and items[i] == item and amounts[i] < STACK:
			var put := mini(n, STACK - amounts[i])
			amounts[i] += put
			n -= put
	for i in SLOTS:
		if n > 0 and items[i] == -1:
			var put := mini(n, STACK)
			items[i] = item
			amounts[i] = put
			n -= put
	return n < start


# Takes from the item's smallest stacks first (the last slot of equal ones), so the main piles stay whole; the
# held stack last
func _remove(item: int, n: int) -> void:
	while n > 0:
		var best := -1
		for i in SLOTS:
			if items[i] == item and (best < 0 or amounts[i] <= amounts[best]):
				best = i
		if best < 0:
			break
		var take := mini(n, amounts[best])
		amounts[best] -= take
		n -= take
		if amounts[best] == 0:
			items[best] = -1
	if n > 0 and held_item == item:
		held_amount -= mini(n, held_amount)
		if held_amount == 0:
			held_item = -1
			held_from = -1


# ------------------------------------------------------------------------------------------------------------
# Moving stacks with the pointer (EdenInventoryUI calls these)

## Picks up the slot's stack (half of it, rounded up, with half)
func pick(slot: int, half := false) -> void:
	if held_item != -1 or items[slot] == -1:
		return
	var n := ceili(amounts[slot] / 2.0) if half else amounts[slot]
	held_item = items[slot]
	held_amount = n
	held_from = slot
	amounts[slot] -= n
	if amounts[slot] == 0:
		items[slot] = -1


## Puts the held stack (or just one of it) into a slot: into an empty slot, onto the same item (what fits; the rest
## stays held) or, the whole stack onto another item, swapped with it
func drop(slot: int, one := false) -> void:
	if held_item == -1:
		return
	if items[slot] == -1 or items[slot] == held_item:
		var put := mini(1 if one else held_amount, STACK - amounts[slot])
		items[slot] = held_item
		amounts[slot] += put
		held_amount -= put
		if held_amount == 0:
			held_item = -1
			held_from = -1
	elif not one:
		var item := items[slot]
		var amount := amounts[slot]
		items[slot] = held_item
		amounts[slot] = held_amount
		held_item = item
		held_amount = amount
		held_from = slot


## Puts the held stack back: where it came from if there is room, else wherever it fits
func return_held() -> void:
	if held_item == -1:
		return
	if held_from >= 0 and (items[held_from] == -1 or items[held_from] == held_item):
		drop(held_from)
	if held_item != -1:
		var item := held_item
		var n := held_amount
		held_item = -1
		held_amount = 0
		held_from = -1
		_add(item, n)


## Makes hotbar slot `slot` a shortcut to `item` (-1: clears it), taking the item off any other slot
func assign(slot: int, item: int) -> void:
	if item >= 0:
		var was := hotbar.find(item)
		if was >= 0:
			hotbar[was] = -1
	hotbar[slot] = item


# ------------------------------------------------------------------------------------------------------------
# Saving the arrangement (never the counts)

func save_to(path := "") -> void:
	var cfg := ConfigFile.new()
	var it := items.duplicate()
	var am := amounts.duplicate()
	# (a stack in the pointer is saved where it came from)
	if held_item != -1 and held_from >= 0 and (it[held_from] == -1 or it[held_from] == held_item):
		it[held_from] = held_item
		am[held_from] += held_amount
	cfg.set_value("layout", "items", it)
	cfg.set_value("layout", "amounts", am)
	cfg.set_value("layout", "hotbar", hotbar)
	cfg.set_value("layout", "known", known.keys())
	cfg.save(path if path != "" else save_path)


## Loads a saved arrangement; anything malformed is ignored (the caller then syncs to the real counts)
func load_from(path := "") -> void:
	clear()
	var cfg := ConfigFile.new()
	if cfg.load(path if path != "" else save_path) != OK:
		return
	var it = cfg.get_value("layout", "items", null)
	var am = cfg.get_value("layout", "amounts", null)
	var hb = cfg.get_value("layout", "hotbar", null)
	var kn = cfg.get_value("layout", "known", [])
	if not (it is PackedInt32Array and am is PackedInt32Array and hb is PackedInt32Array and kn is Array) \
			or it.size() != SLOTS or am.size() != SLOTS or hb.size() != HOTBAR:
		return
	for i in SLOTS:
		if it[i] >= 0 and it[i] < item_count and am[i] > 0:
			items[i] = it[i]
			amounts[i] = mini(am[i], STACK)
	for i in HOTBAR:
		if hb[i] >= 0 and hb[i] < item_count and hotbar.find(hb[i]) < 0:
			hotbar[i] = hb[i]
	for k in kn:
		if k is int and k >= 0 and k < item_count:
			known[k] = true
