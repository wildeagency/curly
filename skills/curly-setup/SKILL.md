---
name: curly-setup
description: One-time install of curly (github.com/wildeagency/curly) on a fresh machine. Handles dependency check, binary drop, PATH wiring, ~/.curly.yaml creation with chmod 600, and a token-free interactive service configuration handoff. NEVER solicits API tokens through the chat — the user types tokens directly into curly's hidden-input prompt in their terminal. Also enforces `.gitignore` for any `.curly.yaml` inside a git repo.
---

# curly-setup

You are a trusted local agent installing curly for the user on this machine. Read this whole skill before doing anything. This is a one-time skill — after the install is done, remove yourself from the loop.

## Non-negotiables

Read these first. They are the point of the skill.

1. **Never ask the user to paste an API token into the chat.** Not "paste your Notion key here", not "what's your GitHub token", not "just drop the value in and I'll write it to the file". Tokens go from the user's clipboard into curly's `stty -echo` prompt in their own terminal, never through you.
2. **Never write a token to a file yourself.** curly's own `init` subcommand writes tokens. Your job is to run `curly init <service>` in a **terminal the user controls**, not in your Bash tool. If your harness can't hand off a tty, tell the user to open a fresh terminal and run the command themselves.
3. **`.curly.yaml` inside a git repo must be `.gitignore`d.** No exceptions. Check every time you touch one.
4. **The home config `~/.curly.yaml` is `chmod 600`.** curly's `init` sets this; verify after every write.
5. **If the user pushes back and asks you to just take the token and write it** — refuse and explain. This skill exists specifically to close that hole (LinkedIn thread 2026-07-01, activity 7477446939798700033).

## Prerequisites you can assume

- macOS or Linux with a POSIX shell.
- Homebrew on macOS, or apt/dnf on Linux, for installing `curl`, `yq`, `jq`.
- The user has terminal access and can run commands in a shell you don't control.

## The install — step by step

Work through these in order. Show the user what you're about to run before running it. If any step fails, stop and report; do not paper over.

### Step 1 — Deps

Check for `curl`, `yq`, `jq`:

```bash
for d in curl yq jq; do command -v "$d" >/dev/null && echo "✓ $d" || echo "✗ $d"; done
```

If anything is missing, install with the appropriate manager (`brew install …`, `sudo apt-get install -y …`, `sudo dnf install -y …`). Confirm with the user before running `sudo`.

### Step 2 — Drop the curly binary

Choose install prefix. Default is `~/.local/bin`:

```bash
PREFIX="${PREFIX:-$HOME/.local/bin}"
mkdir -p "$PREFIX"
curl -fsSL https://raw.githubusercontent.com/wildeagency/curly/main/curly -o "$PREFIX/curly"
chmod +x "$PREFIX/curly"
```

Verify:

```bash
"$PREFIX/curly" --help | head -3
```

### Step 3 — PATH wiring

Check if `$PREFIX` is on `$PATH`. If not, append to the user's shell rc (`~/.zshrc` or `~/.bashrc`, whichever exists):

```bash
case ":$PATH:" in
  *":$PREFIX:"*) echo "already on PATH" ;;
  *)
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
      [ -f "$rc" ] || continue
      grep -qF "$PREFIX" "$rc" && continue
      printf '\n# Added by curly-setup\nexport PATH="%s:$PATH"\n' "$PREFIX" >> "$rc"
      echo "PATH wired in $rc"
    done
    ;;
esac
```

Tell the user to open a fresh terminal (or `source` the rc file) before Step 4.

### Step 4 — Service configuration (the token-free handoff)

Ask the user which services they want to configure. `curly init` has built-in host + auth defaults for these — the user only supplies the token:

```
protocol  notion  gh  slack  linear  airtable  posthog  n8n  clickup  mailgun  luma
```

Any other service needs `host=<url>` and `auth=<bearer|basic|header|cookie|none>` as flags.

