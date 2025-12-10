extends Control
class_name SoundCloudPlayer

signal status_changed(message: String)
signal error_occurred(message: String)
signal track_started(title: String)

const CLIENT_ID = "did you think I'd leave the client id here ? well get outta here if so" 
const BASE_URL = "https://api-v2.soundcloud.com"
const PLAYLIST_FILE = "user://my_playlists_v2.json"

@onready var http_api: HTTPRequest = %HttpApi
@onready var http_stream_resolver: HTTPRequest = %HttpStreamResolver
@onready var http_downloader: HTTPRequest = %HttpDownloader
@onready var audio_player: AudioStreamPlayer = %AudioStreamPlayer

@onready var tab_container: TabContainer = %TabContainer

@onready var input_search: LineEdit = %InputSearch
@onready var btn_search: Button = %BtnSearch
@onready var list_results: ItemList = %ListResults
@onready var btn_load_more: Button = %BtnLoadMore
@onready var btn_view_artist: Button = %BtnViewArtist
@onready var btn_add_to: Button = %BtnAddTo
@onready var popup_add_to_playlist: PopupMenu = %PopupAddToPlaylist

@onready var option_playlist_select: OptionButton = %OptionPlaylistSelect
@onready var input_new_playlist: LineEdit = %InputNewPlaylist
@onready var btn_create_playlist: Button = %BtnCreatePlaylist
@onready var btn_delete_playlist: Button = %BtnDeletePlaylist
@onready var btn_share: Button = %BtnShare
@onready var btn_import: Button = %BtnImport
@onready var btn_add_local: Button = %BtnAddLocal
@onready var list_playlist: ItemList = %ListPlaylist
@onready var btn_delete_track: Button = %BtnDeleteTrack
@onready var popup_import_dialog: ConfirmationDialog = %PopupImportDialog
@onready var input_import_code: TextEdit = %InputImportCode
@onready var file_dialog_local: FileDialog = %FileDialogLocal

@onready var btn_prev: Button = %BtnPrev
@onready var btn_play_pause: Button = %BtnPlayPause
@onready var btn_next: Button = %BtnNext
@onready var btn_loop: Button = %BtnLoop
@onready var btn_annotations: Button = %BtnAnnotations
@onready var lbl_time: Label = %LblTime
@onready var slider_seek: HSlider = %SliderSeek
@onready var slider_volume: HSlider = %SliderVolume
@onready var lbl_speed: Label = %LblSpeed
@onready var slider_speed: HSlider = %SliderSpeed
@onready var status_label: Label = %StatusLabel

@onready var window_annotations: Window = %WindowAnnotations
@onready var input_note: TextEdit = %InputNote
@onready var btn_save_note: Button = %BtnSaveNote
@onready var input_cue_time: LineEdit = %InputCueTime
@onready var btn_get_time: Button = %BtnGetTime
@onready var input_cue_label: LineEdit = %InputCueLabel
@onready var btn_add_cue: Button = %BtnAddCue
@onready var list_cues: ItemList = %ListCues
@onready var btn_del_cue: Button = %BtnDelCue

var current_query: String = ""
var current_offset: int = 0
var current_track_metadata: Dictionary = {} 
var current_playlist_entry_ref: Dictionary = {} 
var expected_duration_ms: int = 0

var playlists_data: Dictionary = {}	
var current_viewed_playlist_name: String = "Favoris"
var current_playing_context: String = ""	

enum LoopMode { DISABLED, ENABLED }	
var current_loop_mode: LoopMode = LoopMode.DISABLED

var current_playlist_index: int = -1	
var current_search_index: int = -1	
var is_seeking: bool = false

