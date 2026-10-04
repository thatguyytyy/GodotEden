extends Node
## Autoload (EdenSteam): multiplayer through Steam (GodotSteam, built into the engine). Worlds stay on SpacetimeDB;
## Steam finds them and carries their traffic, so friends can join without port forwarding:
##   Host   playing a world on this computer opens a Steam lobby for it (name, seed, settings, database) and accepts
##          Steam P2P connections, each piped to its local SpacetimeDB.
##   Friend finds the lobby (the Play screen's "Steam" server) or accepts an invite from the Steam overlay, and plays
##          through a local port: every TCP connection the game opens to http://127.0.0.1:<port> (its HTTP calls and
##          its WebSocket) becomes a Steam P2P connection to the host, relayed by Steam.
## Off (and the game unchanged) when the engine has no GodotSteam or Steam isn't running. App id 480 is Valve's
## Spacewar test app, shared by every developer: lobbies are tagged so only Eden's are listed.

signal lobbies_found(lobbies: Array)
## A lobby joined through an invite or join_lobby(): EdenSession is set for its world; start the game
signal world_ready_to_join

const APP_ID := 480 # ponytail: Spacewar for testing; the game's own app id once it has one
const LOBBY_TAG := "eden_world"
const VIRTUAL_PORT := 0
const MAX_MEMBERS := 16
## Bytes read from a TCP stream per Steam message (Steam's limit is 512 KB)
const CHUNK := 65536

var steam: Object
var available := false
var lobby_id := 0
## The lobby's world, while hosting: {name, database, seed, settings, port}
var hosting := {}
## Opens a Steam connection to the host for a local TCP connection (a test swaps in a loopback pair)
var open_to_host: Callable

## Steam connection -> {tcp: StreamPeerTCP, up: bool (Steam side connected), to_tcp, to_steam: PackedByteArray}
var _links := {}
var _listen := 0
var _proxy: TCPServer
var _proxy_host := 0
var _joining := 0
## EDEN_STEAM_DEBUG=1: log the tunnel's connections and bytes
var _debug := OS.has_environment("EDEN_STEAM_DEBUG")


func _ready() -> void:
	if not Engine.has_singleton("Steam"):
		return
	steam = Engine.get_singleton("Steam")
	var r: Dictionary = steam.steamInitEx(APP_ID, false)
	if int(r.get("status", -1)) != 0:
		print("EdenSteam: off (%s)" % r.get("verbal", "Steam not running"))
		return
	available = true
	print("EdenSteam: on as %s" % steam.getPersonaName())
	steam.initRelayNetworkAccess()
	steam.network_connection_status_changed.connect(_on_connection)
	steam.lobby_created.connect(_on_lobby_created)
	steam.lobby_match_list.connect(_on_lobby_list)
	steam.lobby_joined.connect(_on_lobby_joined)
	steam.join_requested.connect(func(lobby: int, _friend: int): join_lobby(lobby)) # a lobby invite
	steam.join_game_requested.connect(func(_friend: int, connect: String): # "Join game" on a friend
		if connect.begins_with("+connect_lobby "):
			join_lobby(int(connect.trim_prefix("+connect_lobby "))))
	open_to_host = func(host: int) -> int: return steam.connectP2P(host, VIRTUAL_PORT, {})
	# Launched from a Steam invite while the game wasn't running: "+connect_lobby <id>"
	var args := OS.get_cmdline_args()
	var i := args.find("+connect_lobby")
	if i >= 0 and i + 1 < args.size():
		join_lobby.call_deferred(int(args[i + 1]))


func _process(_delta: float) -> void:
	if not available:
		return
	steam.run_callbacks()
	_accept_local()
	_pump()


static func k(name: String) -> int:
	return ClassDB.class_get_integer_constant("Steam", name)


# ------------------------------------------------------------------------------------------------------------
# Hosting

