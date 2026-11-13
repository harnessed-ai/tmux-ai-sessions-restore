// tmux-ai-sessions-restore — OpenCode capture plugin.
//
// OpenCode has no shell hooks, so install_hooks.sh copies this file into OpenCode's global
// plugins/ directory (with CAPTURE pointing at this checkout's capture_session.sh), and
// uninstall_hooks.sh removes it. It runs inside the OpenCode process, so it sees the pane's
// $TMUX_PANE, and capture_session.sh (its child) finds OpenCode as its parent CLI process.
//
// On every user prompt it pipes {"session_id", "cwd"} into `capture_session.sh opencode`,
// which stamps the pane; a tmux-resurrect save then relaunches the pane as
// `opencode --session <id>`. Subagent (child) sessions are skipped: they belong to the
// pane's session, not the other way round. It never throws and writes nothing.

import { spawn } from "node:child_process";

const CAPTURE = "__CAPTURE__";

export const TmuxAiSessionsRestore = async ({ client, directory }) => {
  if (!process.env.TMUX || !process.env.TMUX_PANE) return {};

  const child = new Map(); // sessionID -> is a subagent session
  const seen = new Set(); // user message ids already captured
  const isChild = async (id) => {
    if (child.has(id)) return child.get(id);
    try {
      const res = await client.session.get({ path: { id } });
      const c = Boolean(res?.data?.parentID);
      child.set(id, c);
      return c;
    } catch {
      return false;
    }
  };

  const capture = async (sessionID, messageID) => {
    try {
      if (!sessionID) return;
      if (messageID) {
        if (seen.has(messageID)) return;
        seen.add(messageID);
        if (seen.size > 1000) seen.clear();
      }
      if (await isChild(sessionID)) return;
      const p = spawn("bash", [CAPTURE, "opencode"], { stdio: ["pipe", "ignore", "ignore"] });
      p.on("error", () => {});
      p.stdin.on("error", () => {});
      p.stdin.end(JSON.stringify({ session_id: sessionID, cwd: directory }));
    } catch {}
  };

  return {
    "chat.message": async (input, output) => {
      await capture(input?.sessionID, input?.messageID ?? output?.message?.id);
    },
    event: async ({ event }) => {
      const info = event?.properties?.info;
      if (!info) return;
      if (event.type === "session.created" || event.type === "session.updated") {
        child.set(info.id, Boolean(info.parentID));
      } else if (event.type === "message.updated" && info.role === "user") {
        await capture(info.sessionID, info.id);
      }
    },
  };
};