func _ready():
	btn_search.pressed.connect(func(): _on_search_submitted(input_search.text))
	btn_add_local.pressed.connect(func(): file_dialog_local.popup_centered())
	_update_loop_button_text()
	slider_seek.drag_started.connect(func(): is_seeking = true)
	window_annotations.close_requested.connect(func(): window_annotations.hide())
	btn_get_time.pressed.connect(func(): input_cue_time.text = str(int(audio_player.get_playback_position())))

	_load_playlists_data()
	
	audio_player.volume_db = linear_to_db(slider_volume.value)
	
	await get_tree().create_timer(0.2).timeout
	if not FileAccess.file_exists(volume_saving_path):
		pass 
	else:
		var file = FileAccess.open(volume_saving_path, FileAccess.READ)
		
		if file:
			var json_string = file.get_as_text()
			file.close()
			var json = JSON.new()
			var error = json.parse(json_string)
			if error == OK:
				%SliderVolume.value = json.get_data()
			else:
				print("Erreur JSON, ", json.get_error_line())
		else:
			print("Erreur, ", volume_saving_path)
	_emit_status("Bienvenue.")

func _process(_delta):
	if audio_player.playing and not is_seeking:
		var current = audio_player.get_playback_position()
		var total = audio_player.stream.get_length() if audio_player.stream else 0.0
		
		if total > 0:
			slider_seek.max_value = total
			slider_seek.value = current
			lbl_time.text = _format_time(current) + " / " + _format_time(total)
		else:
			slider_seek.value = 0
			lbl_time.text = "0:00 / 0:00"

func _on_local_files_selected(paths: PackedStringArray):
	for path in paths:
		var file_name = path.get_file()
		var local_track = {
			"type": "LOCAL",
			"title": file_name,
			"artist": "Local File",
			"path": path,
			"track_id": path.hash(),
			"duration": 0,
			"user_data": {}
		}
		playlists_data[current_viewed_playlist_name].append(local_track)
	
	_save_playlists_data()
	_emit_status(str(paths.size()) + " fichier(s) locaux ajoutés.")

func _open_annotation_window():
	if current_playlist_entry_ref.is_empty():
		_emit_status("Impossible d'annoter : Piste non sauvegardée dans une playlist")
		return
	window_annotations.popup_centered()
	_refresh_annotation_ui()

func _refresh_annotation_ui():
	var user_data = current_playlist_entry_ref.get("user_data", {})
	input_note.text = user_data.get("note", "")
	list_cues.clear()
	var cues = user_data.get("cues", [])
	cues.sort_custom(func(a, b): return a["time"] < b["time"])
	
	for i in range(cues.size()):
		var c = cues[i]
		var txt = _format_time(c["time"]) + " - " + c["label"]
		list_cues.add_item(txt)
		list_cues.set_item_metadata(i, c)

func _save_current_annotation():
	if current_playlist_entry_ref.is_empty(): return
	if not current_playlist_entry_ref.has("user_data"):
		current_playlist_entry_ref["user_data"] = {}
	current_playlist_entry_ref["user_data"]["note"] = input_note.text
	_save_playlists_data()
	_emit_status("Note sauvegardée.")

func _add_cue_point():
	if current_playlist_entry_ref.is_empty(): return
	var t = float(input_cue_time.text)
	var l = input_cue_label.text
	if l == "": l = "Marqueur"
	
	if not current_playlist_entry_ref.has("user_data"): current_playlist_entry_ref["user_data"] = {}
	var user_data = current_playlist_entry_ref["user_data"]
	if not user_data.has("cues"): user_data["cues"] = []
	user_data["cues"].append({"time": t, "label": l})
	
	input_cue_label.text = ""
	input_cue_time.text = ""
	_save_playlists_data()
	_refresh_annotation_ui()

func _on_cue_activated(index: int):
	var meta = list_cues.get_item_metadata(index)
	audio_player.seek(meta["time"])
	_emit_status("Saut vers : " + meta["label"])

func _delete_selected_cue():
	if list_cues.get_selected_items().is_empty() or current_playlist_entry_ref.is_empty(): return
	var idx = list_cues.get_selected_items()[0]
	var meta = list_cues.get_item_metadata(idx)
	var cues = current_playlist_entry_ref["user_data"]["cues"]
	cues.erase(meta)
	_save_playlists_data()
	_refresh_annotation_ui()

func _delete_current_playlist():
	if current_viewed_playlist_name == "Favoris":
		_emit_status("Impossible de supprimer 'Favoris'.")
		return
	if playlists_data.has(current_viewed_playlist_name):
		playlists_data.erase(current_viewed_playlist_name)
		current_viewed_playlist_name = playlists_data.keys()[0]
		_save_playlists_data()
		_emit_status("Playlist supprimée.")

