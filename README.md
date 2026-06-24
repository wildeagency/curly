# curly

**Your API token is sitting in your bash history.**

```bash
curl -H "Authorization: Bearer sk-live-7f3a..." https://api.example.com/v1/users
#                                  ^^^^^^^^^^^
#                                  → ~/.zsh_history forever
#                                  → screen-share leak
#                                  → paste-into-Slack leak
```

`curly` is a ~120-line bash script that wraps `curl` with a YAML service registry. Tokens live in a separate file you never paste into a terminal. The command-line stays clean:

```bash
curly gh /user
curly notion /pages -X POST -d '{...}'
curly stripe /v1/customers
```

That's it. Single file, three commands (`curl`, `yq`, `jq`), no daemon, no agent, no SaaS account.

---

## Install

```bash
brew install yq jq

mkdir -p ~/.local/bin
curl -sL https://raw.githubusercontent.com/wildeagency/curly/main/curly \
  -o ~/.local/bin/curly && chmod +x ~/.local/bin/curly
```

Then create your config:

```bash
curl -sL https://raw.githubusercontent.com/wildeagency/curly/main/examples/curly.yaml \
  -o ~/.curly.yaml
curl -sL https://raw.githubusercontent.com/wildeagency/curly/main/examples/curly.env.tmpl \
  -o ~/.curly.env && chmod 600 ~/.curly.env
# Edit ~/.curly.env — paste the tokens you actually have.
```

Verify:

```bash
curly doctor
```

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

Any `curl` flag passes through: `-G`, `-X DELETE`, `-d @body.json`, `--data-urlencode`, `-i`, `-v`, `-o file`, `--limit-rate`…

---

## Adding a service

It's a YAML edit. The script never needs touching.

```yaml
services:
  stripe:
    host: https://api.stripe.com
    token: ${STRIPE_API_KEY}
    auth: bearer
```

Then add `STRIPE_API_KEY=sk_live_xxx` to `~/.curly.env`.

```bash
curly stripe /v1/customers | jq .data[0].email
```

### Schema

| field | type | notes |
|---|---|---|
| `host` | string | Base URL (no trailing `/`). Supports `${VAR}` and `${VAR:-default}`. |
| `token` | string | Passed to the auth mode. Supports `${VAR}`. |
| `auth` | `bearer` \| `basic` \| `header` \| `cookie` \| `none` | How to send the token. |
| `auth_header` | string | Required when `auth: header`. e.g. `X-Api-Key`. |
| `headers` | map | Static request headers. Values support `${VAR}` — header is dropped if value resolves empty. |
| `user_agent` | string | Sent as `User-Agent`. Some anti-bot pages need a browser UA. |

Worked examples in [`examples/curly.yaml`](examples/curly.yaml) cover every shape: bearer (most APIs), basic (Mailgun), non-`Bearer` header (ClickUp puts the token raw in `Authorization`, n8n uses `X-N8N-API-KEY`), cookie (Luma), token baked into the URL path (Telegram), conditional headers that drop when their env var is empty (protocol.supply's `X-Ghost-User-Id`), and env-overridable hosts (n8n, PostHog).

---

## Why a separate `.env` file?

Because `curly.yaml` is safe to share — post it on LinkedIn, commit it to your team's dotfiles repo, paste it into a GitHub issue. `~/.curly.env` (chmod 600) holds the secrets and never leaves your machine.

This is the same separation `1Password CLI`, `aws-vault`, `ssh-agent`, and `op run` give you — without any of the infrastructure.

---

## Config search order

| file | purpose |
|---|---|
| `~/.curly.yaml` (or `$CURLY_YAML`) | global service registry |
| `~/.curly.env` (or `$CURLY_ENV_FILE`) | global secrets |
| `./.curly.env` | project-local secrets (sourced last → wins) |

---

## What's actually in the script

[All 126 lines.](curly) The hot path is at the bottom and reads top-down:

1. Source `~/.curly.env` so YAML `${VAR}` references resolve.
2. Look up the service in `~/.curly.yaml` (one `yq` call → JSON, then `jq` for fields).
3. Build a `curl` argv based on the `auth:` mode.
4. `exec curl`.

The subcommands (`services`, `doctor`) are a few lines each at the top, in a `case` statement.

---

## License

MIT. Built at [Wilde Agency](https://wilde.agency).