## Opens a lobby for the world being played on this computer (the SpacetimeDB on local `port`)
func host(world: Dictionary) -> void:
	if not available or not hosting.is_empty():
		return
	hosting = world
	# ponytail: public (listable) so testers find it; friends-only once invites are the only way in
	steam.createLobby(k("LOBBY_TYPE_PUBLIC"), MAX_MEMBERS)


func _on_lobby_created(result: int, lobby: int) -> void:
	if result != 1 or hosting.is_empty(): # k_EResultOK
		print("EdenSteam: couldn't create a lobby (result %d)" % result)
		return
	lobby_id = lobby
	steam.setLobbyData(lobby, LOBBY_TAG, "1")
	steam.setLobbyData(lobby, "name", str(hosting.name))
	steam.setLobbyData(lobby, "database", str(hosting.database))
	steam.setLobbyData(lobby, "seed", str(hosting.seed))
	steam.setLobbyData(lobby, "settings", JSON.stringify(hosting.settings))
	steam.setLobbyData(lobby, "host", steam.getPersonaName())
	steam.setRichPresence("connect", "+connect_lobby %d" % lobby)
	_listen = steam.createListenSocketP2P(VIRTUAL_PORT, {})
	print("EdenSteam: hosting %s in lobby %d" % [hosting.name, lobby])


## The Steam overlay's invite dialog for the current lobby
func invite_friends() -> void:
	if available and lobby_id != 0:
		steam.activateGameOverlayInviteDialog(lobby_id)


# ------------------------------------------------------------------------------------------------------------
# Finding and joining

## Eden lobbies anywhere (lobbies_found gets [{lobby, name, host, database, seed, settings, members}])
func find_lobbies() -> void:
	if not available:
		lobbies_found.emit([])
		return
	steam.addRequestLobbyListStringFilter(LOBBY_TAG, "1", k("LOBBY_COMPARISON_EQUAL"))
	steam.addRequestLobbyListDistanceFilter(k("LOBBY_DISTANCE_FILTER_WORLDWIDE"))
	steam.requestLobbyList()


func _on_lobby_list(lobbies: Array) -> void:
	var out := []
	for lobby in lobbies:
		out.append(lobby_info(lobby))
	lobbies_found.emit(out)


func lobby_info(lobby: int) -> Dictionary:
	return {"lobby": lobby, "name": steam.getLobbyData(lobby, "name"), "host": steam.getLobbyData(lobby, "host"),
			"database": steam.getLobbyData(lobby, "database"), "seed": int(steam.getLobbyData(lobby, "seed")),
			"settings": EdenWorldSettings.from_json(steam.getLobbyData(lobby, "settings")),
			"members": steam.getNumLobbyMembers(lobby)}


func join_lobby(lobby: int) -> void:
	if available and lobby != lobby_id:
		_joining = lobby
		steam.joinLobby(lobby)


func _on_lobby_joined(lobby: int, _permissions: int, _locked: bool, response: int) -> void:
	if lobby != _joining:
		return # (our own lobby, as its host)
	_joining = 0
	if response != 1: # k_EChatRoomEnterResponseSuccess
		print("EdenSteam: couldn't join lobby %d (response %d)" % [lobby, response])
		return
	lobby_id = lobby
	var info := lobby_info(lobby)
	var url := tunnel_to(steam.getLobbyOwner(lobby))
	EdenSession.play_online(url, info.database, info.name, info.seed, info.settings)
	world_ready_to_join.emit()


## Starts the local end of the tunnel to a host and returns its URL. The port is the same each time for a host, so
## the SpacetimeDB identity saved for that URL (EdenWorlds.token) still matches their server.
func tunnel_to(host: int) -> String:
	_close_tunnel()
	_proxy_host = host
	var port := 41000 + host % 10000
	_proxy = TCPServer.new()
	if _proxy.listen(port, "127.0.0.1") != OK:
		push_error("EdenSteam: local port %d is taken" % port)
	return "http://127.0.0.1:%d" % port


