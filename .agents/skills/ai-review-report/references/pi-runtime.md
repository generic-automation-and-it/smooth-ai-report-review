# pi runtime facts

Measured 2026-11-17 on macOS arm64 (Darwin 27.2.0), pi `1.5.2` (npm `latest`, the newest release at
measurement time) and OpenCode `v2.0.29`. All model traffic went to a throwaway localhost
OpenAI-compatible endpoint under `.context/pi-cli/spike/` (gitignored); no provider secret was used and
no request left the machine. Every command below is written with a dummy local key referenced as
`$MOCK_KEY`; values are never recorded.

Later pins: re-run the command in a section to re-measure that fact. `references/` is edit-time
documentation and is never read during a review.

## M1 Install

- `npm` route installs an exact version without a preinstalled Node check by the package itself:
  `engines` declares `node >=22.19.0`, and npm only warns when the engine is unmet unless
  `--engine-strict` is set, so the gate must check Node itself.
- `npm view @earendil-works/pi-coding-agent@1.5.2 engines dependencies --json` records the exact
  direct pins and the Node floor. Direct dependencies are exact versions; their transitive ranges are
  not pinned without the published lockfile.
- The official `pi.dev` installer (`curl -fsSL https://pi.dev/install.sh | sh`) resolves
  `https://pi.dev/api/installer/releases/latest` — it has **no exact-version argument** — and pins the
  whole tree from the downloaded `package-lock.json`. When Node is missing or below 22.19 it offers an
  interactive install; with no terminal it exits and asks the user to install Node first.
- GitHub's `ubuntu-latest` image (Ubuntu 24.04 runner readme) ships Node `22.23.4`, above the floor.

```bash
npm install --prefix .context/pi-cli/spike/pi-install --ignore-scripts \
  @earendil-works/pi-coding-agent@latest
npm view @earendil-works/pi-coding-agent@1.5.2 engines dependencies --json
curl -sf https://pi.dev/install.sh | grep -nE 'releases/latest|package-lock|22\.19'
curl -sf https://raw.githubusercontent.com/actions/runner-images/main/images/ubuntu/Ubuntu2404-Readme.md \
  | grep -n 'Node.js'
```

Observed: exact npm install of 1.5.2 succeeded (123 packages, rc 0); the installer pins transitives
but cannot take a version pin.

## M2 Print contract

`pi --print --no-session` with the prompt on stdin writes **only the final answer** to stdout and
nothing else. Exit codes were measured with a scripted endpoint:

| Response | Exit | stdout | stderr |
|---|---|---|---|
| 200 answer | 0 | final answer only | empty |
| HTTP 401 | 1 | empty | `401: {...}` |
| HTTP 404 | 1 | empty | `404: {...}` |
| HTTP 500 | 1 | empty | `500: {...}` |
| unknown model id | 0 | answer | `Warning: Model "<id>" not found for provider "<id>". Using custom model id.` |
| empty answer | 0 | empty | empty |
| length-truncated answer | 0 | empty | empty |

`--mode json` also exits 0 for empty and truncated answers, so it is unsuitable for the gate.

```bash
printf 'Say OK' | pi --print --no-session --model <provider>/<model>
printf 'Say OK' | pi --print --no-session --mode json --model <provider>/<model>
```

The unknown-model case is not a failure: pi silently accepts an arbitrary model id for a declared
provider, so the gate's preflight must verify the requested id itself (M3).

## M3 Providers

`models.json` can declare every OpenCode provider ID, including ids that shadow a pi built-in
(`openai`, `anthropic`): a built-in ID changes that provider, any other id adds one. The SDK → pi
`api` mapping measured against `assets/opencode.json`:

| OpenCode `npm` | pi `api` |
|---|---|
| `@ai-sdk/google` | `google-generative-ai` |
| `@ai-sdk/github-copilot` | `openai-completions` |
| `@ai-sdk/openai` (chat) | `openai-completions` |
| `@ai-sdk/openai` (Responses API) | `openai-responses` |
| `@ai-sdk/openai-compatible` | `openai-completions` |
| `@ai-sdk/anthropic` | `anthropic-messages` |
| `@openrouter/ai-sdk-provider` | `openai-completions` |

- `--model openrouter/deepseek/deepseek-v4-pro` resolves to provider `openrouter` and model
  `deepseek/deepseek-v4-pro`; the request body carried exactly that model id.
