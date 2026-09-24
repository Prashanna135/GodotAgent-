# GodotAgent

An AI coding agent that lives in Godot, for working on Godot projects.
It reads and edits your scripts, runs checks and headless tests to
confirm its own work, and talks to whatever LLM you point it at —
OpenAI, Gemini, Groq, a local Ollama model, or DeepSeek's web chat via
the included bridge.

Everything's built in GDScript. No editor plugin, no addon folder, no
`.tscn` editing. Clone it, open it as a project, run it.

## What you need

- Godot 4.7 or newer. Earlier 4.x probably works but I haven't tried.
- Access to an LLM. Cloud API, local server, or the DeepSeek bridge.
- Python 3.10+ if you want to use the DeepSeek bridge. Skip it otherwise.

## Getting it running

```bash
git clone https://github.com/Prashanna135/GodotAgent-.git
```

Open the folder in Godot, hit F5. You'll get an empty chat window. Click
Settings in the top bar, pick your provider, drop in your API key, and
you're set. For local models just point it at the Ollama or LM Studio
URL — those don't need a key.

## Settings, briefly

**Provider** — preset list, or Custom if yours isn't there. Endpoint and
model go in as plain text.

**Model tier** — this one matters more than it looks. Pick Auto and the
harness guesses based on the model name: tiny local models get extra
nudges and smaller tool output caps, cloud models get none of that
because it's wasted tokens on something that already reads context
properly. If Auto gets it wrong, set it manually.

**Timeout** — 120 seconds is fine for cloud APIs. The DeepSeek bridge
needs 600 or more because each round trip is a real browser interaction.

**Tools** — you can disable tools you don't use. Every tool's schema
gets sent on every request, so turning off the ones you'll never call
makes things cheaper. launch_editor, launch_project, write_plan, and
update_plan are the usual ones to drop.

## Using it

Open a project with File → Open Project. The agent gets access to that
folder and only that folder — everything goes through a path sandbox
that won't let it escape.

Then just describe what you want:

- "read scripts/player.gd and fix the null reference on line 42"
- "add a health system to the enemy base class"
- "the project won't boot headlessly, figure out why"

It'll start calling tools. You can watch each call and its result in
the chat. If it wants to do something destructive — delete a file, run
a shell command — you get a dialog and can say no.

Changes are reversible. Hit History in the top bar and you'll see every
file it touched with a diff and a Revert button.

## The tools

This is the actual reason to use this thing over pasting code into a
chat window. All of these run inside your project with no copy-pasting.

### Reading

- **read_file** — read a text file. Big files need a line range or you
  get refused.
- **read_files** — several files in one call. Worth using on the DeepSeek
  bridge where each call is a 30-second browser wait.
- **list_directory** — folder contents.
- **search_text** — find a substring. Skips .godot/, imports, binaries.
- **find_files** — find by filename, globs or partial names.
- **find_symbol** — where's a function/class/signal/variable declared.
  Also picks up autoloads, which find_symbol would otherwise miss
  because they live in project.godot instead of a .gd file.
- **find_references** — everywhere a symbol is used. Catches the
  connect("died", ...) string-literal cases that a naive rename breaks.

### Editing

- **edit_file** — replace a chunk of text. Refuses if the chunk appears
  more than once, which forces the model to add enough context to be
  unambiguous.
- **edit_file_lines** — replace by line number. Handy when you have a
  line from an error message but don't know the exact current text.
- **write_file** — overwrite the whole thing. Won't let you replace a
  1KB+ file with a tiny stub, which is a mistake small models make
  constantly.
- **create_file** — new file. Errors if it exists.
- **delete_file** — needs your approval.
- **revert_last_change** — undo the last write/edit/delete. Call it
  again to step back further.

### Running Godot

- **check_script** — parse one .gd. Fast. Runs automatically after edits.
- **check_project** — parse every .gd. Slower but catches scripts that
  only load at runtime.
- **launch_headless** — boot the project and capture output. Catches
  things that pass a parse check but blow up when scripts actually run.
