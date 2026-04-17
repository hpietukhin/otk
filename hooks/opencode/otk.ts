import type { Plugin } from "@opencode-ai/plugin"

// otk OpenCode plugin — rewrites commands to compact forms for token savings.
// Requires: otk binary in PATH (or set OTK_BIN env var to full path).
//
// Handled: git status/log/diff, pytest, ls, cat.
// All other commands pass through unchanged.

const OTK_BIN = process.env.OTK_BIN ?? "otk"

export const OtkOpenCodePlugin: Plugin = async ({ $ }) => {
  try {
    await $`which ${OTK_BIN}`.quiet()
  } catch {
    console.warn("[otk] otk binary not found in PATH — plugin disabled")
    return {}
  }

  return {
    "tool.execute.before": async (input, output) => {
      const tool = String(input?.tool ?? "").toLowerCase()
      if (tool !== "bash") return
      const args = output?.args
      if (!args || typeof args !== "object") return

      const command = (args as Record<string, unknown>).command
      if (typeof command !== "string" || !command) return

      try {
        const result = await $`${OTK_BIN} rewrite ${command}`.quiet().nothrow()
        const rewritten = String(result.stdout).trim()
        if (rewritten && rewritten !== command) {
          ;(args as Record<string, unknown>).command = rewritten
        }
      } catch {
        // otk rewrite failed — pass through unchanged
      }
    },
  }
}