- `$NAME` interpolation works in `apiKey` (the request carried the resolved local key) and **does not
  work in `baseUrl`** (a `$VAR` base URL failed with `Invalid URL`). Gate-derived `models.json` must
  write literal URLs.
- `pi auth check --provider <id>` prints `ready` when the referenced key variable is set and
  `not_ready` when it is not.
- `pi --list-models` lists only the built-in catalog; models a `models.json` declares are **not**
  listed. Requested ids cannot be verified through `--list-models`.

```bash
OPENROUTER_KEY=$MOCK_KEY pi --print --no-session --model openrouter/deepseek/deepseek-v4-pro
pi --list-models | grep -c openrouter
pi auth check --provider openrouter
```

## M4 Native context

Fixture: a git repo with root `AGENTS.md`, root `CLAUDE.md`, root `AGENTS.override.md`, nested
`ci_temp/AGENTS.md` and `sub/AGENTS.md`; cwd is `ci_temp/chunk_1`. The system prompt each runtime sent
to the local endpoint was inspected for each marker.

| Runtime | Loaded at start | Marker observed |
|---|---|---|
| pi (default) | root `AGENTS.override.md` (replaces `AGENTS.md`/`CLAUDE.md`), nested `ci_temp/AGENTS.md` | 47163-char prompt |
| pi `-nc` | none | 14077-char prompt |
| OpenCode v2 (`OPENCODE_DISABLE_CLAUDE_CODE=1`) | root `AGENTS.md`, nested `ci_temp/AGENTS.md`; no `CLAUDE.md`, no override | 34986-char prompt |

On read: OpenCode v2 **attaches the nested `AGENTS.md`** of a directory after the model reads a file
there (the marker appeared in the following request). pi does **not** attach it.

```bash
printf 'hi' | pi --print --no-session --model <provider>/<model>
printf 'hi' | pi --print --no-session -nc --model <provider>/<model>
OPENCODE_DISABLE_CLAUDE_CODE=1 opencode run --standalone --agent review --model <provider>/<model>
```

Consequence for the adapter: the pi native-context set is the content OpenCode loads for the same cwd
— root `AGENTS.md` content (never the override) plus each nested ancestor `AGENTS.md` — supplied with
`--append-system-prompt` under `-nc`; OpenCode's on-read attachment has no direct pi equivalent and
must be implemented explicitly if parity requires it.

## M5 Tools and permissions

pi's default request advertises `read`, `bash`, `edit`, `write`. Enabling the search tools with
`--tools read,grep,find,ls` yields: `read {path, offset, limit}`, `grep {pattern (required), path,
glob, ignoreCase, literal, context, limit}`, `find {pattern, path, limit}`, `ls {path, limit}`.

- pi `grep` **searches hidden files** and **skips gitignored files** (a marker in `.hidden.txt` was
  found; a marker in a `.gitignore`d file was not).
- A pi `tool_call` handler receives the tool name and its input, so a `grep` with a `path` is decidable
  by path; a path-less search must be decided against the directory it would search.
- OpenCode v2 `read` permission patterns match the **file path**: `*.env` deny blocked a read of
  `.env`, `/proc/**` deny blocked `/proc/self/environ`, and a later `*.env.example` allow overrode an
  earlier `*.env.*` deny.
- OpenCode v2 `grep` permission patterns match the **query**, not the path: with `*.env` deny, a search
  whose *path* was `.env` and whose *pattern* was `SECRET` was allowed; a search whose *pattern* was
  `.env` was denied.

```bash
printf 'go' | pi --print --no-session --tools read,grep,find,ls --model <provider>/<model>
printf 'go' | OPENCODE_DISABLE_CLAUDE_CODE=1 opencode run --standalone --agent review \
  --model <provider>/<model>
```

## M6 Isolation

With `--no-approve` a hostile checkout has no effect: `.pi/settings.json`, `.pi/extensions/marker.ts`,
`.pi/mcp.json`, `.pi/SYSTEM.md` and `.agents/skills/x/SKILL.md` neither altered the system prompt nor
the tool list, wrote no marker and started no MCP server. With `--approve` the same checkout ran the
extension in-process, spawned the MCP server, injected `SYSTEM.md`, and replaced the tool list from
project settings — project trust is never granted by the gate.

