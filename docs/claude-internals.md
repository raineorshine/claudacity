# Claude Desktop, Claude Code and Anthropic's API, as claudacity sees them

claudacity drives parts of Claude it does not own: Desktop's data directory, Claude Code's CLI, and Anthropic's OAuth-backed endpoints. None of this is a documented contract. Each fact below was observed on macOS in September 2026 (Claude Code 2.1.28x, Desktop 2.99xx); re-check it when behavior changes.

## Logins

- Each profile's Claude Code login is JSON under `claudeAiOauth` in the Keychain: `Claude Code-credentials` for the active profile, `claudacity-code-<profile>` for saved ones. It carries `accessToken`, `refreshToken`, `expiresAt` (ms), and `refreshTokenExpiresAt`. The active profile's `claudacity-code-<profile>` is the copy saved at the last switch away from it: Claude Code refreshes only the live entry, so `claudacity whoami` lists the active profile as `EXPIRED` while it works.
- Saved access tokens expire within hours, so reading an inactive profile's usage means refreshing first: `POST https://platform.claude.com/v1/oauth/token` with `{"grant_type":"refresh_token","refresh_token":…,"client_id":"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`. `console.anthropic.com/v1/oauth/token` returns 404.
- The token endpoint sits behind Cloudflare, which rejects curl's and Python's default user agents with `error code: 1010`. Send a CLI-style `User-Agent` (`src/http.zig` owns it).
- **A refresh rotates the refresh token.** The new login must be written back before anything else uses it (`keychain.update`, in place with `-U`), and any other copy of the old token is dead. Two tools refreshing the same saved login invalidate each other: running `claude-swap` alongside claudacity left both overflow profiles answering `invalid_grant` ("Refresh token not found or invalid"). The only recovery is signing in again: `claudacity use <p>`, `claude auth login --email <addr>`, `claudacity save <p>`.
- **`claude auth login --email <addr>` does not choose the account.** `--email` only becomes the OAuth `login_hint`; the browser authorizes whatever claude.ai account it is already signed in to and reports `Login successful`. Sign out of claude.ai (or sign in from a private window) first, and confirm with `claude auth status` before `claudacity save`. Two profiles showing identical 5-hour and weekly usage with the same reset times in `claudacity usage` are one account saved twice.
- **`claude auth login` writes into whichever profile is active.** It replaces `Claude Code-credentials` and rewrites `oauthAccount` in the active `~/.claude.<profile>.json`. claudacity's email column in `whoami` and the carry-over paths read that `oauthAccount`, so both follow the wrong account. `claudacity use <other>` and `claudacity handoff` then auto-save the active login into the active profile's `claudacity-code-<profile>`, destroying its own saved login.
- **A login records its plan at sign-in.** `subscriptionType` (`pro`, `max`, …) is stamped when the login is created and a refresh does not change it, so an upgrade leaves the saved login naming the old plan. `claudacity usage` (and `claudacity handoff`) rewrite it in `claudacity-code-<profile>` from the profile endpoint below; the live `Claude Code-credentials` entry is left to Claude Code.
- **Repairing a login made under the wrong profile:** `claudacity save <intended>` (copies the active login to where it belongs), swap the two `oauthAccount` blocks back between the profile JSONs, then `claudacity use <active>`. Using the profile that is already active skips the auto-save and restores its saved login to `Claude Code-credentials`.

- A 401 from a probe with the live `Claude Code-credentials` token usually means it expired (`claudacity whoami` shows `EXPIRED`), not that the route refuses OAuth. `claudacity usage` refreshes every login first.

## Endpoints (Bearer = the profile's access token)

- Usage: `GET https://api.anthropic.com/api/oauth/usage`, `anthropic-beta: oauth-2025-04-20`. Returns `five_hour` and `seven_day` blocks with `utilization` (percent) and `resets_at` (ISO 8601 with fractional seconds and offset); either block can be `null`. `five_hour` is `null` when the account has used nothing since its last 5-hour window ended.
- Profile: `GET https://api.anthropic.com/api/oauth/profile`, same beta header. `organization.organization_type` is `claude_max`, `claude_pro`, `claude_team` or `claude_enterprise`, mapped to Claude Code's `subscriptionType` by dropping the `claude_` prefix. Observed October 2026: an account upgraded from Pro reported `claude_max`.
- Cloud sessions: `GET https://api.anthropic.com/v1/sessions?limit=50`, headers `anthropic-beta: ccr-byoc-2025-07-29`, `anthropic-version: 2023-06-01`, `x-organization-uuid: <org>`. Pages with `has_more` / `last_id`; the next page is `&after_id=<last_id>`. `environment_kind` is `anthropic_cloud` for cloud sessions and `bridge` for local sessions served over Remote Control. `session_status` is `running`, `idle`, `requires_action` or `archived`. The repo is in `session_context.sources[].url` (type `git_repository`) and the branch in `external_metadata.current_branches`.