## Leaves the lobby and closes every connection (back at the main menu)
func leave() -> void:
	if not available:
		return
	_close_tunnel()
	for conn in _links.keys():
		_drop(conn)
	if _listen != 0:
		steam.closeListenSocket(_listen)
		_listen = 0
	if lobby_id != 0:
		steam.leaveLobby(lobby_id)
		steam.clearRichPresence()
		lobby_id = 0
	hosting = {}


func _close_tunnel() -> void:
	if _proxy:
		_proxy.stop()
		_proxy = null
	_proxy_host = 0


# ------------------------------------------------------------------------------------------------------------
# The tunnel: one Steam connection per TCP connection, bytes copied both ways

## Links a Steam connection to a TCP stream (bytes for Steam wait until the connection is up)
func link(conn: int, tcp: StreamPeerTCP) -> void:
	var info: Dictionary = steam.getConnectionInfo(conn)
	var up := int(info.get("connection_state", 0)) == k("CONNECTION_STATE_CONNECTED")
	_links[conn] = {"tcp": tcp, "up": up, "to_tcp": PackedByteArray(), "to_steam": PackedByteArray()}
	if _debug:
		print("EdenSteam: link %d (up %s) %s" % [conn, up, info])


func _accept_local() -> void:
	while _proxy and _proxy.is_connection_available():
		var tcp := _proxy.take_connection()
		var conn: int = open_to_host.call(_proxy_host)
		if conn == 0:
			tcp.disconnect_from_host()
		else:
			link(conn, tcp)


func _on_connection(conn: int, info: Dictionary, _old_state: int) -> void:
	var state := int(info.connection_state)
	if state == k("CONNECTION_STATE_CONNECTING") and _listen != 0 and int(info.listen_socket) == _listen:
		steam.acceptConnection(conn) # a friend of the lobby: pipe it to our SpacetimeDB
		var tcp := StreamPeerTCP.new()
		tcp.connect_to_host("127.0.0.1", int(hosting.port))
		link(conn, tcp)
	elif state == k("CONNECTION_STATE_CONNECTED") and _links.has(conn):
		_links[conn].up = true
	elif state == k("CONNECTION_STATE_CLOSED_BY_PEER") or state == k("CONNECTION_STATE_PROBLEM_DETECTED_LOCALLY"):
		_drop(conn)


func _pump() -> void:
	var reliable := k("NETWORKING_SEND_RELIABLE")
	for conn in _links.keys():
		var l: Dictionary = _links[conn]
		var tcp: StreamPeerTCP = l.tcp
		tcp.poll()
		var status := tcp.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			_drop(conn)
			continue
		var tcp_up := status == StreamPeerTCP.STATUS_CONNECTED
		# TCP -> Steam
		if tcp_up and tcp.get_available_bytes() > 0:
			var got: Array = tcp.get_partial_data(mini(tcp.get_available_bytes(), CHUNK))
			if got[0] == OK:
				l.to_steam.append_array(got[1])
		if l.up and not l.to_steam.is_empty():
			var r: Dictionary = steam.sendMessageToConnection(conn, l.to_steam, reliable)
			if _debug:
				print("EdenSteam: %d -> steam %d bytes: %s" % [conn, l.to_steam.size(), r])
			if int(r.get("result", 1)) == 1:
				l.to_steam = PackedByteArray()
		# Steam -> TCP
		for m in steam.receiveMessagesOnConnection(conn, 64):
			l.to_tcp.append_array(m.payload)
			if _debug:
				print("EdenSteam: %d <- steam %d bytes (tcp status %d)" % [conn, m.payload.size(), status])
		if tcp_up and not l.to_tcp.is_empty():
			var sent: Array = tcp.put_partial_data(l.to_tcp)
			if sent[0] == OK:
				l.to_tcp = l.to_tcp.slice(sent[1])


func _drop(conn: int) -> void:
	if not _links.has(conn):
		steam.closeConnection(conn, 0, "", false) # (one we never linked, e.g. refused)
		return
	if _debug:
		print("EdenSteam: drop %d" % conn)
	(_links[conn].tcp as StreamPeerTCP).disconnect_from_host()
	_links.erase(conn)
	steam.closeConnection(conn, 0, "", false)