func _share_current_playlist():
	var tracks = playlists_data.get(current_viewed_playlist_name, [])
	if tracks.is_empty():
		_emit_status("Playlist vide.")
		return
	var export_data = { "name": current_viewed_playlist_name, "tracks": tracks }
	var encoded_code = Marshalls.utf8_to_base64(JSON.stringify(export_data))
	DisplayServer.clipboard_set(encoded_code)
	_emit_status("Code copié dans le presse-papier !")
	OS.alert("Code copié dans le presse-papier !")

func _open_import_popup():
	input_import_code.text = ""
	popup_import_dialog.popup_centered()

func _confirm_import_playlist():
	var code = input_import_code.text.strip_edges()
	if code == "": return
	var json_str = Marshalls.base64_to_utf8(code)
	var json = JSON.new()
	if json.parse(json_str) != OK:
		_emit_error("Code corrompu.")
		return
	var data = json.get_data()
	if not (data is Dictionary and data.has("name") and data.has("tracks")):
		_emit_error("Format invalide.")
		return
	var new_name = data["name"]
	if playlists_data.has(new_name): new_name += " (Import " + str(randi()%100) + ")"
	playlists_data[new_name] = data["tracks"]
	_save_playlists_data()
	current_viewed_playlist_name = new_name
	_refresh_playlist_ui()
	_emit_status("Import réussi.")

func _load_playlists_data():
	playlists_data = { "Favoris": [] }	
	if FileAccess.file_exists(PLAYLIST_FILE):
		var file = FileAccess.open(PLAYLIST_FILE, FileAccess.READ)
		var json = JSON.new()
		if json.parse(file.get_as_text()) == OK:
			var data = json.get_data()
			if data is Dictionary: playlists_data = data
	if not playlists_data.has(current_viewed_playlist_name):
		current_viewed_playlist_name = playlists_data.keys()[0]
	_refresh_playlist_ui()

func _save_playlists_data():
	var file = FileAccess.open(PLAYLIST_FILE, FileAccess.WRITE)
	file.store_string(JSON.stringify(playlists_data, "\t"))
	file.close()
	_refresh_playlist_ui()

func _refresh_playlist_ui():
	option_playlist_select.clear()
	var keys = playlists_data.keys()
	var selected_idx = 0
	for i in range(keys.size()):
		option_playlist_select.add_item(keys[i])
		if keys[i] == current_viewed_playlist_name: selected_idx = i
	option_playlist_select.select(selected_idx)
	
	list_playlist.clear()
	var tracks = playlists_data.get(current_viewed_playlist_name, [])
	if tracks.is_empty():
		list_playlist.add_item("Playlist vide.")
	else:
		for track in tracks:
			var txt = ""
			var type = track.get("type", "SC")
			var note_indicator = ""
			if track.get("user_data", {}).get("note", "") != "":
				note_indicator = " 📝"
			if type == "LOCAL":
				txt = "📁 " + track.get("title", "Fichier") + note_indicator
			else:
				txt = track.get("title", "???") + " - " + track.get("artist", "???") + note_indicator
			var idx = list_playlist.add_item(txt)
			list_playlist.set_item_metadata(idx, track)

func _create_new_playlist():
	var namee = input_new_playlist.text.strip_edges()
	if namee == "" or playlists_data.has(name): return
	playlists_data[namee] = []
	current_viewed_playlist_name = namee
	input_new_playlist.text = ""
	_save_playlists_data()
	_emit_status("Playlist '" + namee + "' créée.")

func _on_playlist_view_changed(index: int):
	current_viewed_playlist_name = option_playlist_select.get_item_text(index)
	_refresh_playlist_ui()

func _delete_selected_track():
	if list_playlist.get_selected_items().is_empty(): return
	var idx = list_playlist.get_selected_items()[0]
	var tracks = playlists_data.get(current_viewed_playlist_name, [])
	if tracks.size() > idx:
		tracks.remove_at(idx)
		_save_playlists_data()
		_emit_status("Titre supprimé.")

