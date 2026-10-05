# Eden Inventory

A standard inventory for the player in `eden_play.tscn`: a backpack of stacks you arrange with the mouse, and a
hotbar of shortcuts. Turn it on in **Project Settings > Plugins > Eden Inventory**; turned off, EdenMiner's own
6-slot hotbar and Tab list are back exactly as before.

## Controls

**Hotbar** (bottom of the screen, always shown)
- 9 slots, **1-9** or the **mouse wheel** pick one; its item goes in hand (what RMB places).
- **Z** puts away what's in hand (nothing selected; a number picks it up again).
- Each slot is a *shortcut* to an item type and shows how many you have in all. A shortcut to something you have
  none of stays, greyed out, until you pick more up. An item is on one slot at most.
- An item you had none of (new, or run out of) goes onto the first empty slot when you pick it up, unless it
  still has a shortcut. A shortcut you remove while you still have some of the item stays removed.

**Backpack** (**Tab** opens it; Tab, Esc or a click outside closes it)
- 36 slots, stacks of up to 999. The pointer shows and you can still walk; digging and placing wait until it's closed.
- Stacks and hotbar shortcuts move either way: **press, drag and release** on another slot, or **click** (it stays
  in the pointer) and **click** where it goes.
- **Stacks**: LMB takes the whole stack, RMB half of it. Put down onto the same item they merge, onto another they
  swap; RMB with a stack in the pointer puts down one. Dragged out of the window, a stack goes back.
- **Shortcuts**: moved onto another hotbar slot they swap places; moved anywhere else (the backpack, off the bar)
  they're removed. **RMB** on a hotbar slot removes its shortcut too.
- **1-9** with the pointer over a stack, or a stack put on a hotbar slot (it goes back): that slot becomes the
  item's shortcut.
- Hovering shows the item's name, how many you have and what it's for.
- **Shift+click** does nothing yet: it's kept for quick-moving into containers.
- Closing with a click outside doesn't dig: the mouse goes back to the game when the button is released.

## How it works

- `EdenMiner.counts` (how many of each item; the server keeps them in `player_inventory`) stays the truth. Building,
  multiplayer and the server are unchanged.
- `EdenInventoryLayout` arranges those counts into stacks and keeps them adding up: items gained top up a stack of
  that item, then fill an empty slot; items spent (placing ground, building) come off the smallest stack. What a
  full backpack can't hold is listed under the grid.
- Only the arrangement is saved, on this computer (`user://eden_inventory.cfg`, one for all worlds). It's always
  matched back to the real counts, so editing it can't add items. Tests can point `EdenInventoryLayout.save_path`
  at a file of their own.
- New item types in `EdenMiner.ITEMS` show up on their own (up to the server's 16).

## Files

| File | |
|---|---|
| `plugin.gd`, `plugin.cfg` | On / off: adds or removes the `EdenInventory` autoload |
| `eden_inventory.gd` | The autoload: sets `EdenMiner.external_ui` on the player's miner and attaches the UI |
| `inventory_layout.gd` | `EdenInventoryLayout`: slots, stacks, syncing to the counts, save / load |
| `inventory_ui.gd` | `EdenInventoryUI`: hotbar, backpack window, tooltip, input |
| `inventory_slot.gd` | `EdenInventorySlot`: one slot |
| `_inventory_test.gd` | Test of the layout: `godot --headless --path demo_eden -s res://addons/eden_inventory/_inventory_test.gd` |

Outside the plugin: `EdenMiner.external_ui` (no hotbar / panel of its own, 1-6 / wheel / Tab left to the plugin,
`selected` may be -1), and `EdenPlayer.ui_open()` also counts visible Controls in the group `eden_pointer_ui`.