- Cloud environments (network allowlist, env vars, setup script) belong to the account, so each profile has its own. Same headers as cloud sessions. `GET https://api.anthropic.com/v1/environment_providers?limit=100` lists them (`environments`, `has_more`, `last_id`) with `config: null`; `kind` is `anthropic_cloud` or `bridge` (one per Remote Control machine and folder). `GET …/environment_providers/<environment_id>` returns `{"config":{…}}` with `environment_type`, `sub_type`, `cwd`, `init_script`, `environment`, `languages` and `network_config` (`allowed_hosts`, `allow_default_hosts`). `POST …/environment_providers/cloud/create` takes `{name, kind:"anthropic_cloud", description, config}`, and `POST …/environment_providers/<environment_id>` takes `{name, description, config}` and replaces it. claude.ai's own `…/private/organizations/<org>/environments/<id>` routes answer 403 to an OAuth token. Observed October 2026.

## Plugin marketplaces on claude.ai (observed October 2026)

- A personal marketplace added on claude.ai never re-syncs on push, "Sync automatically" notwithstanding: the repo gets no webhook. Cloud sessions load plugins only from the claude.ai account, and Desktop sessions on Claude Code 2.1.286 loaded the stale `<name>@synced` copy over a newer local install. claudacity syncs the account it switches to (`src/marketplaces.zig`).
- The OAuth token reaches only reads: `GET https://api.anthropic.com/api/oauth/organizations/<org>/marketplaces` (beta `oauth-2025-04-20`, needs the `user:plugins` scope) lists every marketplace with `id`, `name`, `scope` (`account` or `default`), `is_org_native` and `source.{source,repo,last_synced_sha}`; `…/marketplaces/<id>/plugins?limit=` lists its plugins. Per-marketplace reads and the sync route are 404 under `/api/oauth/`, and claude.ai's own route answers 403 "This endpoint does not accept OAuth access tokens".
- claude.ai's routes take the `sessionKey` cookie, which each profile's Desktop data holds (`Cookies`, host `.claude.ai`; read it with `?immutable=1` while Desktop runs). Base `https://claude.ai/api/organizations/<org>/marketplaces/`:
  - `GET list-account-marketplaces` → `{marketplaces:[…]}`, the account's own marketplaces only (not the default directory). Each record: `id`, `name`, `source` (`github`), `source_url`, `sync_status`, `last_synced_sha`, `sync_started_at`, `sync_ended_at`, `sync_errors` (JSON string, warnings even on success), `auto_sync_on_push`.
  - `GET <id>/account-get` → one record.
  - `POST <id>/account-sync` (body `{}`) → the record. A settled `sync_status` (`success`, `fail`, `failed_content`, `failed_transient`, `failed_auth`, `failed_limits`) is the result; `in_progress` or `unspecified` means poll `account-get`, as the web app does every 3s for up to 10 tries. 429 means a sync ran recently. When the repo has not moved, the POST answers `success` and leaves `sync_started_at` unchanged.
  - `POST create-account-marketplace` with `{name, source, source_url}`; `<id>/account-update`, `DELETE <id>/account-delete`, `PUT <id>/account-subscription`.
- Desktop's cookie decrypts with the `Claude Safe Storage` Keychain password: key = PBKDF2-HMAC-SHA1(password, `saltysalt`, 1003 rounds, 16 bytes), AES-128-CBC with an IV of 16 spaces over the value minus its `v10` prefix; the token starts at `sk-ant` (`src/desktop.zig`, `src/crypto.zig`).
- claude.ai's Cloudflare answers macOS `/usr/bin/curl` (LibreSSL) with its "Just a moment..." challenge whatever the user agent or HTTP version, so claudacity sends these requests through Zig's `std.http.Client` (`http.sendDirect`), which it lets through. Python's `urllib` gets through only with a browser `User-Agent`; its default agent is challenged too.

## Finding an undocumented endpoint