func _on_add_playlist_pressed():
	if current_track_metadata.is_empty():
		_emit_status("Aucune piste chargée à ajouter.")
		return
	popup_add_to_playlist.clear()
	var keys = playlists_data.keys()
	var current_track_id = current_track_metadata.get("id")
	if current_track_id == null: current_track_id = current_track_metadata.get("track_id")
	
	for i in range(keys.size()):
		var playlist_name = keys[i]
		var tracks_in_playlist = playlists_data.get(playlist_name, [])
		var is_in_playlist = false
		for track in tracks_in_playlist:
			if track.get("track_id") == current_track_id or (track.has("id") and track.id == current_track_id):
				is_in_playlist = true
				break
		var display_name = ("[✅] " if is_in_playlist else "[ ] ") + playlist_name
		popup_add_to_playlist.add_item(display_name, i)
	popup_add_to_playlist.show()

func _on_add_to_playlist_confirm(id: int):
	var target = playlists_data.keys()[id]
	var new_entry = {
		"type": "SC",
		"title": current_track_metadata.get("title", "Unknown"),
		"artist": current_track_metadata.get("user", {}).get("username", "Unknown"),
		"track_id": current_track_metadata.get("id"),
		"permalink_url": current_track_metadata.get("permalink_url"),
		"duration": current_track_metadata.get("duration", 0),
		"user_data": {}
	}
	
	for t in playlists_data[target]:
		if t.get("track_id") == new_entry["track_id"]: return
	
	playlists_data[target].append(new_entry)
	_save_playlists_data()
	_emit_status("Ajouté à : " + target)

func _on_play_pause_pressed():
	if audio_player.stream == null: return
	if audio_player.playing:
		audio_player.stream_paused = true
		btn_play_pause.text = "▶"
	else:
		if audio_player.stream_paused: audio_player.stream_paused = false
		else: audio_player.play()
		btn_play_pause.text = "⏸"

func _on_next_pressed():
	_emit_status("⏭ Suivant...")
	if current_playing_context == "SEARCH": _play_next_search_track()
	else: _play_next_playlist_track()

func _on_prev_pressed():
	if current_playing_context == "SEARCH":
		if current_search_index > 0:
			current_search_index -= 1
			_on_search_item_selected(current_search_index)
	elif current_playing_context != "":
		if current_playlist_index > 0:
			current_playlist_index -= 1
			_play_playlist_track_at_index(current_playlist_index)
const volume_saving_path = "user://last_volume.json"
func _on_volume_changed(value):
	audio_player.volume_db = linear_to_db(value)
	var json_string = JSON.stringify(value)
	
	var file = FileAccess.open(volume_saving_path, FileAccess.WRITE)
	
	if file:
		file.store_string(json_string)
		file.close()
	else:
		push_error("Erreur : Impossible d'ouvrir le fichier pour écriture à ", volume_saving_path)

func _on_speed_changed(value):
	audio_player.pitch_scale = value
	lbl_speed.text = "Vitesse: " + str(value) + "x"

func _on_seek_drag_ended(value_changed: bool):
	if value_changed: audio_player.seek(slider_seek.value)
	is_seeking = false

func _format_time(seconds: float) -> String:
	var m = int(seconds / 60)
	var s = int(seconds) % 60
	return "%d:%02d" % [m, s]

func _on_search_item_selected(index: int):
	var track = list_results.get_item_metadata(index)
	current_search_index = index
	current_playing_context = "SEARCH"
	current_playlist_index = -1
	current_playlist_entry_ref = {} 
	_start_stream_resolution(track)

func _on_playlist_item_selected(index: int):
	current_playing_context = current_viewed_playlist_name	
	current_playlist_index = index
	current_search_index = -1
	_play_playlist_track_at_index(index)

func _play_playlist_track_at_index(index: int):
	var tracks = playlists_data.get(current_playing_context, [])
	if index < 0 or index >= tracks.size(): return
	
	var track_info = tracks[index]
	current_playlist_index = index
	
	current_playlist_entry_ref = track_info
	
	if window_annotations.visible: _refresh_annotation_ui()
	
	var type = track_info.get("type", "SC") 
	
	if type == "LOCAL":
		_play_local_file(track_info)
	else:
		if not track_info.has("permalink_url"):
			_emit_error("Lien manquant.")
			return
		_emit_status("🎵 Chargement de la musique : [" + current_playing_context + "] : " + track_info["title"])
		_resolve_permalink_url(track_info["permalink_url"])

