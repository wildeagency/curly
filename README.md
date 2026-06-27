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

## The 60-second install (recommended)

Open Claude Code or Codex CLI and paste:

> "Install curly from github.com/wildeagency/curly. Ask me which APIs I want to set up, then ask me for each token one at a time and write them into ~/.curly.yaml. `chmod 600` the file. Run `curly doctor` to verify."

The agent reads this README, drops the script in `~/.local/bin/curly`, asks you which services you want (Notion, GitHub, Slack, Linear, Airtable, Stripe, anything else), then asks for each token one at a time. You paste each token; the agent writes them into `~/.curly.yaml` directly and `chmod 600`s the file so only you can read it. Five minutes start to finish.

This is the same install everyone else does — just delegated to the agent that already lives in your terminal.

## The manual install

If you'd rather drive yourself:

```bash
brew install yq jq

mkdir -p ~/.local/bin
curl -sL https://raw.githubusercontent.com/wildeagency/curly/main/curly \
  -o ~/.local/bin/curly && chmod +x ~/.local/bin/curly

curl -sL https://raw.githubusercontent.com/wildeagency/curly/main/examples/curly.yaml \
  -o ~/.curly.yaml && chmod 600 ~/.curly.yaml
```

Edit `~/.curly.yaml`, replace the `xxx...` placeholders with your real tokens (delete the services you don't want), then:

```bash
curly doctor
```

`curly doctor` will warn you if the YAML's permissions are not `600` or `400` — your tokens are in this file, so it has to be readable only by you.

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

**`chmod 600 ~/.curly.yaml`.** Owner-only read/write. `curly doctor` checks this and warns if the file is world-readable. (The recommended install does it for you; do it yourself if you ran the manual install or edited the file with an editor that reset permissions.)

**Don't commit it.** Add `.curly.yaml` to your global `.gitignore`:

```bash
git config --global core.excludesfile ~/.gitignore_global
echo '.curly.yaml' >> ~/.gitignore_global
```

What `curly` does NOT protect against:

- **`ps aux` leak.** While a request is in flight, the full bearer token shows up in the process list (it's a curl argument). Anyone else on the same machine — including processes running as your user — can grep for it. Same risk as raw curl. If this matters for your threat model, curl supports `-H @file` to read headers from disk; `curly` doesn't use that today.
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
3. Look up the service, build a `curl` argv based on the `auth:` mode.
4. `exec curl`.

The subcommands (`services`, `doctor`) are a few lines each at the top, in a `case` statement.

---

## License

MIT. Built at [Wilde Agency](https://wilde.agency).