- Claude Code's binary is a Bun bundle, so `strings -n 6 "$(readlink -f "$(which claude)")" | grep -o '.\{200\}<route>.\{300\}'` shows the route with its headers and request body. Desktop's `/Applications/Claude.app/Contents/Resources/app.asar` greps the same way.
- An operation the CLI never performs (updating a cloud environment, for one) lives only in claude.ai's web bundle. curl gets Cloudflare's challenge page there. Load `https://claude.ai/code` in the Browser pane instead, signed in or not, and from `javascript_tool` fetch every script in `performance.getEntriesByType('resource')`, plus the chunk names those scripts reference, and grep them. Fetch in batches: one call times out after 45s.
- claude.ai's routes take its session cookie, not an OAuth token. Its `/v1/environment_providers/private/organizations/…` routes answer 403 to the Bearer token claudacity sends, while the CLI's route for the same data works. Confirm a route with a read-only GET before writing through it.
- Map the credential, the path prefix and the HTTP client separately: for marketplaces each had its own answer (OAuth reads only under `/api/oauth/`, cookie for writes, curl challenged). A probe that worked only with one header (a browser `User-Agent`) carries that header into any script built from it.
- claude.ai's chunks are flat files imported by relative name (`./shared-msg-0-….js`), so a chunk named in another's imports is fetched from the directory of a script already loaded.
- When a response's shape is unknown, print its keys and value types, never its values: environment configs carry env vars, which can hold secrets.

## Claude Desktop's data directory and account

- The active profile's Desktop data is the live `~/Library/Application Support/Claude`; only inactive profiles have a `Claude.<profile>` copy. A missing `Claude.<active>` is expected: claudacity writes it on the next switch away.
- Desktop keeps app settings in the data directory, so each profile has its own copy. On a switch claudacity copies the `preferences` and `mcpServers` keys of `claude_desktop_config.json` from the profile being left into the live one (`src/desktop_settings.zig`). `config.json`, cookies and `remote-control-state.json` hold account state and stay per profile, as do the org-derived preferences (`coworkHipaaRestricted`, `orgWorkAcrossAppsDisabled`) and the target's own entries in `...ByAccount` maps. The Remote Control settings are `ccRemoteControlDefaultEnabled` (connect new sessions), `remoteControlStayReachable` (use this computer from other devices) and `keepAwakeEnabled`, all in `preferences`.
- The name in Desktop's account picker is the claude.ai account's display name and has no tie to the claudacity profile name. Identify the signed-in account by email (`claudacity whoami`, or `oauthAccount.emailAddress` in `~/.claude.<profile>.json`). That file's `displayName` is Claude Code's cached copy and lags a rename made on claude.ai.

## Claude Desktop's local Code sessions

- One JSON record per session at `~/Library/Application Support/Claude/claude-code-sessions/<accountUuid>/<organizationUuid>/local_*.json`. The two ids come from `oauthAccount` in the profile's `~/.claude.<profile>.json`. Records hold `sessionId`, `cliSessionId`, `cwd`, `title`, `isArchived`, `createdAt`, `lastActivityAt`.
- Desktop reads the records only at launch; a record written while it runs appears after a restart. A record written from outside with a matching history file is listed and continues from that history.
- History: `~/.claude.<profile>/projects/<slug>/<cliSessionId>.jsonl` plus a same-named directory (subagents, tool results). `<slug>` is the `cwd` with every non-alphanumeric character replaced by `-`.
- Each running session is a separate process `…/Application Support/Claude/claude-code/<ver>/claude.app/Contents/MacOS/claude … --resume=<cliSessionId>`. `pkill -x Claude` (what `claudacity use` does) does not end them, so anything copying history after a quit waits for these first (`src/sessions.zig`).

## Claude Code CLI, unattended

- `claude -p --resume <id> --fork-session` loads a local session's full history into a headless copy without touching the original.
- `claude -p --teleport <session_id>` downloads a cloud session headlessly; run it in a throwaway clone of the session's repo, never a real checkout, because it checks out the branch.
- `claude --cloud "<title>"` refuses `--print`. Under `script -q /dev/null` it creates the session and prints `claude.ai/code/session_…`; `claude -p "<msg>" --cloud <id>` then sends to it headlessly.
- Sessions started from the CLI do not appear in Desktop's sidebar.
- Headless runs inside a cloned repo load that repo's `.claude/` settings, hooks and `.mcp.json` unless given `--setting-sources user --strict-mcp-config`.

## launchd

- A `StartCalendarInterval` job missed while the Mac sleeps runs on wake. A job that must only act at night checks the clock itself (`src/handoff.zig`, night window).
- launchd's `PATH` is minimal: the agent's plist sets it to include `claude`'s directory, Homebrew and system paths so `git` and its credential helper work.