func _play_local_file(track_info: Dictionary):
	var path = track_info.get("path", "")
	if not FileAccess.file_exists(path):
		_emit_error("Fichier introuvable : " + path)
		_on_next_pressed()
		return
		
	_emit_status("📁 Local : " + track_info["title"])
	
	var file = FileAccess.open(path, FileAccess.READ)
	var bytes = file.get_buffer(file.get_length())
	
	var stream = null
	if path.ends_with(".mp3"):
		stream = AudioStreamMP3.new()
		stream.data = bytes
	elif path.ends_with(".ogg"):
		stream = AudioStreamOggVorbis.load_from_file(path)
	
	if stream:
		audio_player.stop()
		audio_player.stream = stream
		audio_player.play()
		btn_play_pause.text = "⏸"
		
		current_track_metadata = {
			"title": track_info["title"],
			"id": track_info["track_id"],
			"duration": stream.get_length() * 1000
		}
		track_started.emit(track_info["title"])
	else:
		_emit_error("Format non supporté.")

@warning_ignore("unused_parameter")
func _play_next_playlist_track(force_start: bool = false):
	var tracks = playlists_data.get(current_playing_context, [])
	if tracks.is_empty(): return
	var next_idx = current_playlist_index + 1
	if next_idx >= tracks.size():
		_emit_status("Fin de la playlist.")
		return
	_play_playlist_track_at_index(next_idx)

func _play_next_search_track():
	if list_results.item_count == 0: return
	var next_idx = current_search_index + 1
	if next_idx >= list_results.item_count:
		_emit_status("Fin des résultats.")
		return
	list_results.select(next_idx)
	list_results.ensure_current_is_visible()
	var track = list_results.get_item_metadata(next_idx)
	current_search_index = next_idx
	_start_stream_resolution(track)

func _on_loop_button_pressed():
	@warning_ignore("int_as_enum_without_cast")
	current_loop_mode = (current_loop_mode + 1) % LoopMode.size()
	_update_loop_button_text()

func _update_loop_button_text():
	match current_loop_mode:
		LoopMode.DISABLED: btn_loop.text = "🔁 Désactivé"
		LoopMode.ENABLED: btn_loop.text = "🔂 Activé"

func _on_track_finished():
	btn_play_pause.text = "▶"
	if current_loop_mode == LoopMode.ENABLED:
		audio_player.play()
		btn_play_pause.text = "⏸"
		return
	_on_next_pressed()

func _on_search_submitted(text: String):
	if text.strip_edges() == "": return
	current_query = text
	current_offset = 0
	list_results.clear()
	_fetch_search_results()

func _on_load_more_pressed():
	current_offset += 10
	_fetch_search_results()

func _fetch_search_results():
	_emit_status("🔍 Recherche...")
	btn_load_more.disabled = true
	var params = "q=" + current_query.uri_encode() + "&client_id=" + CLIENT_ID + "&limit=10&offset=" + str(current_offset)
	http_api.request(BASE_URL + "/search/tracks?" + params)

func _on_view_artist_profile_pressed():
	if current_track_metadata.is_empty(): return
	var user_data = current_track_metadata.get("user", {})
	if user_data.has("id"):
		_fetch_artist_tracks(user_data["id"], user_data.get("username", "Inconnu"))

func _fetch_artist_tracks(user_id: int, username: String):
	_emit_status("Pistes de : " + username)
	current_query = username 
	current_offset = 0
	list_results.clear()
	var url = BASE_URL + "/users/" + str(user_id) + "/tracks?client_id=" + CLIENT_ID + "&limit=50"
	tab_container.current_tab = 0
	btn_load_more.disabled = true 
	http_api.request(url)

