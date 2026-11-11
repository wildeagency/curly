# curly

**Your curl one-liners are leaking your API keys.**

```bash
curl -H "Authorization: Bearer sk-live-7f3a..." https://api.example.com/v1/users
#                                  ^^^^^^^^^^^
#                                  → ~/.zsh_history forever
#                                  → terminal scrollback
#                                  → screen-share leak
```

`curly` is a single bash script that wraps `curl` with a YAML service registry. Tokens live in the YAML — kept private with `chmod 600` — and never appear on your command line. One file, one place to edit.

```bash
curly gh /user
curly notion /pages -X POST -d '{...}'
curly stripe /v1/customers
```

Single bash file. Three dependencies (`curl`, `yq`, `jq`). No daemon, no agent, no SaaS account.

---

## Install

**Tokens never go through the agent.** Neither install path below asks you to paste an API key into a chat. Tokens go from your terminal into `curly init`'s hidden-input prompt (`stty -echo`) and land directly in `~/.curly.yaml` at `chmod 600`. If any docs, blog post, or agent tells you to paste tokens into a chat window to set up curly, that flow is retired — point them here.

### One command (recommended)

Fetch the installer, read it, then run it, all in your own terminal:

```bash
curl -fsSLo curly-install.sh https://raw.githubusercontent.com/wildeagency/curly/main/install.sh
less curly-install.sh            # read it first. Never pipe an installer into sh.
sh curly-install.sh protocol     # deps, binary, PATH, then the hidden token prompt, then doctor
```

