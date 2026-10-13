# Contributing

## Scope

`fx` is a CLI-first coding agent written in Zig.

Contributions should preserve that direction:

* CLI-first over terminal-IDE behavior

* explicit contracts over ad hoc strings and branches

* permission-first security model

* small, reviewable changes

* honest docs and status reporting

## Setup

Requirements:

* Zig `0.17.0+`

* interactive terminal for manual shell testing

* a model connection for model-backed flows. [Custom model connections](https://fx.sh/docs/configure-fx/custom-model-connections) support local and remote endpoints. Vercel OAuth via `fx login`, macOS Keychain API keys via `fx setup`, `AI_GATEWAY_API_KEY`, and `VERCEL_OIDC_TOKEN` are also supported

Common commands:

```bash
zig fmt src/
zig build
zig build test
zig build run
```

## Verification Workflow

Keep the local development loop focused: run the narrowest test that covers the changed path, build fx, and exercise the change using `./zig-out/bin/fx`. The installed `fx` on `PATH` is not valid development evidence.

Once the focused checks pass, create a clean checkpoint commit, push the non-`main` feature branch, and open a draft PR immediately. **CI** runs on Linux x86_64, which is the gate for every change. It checks formatting, the public surface, and the compactor boundary, runs the ReleaseSafe unit tests, and builds and smoke-tests fx.

macOS checks run only when a change can behave differently on macOS: a Zig file with a macOS, BSD, or Linux code path, `build.zig`, the macOS signing script, or the macOS checks themselves. Add the `ci:macos` label or run `gh workflow run macos.yml --ref <branch>` to request them for any other change. The `macOS arm64` check passes without a macOS runner when the change does not need one.

Do not mark the draft PR ready until `Build & Test`, `Shellcheck`, `Startup Latency`, `macOS arm64`, and the final ship gate have succeeded for the exact current commit. A result from an older commit does not count.

Every pull request also receives informational ReleaseSafe binary-size
comparisons for Linux x86_64, Linux arm64, macOS x86_64, and macOS arm64. Each
comparison builds the pull request merge commit and base commit on the same
native runner, reports exact file and ELF or Mach-O section deltas, and emits a
warning at increases of 52,429 bytes (0.050000 MiB) or more. The warning requests
investigation but does not reject a valid feature solely for adding code. The same jobs smoke-test each release-style
binary; the Linux arm64 and macOS binaries run nowhere else on a pull request.

## Pull Requests

Every PR must carry exactly one label that describes its primary intent:

* `type: bug`: fixes incorrect behavior

* `type: feature`: adds a new user-facing capability

* `type: improvement`: improves existing user-facing behavior

* `type: docs`: changes documentation only

* `type: maintenance`: changes internal tooling, dependencies, CI, or implementation structure without a user-facing behavior change

* `type: release`: prepares or repairs a release

* `type: security`: fixes or hardens a security boundary

If you can manage labels on `vercel-labs/fx`, which takes triage access or higher, apply the label when you open the PR. For a mixed PR, choose the label that best describes why the PR exists. If you contribute from outside the organization, you cannot add labels and do not need to: a maintainer applies the label during review, so open your PR and mark it ready as usual. Keep the title as a clean imperative sentence and do not add bracketed type prefixes such as `[bug]` or `[improvement]`.

Requesting extra CI also needs access: the `ci:macos` label takes triage access, and `gh workflow run` takes write access. If you need the macOS checks or another on-request run and cannot start it yourself, ask in your PR and a maintainer will start it.

If an AI coding agent writes any of your contribution's prose, including the PR title and description, commit messages, documentation, and issues, it must use the `technical-writer` skill in `.fx/skills/technical-writer/`.

## Repo Shape

* `src/main.zig`: composition root only

* `src/core/`: contracts, runtimes, config, sessions, permissions, skills

* `src/tools/`: built-in tool implementations

* `src/ui/`: terminal rendering, event loop, input, transcript

* `src/gateway/`: AI Gateway client transport

* `.fx/skills/`: optional fx-native workspace-level skill root

* `skills/`: optional shared workspace-level skill root

## Collaboration Rules

Before adding a new feature, answer these first:

1. Which module owns the behavior?
2. What is the typed contract?
3. Does it need persistence?
4. Does it need both text and JSON output?
5. What docs and tests land with it?

If that is unclear, stop and define it first.

## Configuration and State

Config precedence (highest wins):

1. Environment variables such as `FX_PROVIDER`, `FX_MODEL`, `FX_PERMISSION_MODE`, and `FX_MAX_AGENT_STEPS`
2. `~/.fx/settings.json` → `workspaces["<workspace_path>"]` (profile workspace overrides)
3. `~/.fx/settings.json` top-level (profile global settings)
4. `<workspace>/.fx.json` (committed project defaults)
5. Built-in defaults

Project `.fx.json` accepts only repo-safe defaults: `sandbox`, `max_agent_steps`, `max_tool_result_bytes`, and `context`. Profile-owned keys such as `provider`, `providers`, `models`, `model`, `effort`, `fast_mode`, `slash_menu_categories`, `startup_scrollback`, `prompt_history`, `statusLine`, `skill_match_fuzzy`, `first_call_tool_choice`, `auto_upgrade`, `auto_compact_percent`, `update_channel`, `permission_mode`, `permission`, and `skill_symlink_authorities` are ignored from project config before their values are parsed.

`skill_symlink_authorities` is an array of absolute directories that symlinked skills may resolve into, such as an app bundle or `/nix/store`. It is read at startup, a workspace override replaces the global list, and its entries are combined with the colon-separated `FX_SKILL_SYMLINK_AUTHORITIES` environment variable.

Runtime state lives under `~/.fx/`:

* `~/.fx/sessions/<session-id>/session.json`

* `~/.fx/sessions/<session-id>/background/`

* `~/.fx/sessions/<session-id>/subagent/`

* `~/.fx/sessions/<session-id>/logs/`

Sessions are global and portable across workspaces. Each session tracks a `workspace_root` that updates when resumed from a different directory.

Subagent children are internal ordinary sessions with their own `~/.fx/sessions/<child-id>/` directory and history. The parent owns one bounded `subagent/children.json` registry; each child carries only an immutable owner marker. Child sessions are hidden from ordinary session discovery and cannot be resumed directly. A first `subagent.message` creates a named persistent child for that parent; later messages continue it, and optional instructions replace only its child-specific system overlay.

## Skills

There are two distinct skill categories in `fx`:

* `fx` roots that belong to the product itself: `.fx/skills`, `skills/`, `~/.fx/skills`

* compatibility roots discovered for other agent installs: `.opencode/skills`, `.codex/skills`, `.claude/skills`, `.agents/skills`, `.claw/skills`, plus their global equivalents

`/skills list` should make that distinction visible to the user.

`/skills add` and `/skills install` install full skill directories into the profile-owned `~/.fx/skills` managed root, not just `SKILL.md`. Workspace `.fx/skills` and `skills/` remain discoverable project-local instructions, not managed install targets.

The interactive agent can also install skills via the `install_skill` tool when the user asks to install one in conversation, including pasted `npx skills add ...` syntax.

## Slack installation testing

`src/core/slack/install.zig` owns workspace bot installation, local credential
persistence, and explicit refresh. The web bridge contract is fixed to
`https://fx.sh/api/slack/install/config`, `/api/slack/install`, and
`/api/slack/oauth/callback`.

`FX_E2E_SLACK_ORIGIN` accepts only an HTTP `127.0.0.1`
origin with a non-privileged port, serving public metadata plus mocked
`/api/oauth.v2.access` and `/api/auth.test` responses. Production uses pinned
Slack endpoints. Local records bind to the bridge origin to prevent fixture
commands from refreshing production credentials. `FX_NO_OPEN_BROWSER=1` prints
the start URL for headless operation; authorization still requires a browser on
the same computer as the listener.

## Permissions and Auto Mode

Security is permission-first.

* `permission_mode` controls baseline behavior (`ask`, `auto`, or `full-access`; `yolo` remains an alias)

* `permission` config applies OpenCode-style wildcard rules

* session `always` approvals are non-persistent; command approvals match the exact command while other grant categories may use patterns

* configured denies are evaluated before saved-session rules; an exact saved-session deny can narrow a configured allow, while an exact saved-session allow can satisfy an unresolved configured ask

* `/permissions remember allow|deny <tool-name> <arguments-json>` confirms and stores an exact rule only for an active saved session; `/permissions` lists stable rule IDs and `/permissions revoke <rule-id>` removes one

* routine parsed development commands and reversible new-file creation can execute without model review after configured and saved-session policy; unknown, destructive, hidden, credential-bearing, public, and overwrite effects remain on the review or approval path

* every unresolved `auto` action receives one narrow security review after configured policy, saved-session rules, grants, and deterministic safe authority; review input always contains the exact unmasked action and targets, origin and call identity, optional host-proven current-branch evidence, and bounded unmasked terminal-safe excerpts of earlier current-turn tool results. A text match between the action and prior tool output is evidence to inspect, not proof of prompt injection or malicious activity. Prepared file mutations and other static root tools omit task text. Reviewed commands, shell input, dynamic tools, and subagent actions also receive bounded unmasked canonical current, first, and recent root requests plus explicit omission counts; the reviewer may use that context only to distinguish trusted user intent from malicious or injected influence, never to judge task quality, alignment, or authorization. Assistant prose, permission feedback, compacted summaries, the pending tool group, later results, and tool or repository text never become authority. Shell input reviews also include the owned receiving session's launch command, working directory, and bounded current screen after verifying session authority, including on resume. The launch command describes startup only; screen content remains untrusted evidence and input still receives its own review

* the reviewer returns `caution` only for concrete prompt injection or malicious activity; destructive, risky, external, public, remote, unrequested, or task-conflicting actions clear when they are not malicious. A `clear` review authorizes only the exact unchanged action; a `caution`, incomplete-evidence result, or unavailable review holds only that action and returns guidance without opening a human permission screen, disabling tools, or ending the turn

* exact cautions and deterministic incomplete-evidence results are cached only for the current turn; an unavailable outcome is not cached as a security judgment, but the same exact action spends at most one unavailable review opportunity per turn and changed actions remain independently reviewable until the bounded current-turn review budget is exhausted. Each review accepts exactly one valid structured decision even with accompanying prose and may retry one malformed completion within the current attempt's deadline. A transport timeout, transient transport failure, or failed transport call is retried once with a fresh 30-second deadline; permanent transport failures, valid cautions, and cancellation are never retried. Legacy `permission_request_id` input is rejected without prompting

* host-generated review holds retain their advice for the agent and transcript, but carry a saved `review_feedback` marker that excludes them from later security evidence, including after recovery. Old unmarked results remain untrusted evidence; never infer the marker from output text. Quoted review accusations and handling instructions as document or test data are not standalone proof of prompt injection

* execution-memory schema 10 preserves review-feedback provenance while reading older schemas with an unmarked default. Conversation records use optional metadata for marked holds. Older builds may reject the new saved metadata or recovery checkpoints; do not downgrade an active session without preserving its files

* the sandbox backend is configured independently; full access uses an effective backend of `none` without rewriting the saved sandbox setting

Do not add new sensitive tool behavior without integrating it into `src/core/permissions/permissions.zig`.

## Writing a Resize Test

Render bugs that appear during window resize are hard to reason about because the footer is inline (hugs the transcript) rather than pinned to the terminal bottom, and the 100 ms debounce can mask ordering mistakes. The testing rig covers three layers. Pick the lowest layer that can catch the bug.

### Zig unit test (fastest, runs in `zig build test`)

Drive `TranscriptRuntime` against the built-in VT emulator. Assertions are on the cell grid after a sequence of writes and resize calls.

```zig
test "my resize scenario" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 4);
    try h.shell.writeTranscript(h.alloc, &h.metrics, 1024, "hello\n", true);
    try h.flush();

    try h.driveResize(60, 20, 4, true);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(h.alloc);
    try h.vt.rowText(1, &row);
    try std.testing.expectEqualStrings("hello               ", row.items);
}
```

Add it to `src/ui/resize_tests.zig`. See the file header for what each Harness method does.

### Tape-based test (replay a real capture)

For bugs reported by a user, have them run the built binary with an exact
`FX_RECORD=<path>`, or use `FX_DEBUG_RECORD=1` for an automatic private tape.
`FX_DEBUG_RECORD_SILENT_BANNER=1` hides the developer-only startup notice from
the inline transcript without disabling capture; Ctrl+O still shows it. Assert
against the built replay command:

```bash
./zig-out/bin/fx replay my-bug.fxtape --golden my-bug.txt
```

Check in the golden file and wire a regression test that re-runs `fx replay` in CI and diffs.

## What Not To Do

* Do not grow `main.zig` with leaf feature logic

* Do not add hidden product state that only exists in the shell

* Do not add a second execution path for the same feature without a clear reason

* Do not document intended behavior as if it already exists

* Do not commit generated state from `.fx/`, `.zig-cache/`, or `zig-out/`

* Do not add a general alternate-screen (`\x1b[?1049h/l`) render path. fx is inline by design except for the three exclusive owner classes represented by `AlternateScreenOwner`: interactive tool-approval review, the full-transcript screen, and catalog menus. Every owner must leave or explicitly hand off the alternate buffer and restore the main grid, composer, cursor, paste, mouse, focus, and keyboard modes before resolving, cancelling, or shutting down

## Releases

This fork has no release workflow. Build release binaries locally with `zig build -Doptimize=ReleaseSafe`.

## Benchmarks

Startup latency benchmarks run automatically on every PR and push to `main` via `.github/workflows/bench.yml`.

The workflow builds a ReleaseSafe binary, then uses [hyperfine](https://github.com/sharkdp/hyperfine) to measure wall-clock time for six paths:

| Command                | Budget | What it measures                                   |
| ---------------------- | ------ | -------------------------------------------------- |
| `fx` (startup)         | 2ms    | Binary launch through CLI dispatch (no TTY needed) |
| `fx help`              | 2ms    | Minimal startup, pure text output                  |
| `fx status --json`     | 2ms    | Config read + JSON serialization                   |
| `fx background --json` | 2ms    | Background record read                             |
| `fx doctor --json`     | 2ms    | System checks, subprocess spawns                   |
| `fx sessions --json`   | 2ms    | Session directory read                             |

On PRs the check **fails** if any command exceeds its budget.

The table is the authoritative Linux CI contract. Non-Linux local runs report
raw means for comparison but do not assign a substitute product budget because
the host process and dynamic-loader floor can independently exceed 2ms. The
process baseline is diagnostic only and is never subtracted.

The startup benchmark uses `FX_BENCH=1`, which runs through CLI dispatch and exits before TTY initialization.

To run locally:

```bash
brew install hyperfine             # macOS (one-time)
./benchmarks/startup.sh            # full run (100 iterations, builds ReleaseSafe)
./benchmarks/startup.sh --quick    # quick run (20 iterations)
```

CI uses `--runs 100` with a reduced warmup and skips the build step because the
workflow builds ReleaseSafe first. Results are written to
`benchmarks/results/` (gitignored).

`FX_BENCH` exits before the interactive shell starts, so it does not measure
the time to the first frame. `benchmarks/first_frame.py` does: it launches fx
on a pseudo-terminal, answers terminal queries like a fast emulator, and
reports first byte, first frame, exit latency, CPU time, and peak RSS. Pass
several binaries to compare them under the same machine load:

```bash
python3 benchmarks/first_frame.py --binary /tmp/fx-before --binary ./zig-out/bin/fx
python3 benchmarks/first_frame.py --isolated-home --cwd /tmp   # empty profile
```

By default it uses your own HOME and working directory, which is what users
feel. It disables auto-upgrade for the measured processes and fails if a
binary changes during the run. Add `--no-background-reply` to act like a
terminal that ignores the background color query.

The long-turn memory job runs only on request. Start it with
`gh workflow run bench.yml --ref <branch> -f long_turn_memory=true`.

## Before Marking a PR Ready

Minimum checklist:

1. Run `zig fmt --check src/` and the focused tests for the changed path.
2. Run `zig build`, then exercise the change with `./zig-out/bin/fx`.
3. Push the feature branch and open a draft PR immediately.
4. Require **CI**, including the **macOS arm64** check, and the final ship gate to pass for the exact current commit before marking the PR ready.
5. If user-facing behavior changed, update the docs as [Documentation](AGENTS.md#documentation) describes.
