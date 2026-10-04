class_name EdenSession
## The world the main menu sent the game into; EdenPlayer reads it when the play scene starts. Not active when a
## scene is run straight from the editor (the scene's own settings are used then).

static var active := false
## No server: a sandbox that isn't saved
static var offline := true
## The SpacetimeDB server (http base, e.g. http://127.0.0.1:3180) and the world's database on it
static var server := ""
static var database := ""
static var world_name := ""
## The planet generator's seed for this world
static var seed := 12345
## What kind of planet it is (EdenWorldSettings: template, temperature, rainfall)
static var settings := EdenWorldSettings.DEFAULTS
## Why the game came back to the main menu by itself (the host left...), shown there once
static var notice := ""


static func play_online(p_server: String, p_database: String, p_name: String, p_seed: int,
		p_settings := EdenWorldSettings.DEFAULTS) -> void:
	active = true
	offline = false
	server = p_server
	database = p_database
	world_name = p_name
	seed = p_seed
	settings = EdenWorldSettings.normalized(p_settings)


## A single-player world: no server, nothing saved
static func play_offline(p_name := "Single Player", p_seed := 12345, p_settings := EdenWorldSettings.DEFAULTS) -> void:
	active = true
	offline = true
	server = ""
	database = ""
	world_name = p_name
	seed = p_seed
	settings = EdenWorldSettings.normalized(p_settings)


## The WebSocket URL for the server (ws:// for http://, wss:// for https://)
static func ws_url() -> String:
	return server.replace("https://", "wss://").replace("http://", "ws://")