@warning_ignore("unused_parameter")
func _on_search_completed(result, response_code, headers, body):
	btn_load_more.disabled = false 
	if response_code != 200: 
		_emit_error("Erreur API : " + str(response_code))
		return
	var json = JSON.new()
	json.parse(body.get_string_from_utf8())
	var data = json.get_data()
	var tracks_list = []
	
	if data is Dictionary and data.has("collection"): tracks_list = data["collection"]
	elif data is Array: tracks_list = data
	else: return

	var tracks_added = 0
	for track in tracks_list:
		var duration_sec = floor(track.get("duration", 0) / 1000.0)
		if duration_sec >= 28 and duration_sec <= 30: continue	
		var title = track.get("title", "Sans titre")
		var user = track.get("user", {}).get("username", "Inconnu")
		var display = title + " - " + user + " (" + _format_time(duration_sec) + ")"
		var idx = list_results.add_item(display)
		list_results.set_item_metadata(idx, track)
		tracks_added += 1

	if tracks_added > 0: _emit_status("Résultats : " + str(tracks_added))
	else: _emit_status("Aucun résultat.")

func _resolve_permalink_url(url: String):
	audio_player.stop()
	var resolve_url = BASE_URL + "/resolve?url=" + url.uri_encode() + "&client_id=" + CLIENT_ID
	if http_api.request_completed.is_connected(_on_search_completed):
		http_api.request_completed.disconnect(_on_search_completed)
	if not http_api.request_completed.is_connected(_on_permalink_resolved):
		http_api.request_completed.connect(_on_permalink_resolved)
	http_api.request(resolve_url)

@warning_ignore("unused_parameter")
func _on_permalink_resolved(result, response_code, headers, body):
	http_api.request_completed.disconnect(_on_permalink_resolved)
	http_api.request_completed.connect(_on_search_completed)
	if response_code != 200:
		_emit_error("Erreur Permalink.")
		_on_next_pressed()	
		return

	var json = JSON.new()
	json.parse(body.get_string_from_utf8())
	var track = json.get_data()
	if track.has("media"): _start_stream_resolution(track)
	else: _on_next_pressed()

func _start_stream_resolution(track: Dictionary):
	audio_player.stop()
	btn_play_pause.text = "⏸"
	current_track_metadata = track
	expected_duration_ms = track.get("duration", 0)
	var best_url = ""
	if track.has("media") and track["media"].has("transcodings"):
		for t in track["media"]["transcodings"]:
			if t["format"]["protocol"] == "progressive" and t["format"]["mime_type"].begins_with("audio/mpeg"):
				best_url = t["url"]	
				break
	if best_url == "":
		_emit_error("Stream introuvable.")
		_on_next_pressed()
		return
	var auth_url = best_url + "?client_id=" + CLIENT_ID
	http_stream_resolver.request(auth_url)

@warning_ignore("unused_parameter")
func _on_stream_resolved(result, response_code, headers, body):
	if response_code != 200:	
		_emit_error("Erreur lien stream.")
		_on_next_pressed()
		return
	var json = JSON.new()
	json.parse(body.get_string_from_utf8())
	var data = json.get_data()
	if data.has("url"): http_downloader.request(data["url"])

@warning_ignore("unused_parameter")
func _on_mp3_downloaded(result, response_code, headers, body):
	if response_code != 200:
		_emit_error("Erreur DL MP3.")
		_on_next_pressed()
		return
	var stream = AudioStreamMP3.new()
	stream.data = body
	if stream.get_length() < 31.0 and expected_duration_ms > 60000:
		_emit_error("Raccourci par l'API ; passage au titre suivant")
		_on_next_pressed()
		return
	audio_player.stream = stream
	audio_player.play()
	btn_play_pause.text = "⏸"
	_emit_status("Lecture : " + current_track_metadata.get("title", ""))
	track_started.emit(current_track_metadata.get("title", ""))

func _create_http_request(callback: String) -> HTTPRequest:
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(Callable(self, callback))
	return http

func _emit_status(msg):
	print(msg)
	if status_label:
		status_label.text = msg
		status_label.tooltip_text = msg
	status_changed.emit(msg)

func _emit_error(msg):
	push_error(msg)
	if status_label:
		status_label.text = "ERR: " + msg
		status_label.tooltip_text = msg
	error_occurred.emit(msg)
