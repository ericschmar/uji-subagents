# uji-subagents

Background subagents for [uji](https://github.com/uji-labs/uji), with a live
sidebar, per-agent transcripts, and steering while they work.

This is a managed take on the `subagent` plugin from
[uji-plugins](https://github.com/uji-labs/uji-plugins). Each agent still runs as
its own `uji run` process with its own context, tools and saved session, but
the parent no longer waits for it: starting agents returns task IDs
immediately, results arrive on their own, and you can watch or redirect an
agent mid-turn from the UI.

## Install

```lua
uji.pack.add({ "ericschmar/uji-subagents" })

local subagents = require("managed_subagent")
subagents.setup({})

uji.ui.configure({ theme = subagents.wrap_theme(require("uji.themes.default")()) })
```

`wrap_theme` installs the sidebar screen on top of the theme you pass. Without
it the tools still run, but the sidebar is not drawn. Any named theme works
the same way:

```lua
local theme = require("uji.themes.catppuccin_mocha")
uji.ui.configure({ theme = subagents.wrap_theme(theme) })
```

For local development, point at a working copy:

```lua
uji.pack.add({ { dir = "~/develop/uji-subagents" } })
```

The module is `managed_subagent`, but the tool it registers is named
`subagent`. Use it instead of, not alongside, the `subagent` plugin from
`uji-plugins`.

## Agents

An agent is a markdown file. Front matter describes it; the body is appended to
its system prompt.

```markdown
---
name: scout
description: Finds code and reports paths and line numbers without changing files
tools: read_file, run_command
model: anthropic/claude-haiku-4-5
effort: low
---
You are a read-only investigator. Report findings with file paths and line
numbers, and say what you could not verify.
```

| Field | Meaning |
|---|---|
| `name` | The agent's name. Defaults to the file name. |
| `description` | Required. The parent model reads this to choose an agent. |
| `tools` | Comma-separated tools, with or without brackets. Default is every tool. |
| `model` | `provider/model`. Defaults to the model in use. |
| `effort` | Reasoning effort. Defaults to the effort in use. |

Agents live in `agents/` in your config directory and in packs. With the
`project` or `both` scope, uji also reads `.uji/agents/` in the session's
directory, where a project agent replaces a user agent of the same name.

| Scope | Agents used |
|---|---|
| `user` | Your config and packs |
| `project` | The project's `.uji/agents/` only |
| `both` | Both, project agents overriding user agents with the same name |

Agents from the project ask for approval before they run unless
`confirm_project = false`, because the repository controls their contents.

## The `subagent` tool

| Arguments | Runs |
|---|---|
| `agent` and `task` | One agent |
| `tasks` | A list of `{ agent, task }` in parallel |
| `chain` | A list of `{ agent, task }` in order |
| `cwd` | Working directory for the task; defaults to the parent's |
| `scope` | `user`, `project` or `both` for this call |

Every item may carry its own `cwd`. In a chain, `{previous}` in a task is
replaced with the previous step's answer, and a failed step cancels the rest of
the chain.

The call returns task IDs and leaves the main conversation usable:

```
Started in background. You can continue; results will arrive automatically.
agent-1 · scout · starting
agent-2 · worker · starting
```

Each result arrives once as a new message in the parent transcript and as a
notification. Agents start in the parent's model and effort unless the agent
file says otherwise. Their conversations are saved as child sessions under
the parent, which `uji resume --id <ID>` opens.

### Managing tasks

| Tool | Arguments | Does |
|---|---|---|
| `subagent_status` | `id` optional | Progress, steering state and the final result. Omit `id` for every task. |
| `subagent_steer` | `id`, `text` | Queues a mid-turn instruction for a running agent. |
| `subagent_stop` | `id` | Stops a queued or running agent. |

Steering is cooperative: the worker consumes queued text at the next
model/tool-cycle boundary. It can redirect the next step but cannot undo a tool
call already running. The UI shows each instruction as `pending`, `sending`,
`queued`, `delivery_unknown`, `consumed` or `not_consumed`.

Statuses go `queued` → `starting` → `running` → `completed`, `failed` or
`cancelled`, with `stopping` while a stop is delivered.

## UI

When the terminal is at least 100 columns wide, uji gets a right sidebar with
the main conversation and every agent. Each row shows the agent, its status
and an unread dot. Click an agent to open its live transcript, tool calls,
reasoning and steering history.

| Key or command | Does |
|---|---|
| `/agents` or `Alt-A` | Pick an agent |
| `/agent-main` or `Alt-M` | Return to the main conversation |
| `Esc` | Return to main from an agent view, without interrupting it |
| `Enter` | Steer the selected agent with the child composer |
| `PgUp` / `PgDn` / `Ctrl-P` / `Ctrl-N` | Scroll the child transcript |
| `/agent-stop [id]` | Stop an agent, or pick one |

The child composer keeps its own draft per agent, and the main draft is never
modified while you type there. Emacs-style editing keys work in the child
composer. On a narrow terminal the sidebar is hidden; `/agents` and `Alt-A`
still open the picker, and the agent view still shows its return link.

## Options

```lua
require("managed_subagent").setup({
  policy = "allow",
  scope = "user",
  confirm_project = true,
  concurrency = 4,
  max_tasks = 8,
  output = 51200,
  max_history = 100,
  skip = false,
})
```

| Option | Meaning | Default |
|---|---|---|
| `policy` | Whether starting, steering or stopping agents asks first: `"allow"`, `"ask"` or `"deny"`. | `"allow"` |
| `scope` | Default agent scope: `"user"`, `"project"` or `"both"`. | `"user"` |
| `confirm_project` | Ask before running an agent from the project. | `true` |
| `concurrency` | How many agents run at once across all launches. | `4` |
| `max_tasks` | The most tasks one call may launch. | `8` |
| `output` | Bytes of each result kept when it is delivered. | `51200` |
| `max_history` | The most tasks kept in history. When it is full and nothing is running, old history is cleared. | `100` |
| `skip` | `true` disables the sidebar and child view; the tools still work. | `false` |

`setup` also adds a short context block telling the model that agents run in
the background, that results arrive automatically, and which agents exist.

## How it works

The parent starts each worker as:

```
uji run --json --parent <session-id> --title <agent>: <task> ...
```

with a random token in `UJI_MANAGED_TOKEN` and its task ID in
`UJI_MANAGED_ID`. The worker attaches a child session, enforces the agent's
tool list and prompt, opens a control listener on loopback, and streams JSON
events on stdout: live text, reasoning, messages, tool progress, steering
acknowledgements and the final result.

The parent keeps the event stream in memory for the live view, schedules
launches against the concurrency limit, substitutes `{previous}` for chains,
and delivers each result once. Steering and stop travel to the worker as
token-authenticated HTTP requests on `127.0.0.1`. A stop is graceful: the
worker interrupts its turn, and is killed if it does not exit in time. Quitting
or restarting uji stops every managed agent and its shell subprocesses.

## Limitations

- Requires uji `0.2.3` exactly. The worker asserts the version and the
  steering API.
- Agents must use uji's default provider loop; providers with their own loop,
  such as a coding-agent CLI, cannot be steered.
- Agents do not get the `subagent` tool, so nesting is not supported.
- Workers run tool calls without asking. Your tool policy still applies, so
  use prompt instructions and `tools` to keep read-only agents read-only.
- Interrupting the parent turn does not stop background agents. Use
  `subagent_stop`, `/agent-stop`, or quit uji.
- Concurrent agents share the working directory unless you give each a `cwd`,
  so they can overwrite each other's edits.
- A task is limited to 128 KiB, and a steering instruction to 32 KiB.
- The live transcript is trimmed in memory; the complete child conversation
  stays in its session.

## Development

```sh
python3 tests/check.py
```

The suite runs unit tests for discovery, scheduling, chains, steering and the
control protocol, a real-process integration test with two workers, and a
terminal UI test in a PTY. It needs `uji` 0.2.3 on `PATH` and `python3`.

| Path | Contents |
|---|---|
| `lua/managed_subagent/init.lua` | Setup, tools and model context |
| `lua/managed_subagent/agents.lua` | Agent discovery and resolution |
| `lua/managed_subagent/manager.lua` | Scheduling, lifecycle, steering, delivery |
| `lua/managed_subagent/protocol.lua` | Worker events and control protocol |
| `lua/managed_subagent/worker.lua` | The child `uji run` runtime |
| `lua/managed_subagent/ui.lua` | Sidebar, child view and theme wrapper |
| `lua/managed_subagent/input.lua` | Child view keys and paste handling |
| `tests/` | Unit, integration and terminal UI tests |