`-ne -e <path>` loads exactly that extension and nothing else. `-ns`, `-np` and `--no-mcp` disable
skills, prompt templates and MCP discovery. `PI_OFFLINE=1` still permits provider calls (a local request
was served normally). `PI_TELEMETRY=0` and `PI_SKIP_VERSION_CHECK=1` are accepted.

Even with `--no-session`, pi writes `models-store.json` and `auth.json` into `PI_CODING_AGENT_DIR`, so
that directory must be gate-owned, run-local and mode 0700.

```bash
printf 'go' | PI_CODING_AGENT_DIR=<gate-dir> pi --print --no-session --no-approve \
  -ns -np --no-mcp -ne --model <provider>/<model>
printf 'go' | PI_CODING_AGENT_DIR=<gate-dir> PI_OFFLINE=1 pi --print --no-session --no-approve \
  -ns -np --no-mcp -ne --model <provider>/<model>
```

## M7 Wire shape

With an `openai-completions` provider pi sends `POST {baseUrl}/chat/completions` with
`Authorization: Bearer <resolved key>` and a body carrying `model`, `messages`, `tools`,
`stream: true`, `stream_options`, `max_completion_tokens` and `store`. The reply is SSE:
`data: {"object":"chat.completion.chunk","choices":[{"delta":{"content":…},"finish_reason":null}]}`,
a final chunk with `finish_reason` and `usage`, then `data: [DONE]`. Tool calls arrive as
`delta.tool_calls[]` with `index`, `id`, `type` and `function {name, arguments}`. Headers include the
OpenAI SDK's `x-stainless-*` set and `user-agent: pi/<version> (<os>; node/<version>; <arch>)`.

```bash
printf 'go' | pi --print --no-session --model <provider>/<model>   # inspect the recorded request
```

The L2 mock in the `pi-backend-regressions` job must implement this SSE shape, not a plain JSON body.

## M8 Attribution

pi is MIT licensed (`Copyright (c) 2025 Mario Zechner`, repository `earendil-works/pi`). The published
docs describe applications "powered by Pi"; no separate trademark or notice requirement was found.
The display name used by the runtime footer is `Pi`.

```bash
npm view @earendil-works/pi-coding-agent@1.5.2 license repository.url --json
```

## Outcomes

| Decision | Value |
| D2 | Minimum supported pi version is `1.5.2` — the release measured here; an explicit pin must be at or above it and is installed exactly, and a cached binary below it is rejected even when first on `PATH`. |
| D3 | Install route is the npm route: `npm install -g --ignore-scripts @earendil-works/pi-coding-agent@<exact>`, behind a Node ≥ 22.19 check that fails before any model call; the `pi.dev` installer is rejected because it cannot take an exact version. Transitive dependencies are not pinned by this route — the accepted trade-off. Never `actions/setup-node`. |
| D6 | The explicit native-context set is the root `AGENTS.md` content (the OpenCode-loaded set, never `AGENTS.override.md`) plus every nested ancestor `AGENTS.md` between the repo root and the chunk cwd, supplied with repeatable `--append-system-prompt` under `-nc`. OpenCode attaches a nested `AGENTS.md` on read; pi does not, so that attachment is implemented explicitly for pi. |
| D7 | Content search is **denied** to both roles on both backends: OpenCode matches `grep` permission patterns on the query, not the path, so `grep` cannot be fenced by file path on both runtimes. |
| D15 | OpenCode **can** express a `/proc/**` read deny (verified effective on `/proc/self/environ`), so the deny is added explicitly instead of recording a Current Status gap. |

## Stop verdict

- **Can pi meet every HLD Goal 3 and Goal 4 criterion?** Yes, with the mechanisms measured here: a
  `tool_call` handler blocks any tool name (built-in, extension or MCP) and any path it can resolve
  (M5, M6); `--no-approve` plus a gate-owned `PI_CODING_AGENT_DIR` keeps project configuration out
  (M6); a per-attempt child environment can carry exactly one provider key (M3); `$NAME` key references
  keep key values out of files (M3). pi has no OS sandbox of its own (external only); the role contract
  is enforced by the pinned extension, which is the design's chosen mechanism.
- **Can OpenCode deny `read` by path?** Yes — path-glob `read` denials are enforced, `/proc/**`
  included (M5). The plan's WT-02 stop condition is not triggered.
