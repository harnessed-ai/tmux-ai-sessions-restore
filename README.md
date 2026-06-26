# tmux-ai-sessions-restore

Resume your **AI coding conversations** after a reboot — not just your tmux layout.

[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) +
[tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) bring back your sessions,
windows, panes and working directories. But an AI CLI running in a pane comes back
**cold** — a brand-new, empty conversation. This plugin is the missing layer: it makes
`claude` and `kiro-cli chat` relaunch **resumed**, in the same pane, where you left off.

Supports **Claude Code** (`claude`) and **Kiro CLI** (`kiro-cli chat`).

```
reboot ─▶ resurrect/continuum restore panes + cwd ─▶ this plugin relaunches each
          AI pane as `--resume <id>` ─▶ you're back in the same conversation
```

## How it works

1. **Capture** — each tool's own first-prompt hook (Claude `UserPromptSubmit`, Kiro
   `userPromptSubmit`) runs *inside the pane*, so it knows `$TMUX_PANE`. It stamps the live
   session id onto that pane as tmux pane-options (`@ai_session_id`, `@ai_tool`). Capturing
   on the first prompt (not session start) means a pane is only marked once its session
   actually has a transcript to resume. No change to how you launch the tools; nothing is
   written to disk by us.
2. **Save** — a `@resurrect-hook-post-save-all` hook reads those pane-options and rewrites
   the matching pane's command in resurrect's own save file to a resume command
   (`claude --resume <id>` / `kiro-cli chat --resume-id <id>`). It only rewrites a pane
   that is *actually running the tool* right now — detected via the pane's process subtree,
   so it sees through shell-integration wrappers (kiro-cli's `kiro-cli-term`, Amazon Q's
   figterm) and still skips stale markers on panes you've since reused.
3. **Restore** — resurrect replays that command unchanged, in the pane's saved cwd.

resurrect only re-runs a pane's saved command if it matches `@resurrect-processes`, so the
plugin also appends a relaxed match (`~claude`, `~kiro-cli`) to that option on load.
Without it, restore brings back your layout but every AI pane is just a bare shell.

Because the id is stamped per-pane, this is correct even with **many AI panes in the same
directory** — where "resume the latest conversation" would collapse them all onto one.

## Requirements

This is an **add-on layer — it does nothing on its own.** It rewrites entries in
tmux-resurrect's save file, so you need:

- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) — **required** (owns the
  save file this plugin rewrites, and replays the resume command on restore)
- [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) — **required for the
  automatic reboot→restore experience**; without it you save/restore by hand with
  `prefix + Ctrl-s` / `prefix + Ctrl-r`
- tmux ≥ 3.0 (pane-level user options)
- `jq`
- `claude` and/or `kiro-cli` on your `PATH`

## Install (TPM)

```sh
curl -fsSL https://raw.githubusercontent.com/bmohan01/tmux-ai-sessions-restore/main/install.sh | bash
```

Then inside tmux: **`prefix + I`**

That's it. The script clones the repo and splices the `@plugin` line into `~/.tmux.conf`
at the right slot (after resurrect, before continuum). `prefix + I` tells TPM to finish
the install and register the Claude/Kiro hooks.

<details>
<summary>Manual install</summary>

Add to `~/.tmux.conf`. **Order matters: load this after resurrect but _before_ continuum** —
it must set `@resurrect-processes` before continuum starts its (backgrounded) auto-restore,
otherwise restore brings back your layout with bare shells.

```tmux
set -g @continuum-restore 'on'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'bmohan01/tmux-ai-sessions-restore'
set -g @plugin 'tmux-plugins/tmux-continuum'

run '~/.tmux/plugins/tpm/tpm'
```

Then `prefix + I` to install.

</details>

### What this writes outside tmux (and how to opt out)

Unlike resurrect (which is pure tmux), this plugin needs a hook **inside each AI tool** to
learn a pane's session id. On first load it registers them for you (idempotent):

