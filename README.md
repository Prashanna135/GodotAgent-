# GodotAgent

An AI coding agent for Godot 4, built entirely in Godot itself. It reads,
writes, and searches your project's files, runs checks and headless
scenarios to verify its work, and talks to any OpenAI-compatible LLM
endpoint — cloud APIs, local Ollama models, or the included DeepSeek Web
Bridge.

The whole UI is built in GDScript. There is no editor plugin to install,
no addon folder to copy. You clone the repo, open it as a Godot project,
and start a task.

---

## Requirements

- **Godot 4.7 or newer.** Earlier 4.x versions may work but aren't tested.
- **An LLM endpoint.** Either a cloud API (OpenAI, Gemini, Groq,
  OpenRouter), a local server (Ollama, LM Studio), or the bundled
  DeepSeek Web Bridge (see below).
- **Python 3.10+** — only if you want to use the DeepSeek Web Bridge.
  Native API providers don't need it.

---

## Installation

1. Clone the repo and open the folder in Godot:

   git clone https://github.com/Prashanna135/GodotAgent-.git

   Then **File → Open Project** in Godot and select the folder.

2. Press F5 to run. The first launch shows a chat window with no project
   loaded. That's expected.

3. Click **Settings** in the top bar and configure your provider.

---

## Configuration

The Settings dialog has four sections.

**Model provider** — pick from the preset list, or choose *Custom* and
enter the endpoint URL directly.

| Provider | Endpoint | Notes |
|---|---|---|
| Google AI Studio | `generativelanguage.googleapis.com/v1beta/openai/…` | Free tier available |
| OpenAI | `api.openai.com/v1/chat/completions` | Paid |
| Groq | `api.groq.com/openai/v1/chat/completions` | Generous free tier |
| OpenRouter | `openrouter.ai/api/v1/chat/completions` | Free-tier options |
| Ollama (local) | `localhost:11434/v1/chat/completions` | Requires Ollama running |
| LM Studio (local) | `localhost:1234/v1/chat/completions` | Requires LM Studio running |
| DeepSeek Web Bridge | `127.0.0.1:5000/v1/chat/completions` | See bridge section below |

Fill in your **API key** (leave blank for local servers). Set the
**Model** name exactly as the provider spells it.

**Model tier** controls how much the harness helps the model. Pick *Auto*
and it'll guess from the model name — a small local model gets
hand-holding and small caps, a cloud model gets none of it. Override it
if the guess is wrong.

**Timeout** is how long to wait for the LLM's response. The default of
120 seconds is fine for cloud APIs. Set it higher (600+) if you're using
the DeepSeek Web Bridge, because each round trip there is a real browser
interaction.

**Tools** lets you turn optional tools off to save tokens. Every tool's
schema is sent on every API call, so disabling ones you don't use makes
requests cheaper. `launch_editor`, `launch_project`, `write_plan`, and
`update_plan` are good candidates if you don't use them.

---

## Using the agent

1. **Open a project.** File → Open Project, pick a Godot project folder
   on disk. The agent now has access to that folder only — everything it
   reads and writes goes through a sandbox that can't escape the folder
   you selected.

2. **Type a task.** Describe what you want in plain English. Examples:

   - "Read scripts/player.gd and fix the null reference on line 42."
   - "Add a health system to the enemy base class."
   - "Why is my project failing to boot headlessly? Run a check and tell me."

   Press Enter. The agent will start calling tools.

3. **Watch it work.** Tool calls and their results appear in the chat.
   The Activity panel shows the raw log. The status bar shows what phase
   the agent is in.

4. **Approve if asked.** Some tools (deleting files, running terminal
   commands) require your approval. A dialog appears; click Allow or Deny.

5. **Review changes.** The **History** button in the top bar opens a diff
   view of every file the agent modified. Each entry has a Revert button.

---

## Tools

The agent's power comes from its tools. Every task is the model choosing
which of these to call, in what order, based on what it needs. All file
operations are sandboxed to the project folder you opened.

### Reading and searching

| Tool | What it does |
|---|---|
| `read_file` | Read a UTF-8 text file. Large files require a line range instead of dumping the whole thing. |
| `read_files` | Read several files in one call. Cheaper than N separate `read_file` calls on the web-chat tier, where each round trip is a browser wait. |
| `list_directory` | List a folder's immediate contents. |
| `search_text` | Substring search across the project. Skips generated files and binary assets automatically. |
| `find_files` | Find files by name — globs (`*.tscn`) or substrings. Code sorts before assets. |
| `find_symbol` | Find declarations of a function, class, signal, variable, constant, or enum across the project. Also reports autoloads from `project.godot`. |
| `find_references` | Find every place a symbol is used — call sites, reads, signal connections. Catches string-literal references like `connect("died", ...)`. |

### Editing

| Tool | What it does |
|---|---|
| `edit_file` | Replace an exact block of text. Fails if the block appears more than once, so the model has to add enough context to be unambiguous. |
| `edit_file_lines` | Replace a range of lines by number. Use when you have a line number from a check but not the exact current text. |
| `write_file` | Overwrite a whole file. Refuses to replace a ≥1 KB file with <20% of its size, so a partial write can't destroy the original. |
| `create_file` | Create a new file. Fails if it already exists — use `write_file` for overwriting. |
| `delete_file` | Delete a single file. Requires user approval. |
| `revert_last_change` | Undo the most recent write, create, edit, or delete. Call again to step further back. |

### Running Godot

