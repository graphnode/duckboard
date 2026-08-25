@tool
extends RefCounted
## Every key Duckboard claims that a user could reasonably want somewhere else — registered with the
## editor, so they are listed and REBINDABLE under Editor Settings ▸ Shortcuts ▸ Duckboard rather than
## being facts of the source.
##
## [b]Why this is not a home-grown key map.[/b] Duckboard's bindings deliberately shadow the editor's
## own while the map mode is on: `R`, `E`, `T` and `F` are Godot's transform modes and Focus
## Selection, `Ctrl+G` is Scene ▸ Group Selected Nodes, `Ctrl+C` / `Ctrl+V` are the scene clipboard.
## Shadowing is the right behaviour — but a user whose muscle memory or keyboard layout disagrees had
## no recourse at all, and a plugin that hard-codes over the editor's keys and offers no way out is
## the kind of guest that gets uninstalled. The editor already owns a Shortcuts UI that shows the
## conflict and lets them settle it, so the whole job here is to turn up in it.
##
## [b]The engine keeps the user's answer, not us.[/b] [code]EditorSettings.add_shortcut[/code] is
## idempotent by design: a shortcut already loaded from the saved editor settings keeps ITS events
## (the settings load before any plugin does), and one the user has customised is refused outright
## rather than reset to the default. So registering unconditionally on every [code]_enter_tree[/code]
## is correct — it states the defaults, it cannot flatten a rebind.
##
## What is deliberately NOT here: the modal gesture keys — `Escape`, `Enter`, `Delete`, the arrow-key
## nudge and the grid-size digits. Those are not commands, they are what a key MEANS inside a gesture
## already in progress, and a rebinding list is the wrong place to describe them.

## Namespace for the whole set. The first path slice is what the Shortcuts tab uses as the section
## heading, so this is also the word "Duckboard" appearing there.
const PREFIX := "duckboard/"

## id -> {name, default}. `name` is what the Shortcuts tab lists — a command, phrased as one, since
## that column is the only description the tab shows. `default` is a display chord, or "" for a
## binding that ships unbound but is worth OFFERING: Texture Lock has no key in TrenchBroom either,
## and registering it empty is what lets someone give it one.
##
## The ids match the palette's button ids exactly, which is what lets [ToolPalette] look a binding up
## for a button without a second table to keep in step.
const BINDINGS := {
	# Commands the plugin itself runs.
	"group": {"name": "Group Brushes", "default": "Ctrl+G"},
	"ungroup": {"name": "Ungroup Brushes", "default": "Shift+Ctrl+G"},
	"copy": {"name": "Copy as TrenchBroom Map", "default": "Ctrl+C"},
	"paste": {"name": "Paste TrenchBroom Map", "default": "Ctrl+V"},
	# Tools — TrenchBroom's own letters.
	"brush": {"name": "Brush Tool", "default": "B"},
	"clip": {"name": "Clip Tool", "default": "C"},
	"vertex": {"name": "Vertex Tool", "default": "V"},
	"edge": {"name": "Edge Tool", "default": "E"},
	"face": {"name": "Face Tool", "default": "F"},
	"rotate": {"name": "Rotate Tool", "default": "R"},
	"scale": {"name": "Scale Tool", "default": "T"},
	"shear": {"name": "Shear Tool", "default": "G"},
	# Selection operations.
	"duplicate": {"name": "Duplicate Selection", "default": "Ctrl+D"},
	"duplicate_linked": {"name": "Linked Duplicate", "default": "Ctrl+Shift+D"},
	"flip_h": {"name": "Flip Horizontally", "default": "Ctrl+F"},
	"flip_v": {"name": "Flip Vertically", "default": "Ctrl+Alt+F"},
	# Sticky options.
	"texture_lock": {"name": "Toggle Texture Lock", "default": ""},
	"uv_lock": {"name": "Toggle UV Lock", "default": "U"},
}


## State the defaults. Called once per [code]_enter_tree[/code]; see the class docs for why running it
## again cannot undo a rebind.
##
## [b]There is deliberately no unregister on the way out, and removing one would be a bug.[/b]
## [EditorSettings] SAVES the shortcut map it is holding, so dropping these in `_exit_tree` — which
## also runs on editor shutdown — would throw away the user's rebinds on the way past. Left alone they
## keep themselves tidy: a shortcut restored from saved settings carries no `original` meta until a
## plugin states its default again, and the Shortcuts tab lists only shortcuts that have one. So with
## the addon disabled the section simply does not appear after a restart, while every rebind waits
## intact for it to come back.
static func register() -> void:
	var es := EditorInterface.get_editor_settings()
	for id in BINDINGS:
		var shortcut := Shortcut.new()
		# The tab falls back to the path's second slice when this is empty, which would list these as
		# "flip_h" and "uv_lock".
		shortcut.resource_name = BINDINGS[id]["name"]
		var chord: String = BINDINGS[id]["default"]
		if not chord.is_empty():
			shortcut.events = [_event(chord)]
		es.add_shortcut(PREFIX + id, shortcut)


## The live [Shortcut] for `id` — the user's binding if they changed it, the default otherwise.
static func of(id: String) -> Shortcut:
	return EditorInterface.get_editor_settings().get_shortcut(PREFIX + id)


## Does `event` fire `id` right now? Modifiers must match EXACTLY (Godot's [Shortcut] compares the
## whole modifier mask), which is what keeps `Ctrl+Alt+F` from also firing `Ctrl+F`.
static func matches(id: String, event: InputEvent) -> bool:
	var shortcut := of(id)
	return shortcut != null and shortcut.matches_event(event)


## The binding as a user would write it, for a tooltip. Empty when nothing is bound — a tooltip
## reading "(None)" is worse than a tooltip with no chord in it at all.
static func as_text(id: String) -> String:
	var shortcut := of(id)
	if shortcut == null or shortcut.events.is_empty():
		return ""
	return shortcut.get_as_text()


## A display chord — "B", "Ctrl+D", "Ctrl+Alt+F" — as the event that binds it.
##
## CTRL goes in through [code]command_or_control_autoremap[/code] rather than as a plain
## [code]ctrl_pressed[/code]: that is the engine's own way to say "Ctrl here, Cmd on a Mac", and it
## resolves per platform at match time. The hand-rolled version of this used to be an
## `is_ctrl_pressed() or is_meta_pressed()` test at every call site.
static func _event(chord: String) -> InputEventKey:
	var event := InputEventKey.new()
	for part in chord.split("+"):
		match part.strip_edges().to_lower():
			"ctrl", "cmd", "meta": event.command_or_control_autoremap = true
			"alt": event.alt_pressed = true
			"shift": event.shift_pressed = true
			_: event.keycode = OS.find_keycode_from_string(part.strip_edges())
	return event
