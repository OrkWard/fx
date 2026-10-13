```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://fx.sh/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

# fx

fx is the smallest coding agent: one native binary with no runtime to install. It's written in Zig and runs the same on your laptop, in CI, or inside an agent sandbox.

It works with the model you choose, and its output is closer to a Unix shell than an IDE: the conversation prints into your scrollback instead of filling the screen.

## Features

- **Small and fast**: the Apple silicon release has a hard size limit, and startup is benchmarked on every pull request. CI fails a change if any measured command takes longer than 2 ms on Linux ([benchmarks](benchmarks/)).
- **Any model**: use your ChatGPT or Grok subscription, or any OpenAI-compatible endpoint such as Ollama or OpenRouter ([custom connections](https://fx.sh/docs/configure-fx/custom-model-connections)).
- **Inline output**: the conversation stays in your terminal's scrollback, where you can scroll, search, and copy it like any other command's output. tmux bindings and copy mode keep working, and terminals that support the [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status) can show when fx is busy or waiting for you.
- **Your own shell**: commands run in your login shell with your aliases, functions, and `PATH`. fx runs your startup files once and reuses the result, so a slow `.zshrc` doesn't slow down every command.
- **Permissions**: the default `auto` mode runs routine work, such as editing project files and running tests, without asking. Anything else goes to a model that checks it for prompt injection or malicious behavior first. Switch to `ask` to approve each action yourself, or to `full-access` to turn the checks off ([permissions](https://fx.sh/docs/configure-fx/permissions)).
- **Sessions**: fx saves your conversations, so `fx -c` picks up where you left off in a project. When a conversation fills the model's context, fx compacts older turns and keeps their full text on disk for the agent to look up ([sessions](https://fx.sh/docs/using-fx/sessions)).
- **Skills and subagents**: fx loads skills from `.fx/skills`, `~/.fx/skills`, and the folders other agents use, like `.claude/skills` and `.agents/skills`. It hands independent work to subagents and follows your project's `AGENTS.md`.

## Install

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

fx runs on macOS and Linux, on x86_64 and arm64. The installer puts it in `~/.local/bin`. fx checks for updates in the background, and `fx upgrade` installs the latest release right away. [CHANGELOG.md](CHANGELOG.md) lists what changed in each release. You can also [try fx in your browser](https://fx.sh/try) without installing anything.

## Quick start

Sign in with one of these:

```bash
fx login codex    # ChatGPT subscription
fx login grok     # Grok subscription
```

Then open a project and start fx:

```bash
cd your-project
fx
```

Type what you want done and press Enter. `/help` lists the slash commands.

For a single request without the interactive shell, use `fx ask`. Add `--json` when a script needs to read the result:

```bash
fx ask "explain the changes in this repository"
fx ask --json "summarize the failing tests" | jq -r .final_output
```

## How it works

Each request runs as a loop. fx sends the model your message, the conversation so far, your project's `AGENTS.md`, and short descriptions of the tools it can use. The model either replies or asks to call a tool: read or edit a file, run a shell command, search the web, load a skill, or start a subagent. fx checks each call against your permission mode and rules, runs the ones that pass, and sends the results back. The loop ends when the model replies without asking for another tool.

Skill instructions don't go to the model up front. They load when the model asks for them, which keeps the context small and leaves more room for your code.

Commands run by fx receive `AI_AGENT=fx` in their environment. Development tools can use it to detect fx.

fx prints every step inline as it happens and saves the session under `~/.fx/sessions/`, so you can resume it later.

## Use fx from other programs

| Surface | Use it for |
| --- | --- |
| `fx ask` | One request from a script or CI job. `--json` returns structured output, and `--resume` continues a saved session. |

## Documentation

The manual lives at [fx.sh/docs](https://fx.sh/docs). It covers models, permissions, configuration, skills, sessions, and every CLI and slash command.

For agents, [fx.sh/llms.txt](https://fx.sh/llms.txt) lists every page as Markdown, and [fx.sh/llms-full.txt](https://fx.sh/llms-full.txt) puts the whole manual in one file. Adding `.md` to any docs URL returns that page as Markdown.

## Feedback

Run `/feedback` inside fx to open the feedback form, or [open an issue](https://github.com/vercel-labs/fx/issues/new/choose). If something looks wrong in your terminal, `/trace` creates a private diagnostic report you can attach ([share feedback](https://fx.sh/docs/using-fx/share-feedback)).

## Contributing

You need [Zig 0.17.0](https://ziglang.org/download/) to build fx:

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build
./zig-out/bin/fx
```

Test your changes with the freshly built `./zig-out/bin/fx`. A bare `fx` may be an older copy on your `PATH`.

`zig build test` runs the unit tests, which sit next to the code they cover.

The source is laid out like this:

```text
src/
  main.zig    entry point that wires everything together
  core/       agent loop, sessions, config, permissions, skills
  tools/      built-in tools: files, shell, web, skills, subagents
  ui/         terminal rendering and input
  gateway/    model provider transport
benchmarks/   startup, memory, and latency benchmarks
```

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you open a pull request. It covers verification, CI, and PR labels. If a coding agent is helping you, [AGENTS.md](AGENTS.md) has the rules for working in this repository, and fx reads that file on its own when you start it here.

## Security

Report vulnerabilities through the [contact page](https://fx.sh/contact) instead of a public issue.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
