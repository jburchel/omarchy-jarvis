# Jarvis for Omarchy

A voice for whatever AI agent you're running in the terminal — with a way to shut it up.

- **Speaks** with free neural TTS: Edge TTS online, Piper offline, espeak-ng as a last resort.
- **Interrupts**: `jarvis hush` stops playback and drops the queue. Bound to a key, and to your
  dictation toggle so starting to talk silences it.
- **"Hey Jarvis"** wake word (openWakeWord, ~3% CPU): hush → chime → start dictation, hands-free.
  It ends by itself after ~1.8 s of silence (Voxtype then types the text and, with `auto_submit`,
  presses Enter); **"Hey Jarvis, stop"** ends it early — the command words never reach the typed text.
- **Bar widget**: idle / speaking / listening / muted at a glance. Click to mute, right-click to
  hush, middle-click to toggle the wake word.
- **Pronunciation dictionary** so it says "plug-in", not "pluggin".
- **Agent-agnostic**: the core is a CLI (`jarvis say`, `jarvis hush`). Claude Code, Codex,
  Gemini CLI, or anything with hooks can drive it; dictation lands in whichever window is focused.

![Jarvis in the Omarchy bar](preview.png)

## Requirements

- Omarchy (Quickshell shell, Hyprland, PipeWire)
- `python3`, `jq`, `mpv` (or `ffplay` / `pw-play`)
- For the wake word: `pw-record` (PipeWire, already on Omarchy)
- For dictation via wake word: [Voxtype](https://github.com/peteonrails/voxtype) — `omarchy voxtype install`

## Install

```bash
omarchy plugin add https://github.com/jburchel/omarchy-jarvis --enable
~/.config/omarchy/plugins/io.github.jburchel.jarvis/bin/jarvis setup
ln -s ~/.config/omarchy/plugins/io.github.jburchel.jarvis/bin/jarvis ~/.local/bin/jarvis
```

`setup` creates a Python venv at `~/.local/share/jarvis/venv` and installs `edge-tts`, `piper-tts`
and `openwakeword` from `requirements.txt` — every package (transitive ones included) at an exact
version with a verified hash (`pip --require-hashes --only-binary :all:`), so nothing unreviewed can
slip in later. It then downloads the `en_GB-alan-medium` Piper voice (~60 MB) and checks it against
`models.sha256`; the wake-word models ship inside the hash-pinned `openwakeword` wheel and are never
fetched at runtime. Finally it writes `~/.config/jarvis/config.sh` and generates a chime. It does
not touch any other config. Re-run `setup` after updating the plugin to pick up new pins.

Then, optionally:

```bash
jarvis listen enable      # "Hey Jarvis" — installs a systemd --user service (jarvis-listen)
```

For the spoken stop ("Hey Jarvis, stop" / "pause listening" / "that's all") add the filter to
`~/.config/voxtype/config.toml`, then `systemctl --user restart voxtype`:

```toml
[output.post_process]
command = "/path/to/omarchy-jarvis/bin/jarvis-dictation-filter"
timeout_ms = 3000
fallback_on_empty = false   # a dictation that was only the command types nothing
```

A dictation the wake word started ends on its own: once you have spoken, `JARVIS_SILENCE_SECS`
(default 1.5) of quiet stops it, and if nothing is said within `JARVIS_MAX_WAIT_SECS` (default 15)
it is cancelled. Voxtype has its own cap, `max_duration_secs` in its config (120 by default) — raise it if you talk at length. `JARVIS_SILENCE_SECS=0` leaves it to the stop word and the key. Dictations started
from the key are yours to end (key or stop word). Between dictations the daemon ignores everything
but the wake word. The filter also drops whisper's silence hallucinations ("Thanks for watching!",
"you"), so a false wake types nothing.
Word lists: `JARVIS_START_WORDS` / `JARVIS_STOP_WORDS` (regex) in `config.sh`;
`JARVIS_STOP_GRACE` is how long after the stop wake the recording runs on (default 1 s).

Add the widget to your bar if `--enable` didn't place it where you want:

```bash
omarchy bar move io.github.jburchel.jarvis --section right
```

### Keybindings (add to `~/.config/hypr/bindings.lua`)

```lua
o.bind("SUPER + SHIFT + J", "Jarvis hush", "jarvis hush")
-- Route your dictation key through Jarvis so it hushes first (Right Alt shown; use yours):
o.bind("code:108", "Toggle dictation", "jarvis dictate")
```

## Use

