# curly

**Your curl one-liners are leaking your API keys.**

```bash
curl -H "Authorization: Bearer sk-live-7f3a..." https://api.example.com/v1/users
#                                  ^^^^^^^^^^^
#                                  → ~/.zsh_history forever
#                                  → terminal scrollback
#                                  → screen-share leak
```

`curly` is a ~130-line bash script that wraps `curl` with a YAML service registry. Tokens live in the YAML (chmod 600, never in your command line). One file, one place to edit.

```bash
curly gh /user
curly notion /pages -X POST -d '{...}'
curly stripe /v1/customers
```

Single bash file. Three dependencies (`curl`, `yq`, `jq`). No daemon, no agent, no SaaS account.

---

## The 60-second install (recommended)

Open Claude Code or Codex CLI and paste:

> "Install curly from github.com/wildeagency/curly. Ask me which APIs I want to set up, then ask me for each token one at a time and write them into ~/.curly.yaml. chmod 600 the file. Run `curly doctor` to verify."

The agent reads this README, drops the script, asks you which services you want (one of: Notion, GitHub, Slack, Linear, Airtable, Stripe, anything else), then asks for each token one at a time. You paste each token; the agent writes them into `~/.curly.yaml` directly. Five minutes start to finish.

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

## Sharing your config with a teammate

`~/.curly.yaml` has your real tokens in it. Don't commit it.

To share the *shape* (so your teammate can fill in their own tokens):

```bash
sed 's/^\(\s*token:\).*/\1 REDACTED/' ~/.curly.yaml > curly-shape.yaml
```

Send `curly-shape.yaml`. They paste their own tokens in.

---

## What's actually in the script

[All 130 lines.](curly) The hot path is at the bottom and reads top-down:

1. Look up the service in `~/.curly.yaml` (one `yq` call → JSON, then `jq` for fields).
2. Build a `curl` argv based on the `auth:` mode.
3. `exec curl`.

The subcommands (`services`, `doctor`) are a few lines each at the top, in a `case` statement.

---

## License

MIT. Built at [Wilde Agency](https://wilde.agency).
