# pi.nvim

A Neovim plugin for interacting with [pi](https://pi.dev) - the minimal cli agent.

<p align="center">
<a href="https://asciinema.org/a/RuG4c2kkhrLx1ChZ">
  <img src="https://github.com/pablopunk/pi.nvim/blob/main/assets/asciinema.gif?raw=true&forceUpdate" width="100%" />
</a>
</p>

It's funny that all AI plugins for Neovim are quite complex to interact with, like they want to imitate all current IDE features, while those are trending towards the simplicity of the CLI (which is the reason most users choose neovim in the first place). [pi.dev](https://pi.dev/) is the best example of this philosophy, and the perfect candidate to integrate in neovim.

## Features

- **Context aware**: Sends your current buffer, cwd, and selection as context.
- **Unsaved-buffer aware**: Tells pi to treat the sent Neovim buffer content as the source of truth, even if the on-disk file is stale.
- **Simple configuration**: Just set your preferred AI model.
- **Gets out of your way**: You ask it. It does it. Done.

## Requirements

- [Neovim](https://neovim.io/) 0.10+
- [pi](https://github.com/badlogic/pi-mono) installed globally: `npm install -g @mariozechner/pi-coding-agent`
- Your preferred models availble in pi: `pi --list-models`

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{ "pablopunk/pi.nvim" }
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use "pablopunk/pi.nvim"
```

### Using [mini.deps](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-deps.md)

```lua
MiniDeps.add("pablopunk/pi.nvim")
```

## Config

All config is optional:

```lua
require("pi").setup()
```

Override only the ones you need:

```lua
require("pi").setup({
  provider = "openrouter",
  model = "openrouter/free",
  thinking = "off", -- be careful, thinking is time-consuming, it's not a great experience if you want simplicity
  system_prompt = "You are a helpful assistant.",
  append_system_prompt = "Always respond concisely.",
  context = {
    max_bytes = 24000,
    ask = {
      surrounding_lines = 80,
    },
    selection = {
      surrounding_lines = 40,
    },
  },
  prompt = {
    popup = true,
    ai_rewrite = true,
    width = 0.65,
    height = 0.35,
    send_key = "<C-s>",
    send_normal_key = "<leader><CR>",
    rewrite_key = "<leader>r",
    cancel_key = "q",
  },
  session = {
    split = "right",
    width = 0.35,
    continue = true,
    scope = "cwd",
    inject_context = true,
    include_open_buffers = true,
    max_buffer_bytes = 12000,
    max_total_context_bytes = 60000,
  },
  skills = true,
  extensions = true,
})
```

| Prop | Default | Description |
|------|---------|-------------|
| `provider` | `nil` | pi provider to use. If omitted, pi uses its own default configuration. |
| `model` | `nil` | Model name to use. If omitted, pi uses its own default configuration. |
| `thinking` | `"off"` | Sets pi's thinking level (`--thinking`). Supported values: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`. |
| `system_prompt` | `nil` | Passes a custom system prompt to pi (`--system-prompt`). Use with care, since this overrides pi's generated baseline instructions. |
| `append_system_prompt` | `nil` | Appends text to the system prompt (`--append-system-prompt`). pi.nvim always appends its non-interactive execution instruction, and this option is concatenated after it. |
| `context.max_bytes` | `24000` | Maximum size in bytes for sent context before trimming. |
| `context.ask.surrounding_lines` | `80` | Number of lines before and after the current cursor line to include for `:PiEdit` and other buffer-context commands. |
| `context.selection.surrounding_lines` | `40` | Number of lines before and after the current visual selection to include for selection/range context. |
| `prompt.popup` | `true` | Use a real editable popup buffer instead of one-line `vim.ui.input` for non-session prompts. |
| `prompt.ai_rewrite` | `true` | Enable AI prompt rewrite inside the prompt popup. |
| `prompt.width` | `0.65` | Prompt popup width as ratio or absolute columns. |
| `prompt.height` | `0.35` | Prompt popup height as ratio or absolute rows. |
| `prompt.send_key` | `"<C-s>"` | Insert/normal mode key to send the prompt. |
| `prompt.send_normal_key` | `"<leader><CR>"` | Normal mode key to send the prompt. |
| `prompt.rewrite_key` | `"<leader>r"` | Normal/visual mode key to AI-rewrite the prompt. Uses your configured `<leader>` (space if `vim.g.mapleader = " "`). |
| `prompt.cancel_key` | `"q"` | Normal mode key to close the prompt popup without sending. |
| `session.split` | `"right"` | Side used for the pi TUI window. |
| `session.width` | `0.35` | Session window width as ratio or absolute columns. |
| `session.continue` | `true` | Start session commands with `--continue` so pi reconnects to the previous workspace session. |
| `session.scope` | `"cwd"` | Use a workspace-specific `--session-dir` for session commands. Set to `"global"` to use pi's default session lookup. |
| `session.inject_context` | `true` | Append Neovim context to the session system prompt instead of pasting it into the TUI input. |
| `session.include_open_buffers` | `true` | Include all loaded file-backed buffers (LazyVim bufferline tabs) in session context. |
| `session.max_buffer_bytes` | `12000` | Maximum bytes included for each open buffer in session context. |
| `session.max_total_context_bytes` | `60000` | Maximum total bytes for hidden session context. |
| `skills` | `true` | Whether pi discovers and loads skills. Set to `false` to pass `--no-skills`. |
| `extensions` | `true` | Whether pi discovers and loads extensions. Set to `false` to pass `--no-extensions`. |

Use `pi --list-models` to see available models.

**Examples:**

This is basically the same as doing `pi --provider <provider> --model <model>`, so you can test it out on the cli to make sure it works.
```lua
-- OpenRouter kimi-k2.5
{ provider = "openrouter", model = "moonshotai/kimi-k2.5" }

-- OpenAI overriding the default thinking level
{ provider = "openai", model = "gpt-5-mini", thinking = "high" }

-- OpenRouter haiku-4.5
{ provider = "openrouter", model = "anthropic/claude-haiku-4.5" }

-- Anthropic haiku-4-5
{ provider = "anthropic", model = "claude-haiku-4-5" }

-- OpenAI
{ provider = "openai", model = "gpt-4.1-mini" }
```

Run `pi --list-models` to see available options.

### Keymaps

No keymaps by default. You choose.

```lua
-- Ask pi to edit with current buffer or selected range as context
vim.keymap.set({ "n", "v" }, "<leader>ae", ":PiEdit<CR>", { desc = "Pi edit" })

-- Ask pi a read-only question with current buffer or selected range as context
vim.keymap.set({ "n", "v" }, "<leader>aq", ":PiQuestion<CR>", { desc = "Pi question" })

-- Ask pi to do deeper read-only research
vim.keymap.set({ "n", "v" }, "<leader>ar", ":PiResearch<CR>", { desc = "Pi research" })
vim.keymap.set("n", "<leader>aa", ":PiActivity<CR>", { desc = "Pi activity" })

-- Open full pi terminal sessions
vim.keymap.set({ "n", "v" }, "<leader>as", ":PiSession<CR>", { desc = "Pi session" })
vim.keymap.set({ "n", "v" }, "<leader>aQ", ":PiSessionQA<CR>", { desc = "Pi QA session" })
```

## Usage

### Commands

| Command | Backend | Tools | Description |
|---------|---------|-------|-------------|
| `:PiEdit` | RPC | Full pi tools | Prompt for an edit request using selected lines when invoked with a range, otherwise buffer context |
| `:PiQuestion` | RPC | `read,grep,find,ls,web_search,web_fetch` | Quick read-only Q&A with repo/web lookup |
| `:PiResearch` | RPC | `read,grep,find,ls,bash,web_search,web_fetch` | Deeper read-only investigation and reporting |
| `:PiSession` | Terminal | Full pi tools | Open a full interactive pi coding session |
| `:PiSessionQA` | Terminal | `read,grep,find,ls,bash,web_search,web_fetch` | Open a full interactive QA/research session |
| `:PiHistory` | Local | n/a | Open request/answer history for non-terminal commands |
| `:PiHistoryLast` | Local | n/a | Open latest request/answer history entry |
| `:PiActivity` | Local | n/a | Toggle activity popup for the active or latest RPC request |
| `:PiCancel` | Local | n/a | Cancel the active RPC request immediately |
| `:PiLog` | Local | n/a | Open the technical session log in a new split |

## Behavior

- Runs asynchronously and keeps editing nonblocking.
- Uses visual command ranges as selection context; otherwise uses cursor/buffer context.
- `:PiEdit`, `:PiQuestion`, and `:PiResearch` first open a markdown prompt popup with `# Prompt`, `# Optimized Prompt`, a visible rewrite status, and shortcuts. Write your rough prompt in `# Prompt`, press `<leader>r` to fill `# Optimized Prompt`, edit the optimized text if needed, then send with `<C-s>` or `<leader><CR>`. If `# Optimized Prompt` is empty, sending falls back to `# Prompt`. Shortcut help is never sent.
- `:PiActivity` toggles a markdown activity popup for the active or latest RPC request so you can see status changes and tool calls while pi works.
- `:PiQuestion` and `:PiResearch` stream answers into a markdown popup after you send the prompt.
- `:PiEdit`, `:PiQuestion`, and `:PiResearch` append request + assistant text to `stdpath("data")/pi.nvim/history.md`.
- `:PiSession` and `:PiSessionQA` open pi in a right-side TUI window without RPC or `--no-session`. They skip the prompt popup, reconnect to the current workspace session with `--continue`, and append current/open-buffer context as hidden system-prompt context instead of pasting text into the TUI input.
- Session context includes the current buffer, visual range metadata when invoked from visual mode, and all loaded file-backed buffers (the buffers shown as LazyVim tabs). Modified buffers are marked so unsaved changes remain source of truth.
- Web tools require the `pi-search` extension and `extensions = true`. If extensions are disabled, pi.nvim warns and still passes the configured tool allowlist.
- Uses `nvim-notify` for status updates when available; otherwise falls back to a small floating status window.
- Reloads changed loaded buffers on success so pi's on-disk edits are reflected in Neovim.
- Treats sent buffer/selection context as newer than disk, so unsaved Neovim changes are the source of truth for the agent.
- Trims oversized context for speed instead of always sending the full file.


## License

MIT