It checks for `curl`, `yq` and `jq` and installs them with brew if any are missing. It drops `curly` in `~/.local/bin`, adds that to PATH in `~/.zshrc` / `~/.bashrc`, and runs `curly init protocol`. That prompts for your token with input hidden. Get the token at [protocol.supply/api-keys](https://protocol.supply/api-keys) → **New key**. The installer finishes with `curly doctor`, which proves the token works. Any service name works in place of `protocol` (`sh curly-install.sh notion`). Leave the name off to install only.

The installer never takes a token as an argument. Argv lands in shell history and `ps`, so a bare value after the service name is refused.

### With an agent (Claude Code, Codex CLI, etc.)

Copy the setup skill into your agent's skills directory, then ask it to run. Claude Code reads `~/.claude/skills/`; Codex reads `~/.agents/skills/` (set `SKILLS=~/.agents/skills` below).

```bash
SKILLS=~/.claude/skills   # Codex: ~/.agents/skills
mkdir -p "$SKILLS/curly-setup"
curl -sL https://raw.githubusercontent.com/wildeagency/curly/main/skills/curly-setup/SKILL.md \
  -o "$SKILLS/curly-setup/SKILL.md"
```

Codex's default sandbox blocks network for commands; allow it with `network_access = true` under `[sandbox_workspace_write]` in `~/.codex/config.toml`. On Windows, use WSL2 (supported) or Git Bash with `jq` and `yq` installed — see [`@protocol/windows`](https://api.protocol.supply/@protocol/windows).

Then in your agent:

> "Install curly using the curly-setup skill."

The agent installs the script, wires PATH, and — for each service you name — tells you the exact command to run in your own terminal. You run `curly init <service>` yourself; curly prompts for the token with input hidden and writes it straight to the YAML. The agent never sees the token.

### Manual (yourself)

```bash
brew install yq jq   # or: sudo apt-get install -y yq jq

mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/wildeagency/curly/main/curly \
  -o ~/.local/bin/curly && chmod +x ~/.local/bin/curly
export PATH="$HOME/.local/bin:$PATH"   # add this line to ~/.zshrc or ~/.bashrc

# Per service — curly creates ~/.curly.yaml at chmod 600 on first run and
# prompts for the token with input hidden. Built-in defaults for common
# services (host + auth) mean you only supply the token:
curly init protocol       # then paste your protocol.supply token when prompted
curly init notion         # then paste your Notion integration token
curly init gh             # then paste your GitHub PAT
# ... same shape for: slack linear airtable posthog n8n clickup mailgun luma

# Anything not in the built-in list needs host= and auth=:
curly init stripe host=https://api.stripe.com auth=bearer
# (curly then prompts for the token)

curly doctor              # verifies deps, perms, .gitignore hygiene, and that each token WORKS
curly doctor --offline    # same, but token presence only (no network)
```

`curly doctor` will error out if `.curly.yaml` is tracked by git (rotate immediately) and warn if a repo-local `.curly.yaml` isn't covered by `.gitignore`.

**Token validity.** A token that is present is not a token that works. Doctor makes one cheap authenticated call per service and reports what came back. It never prints a token or a response body.

```
  protocol     bearer  ok (verified: GET /impulse/mine?limit=1 → 200)
  slack        bearer  INVALID — invalid_auth
  openai       bearer  INVALID — rejected (HTTP 401): expired, revoked, or wrong token
  gh           bearer  MISSING TOKEN — set services.gh.token in your curly config
  myapi        bearer  present, unverified — set services.myapi.check to an authenticated path
```

Known hosts (protocol, GitHub, Slack, Notion, Linear, Airtable, PostHog, ClickUp, Mailgun, OpenAI, Anthropic, Stripe, Apify, Cloudflare, Grafana Cloud, Telegram, n8n) have a built-in probe. For anything else, name a path that **requires** auth. A public path answers 200 to any token, so it proves nothing:

```yaml
  myapi:
    host: https://api.example.com
    auth: bearer
    token: ...
    check: /v1/me                        # GET; must need auth
    # check_body: '{"query":"{ me }"}'   # set this to POST instead
    # check: false                       # skip the probe for this service
```

Doctor exits 1 when any token reads `INVALID`, `EXPIRED`, `REJECTED` (403), or `REFUSED` (host-override guard). Unreachable hosts, 404s, 429s, and 5xx read `unverified`, not invalid. `CURLY_DOCTOR_TIMEOUT` sets the per-probe timeout (default 8s).

---

## Quickstart

```bash
# GitHub
curly gh /user | jq .login

# Notion — auto Content-Type for -d bodies
curly notion /pages -X POST -d '{"parent":{"page_id":"..."}, "properties":{...}}'

# Linear, Slack, Airtable, ClickUp, Telegram, Mailgun, PostHog, n8n…
# All share the same shape:
curly <service> <path> [curl-options]
```

Leading `/` on `<path>` is optional: `curly gh user` == `curly gh /user`.

Any `curl` flag passes through: `-G`, `-X DELETE`, `-d @body.json`, `--data-urlencode`, `-i`, `-v`, `-o file`…

**Exit codes reflect HTTP status.** curly runs with `--fail-with-body`, so an HTTP error is a non-zero exit — a 4xx/5xx **fails** instead of masquerading as success, while the error body is still printed so you can see (and parse) what went wrong. `2xx/3xx` → exit 0; `4xx/5xx` → exit 22; a transport failure keeps curl'"'"'s own exit code. This means `curly svc /thing && next` no longer runs `next` on a 404.

---

## Adding a service

It's a YAML edit. The script never needs touching.

```yaml
services:
  stripe:
    host: https://api.stripe.com
    token: PASTE_YOUR_STRIPE_SECRET_KEY_HERE
    auth: bearer
```

Then `curly stripe /v1/customers | jq .data[0].email`.

### Schema

| field | type | notes |
|---|---|---|
| `host` | string | Base URL (no trailing `/`). |
| `token` | string | The secret. Pasted literal, or `${VAR}` to pull from env (escape hatch for vault tools like `op run`). |
| `auth` | `bearer` \| `basic` \| `header` \| `cookie` \| `none` | How to send the token. |
| `auth_header` | string | Required when `auth: header`. e.g. `X-Api-Key`. |
| `headers` | map | Static request headers. Drop a header by leaving the value empty. |
| `user_agent` | string | Sent as `User-Agent`. Some anti-bot pages need a browser UA. |

Worked examples in [`examples/curly.yaml`](examples/curly.yaml) cover every shape: bearer, basic (Mailgun), non-`Bearer` header (ClickUp puts the token raw in `Authorization`, n8n uses `X-N8N-API-KEY`), cookie (Luma), and token baked into the URL path (Telegram).

---

## Project-local overrides

`curly` reads a chain of `.curly.yaml` files and deep-merges them. Files closer to your current directory override files further away:

1. `~/.curly.yaml` — your personal base (lowest precedence)
2. Every `.curly.yaml` from `/` down to `$PWD` — each one overrides the previous

So you can drop a `.curly.yaml` inside any project to point one service at a different host, swap a token, or add a project-only service. Everything else stays inherited from your home file.

```yaml
# ~/.curly.yaml
services:
  n8n:
    host: https://n8n.prod.example.com
    token: PROD_TOKEN
    auth: header
    auth_header: X-N8N-API-KEY
```

```yaml
# ~/code/staging-tools/.curly.yaml — only what changes for this project
services:
  n8n:
    host: http://localhost:5678/api/v1
    token: LOCAL_DEV_TOKEN
```

Running `curly n8n /workflows` from inside `~/code/staging-tools/` (or any subdirectory) hits localhost with the dev token, while everywhere else still hits prod. `auth` and `auth_header` are inherited from home — you only restate the fields you're overriding. The merge is deep, so an override to `headers.X-Foo` keeps the rest of `headers` intact.

`curly doctor` shows the full chain in precedence order so you can see exactly what's stacking:

```
✓ config sources (later overrides earlier):
    /Users/me/.curly.yaml                       (perms: 600)
    /Users/me/code/staging-tools/.curly.yaml    (perms: 600)
```

**One escape hatch.** Set `CURLY_YAML=/path/to/file.yaml` to bypass the chain entirely and read only that one file. Handy for `op run` / `aws-vault` flows that hand you a fully-rendered config.

**`chmod 600` and gitignore.** Anywhere `.curly.yaml` lives, it can hold tokens. Same rules as the home file: `chmod 600`, and add `.curly.yaml` to your `.gitignore` (or global excludesfile). If you want to commit a shared shape for teammates, redact tokens first (see [Sharing your config with a teammate](#sharing-your-config-with-a-teammate)).

---

## Security

`~/.curly.yaml` holds your tokens in cleartext. Two house rules:

**`chmod 600 ~/.curly.yaml`.** Owner-only read/write. `curly init` sets this on file creation. `curly doctor` warns if the file is world-readable.

**Don't commit it.** `curly doctor` **errors out** if any `.curly.yaml` in the config chain is tracked by git — that's a rotate-your-tokens-now condition. It also warns if a repo-local `.curly.yaml` isn't covered by `.gitignore`. Best practice: add `.curly.yaml` to your global `.gitignore` so you can't forget:

```bash
git config --global core.excludesfile ~/.gitignore_global
echo '.curly.yaml' >> ~/.gitignore_global
```

**Host-override guard.** If a `.curly.yaml` inside a project directory changes `host` for a service while inheriting the token from `~/.curly.yaml`, curly refuses the request — that shape can exfiltrate real credentials to an attacker-controlled endpoint. Opt in per-invocation with `CURLY_ALLOW_HOST_OVERRIDE=1` if the shape is intentional.

**No `eval` on config values.** `${VAR}` and `${VAR:-default}` expand via bash indirection (`${!name-}`), not `eval`. Anything else in a YAML value — backticks, `$(…)`, stray quotes — passes through as literal text and cannot execute code.

**Token stays out of argv.** Credentials and config headers reach curl as a `-K` config through an in-memory process-substitution pipe, never as `-H` arguments, so `ps aux` and `/proc/<pid>/cmdline` don't show them.

What `curly` does NOT protect against:

- **Backups / Time Machine.** If `~/.curly.yaml` is in your backup set, the tokens go with it. Exclude the file if that matters.

What `curly` does protect against:

- Tokens in your shell history (`~/.zsh_history` is `chmod 644` by default; `~/.curly.yaml` is `chmod 600`).
- Tokens in your terminal scrollback / screen-share / Zoom recording.
- Tokens pasted by accident when someone says "share your screen real quick."

## Sharing your config with a teammate

To share the *shape* of your config (so your teammate can fill in their own tokens):

```bash
sed 's/^\(\s*token:\).*/\1 REDACTED/' ~/.curly.yaml > curly-shape.yaml
```

Send `curly-shape.yaml`. They paste their own tokens in.

---

## What's actually in the script

[Read the source.](curly) The hot path is at the bottom and reads top-down:

1. Discover every `.curly.yaml` in the chain (`$HOME` + ancestors of `$PWD`).
2. Deep-merge them into a single JSON blob via `yq ea`.
3. Look up the service. Credentials and config headers go into a `curl -K` config, not argv.
4. `exec curl`, with that config on a process-substitution fd, so the token never shows up in `ps`.

The subcommands (`services`, `doctor`) are a few lines each at the top, in a `case` statement.

---

## License

MIT. Built at [Wilde Agency](https://wilde.agency).
