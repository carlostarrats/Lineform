# Open agent-written Markdown in Lineform (Claude Code hook)

Verified against **Claude Code v2.1.198**.

This hook opens any Markdown or text file your agent writes or edits in Lineform, so you read
and review it in a real window (with live reload) instead of scrolling the terminal.

## Setup

1. Install the `lineform` command line tool: in Lineform, choose **Lineform → Install Command
   Line Tool…** (or symlink it manually — see the app’s dialog). The recipe also works without
   it via `open`.
2. Add the hook to your Claude Code settings. Use one of:
   - `~/.claude/settings.json` — applies to all your projects.
   - `.claude/settings.json` — this project only (shareable/committed).
   - `.claude/settings.local.json` — this project, local only.

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "f=$(jq -r '.tool_input.file_path // empty'); case \"$f\" in *.md|*.markdown|*.txt) command -v lineform >/dev/null 2>&1 && lineform \"$f\" || open -b com.lineform.app \"$f\";; esac"
          }
        ]
      }
    ]
  }
}
```

**What it does:** after Claude Code’s `Write` or `Edit` tool runs, the hook reads the event JSON
on stdin, extracts `tool_input.file_path` with `jq`, and — only for `.md`, `.markdown`, or `.txt`
files — opens it in Lineform (using the `lineform` CLI if installed, otherwise `open -b
com.lineform.app`). It exits silently for any other file, so it never interferes with normal work.

**Notes**
- `"Write|Edit"` matches both tools in one entry (on v2.1.191+ you may also write `"Write,Edit"`).
- The hook fires once per matching tool call. Because Lineform live-reloads the open document,
  repeated edits to the same file refresh the existing window rather than piling up new ones.
- Requires `jq` (preinstalled on macOS via most setups; `brew install jq` otherwise).

## A note on “open approved plans”

An earlier design imagined a second recipe that opened an approved plan when you exit plan mode.
Verified against Claude Code v2.1.198, **`ExitPlanMode` does not emit a `PostToolUse` file-path
event** — it triggers a permission request, and the plan is passed as text, not as a file on
disk — so there is no reliable file path for a hook to open. Rather than publish a recipe that
doesn’t work, it is omitted until a verified mechanism exists. (If you write plans to a file
yourself, the Write/Edit recipe above already opens them.)

## Other agents

Recipes for other agents (Codex, OpenCode, …) will be added only after the same end-to-end
verification against their current releases — never from documentation alone.