| | |
|---|---|
| `printf '%s' "text" \| jarvis say` | speak (queued). The text always comes on stdin — never on the command line, where every local process could read it |
| `… \| jarvis say --low` | speak only if idle — for chatter like tool narration |
| `… \| jarvis say --replace` | speak, dropping any earlier `--replace` line still queued — for turn summaries, where only the latest matters |
| `jarvis hush` | stop now, drop the queue |
| `jarvis mute` / `unmute` / `toggle-mute` | silence until told otherwise |
| `jarvis dictate` | hush, chime, run `JARVIS_DICTATE_CMD` (default `voxtype record toggle`) |
| `jarvis dictate stop` / `cancel` | end the recording and type it (`JARVIS_DICTATE_STOP_CMD`) — what the silence stop and "Hey Jarvis, stop" run — or drop it |
| `jarvis listen enable\|disable\|start\|stop\|status` | wake-word service |
| `jarvis pronounce plugin "plug-in"` | teach a pronunciation; no args lists them |
| `jarvis voice en-GB-ThomasNeural` | change the Edge voice (`jarvis voices` to list) |
| `jarvis piper-voice en_US-ryan-high` | download + set the offline voice — only names pinned in `models.sha256` (`jarvis voices` lists them); anything else is refused |
| `jarvis test [edge\|piper\|espeak]` | hear a line |
| `jarvis status` / `jarvis log` | health / recent errors |

Settings live in `~/.config/jarvis/config.sh`; every key is documented with its default in
`bin/jarvis-env` (engine, voices, rate, wake-word threshold and action, how it addresses you,
visualizer colours, …).

State file: `$XDG_RUNTIME_DIR/jarvis-$UID/state` — `idle | speaking | listening | muted | off`.
The bar widget watches it; so can anything else. All runtime files live in that directory, which
Jarvis creates mode 0700 and refuses to use unless it is a plain directory owned by you; there is
no `/tmp` fallback. Without `XDG_RUNTIME_DIR` (a session outside logind) every command exits with
an error unless `JARVIS_CACHE` points at a private directory.

## Hooking up an agent

Jarvis doesn't know which LLM you use. Your agent pipes text into the CLI at the right
moments — always over stdin, so agent output (which can contain anything the agent saw)
never appears in a process listing:

- turn finished → `printf '%s' "<short summary of the last message>" | jarvis say --replace`
- needs approval / input → `printf '%s' "Sir, I need your approval." | jarvis say`
- tool starting → `printf '%s' "Editing config" | jarvis say --low`

`jarvis say` refuses text on its command line (exit 2). One line is cut at `JARVIS_SAY_MAX`
characters (3000).

**Claude Code:** a ready-made hooks plugin (Stop / Notification / PreToolUse / SessionStart,
with Haiku summaries of long replies) lives in the companion repo
[`jburchel/jarvis`](https://github.com/jburchel/jarvis).

**Codex CLI:** point `notify` in `~/.codex/config.toml` at a script that reads the JSON
payload and pipes the summary into `jarvis say` on `agent-turn-complete`.

**Anything else:** if it has hooks, same pattern; if it doesn't,
`agent … | tee /dev/tty | tail -n 5 | jarvis say`.

## Remove

```bash
jarvis listen disable                 # stops + removes the systemd user service
omarchy plugin remove io.github.jburchel.jarvis
rm -f ~/.local/bin/jarvis
rm -rf ~/.local/share/jarvis          # venv, voices, chime  (optional)
rm -rf ~/.config/jarvis               # config, pronunciations, mute flag  (optional)
```

Remove the two `o.bind` lines from `bindings.lua` if you added them. Nothing else is written
outside those paths and `$XDG_RUNTIME_DIR/jarvis-$UID/` (cleared on reboot).

## Privacy

- Edge TTS sends the *text to be spoken* to Microsoft's servers. Set `JARVIS_ENGINE="piper"`
  for fully offline speech.
- The wake-word daemon processes microphone audio **locally only** (openWakeWord, ONNX on CPU).
  Nothing is recorded or sent anywhere. While Voxtype is recording, the daemon only measures
  whether you are still talking (Silero VAD, also local) and listens for a second "Hey Jarvis".
- Dictation itself is Voxtype's — whisper.cpp, local.
- What Jarvis says is agent output and may contain anything the agent saw. `jarvis-say` never
  logs it (`jarvis.log` records status and length only) and never puts it on a command line
  (synthesizers read it from a mode-0600 file in the private runtime directory; the overlay
  reads its caption from another). One line is cut at `JARVIS_SAY_MAX` characters (3000).

## License

MIT — see [LICENSE](LICENSE), which also lists the third-party components this plugin
installs or depends on.
