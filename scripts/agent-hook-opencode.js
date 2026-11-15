// agent-hook-opencode.js — OpenCode adapter for the shared harnessed-ai agent hook.
//
// OpenCode has no shell hooks, so install-hooks.sh copies this file into OpenCode's global
// plugins/ directory, with __AGENT_HOOK__ replaced by the installed agent-hook.sh. It runs
// inside the OpenCode process, so it sees the pane's $TMUX_PANE, and agent-hook.sh (its
// child) finds OpenCode as its agent process. Each OpenCode event becomes the agent-hook
// event with Claude's name:
//
//   your prompt (chat.message)        → UserPromptSubmit  (working; records the session id)
//   tool.execute.before / .after      → PreToolUse / PostToolUse  (what it's doing)
//   permission.asked                  → PermissionRequest (waiting on you)
//   permission.replied                → PostToolUse       (working again)
//   session.idle after a turn         → Stop              (done)
//   session.error                     → StopFailure       (error)
//   session.created / title changes   → SessionStart / SessionTitle (the session's name)
//
// Subagent (child) sessions are skipped: they belong to the pane's session. Shared by the
// harnessed-ai tmux plugins (an identical copy ships with each). Never throws, writes nothing.

import { spawn } from "node:child_process";

const HOOK = "__AGENT_HOOK__";

export const HarnessedAiAgentHook = async ({ client, directory }) => {
  if (!process.env.TMUX || !process.env.TMUX_PANE) return {};

  const child = new Map(); // sessionID -> is a subagent session
  const titles = new Map(); // sessionID -> last title sent
  const active = new Set(); // sessions with a turn in progress (so idle means "done")
  const seen = new Set(); // user message ids already reported

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

  // OpenCode names new sessions "New session - <timestamp>" until it has summarised one.
  const usefulTitle = (t) => (typeof t === "string" && t && !/^New session\b/.test(t) ? t : "");

  const send = async (event, sessionID, extra = {}) => {
    try {
      if (!sessionID || (await isChild(sessionID))) return;
      const payload = { hook_event_name: event, session_id: sessionID, cwd: directory, ...extra };
      const title = titles.get(sessionID);
      if (title) payload.session_title = title;
      const p = spawn("bash", [HOOK, "opencode", event], { stdio: ["pipe", "ignore", "ignore"] });
      p.on("error", () => {});
      p.stdin.on("error", () => {});
      p.stdin.end(JSON.stringify(payload));
    } catch {}
  };

  const prompt = async (sessionID, messageID) => {
    if (messageID) {
      if (seen.has(messageID)) return;
      seen.add(messageID);
      if (seen.size > 1000) seen.clear();
    }
    active.add(sessionID);
    await send("UserPromptSubmit", sessionID);
  };

  return {
    "chat.message": async (input, output) => {
      await prompt(input?.sessionID, input?.messageID ?? output?.message?.id);
    },
    "tool.execute.before": async (input, output) => {
      active.add(input?.sessionID);
      await send("PreToolUse", input?.sessionID, { tool_name: input?.tool, tool_input: output?.args ?? {} });
    },
    "tool.execute.after": async (input) => {
      await send("PostToolUse", input?.sessionID, { tool_name: input?.tool });
    },
    event: async ({ event }) => {
      try {
        const p = event?.properties ?? {};
        switch (event?.type) {
          case "session.created":
          case "session.updated": {
            const info = p.info;
            if (!info?.id) return;
            child.set(info.id, Boolean(info.parentID));
            if (info.parentID) return;
            const t = usefulTitle(info.title);
            const renamed = t && titles.get(info.id) !== t;
            if (renamed) titles.set(info.id, t);
            if (event.type === "session.created") await send("SessionStart", info.id);
            else if (renamed) await send("SessionTitle", info.id);
            return;
          }
          case "message.updated": // older OpenCode versions report prompts only here
            if (p.info?.role === "user") await prompt(p.info.sessionID, p.info.id);
            return;
          case "session.idle":
            if (!active.delete(p.sessionID)) return; // idle without a turn: nothing finished
            await send("Stop", p.sessionID);
            return;
          case "permission.asked":
          case "permission.updated":
            await send("PermissionRequest", p.sessionID);
            return;
          case "permission.replied":
            await send("PostToolUse", p.sessionID);
            return;
          case "session.error":
            active.delete(p.sessionID);
            await send("StopFailure", p.sessionID);
            return;
        }
      } catch {}
    },
  };
};