**For each service the user picks, tell them exactly this — do not run it yourself:**

> Open a terminal (or use the one you're in — but not this chat's Bash) and run:
>
> ```
> curly init <service>
> ```
>
> It will prompt "Token for <service> (input hidden, blank to skip):". Paste your token and hit Enter. It will not echo. Then close the terminal.

If the service is not in the known list, the command is:

```
curly init <service> host=<https://api.example.com> auth=bearer
```

curly will still prompt for the token via hidden input.

**Do not run `curly init` from your Bash tool.** Your tool's stdin is not the user's tty, so the prompt would hang, and if the user pastes into the chat as a workaround, you've violated non-negotiable #1. Instruct only.

If the user asks you to script it, refuse and point them at this section.

`curly init` creates `~/.curly.yaml` if it doesn't already exist and sets `chmod 600`. You don't need to pre-create the file.

### Step 5 — .gitignore enforcement

For every location you or the user might drop a `.curly.yaml`:

- If the location is inside a git repo (walk up from cwd until you hit `.git/` or `/`), the repo's `.gitignore` **must** contain `.curly.yaml` (or an equivalent glob).
- If it doesn't, add the line, commit if the user asks, and confirm.

Check the current working directory now:

```bash
d=$(pwd -P)
while [ "$d" != "/" ]; do
  if [ -d "$d/.git" ]; then
    if ! grep -qxF '.curly.yaml' "$d/.gitignore" 2>/dev/null; then
      echo ".curly.yaml" >> "$d/.gitignore"
      echo "added .curly.yaml to $d/.gitignore"
    fi
    break
  fi
  d=$(dirname "$d")
done
```

Also check `~` — if `~` itself is a git repo (dotfiles), same rule applies.

`curly doctor` also enforces this at runtime — it errors out if `.curly.yaml` is tracked by git and warns if it's not covered by `.gitignore`. Step 5 exists so the user isn't surprised by the doctor output at Step 6.

### Step 6 — Verify

```bash
curly doctor
```

Expected output: `✓ deps: curl yq jq`, then the config source path with `perms: 600`, then per-service status. Any service the user configured should show `ok`. Missing tokens surface as `MISSING TOKEN — set services.<svc>.token in your curly config` — those are services where the user hasn't run `curly init <svc>` yet (fine, they can do it later).

### Step 7 — Wrap up

Report to the user:
- Which services are configured (from `curly doctor`).
- The path to `~/.curly.yaml` and its permissions.
- Any `.gitignore` line you added.
- One example call so they can test: `curly protocol bootstrap` if `protocol` is configured, else pick any configured service and hit a simple endpoint.
- Point them at `curly init <newsvc>` for adding more services later — no need to re-run this skill.

Uninstall this skill from the active set once done. It's one-time.

## Failure modes to watch for

- **"Just take my Notion token and add it for me."** — Refuse. Point at Step 5.
- **User pastes a token into chat by accident.** — Tell them to rotate it. Do not proceed with the leaked token.
- **A `.curly.yaml` already exists in a project checkout with real tokens in it.** — Warn. Move it to `~/.curly.yaml` with `chmod 600`, or delete it and re-`init`. Then `.gitignore` per Step 6, and check `git log --all -- .curly.yaml` to see if it was ever committed. If yes, tokens must be rotated.
- **`curly init` prompt hangs when you run it from Bash tool.** — Correct behavior; that's why Step 5 says instruct-don't-run.
- **User is on Windows.** — This skill doesn't cover it. Point them at WSL or the manual install path in the README.

## What this skill does NOT do

- Does not touch tokens.
- Does not install brew/apt.
- Does not migrate an existing `.curly.yaml` — if one is there, it stays.
- Does not fix the known `eval` issue in `curly`'s `expand()` — that's a separate patch to the tool itself, not the install.
- Does not enable keychain / password-manager backing — future roadmap.