- `~/.claude/settings.json` — a `UserPromptSubmit` hook
- your default Kiro agent `~/.kiro/agents/kiro_default.json` — a `userPromptSubmit` hook
  (materialised from the built-in default agent if you don't already have one on disk)

Each hook only stamps a tmux pane-option and does nothing else. To manage it yourself
instead of letting the plugin do it:

```sh
set -g @ai-restore-auto-install 'off'   # in tmux.conf: disable auto-install on load
scripts/install_hooks.sh                # then register the hooks manually
scripts/uninstall_hooks.sh              # remove them anytime
```

> Already-running AI sessions are picked up the **next time you send a prompt** in them;
> sessions that were never captured fall back to a normal cold launch.

## Configuration

| Option | Default | Description |
| --- | --- | --- |
| `@ai-restore-enabled-tools` | `claude kiro` | Which tools to restore. |
| `@ai-restore-claude-command` | `claude` | Launch command for Claude. |
| `@ai-restore-kiro-command` | `kiro-cli chat` | Launch command for Kiro. |
| `@ai-restore-cold-fallback` | `on` | Append `\|\| <cold launch>` so an expired/invalid id starts a normal session instead of erroring. |
| `@ai-restore-auto-install` | `on` | Auto-register capture hooks on plugin load. |

Example:

```tmux
set -g @ai-restore-enabled-tools 'claude'
set -g @ai-restore-cold-fallback 'on'
```

## Verify it works

```sh
# 1. start an AI CLI in a pane and chat a little
claude            # or: kiro-cli chat

# 2. in another pane, confirm the live session was captured onto the pane
tmux show -p -t <that-pane> -v @ai_session_id      # prints a UUID

# 3. save, then check resurrect baked in a resume command
tmux run-shell ~/.tmux/plugins/tmux-resurrect/scripts/save.sh
grep -- '--resume' ~/.local/share/tmux/resurrect/last    # older resurrect: ~/.tmux/resurrect/last

# 4. kill the server and restore
tmux kill-server
tmux                     # continuum auto-restores, or: prefix + Ctrl-r
```

The AI pane should reopen already in your prior conversation.

## Why this rides resurrect's storage

The plugin adds **no storage of its own**. During a session the mapping lives only as
ephemeral tmux pane-options (in the server's memory, gone when the pane closes). The only
durable artifact is the resume command written into **resurrect's existing save file**
(field 11, the per-pane "restored command"). resurrect replays it on restore *if* the
command matches `@resurrect-processes` — which is why the plugin adds `~claude`/`~kiro-cli`
to that option. After a restore the next prompt re-stamps the pane, so the mapping
regenerates every cycle and never needs to survive a reboot itself.

## Limitations

- A pane is only captured once you've **sent at least one prompt** in it after the hooks
  were installed; before that (or if never captured) it cold-starts.
- Claude resume is scoped to the originating directory — if you `cd` away from where a
  session started before saving, it falls back to a cold launch.
- Kiro's `--no-interactive` mode does not fire the prompt hook; interactive `kiro-cli chat`
  (the normal usage) does.
- continuum saves *current reality*: if a restore fails to resume (e.g. an expired or
  never-persisted session), the next autosave records that pane's cold state. It
  self-heals once the AI CLI is running again (the capture hook re-stamps it).
- Not handled: other AI CLIs, remote/SSH tmux, nested tmux.

## Troubleshooting

**Restore brings back your layout but every pane is a bare shell, and nothing seems
loaded.** Your terminal probably starts tmux with a minimal `PATH` that doesn't include
your tmux/CLI install dir (common with **Ghostty/iTerm launched via launchd + Homebrew**,
where `PATH` is just `/usr/bin:/bin:…`). tmux's `run-shell` plugin loaders then can't find
the `tmux` binary and fail silently, so resurrect/continuum/this plugin never load. Fix it
by giving the tmux server a real `PATH` *before* the plugin `run-shell` lines:

```tmux
set-environment -g PATH "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin"
```

(or launch tmux through a login shell, e.g. Ghostty `command = /bin/zsh -lc "exec tmux new-session -A -s main"`).
Verify with: `tmux run-shell 'command -v tmux'` — it must print a path, not nothing.

**Assistant runs behind a shell-integration wrapper** (e.g. kiro-cli / Amazon Q's
`*-term` pty). The plugin detects the assistant via the pane's process *subtree*, so this
works — but if you see panes that should be assistants restore cold, confirm the assistant
is a descendant of the tmux pane's process (`#{pane_pid}`), not a detached terminal.

## Uninstall

```sh
scripts/uninstall_hooks.sh        # remove the Claude/Kiro capture hooks
```

Then remove the `@plugin` line and restart tmux to drop the resurrect save hook.
