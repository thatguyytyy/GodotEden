extends Node
## Autoload (EdenMusic): the main menu song, the songs that play at random in the game, and the button sounds.
## Nothing to configure: drop audio files (.ogg, .mp3 or .wav) in these folders and they are picked up.
##   res://audio/music/menu/   main menu song (one is picked at random if there are several)
##   res://audio/music/game/   in-game songs: played in random order, a pause between them, never the same twice
##   res://audio/sfx/          button_hover.* and button_click.*, played for every button in the game's UI
## With no files in a folder, that part is simply silent.

const MUSIC_DIR := "res://audio/music"
const SFX_DIR := "res://audio/sfx"
const EXTENSIONS := ["ogg", "mp3", "wav"]
const FADE := 1.5
## Seconds of quiet between in-game songs (random within)
const GAP := Vector2(6.0, 25.0)
const MUSIC_DB := -6.0
const SFX_DB := -8.0

var _music: AudioStreamPlayer
var _sfx: AudioStreamPlayer
var _hover: AudioStream
var _click: AudioStream
var _mode := ""
var _last := ""
var _tween: Tween


func _ready() -> void:
	if "--server" in OS.get_cmdline_user_args(): # the dedicated server (server/eden_server.gd) plays nothing
		set_process(false)
		return
	_music = AudioStreamPlayer.new()
	_music.volume_db = MUSIC_DB
	_music.finished.connect(_on_finished)
	add_child(_music)
	_sfx = AudioStreamPlayer.new()
	_sfx.volume_db = SFX_DB
	var poly := AudioStreamPolyphonic.new()
	poly.polyphony = 4
	_sfx.stream = poly
	add_child(_sfx)
	_sfx.play()
	_hover = _find(SFX_DIR, "button_hover")
	_click = _find(SFX_DIR, "button_click")
	get_tree().node_added.connect(_on_node_added)


func play_menu() -> void:
	_switch("menu")


func play_game() -> void:
	_switch("game")


func _switch(mode: String) -> void:
	if mode == _mode:
		return
	_mode = mode
	if _tween:
		_tween.kill()
	if _music.playing:
		_tween = create_tween()
		_tween.tween_property(_music, "volume_db", -60.0, FADE)
		_tween.tween_callback(_start_next.bind(mode))
	else:
		_start_next(mode)


func _start_next(mode: String) -> void:
	if mode != _mode:
		return
	_music.stop()
	var song := _pick(mode)
	if song == "":
		return
	_last = song
	var stream := load(song) as AudioStream
	if stream == null:
		return
	if mode == "menu": # the menu song loops
		if stream is AudioStreamOggVorbis or stream is AudioStreamMP3:
			stream.loop = true
		elif stream is AudioStreamWAV:
			stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
			stream.loop_end = stream.get_length() * stream.mix_rate
	_music.stream = stream
	_music.volume_db = -60.0
	_music.play()
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_music, "volume_db", MUSIC_DB, FADE)


## A song of the mode's folder, at random, not the one just played (unless it is the only one)
func _pick(mode: String) -> String:
	var songs := _files(MUSIC_DIR.path_join(mode))
	if songs.size() > 1:
		songs.erase(_last)
	return songs[randi() % songs.size()] if not songs.is_empty() else ""


func _on_finished() -> void:
	if _mode != "game":
		return # (the menu song loops)
	var mode := _mode
	await get_tree().create_timer(randf_range(GAP.x, GAP.y)).timeout
	if _mode == mode and not _music.playing:
		_start_next(mode)


# ------------------------------------------------------------------------------------------------------------
# Button sounds

func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		node.mouse_entered.connect(_play_sfx.bind(_hover, node))
		node.pressed.connect(_play_sfx.bind(_click, node))


func _play_sfx(stream: AudioStream, button: BaseButton) -> void:
	if stream == null or button.disabled:
		return
	(_sfx.get_stream_playback() as AudioStreamPlaybackPolyphonic).play_stream(stream)


# ------------------------------------------------------------------------------------------------------------

## Audio files in a folder (an exported build lists them with .import or .remap on the end)
static func _files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir): # an empty folder (sfx/) isn't exported
		return out
	for f in DirAccess.get_files_at(dir):
		f = f.trim_suffix(".import").trim_suffix(".remap")
		if f.get_extension().to_lower() in EXTENSIONS and not out.has(dir.path_join(f)):
			out.append(dir.path_join(f))
	return out


## The file in a folder named `base`.<any audio extension>, loaded, or null
static func _find(dir: String, base: String) -> AudioStream:
	for f in _files(dir):
		if f.get_file().get_basename() == base:
			return load(f) as AudioStream
	return null
