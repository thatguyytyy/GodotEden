# Eden audio

Drop files in (.ogg, .mp3 or .wav); `menu/eden_music.gd` (autoload `EdenMusic`) finds them, no setup needed.

- `music/menu/`  main menu song (loops; one picked at random if there are several)
- `music/game/`  in-game songs, played in random order with a pause between them
- `sfx/button_hover.*` and `sfx/button_click.*`  played for every button in the UI

Empty folder = silence for that part. Volumes and the pause between songs are constants at the top of `eden_music.gd`.