| Tool | What it does |
|---|---|
| `check_script` | Syntax-check one `.gd` file. Fast. Runs automatically after every edit on a `.gd`. |
| `check_project` | Syntax-check every `.gd` file in the project. Slower — one subprocess per file — but catches scripts reachable only at runtime. |
| `launch_headless` | Run the project headlessly and capture stdout/stderr. Catches errors that only surface when scripts actually load. |
| `run_scenario` | **Behavioral verification.** Write a small GDScript scenario, run it headlessly against the real project, get a PASS/FAIL verdict. This is how the agent tests movement, collisions, damage, timers — anything that works at runtime but not at parse time. |
| `launch_editor` | Launch the Godot editor on the project. Returns immediately. |
| `launch_project` | Run the project windowed. Returns immediately. |

### Scene and asset inspection

| Tool | What it does |
|---|---|
| `inspect_scene` | Parse a `.tscn` and return the node tree — names, types, attached scripts, ext_resources — instead of raw resource syntax. |
| `find_node` | Locate a node inside a scene by name or type. |
| `get_node_property` | Read one property of a node as defined in the scene file. |
| `find_scene_users` | Every other scene or script that preloads or instances a given scene. Answers "what uses this?" |

### Project analysis

| Tool | What it does |
|---|---|
| `list_autoloads` | Every autoload singleton declared in `project.godot`. Useful because autoloads aren't `.gd` declarations, so `find_symbol` won't find them. |
| `find_rpc_calls` | Every `@rpc`-annotated function and every `rpc()`/`rpc_id()` call site, grouped by method name. Built for multiplayer bugs where host and client disagree about who called what. |
| `find_signal_wiring` | Every `.connect(...)` and `.emit()` / `emit_signal(...)` for a signal, plus its declaration. `find_references` on a signal, essentially. |

### Godot API lookup

| Tool | What it does |
|---|---|
| `godot_api_lookup` | Look up a Godot class's methods, signals, properties, constants, and enums from the engine's own class reference. Pass `member="..."` to check one name — it suggests near-misses when the name doesn't exist. Catches hallucinated API calls before they're written. |

### Task planning

| Tool | What it does |
|---|---|
| `write_plan` | Set a multi-step plan for a task. The plan shows in the UI as the agent works through it. |
| `update_plan` | Mark one plan step in progress, done, or blocked. |

### Tool registration

Every tool's schema costs tokens on every API call, so tools you don't
use can be turned off in **Settings → Tools**. Good candidates for
disabling: `launch_editor`, `launch_project`, `write_plan`, `update_plan`.
The rest are enabled by default.

`check_script`, `check_project`, `launch_headless`, `run_scenario`, and
`godot_api_lookup` need the Godot executable path configured in
**Settings → Godot**.

---

## Optional: DeepSeek Web Bridge

The bridge lets you use DeepSeek's free web chat as if it were an
OpenAI-compatible API. It works by driving a real Chromium browser to
chat.deepseek.com with Playwright, since that endpoint has no native
function-calling and no API.

Setup:

1. Install Python 3.10 or newer.

2. From the `bridge/` folder in the repo:

   python -m venv venv
   source venv/Scripts/activate     # Windows (Git Bash)
   source venv/bin/activate         # macOS / Linux
   pip install -r Requirements.txt
   playwright install chromium

3. Run the bridge:

   python bridge.py

   A Chromium window opens on first run. Log in to DeepSeek in that
   window. Leave it open — the bridge holds the session.

4. In GodotAgent's Settings, choose the **DeepSeek Web Bridge** provider
   preset. Set the timeout to 600 or higher.

5. Point the agent at a project and start a task.

The bridge logs every request to `bridge/bridge_logs/`. If something
goes wrong, that's the first place to look — `index.jsonl` has one line
per request with size, duration, and status.

**Note:** the bridge is more fragile and much slower than a native API.
Each tool call is a real browser round trip (30-90 seconds). Use it when
you don't have an API key and want to try the agent out, not as a
permanent setup. Native providers are faster, cheaper, and more reliable.

**If DeepSeek login via Google fails:** Google blocks OAuth sign-in from
automated browsers. The bridge supports reusing your real Chrome profile
instead — see the config comments at the top of `bridge.py` for the two
environment variables that control this (`DEEPSEEK_BROWSER_CHANNEL` and
`DEEPSEEK_PROFILE_DIR`).

---

## Optional: Godot executable path

Some tools (`check_script`, `check_project`, `launch_headless`,
`run_scenario`, `godot_api_lookup`) need to spawn Godot as a subprocess.
Point the agent at your Godot binary in **Settings → Godot → Executable**.
If it's on your system PATH, you can leave it blank and Godot will be
found automatically.

---

## Troubleshooting

**"No project is open" when I send a message.** Use File → Open Project
first. The agent can't do anything without a project folder.

**The agent writes a tool call but nothing happens.** It may be trying to
call a tool that isn't registered. Check the Activity panel — the log
shows every tool call attempt with its result.

**Requests time out.** Raise the timeout in Settings. Local models can
take a while to respond; the DeepSeek Web Bridge is slow by design.

**A file the agent created disappeared.** Checkpoints are saved to
user://checkpoints/, separate from your project. Use the Revert button in
the History panel to restore a previous state.

**The agent gave up without changing anything.** Some tasks are genuinely
too vague or too large for the model. Try breaking them into smaller
steps. The status bar shows GAVE_UP or BLOCKED instead of COMPLETED when
this happens.

---

## Design notes

A few things that may be non-obvious if you're reading the source:

- **The LLM is stateless per request.** Every request sends the whole
  conversation. There's no server-side session on the provider's side.

- **Tools are sandboxed.** ProjectPathTool.resolve_path() prevents any
  file operation from escaping the project folder you opened.

- **Settings persist to user://agent_settings.cfg**, which is outside
  the repo. Your API key never enters git.

- **The checkpoint system is separate from git.** It has its own stash
  directory under user://checkpoints/ and doesn't touch .git/.

---

## License

MIT. See LICENSE for the full text.