- **run_scenario** — write a GDScript test, run it against the real
  project, get pass/fail. This is how you verify that a movement fix
  actually moves the unit instead of just compiling.
- **launch_editor** / **launch_project** — open the editor or run the
  game. Fire and forget.

### Scenes

- **inspect_scene** — parse a .tscn and show the node tree. Way easier
  to reason about than 40 lines of ext_resource syntax.
- **find_node** — find a node by name or type in a scene.
- **get_node_property** — read a property as set in the scene file.
- **find_scene_users** — what else references this scene.

### Project analysis

- **list_autoloads** — every autoload from project.godot.
- **find_rpc_calls** — every @rpc function and every rpc()/rpc_id()
  call, grouped by method. Built for the multiplayer bug where the
  host calls rpc_id(1, ...) on itself.
- **find_signal_wiring** — every .connect() and .emit() for a signal,
  plus where it's declared.

### API lookup

- **godot_api_lookup** — check what methods/signals/properties a Godot
  class actually has, straight from the engine's own class reference.
  Pass member="..." to check one name and get near-miss suggestions
  when you typed the wrong thing. Prevents the class of bug where the
  model confidently writes `AnimationTree.get_root_motion_position()`
  and it doesn't exist.

### Planning

- **write_plan** / **update_plan** — for multi-step tasks. Shows up in
  the UI so you can see where it is.

Tools marked in Settings as optional (everything except the file read
and edit tools) can be turned off. check_script, check_project,
launch_headless, run_scenario, and godot_api_lookup all need the Godot
executable path set in Settings → Godot.

## DeepSeek bridge (optional)

DeepSeek's web chat doesn't have an API. This bridge drives a real
browser to chat.deepseek.com and pretends it's an OpenAI endpoint, so
GodotAgent can use it without any changes.

Setup:

```bash
cd bridge
python -m venv venv
source venv/Scripts/activate  # or venv/bin/activate on mac/linux
pip install -r Requirements.txt
playwright install chromium
python bridge.py
```

A Chromium window opens. Log into DeepSeek. Leave it open. Then in
GodotAgent's settings, pick the DeepSeek Web Bridge preset and set your
timeout to 600+.

The bridge writes every request to `bridge_logs/`. If something goes
wrong, index.jsonl is where to look.

Honestly: this thing is slow. Each tool call is a real browser round
trip, so 30-90 seconds per call instead of the two seconds a native
API takes. Use it if you don't have an API key and want to try the
agent out. Native providers are better in every way that matters.

If DeepSeek login through Google gives you trouble ("this browser or
app may not be secure"), that's Google blocking automated browsers. The
bridge can reuse your real Chrome profile instead. The two env vars
that control this are documented at the top of bridge.py.

## Setting the Godot path

check_script, check_project, launch_headless, run_scenario, and
godot_api_lookup all spawn Godot as a subprocess. Point the agent at
your Godot binary in Settings → Godot → Executable. If Godot's on your
system PATH, leave it blank and it'll find it.

## When things go wrong

**"No project is open"** — open a project first. File → Open Project.

**Tool call shows in the chat but nothing happened** — likely a tool
that isn't registered. Check the Activity panel; the log shows every
attempt and its result.

**Requests keep timing out** — raise the timeout. Local models are slow
and the DeepSeek bridge is slower.

**A file the agent edited disappeared** — checkpoints are separate from
git, stored in user://checkpoints/. Use History → Revert.

**The agent stops without doing anything** — some tasks are too vague
or too big. Break them up. The status bar shows GAVE_UP or BLOCKED when
this happens, so at least you know it's not silently pretending to be
done.

## If you're reading the source

- Every request sends the whole conversation. No server-side session.
- ProjectPathTool.resolve_path() is the sandbox. Nothing escapes the
  folder you opened.
- Settings live in user://agent_settings.cfg. API keys never enter the
  repo.
- Checkpoints are their own stash directory, separate from git.

## License

MIT. See LICENSE.
