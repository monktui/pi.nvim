local MiniTest = require("mini.test")

local child = MiniTest.new_child_neovim()

local function flush()
  child.lua([[vim.wait(50, function() return false end, 10)]])
end

local function setup_test_env(setup_code)
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.lua([[
    _G.__pi_test_notifications = {}
    _G.__pi_force_notify_backend = true
    _G.__pi_test_history_path = vim.fn.tempname() .. "-pi-history.md"
    vim.notify = function(msg, level)
      table.insert(_G.__pi_test_notifications, { msg = msg, level = level })
    end
  ]])
  child.lua(setup_code or 'require("pi").setup({})')
  child.lua([[require("pi.config").get().prompt.popup = false]])
end

local function setup_buffer(lines, filename)
  child.lua(
    [[
      local lines, filename = ...
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      if filename then
        vim.api.nvim_buf_set_name(0, filename)
      end
    ]],
    { lines, filename }
  )
end

local function set_cursor(line, col)
  child.api.nvim_win_set_cursor(0, { line, col or 0 })
end

local function mock_system()
  child.lua([[
    _G.__pi_test_system = {
      cmd = nil,
      opts = nil,
      on_exit = nil,
      killed = nil,
      closing = false,
      writes = {},
      stdin_closed = false,
    }

    vim.system = function(cmd, opts, on_exit)
      _G.__pi_test_system.cmd = cmd
      _G.__pi_test_system.opts = opts
      _G.__pi_test_system.on_exit = on_exit
      return {
        write = function(_, data)
          table.insert(_G.__pi_test_system.writes, data)
        end,
        kill = function(_, signal)
          _G.__pi_test_system.killed = signal
          _G.__pi_test_system.closing = true
        end,
        is_closing = function()
          return _G.__pi_test_system.closing
        end,
        _state = {
          stdin = {
            close = function()
              _G.__pi_test_system.stdin_closed = true
              _G.__pi_test_system.closing = true
            end,
            flush = function()
              -- No-op in tests
            end,
          },
        },
      }
    end
  ]])

  return {
    get_cmd = function()
      return child.lua_get([[_G.__pi_test_system.cmd]])
    end,
    get_stdin = function()
      return child.lua_get([[table.concat(_G.__pi_test_system.writes, "")]])
    end,
    stdin_was_closed = function()
      return child.lua_get([[_G.__pi_test_system.stdin_closed]])
    end,
    stdout = function(data)
      child.lua([[ _G.__pi_test_system.opts.stdout(nil, ...) ]], { data })
      flush()
    end,
    stderr = function(data)
      child.lua([[ _G.__pi_test_system.opts.stderr(nil, ...) ]], { data })
      flush()
    end,
    exit = function(code, signal)
      child.lua([[ _G.__pi_test_system.on_exit({ code = ..., signal = ... }) ]], { code, signal or 0 })
      flush()
    end,
    killed = function()
      return child.lua_get([[_G.__pi_test_system.killed]])
    end,
  }
end

local function mock_terminal()
  child.lua([[
    _G.__pi_test_terminal = {
      cmd = nil,
      sent = {},
      split_opened = false,
      win_opts = nil,
    }

    local original_open_win = vim.api.nvim_open_win
    vim.api.nvim_open_win = function(buf, enter, opts)
      _G.__pi_test_terminal.split_opened = opts and opts.split == "right"
      _G.__pi_test_terminal.win_opts = opts
      return original_open_win(buf, enter, opts)
    end

    local original_cmd = vim.cmd
    vim.cmd = function(cmd)
      if cmd == "startinsert" then
        return
      end
      return original_cmd(cmd)
    end

    vim.fn.termopen = function(cmd)
      _G.__pi_test_terminal.cmd = cmd
      return 42
    end

    vim.fn.chansend = function(job_id, data)
      table.insert(_G.__pi_test_terminal.sent, { job_id = job_id, data = data })
    end
  ]])

  return {
    get_cmd = function()
      return child.lua_get([[_G.__pi_test_terminal.cmd]])
    end,
    get_sent = function()
      return child.lua_get([[table.concat(vim.tbl_map(function(item) return item.data end, _G.__pi_test_terminal.sent), "")]])
    end,
    split_opened = function()
      return child.lua_get([[_G.__pi_test_terminal.split_opened]])
    end,
    get_win_opts = function()
      return child.lua_get([[_G.__pi_test_terminal.win_opts]])
    end,
  }
end

local function run_pi_edit(input_text)
  local system = mock_system()
  child.lua(string.format(
    [[
      vim.ui.input = function(_, callback)
        callback(%q)
      end
    ]],
    input_text
  ))
  child.cmd("PiEdit")
  flush()
  return system
end

local function run_pi_edit_selection(input_text, start_line, end_line)
  local system = mock_system()
  child.lua(string.format(
    [[
      vim.ui.input = function(_, callback)
        callback(%q)
      end
    ]],
    input_text
  ))
  child.cmd(string.format("%d,%dPiEdit", start_line, end_line))
  flush()
  return system
end

local function run_pi_command(input_text, command, start_line, end_line)
  local system = mock_system()
  child.lua(string.format(
    [[
      vim.ui.input = function(_, callback)
        callback(%q)
      end
    ]],
    input_text
  ))
  if start_line and end_line then
    child.cmd(string.format("%d,%d%s", start_line, end_line, command))
  else
    child.cmd(command)
  end
  flush()
  return system
end

local function decode_prompt(stdin)
  return child.lua(
    [[
      local stdin = ...
      return vim.json.decode(vim.trim(stdin))
    ]],
    { stdin }
  )
end

local function notifications()
  return child.lua_get([[_G.__pi_test_notifications]])
end

local function last_notification()
  local items = notifications()
  return items[#items]
end

local function write_file(path, lines)
  child.lua(
    [[
      local path, lines = ...
      vim.fn.writefile(lines, path)
    ]],
    { path, lines }
  )
end

local function has_arg(cmd, flag)
  for i, arg in ipairs(cmd) do
    if arg == flag then
      return i
    end
  end
  return nil
end

local function arg_after(cmd, flag)
  local idx = has_arg(cmd, flag)
  if not idx then
    return nil
  end
  return cmd[idx + 1]
end

local function last_arg_after(cmd, flag)
  local value = nil
  for i, arg in ipairs(cmd) do
    if arg == flag then
      value = cmd[i + 1]
    end
  end
  return value
end

local function test_pi_edit_uses_vim_system_command()
  setup_test_env()
  setup_buffer({ "print('hello')" }, "/test/file.lua")

  local system = run_pi_edit("refactor this")
  local cmd = system.get_cmd()
  local stdin_mode = child.lua_get([[_G.__pi_test_system.opts.stdin]])

  MiniTest.expect.equality(cmd[1], "pi")
  MiniTest.expect.equality(cmd[2], "--mode")
  MiniTest.expect.equality(cmd[3], "rpc")
  MiniTest.expect.equality(cmd[4], "--no-session")
  MiniTest.expect.equality(stdin_mode, true)

  local append_idx = has_arg(cmd, "--append-system-prompt")
  MiniTest.expect.no_equality(append_idx, nil)
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("running inside the pi.nvim Neovim plugin"), nil)
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("Treat the provided Context as the source of truth"), nil)
end

local function test_pi_edit_includes_context_and_message()
  setup_test_env()
  setup_buffer({ "local x = 1", "local y = 2" }, "/test/file.lua")
  set_cursor(2)

  local system = run_pi_edit("what does this do")
  local prompt = decode_prompt(system.get_stdin())

  MiniTest.expect.equality(prompt.type, "prompt")
  MiniTest.expect.equality(prompt.message:match("what does this do"), "what does this do")
  MiniTest.expect.equality(prompt.message:match("File: /test/file.lua"), "File: /test/file.lua")
  MiniTest.expect.equality(prompt.message:match("Current line: 2"), "Current line: 2")
  MiniTest.expect.equality(prompt.message:match("source of truth"), "source of truth")
  MiniTest.expect.equality(prompt.message:match("may include unsaved changes"), "may include unsaved changes")
  MiniTest.expect.equality(prompt.message:match("local x = 1"), "local x = 1")
  MiniTest.expect.equality(prompt.message:match("running inside the pi.nvim Neovim plugin"), nil)
end

local function test_pi_edit_requires_file()
  setup_test_env()
  setup_buffer({ "code" }, nil)
  child.lua([[
    vim.ui.input = function()
      error("vim.ui.input should not be called")
    end
  ]])

  child.cmd("PiEdit")

  local notification = last_notification()
  MiniTest.expect.equality(notification.msg:match("file"), "file")
end

local function test_context_is_trimmed_for_speed()
  setup_test_env('require("pi").setup({ context = { max_bytes = 16, ask = { surrounding_lines = 2 } } })')
  setup_buffer({ "line one", "line two", "line three" }, "/test/trim.lua")
  set_cursor(2)

  local system = run_pi_edit("trim it")
  local prompt = decode_prompt(system.get_stdin())

  MiniTest.expect.equality(prompt.message:match("trimmed for speed"), "trimmed for speed")
end

local function test_selection_uses_nearby_context()
  setup_test_env('require("pi").setup({ context = { max_bytes = 1000, selection = { surrounding_lines = 1 } } })')
  setup_buffer({ "line1", "line2", "line3", "line4", "line5", "line6" }, "/test/select.lua")

  local system = run_pi_edit_selection("focus selection", 3, 4)
  local prompt = decode_prompt(system.get_stdin())

  MiniTest.expect.equality(prompt.message:match("Selected lines: 3%-4"), "Selected lines: 3-4")
  MiniTest.expect.equality(prompt.message:match("Nearby context %(2%-5%)"), "Nearby context (2-5)")
  MiniTest.expect.equality(prompt.message:match("line1"), nil)
  MiniTest.expect.equality(prompt.message:match("line6"), nil)
end

local function test_edit_uses_range_context_when_range_is_provided()
  setup_test_env('require("pi").setup({ context = { max_bytes = 1000, selection = { surrounding_lines = 1 } } })')
  setup_buffer({ "line1", "line2", "line3" }, "/test/range.lua")

  local system = run_pi_command("focus range", "PiEdit", 2, 2)
  local prompt = decode_prompt(system.get_stdin())

  MiniTest.expect.equality(prompt.message:match("Selected lines: 2%-2"), "Selected lines: 2-2")
  MiniTest.expect.equality(prompt.message:match("line2"), "line2")
  MiniTest.expect.equality(prompt.message:match("Current line"), nil)
end

local function test_question_allows_read_search_web_tools_and_streams_answer()
  setup_test_env()
  setup_buffer({ "local x = 1" }, "/test/question.lua")

  local system = run_pi_command("explain", "PiQuestion")
  local cmd = system.get_cmd()
  local append_idx = has_arg(cmd, "--append-system-prompt")

  MiniTest.expect.equality(arg_after(cmd, "--tools"), "read,grep,find,ls,web_search,web_fetch")
  MiniTest.expect.equality(has_arg(cmd, "--no-tools"), nil)
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("question%-answering mode"), nil)

  system.stdout('{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"hello"}}\n')
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_active_session().answer]]), "hello")
  system.stdout('{"type":"agent_end"}\n')
  system.exit(0, 0)
end

local function test_research_allows_read_search_bash_web_tools()
  setup_test_env()
  setup_buffer({ "local x = 1" }, "/test/research.lua")

  local system = run_pi_command("investigate", "PiResearch")
  local cmd = system.get_cmd()
  local append_idx = has_arg(cmd, "--append-system-prompt")

  MiniTest.expect.equality(arg_after(cmd, "--tools"), "read,grep,find,ls,bash,web_search,web_fetch")
  MiniTest.expect.equality(has_arg(cmd, "--no-tools"), nil)
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("research mode"), nil)
end

local function test_review_allows_read_search_tools_and_uses_review_prompt()
  setup_test_env()
  setup_buffer({ "local x = 1" }, "/test/review.lua")

  local system = run_pi_command("review this", "PiReview")
  local cmd = system.get_cmd()
  local append_idx = has_arg(cmd, "--append-system-prompt")

  MiniTest.expect.equality(arg_after(cmd, "--tools"), "read,grep,find,ls")
  MiniTest.expect.equality(has_arg(cmd, "--no-tools"), nil)
  MiniTest.expect.equality(arg_after(cmd, "--tools"):match("bash"), nil)
  MiniTest.expect.equality(arg_after(cmd, "--tools"):match("web_search"), nil)
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("code review mode"), nil)
end

local function test_review_uses_range_context_when_range_is_provided()
  setup_test_env('require("pi").setup({ context = { max_bytes = 1000, selection = { surrounding_lines = 1 } } })')
  setup_buffer({ "line1", "line2", "line3" }, "/test/review-range.lua")

  local system = run_pi_command("review range", "PiReview", 2, 3)
  local prompt = decode_prompt(system.get_stdin())

  MiniTest.expect.equality(prompt.message:match("Selected lines: 2%-3"), "Selected lines: 2-3")
  MiniTest.expect.equality(prompt.message:match("line2"), "line2")
end

local function test_review_popup_is_prefilled_with_review_prompt()
  setup_test_env()
  child.lua([[require("pi.config").get().prompt.popup = true]])
  setup_buffer({ "local x = 1" }, "/test/review-popup.lua")
  local system = mock_system()

  child.cmd("PiReview")
  flush()

  local popup_text = child.lua_get([[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")]])
  MiniTest.expect.no_equality(popup_text:match("Review this code/config"), nil)
  MiniTest.expect.no_equality(popup_text:match("# Optimized Prompt"), nil)

  child.cmd("stopinsert")
  child.lua([[vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "xt")]])
  flush()

  MiniTest.expect.equality(arg_after(system.get_cmd(), "--tools"), "read,grep,find,ls")
  local prompt = decode_prompt(system.get_stdin())
  MiniTest.expect.no_equality(prompt.message:match("Review this code/config"), nil)
end

local function test_web_tool_warning_when_extensions_disabled()
  setup_test_env('require("pi").setup({ extensions = false })')
  setup_buffer({ "local x = 1" }, "/test/web-tools.lua")

  local system = run_pi_command("explain", "PiQuestion")
  local cmd = system.get_cmd()

  MiniTest.expect.no_equality(has_arg(cmd, "--no-extensions"), nil)
  MiniTest.expect.equality(arg_after(cmd, "--tools"), "read,grep,find,ls,web_search,web_fetch")
  MiniTest.expect.no_equality(last_notification().msg:match("pi%-search"), nil)
end

local function test_question_uses_range_context_when_range_is_provided()
  setup_test_env('require("pi").setup({ context = { max_bytes = 1000, selection = { surrounding_lines = 1 } } })')
  setup_buffer({ "line1", "line2", "line3" }, "/test/question-range.lua")

  local system = run_pi_command("explain range", "PiQuestion", 2, 3)
  local prompt = decode_prompt(system.get_stdin())

  MiniTest.expect.equality(prompt.message:match("Selected lines: 2%-3"), "Selected lines: 2-3")
  MiniTest.expect.equality(prompt.message:match("line2"), "line2")
end

local function test_session_qa_opens_terminal_without_rpc_or_sessionless_flags()
  setup_test_env()
  setup_buffer({ "code" }, "/test/session.lua")
  local terminal = mock_terminal()

  child.cmd("PiSessionQA")

  local cmd = terminal.get_cmd()
  MiniTest.expect.equality(terminal.split_opened(), true)
  MiniTest.expect.equality(cmd[1], "pi")
  MiniTest.expect.equality(has_arg(cmd, "--mode"), nil)
  MiniTest.expect.equality(has_arg(cmd, "--no-session"), nil)
  MiniTest.expect.no_equality(has_arg(cmd, "--continue"), nil)
  MiniTest.expect.no_equality(arg_after(cmd, "--session-dir"), nil)
  MiniTest.expect.equality(arg_after(cmd, "--tools"), "read,grep,find,ls,bash,web_search,web_fetch")
  MiniTest.expect.equality(terminal.get_sent(), "")

  local context_path = last_arg_after(cmd, "--append-system-prompt")
  local context_text = child.lua_get(string.format([[table.concat(vim.fn.readfile(%q), "\n")]], context_path))
  MiniTest.expect.no_equality(context_text:match("Neovim workspace context"), nil)
  MiniTest.expect.no_equality(context_text:match("File: /test/session.lua"), nil)
  MiniTest.expect.no_equality(context_text:match("code"), nil)
end

local function test_session_keeps_tools_enabled()
  setup_test_env()
  setup_buffer({ "code" }, "/test/session-edit.lua")
  local terminal = mock_terminal()

  child.cmd("PiSession")

  local cmd = terminal.get_cmd()
  MiniTest.expect.equality(has_arg(cmd, "--mode"), nil)
  MiniTest.expect.equality(has_arg(cmd, "--no-session"), nil)
  MiniTest.expect.equality(has_arg(cmd, "--no-tools"), nil)
  MiniTest.expect.equality(has_arg(cmd, "--tools"), nil)
  MiniTest.expect.no_equality(has_arg(cmd, "--continue"), nil)
  MiniTest.expect.equality(terminal.get_sent(), "")
end

local function test_session_context_includes_open_buffers()
  setup_test_env()
  setup_buffer({ "current buffer" }, "/test/current.lua")
  child.lua([[
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/test/other.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "other buffer" })
    vim.bo[buf].modified = true
  ]])
  local terminal = mock_terminal()

  child.cmd("PiSession")

  local cmd = terminal.get_cmd()
  local context_path = last_arg_after(cmd, "--append-system-prompt")
  local context_text = child.lua_get(string.format([[table.concat(vim.fn.readfile(%q), "\n")]], context_path))
  MiniTest.expect.no_equality(context_text:match("Current file: /test/current.lua"), nil)
  MiniTest.expect.no_equality(context_text:match("/test/current.lua %(current"), nil)
  MiniTest.expect.no_equality(context_text:match("/test/other.lua %(modified"), nil)
  MiniTest.expect.no_equality(context_text:match("current buffer"), nil)
  MiniTest.expect.no_equality(context_text:match("other buffer"), nil)
end

local function test_session_review_opens_terminal_with_review_tools()
  setup_test_env()
  setup_buffer({ "code" }, "/test/session-review.lua")
  local terminal = mock_terminal()

  child.cmd("PiSessionReview")

  local cmd = terminal.get_cmd()
  MiniTest.expect.equality(terminal.split_opened(), true)
  MiniTest.expect.equality(cmd[1], "pi")
  MiniTest.expect.equality(has_arg(cmd, "--mode"), nil)
  MiniTest.expect.equality(has_arg(cmd, "--no-session"), nil)
  MiniTest.expect.no_equality(has_arg(cmd, "--continue"), nil)
  MiniTest.expect.no_equality(arg_after(cmd, "--session-dir"), nil)
  MiniTest.expect.equality(arg_after(cmd, "--tools"), "read,grep,find,ls,bash")
  MiniTest.expect.equality(terminal.get_sent(), "")

  local append_idx = has_arg(cmd, "--append-system-prompt")
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("code review mode"), nil)
  local context_path = last_arg_after(cmd, "--append-system-prompt")
  local context_text = child.lua_get(string.format([[table.concat(vim.fn.readfile(%q), "\n")]], context_path))
  MiniTest.expect.no_equality(context_text:match("Neovim workspace context"), nil)
  MiniTest.expect.no_equality(context_text:match("File: /test/session%-review%.lua"), nil)
end

local function test_chunked_stdout_updates_and_success_notifies_done()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_edit("go")
  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), true)

  system.stdout('{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta"}}')
  system.stdout('\n{"type":"tool_execution_start","toolName":"read_file"}\n')

  local active_tool = child.lua_get([[require("pi")._get_active_session().active_tool]])
  MiniTest.expect.equality(active_tool, "read_file")

  system.stdout('{"type":"agent_end"}\n')
  MiniTest.expect.equality(system.stdin_was_closed(), true)
  system.exit(0, 0)

  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().bufnr == nil]]), true)
end

local function test_activity_popup_shows_status_and_tools()
  setup_test_env()
  setup_buffer({ "code" }, "/test/activity.lua")

  local system = run_pi_edit("show activity")
  child.cmd("PiActivity")
  flush()
  local initial_text = child.lua_get([[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")]])
  MiniTest.expect.no_equality(initial_text:match("pi activity"), nil)
  MiniTest.expect.no_equality(initial_text:match("PiEdit"), nil)

  system.stdout('{"type":"tool_execution_start","toolName":"grep"}\n')
  local activity_text = child.lua_get([[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")]])
  MiniTest.expect.no_equality(activity_text:match("Tool: grep"), nil)
  MiniTest.expect.no_equality(activity_text:match("Tool started: grep"), nil)

  child.cmd("PiActivity")
  flush()
  MiniTest.expect.equality(child.lua_get([[vim.api.nvim_win_get_config(0).relative]]), "")
end

local function test_error_notifies_and_clears_ui_state()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_edit("break")
  system.stdout('{"type":"response","success":false,"error":"boom"}\n')
  MiniTest.expect.equality(system.stdin_was_closed(), true)
  system.exit(1, 0)

  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().status]]), "error")
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().bufnr == nil]]), true)
  MiniTest.expect.equality(last_notification().msg:match("boom"), "boom")
end

local function test_clean_exit_without_agent_end_is_an_error()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_edit("break")
  system.exit(0, 0)

  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().status]]), "error")
  MiniTest.expect.equality(last_notification().msg:match("before completing request"), "before completing request")
end

local function test_turn_end_does_not_finish_session()
  -- Regression: turn_end means one agent turn finished, not the whole run.
  -- During multi-step tool workflows, the agent emits turn_end between turns
  -- and only emits agent_end when the entire run is complete. See PR #4.
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_edit("multi-turn")

  -- Simulate: tool call -> turn_end with stopReason="toolUse" -> another turn
  system.stdout('{"type":"tool_execution_start","toolName":"edit"}\n')
  system.stdout('{"type":"tool_execution_end","toolName":"edit"}\n')
  system.stdout('{"type":"turn_end","stopReason":"toolUse"}\n')

  -- Session must still be running; stdin must not be closed.
  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), true)
  MiniTest.expect.equality(system.stdin_was_closed(), false)

  -- Now the actual terminal event arrives.
  system.stdout('{"type":"agent_end"}\n')
  MiniTest.expect.equality(system.stdin_was_closed(), true)
  system.exit(0, 0)

  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().status]]), "done")
end

local function test_turn_end_followed_by_agent_end_completes()
  -- Single-turn runs emit turn_end immediately followed by agent_end.
  -- Ensure that pattern still completes cleanly.
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_edit("single turn")
  system.stdout('{"type":"turn_end","stopReason":"endTurn"}\n{"type":"agent_end"}\n')
  MiniTest.expect.equality(system.stdin_was_closed(), true)
  system.exit(0, 0)

  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().status]]), "done")
end

local function test_cancel_kills_process_and_closes_immediately()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_edit("cancel me")
  child.cmd("PiCancel")
  flush()

  MiniTest.expect.equality(system.killed(), 15)
  MiniTest.expect.equality(child.lua_get([[require("pi").is_running()]]), false)
  MiniTest.expect.equality(child.lua_get([[require("pi")._get_last_session().bufnr == nil]]), true)
end

local function test_skills_option_disables_skills()
  setup_test_env('require("pi").setup({ skills = false })')
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_edit("test")
  local cmd = system.get_cmd()

  MiniTest.expect.no_equality(has_arg(cmd, "--no-skills"), nil)
end

local function test_extensions_option_disables_extensions()
  setup_test_env('require("pi").setup({ extensions = false })')
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_edit("test")
  local cmd = system.get_cmd()

  MiniTest.expect.no_equality(has_arg(cmd, "--no-extensions"), nil)
end

local function test_default_thinking_is_off()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_edit("test")
  local cmd = system.get_cmd()
  local thinking_idx = has_arg(cmd, "--thinking")

  MiniTest.expect.no_equality(thinking_idx, nil)
  MiniTest.expect.equality(cmd[thinking_idx + 1], "off")
end

local function test_thinking_option_adds_cli_flag()
  setup_test_env('require("pi").setup({ thinking = "high" })')
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_edit("test")
  local cmd = system.get_cmd()
  local thinking_idx = has_arg(cmd, "--thinking")

  MiniTest.expect.no_equality(thinking_idx, nil)
  MiniTest.expect.equality(cmd[thinking_idx + 1], "high")
end

local function test_invalid_thinking_option_errors()
  local ok, err = pcall(setup_test_env, 'require("pi").setup({ thinking = "turbo" })')

  MiniTest.expect.equality(ok, false)
  MiniTest.expect.no_equality(tostring(err):match("thinking must be one of"), nil)
end

local function test_append_system_prompt_is_concatenated()
  setup_test_env('require("pi").setup({ append_system_prompt = "Always run tests" })')
  setup_buffer({ "code" }, "/test/file.lua")

  local system = run_pi_edit("test")
  local cmd = system.get_cmd()
  local append_idx = has_arg(cmd, "--append-system-prompt")

  MiniTest.expect.no_equality(append_idx, nil)
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("running inside the pi.nvim Neovim plugin"), nil)
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("Treat the provided Context as the source of truth"), nil)
  MiniTest.expect.no_equality(cmd[append_idx + 1]:match("Always run tests"), nil)
end

local function test_second_request_is_blocked_while_running()
  setup_test_env()
  setup_buffer({ "code" }, "/test/file.lua")

  run_pi_edit("first")
  child.lua([[
    vim.ui.input = function(_, callback)
      callback("second")
    end
  ]])
  child.cmd("PiEdit")

  local notification = last_notification()
  MiniTest.expect.equality(notification.msg:match("already running"), "already running")
end

local function test_pi_edit_uses_context_around_cursor()
  setup_test_env('require("pi").setup({ context = { ask = { surrounding_lines = 1 }, max_bytes = 1000 } })')
  setup_buffer({ "line1", "line2", "line3", "line4", "line5", "line6" }, "/test/cursor.lua")
  set_cursor(4)

  local system = run_pi_edit("focus here")
  local prompt = decode_prompt(system.get_stdin())

  MiniTest.expect.equality(prompt.message:match("Current line: 4"), "Current line: 4")
  MiniTest.expect.equality(prompt.message:match("Nearby context %(3%-5%)"), "Nearby context (3-5)")
  MiniTest.expect.equality(prompt.message:match("line2"), nil)
  MiniTest.expect.equality(prompt.message:match("line3"), "line3")
  MiniTest.expect.equality(prompt.message:match("line5"), "line5")
  MiniTest.expect.equality(prompt.message:match("line6"), nil)
end

local function test_success_overwrites_modified_buffer_with_disk_edits()
  setup_test_env()
  local file = child.lua_get([[vim.fn.tempname() .. ".lua"]])
  write_file(file, { "from disk" })
  setup_buffer({ "code" }, file)
  child.lua([[vim.bo.modified = true]])

  local system = run_pi_edit("finish")
  write_file(file, { "updated on disk" })
  system.stdout('{"type":"agent_end"}\n')
  system.exit(0, 0)

  MiniTest.expect.equality(child.lua_get([[vim.bo.modified]]), false)
  local lines = child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]])
  MiniTest.expect.equality(lines[1], "updated on disk")
end

local function test_success_reloads_all_changed_loaded_buffers()
  setup_test_env()
  local file_one = child.lua_get([[vim.fn.tempname() .. ".lua"]])
  local file_two = child.lua_get([[vim.fn.tempname() .. ".lua"]])
  write_file(file_one, { "one before" })
  write_file(file_two, { "two before" })
  setup_buffer({ "one buffer edit" }, file_one)
  child.lua([[vim.cmd("edit " .. ...)]], { file_two })
  child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "two buffer edit" })]])
  child.lua([[vim.bo.modified = true]])
  child.lua([[vim.cmd("buffer #")]])
  child.lua([[vim.bo.modified = true]])

  local system = run_pi_edit("finish")
  write_file(file_one, { "one after agent edit" })
  write_file(file_two, { "two after agent edit" })
  system.stdout('{"type":"agent_end"}\n')
  system.exit(0, 0)

  local buffers = child.lua_get([[{
    one = vim.api.nvim_buf_get_lines(vim.fn.bufnr(...), 0, -1, false),
    one_modified = vim.bo[vim.fn.bufnr(...)].modified,
    two = vim.api.nvim_buf_get_lines(vim.fn.bufnr(select(2, ...)), 0, -1, false),
    two_modified = vim.bo[vim.fn.bufnr(select(2, ...))].modified,
  }]], { file_one, file_two })
  MiniTest.expect.equality(buffers.one[1], "one after agent edit")
  MiniTest.expect.equality(buffers.one_modified, false)
  MiniTest.expect.equality(buffers.two[1], "two after agent edit")
  MiniTest.expect.equality(buffers.two_modified, false)
end

local function test_success_reloads_unmodified_buffer()
  setup_test_env()
  local file = child.lua_get([[vim.fn.tempname() .. ".lua"]])
  write_file(file, { "from disk" })
  setup_buffer({ "code" }, file)
  child.lua([[vim.bo.modified = false]])

  local system = run_pi_edit("finish")
  write_file(file, { "updated on disk" })
  system.stdout('{"type":"agent_end"}\n')
  system.exit(0, 0)

  local lines = child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]])
  MiniTest.expect.equality(lines[1], "updated on disk")
end

local function test_reloaded_buffer_can_be_written_without_changed_since_reading_warning()
  setup_test_env()
  local file = child.lua_get([[vim.fn.tempname() .. ".lua"]])
  write_file(file, { "before" })
  setup_buffer({ "before" }, file)
  child.lua([[vim.bo.modified = false]])

  local system = run_pi_edit("finish")
  write_file(file, { "after agent edit" })
  system.stdout('{"type":"agent_end"}\n')
  system.exit(0, 0)

  child.lua([[_G.__pi_test_notifications = {}]])
  child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "after local write" })]])
  local ok, err = child.lua([[return pcall(vim.cmd, "write")]])

  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(last_notification(), nil)
end

local function test_removed_selection_commands_are_not_registered()
  setup_test_env()

  local commands = child.lua_get([[vim.api.nvim_get_commands({})]])

  MiniTest.expect.equality(commands.PiEditSelection, nil)
  MiniTest.expect.equality(commands.PiQuestionSelection, nil)
  MiniTest.expect.equality(commands.PiSessionEdit, nil)
  MiniTest.expect.equality(commands.PiSessionEditSelection, nil)
  MiniTest.expect.equality(commands.PiSessionQuestion, nil)
  MiniTest.expect.equality(commands.PiSessionQuestionSelection, nil)
end

local function test_history_saves_request_and_answer_for_rpc_commands()
  setup_test_env()
  setup_buffer({ "code" }, "/test/history.lua")

  local system = run_pi_command("explain history", "PiQuestion")
  system.stdout('{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"answer text"}}\n')
  system.stdout('{"type":"agent_end"}\n')
  system.exit(0, 0)

  local history_text = child.lua_get([[table.concat(vim.fn.readfile(require("pi.history").path()), "\n")]])
  MiniTest.expect.no_equality(history_text:match("PiQuestion"), nil)
  MiniTest.expect.no_equality(history_text:match("explain history"), nil)
  MiniTest.expect.no_equality(history_text:match("answer text"), nil)
end

local function test_edit_history_captures_assistant_text_without_answer_popup()
  setup_test_env()
  setup_buffer({ "code" }, "/test/edit-history.lua")

  local system = run_pi_edit("edit history")
  system.stdout('{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"changed file"}}\n')
  system.stdout('{"type":"agent_end"}\n')
  system.exit(0, 0)

  local is_answer_backend = child.lua_get([[require("pi")._get_last_session().ui_backend == "answer"]])
  local history_text = child.lua_get([[table.concat(vim.fn.readfile(require("pi.history").path()), "\n")]])
  MiniTest.expect.equality(is_answer_backend, false)
  MiniTest.expect.no_equality(history_text:match("PiEdit"), nil)
  MiniTest.expect.no_equality(history_text:match("edit history"), nil)
  MiniTest.expect.no_equality(history_text:match("changed file"), nil)
end

local function test_history_commands_open_markdown_buffers()
  setup_test_env()
  child.lua([[vim.fn.writefile({ "## first", "", "old", "---", "", "## second", "", "new", "---" }, require("pi.history").path())]])

  child.cmd("PiHistoryLast")
  MiniTest.expect.equality(child.bo.filetype, "markdown")
  MiniTest.expect.no_equality(table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):match("second"), nil)
  MiniTest.expect.equality(table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):match("first"), nil)

  child.cmd("PiHistory")
  MiniTest.expect.equality(child.bo.filetype, "markdown")
end

local function test_prompt_popup_submits_multiline_prompt()
  setup_test_env()
  child.lua([[require("pi.config").get().prompt.popup = true]])
  setup_buffer({ "code" }, "/test/prompt-popup.lua")
  local system = mock_system()

  child.cmd("PiQuestion")
  child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "# Prompt",
    "",
    "line one",
    "line two",
    "",
    "# Optimized Prompt",
    "",
    "",
    "---",
    "Shortcuts:",
    "<C-s>         Send optimized prompt",
  })]])
  child.cmd("stopinsert")
  child.lua([[vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "xt")]])
  flush()

  local prompt = decode_prompt(system.get_stdin())
  MiniTest.expect.no_equality(prompt.message:match("line one\nline two"), nil)
  MiniTest.expect.equality(prompt.message:match("Shortcuts:"), nil)
  MiniTest.expect.equality(arg_after(system.get_cmd(), "--tools"), "read,grep,find,ls,web_search,web_fetch")
end

local function test_prompt_popup_sends_optimized_prompt_when_present()
  setup_test_env()
  child.lua([[require("pi.config").get().prompt.popup = true]])
  setup_buffer({ "code" }, "/test/prompt-popup-optimized.lua")
  local system = mock_system()

  child.cmd("PiQuestion")
  child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "# Prompt",
    "",
    "rough prompt",
    "",
    "# Optimized Prompt",
    "",
    "optimized prompt",
    "",
    "---",
    "Shortcuts:",
  })]])
  child.cmd("stopinsert")
  child.lua([[vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "xt")]])
  flush()

  local prompt = decode_prompt(system.get_stdin())
  MiniTest.expect.no_equality(prompt.message:match("optimized prompt"), nil)
  MiniTest.expect.equality(prompt.message:match("rough prompt"), nil)
end

local function test_prompt_popup_rewrites_prompt_with_ai()
  setup_test_env()
  child.lua([[require("pi.config").get().prompt.popup = true; require("pi.config").get().prompt.rewrite_key = "<Space>r"]])
  setup_buffer({ "code" }, "/test/prompt-rewrite.lua")
  local system = mock_system()

  child.cmd("PiQuestion")
  child.cmd("stopinsert")
  child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "# Prompt",
    "",
    "fix this maybe",
    "",
    "# Optimized Prompt",
    "",
    "",
    "---",
    "Shortcuts:",
  })]])
  child.lua([[vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<Space>r", true, false, true), "xt")]])
  flush()

  local working_text = child.lua_get([[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")]])
  MiniTest.expect.no_equality(working_text:match("Status: optimizing prompt"), nil)

  MiniTest.expect.no_equality(has_arg(system.get_cmd(), "--print"), nil)
  MiniTest.expect.equality(has_arg(system.get_cmd(), "--mode"), nil)
  MiniTest.expect.no_equality(has_arg(system.get_cmd(), "--no-tools"), nil)
  MiniTest.expect.no_equality(system.get_stdin():match("fix this maybe"), nil)
  MiniTest.expect.no_equality(system.get_stdin():match("File: /test/prompt%-rewrite%.lua"), nil)
  MiniTest.expect.no_equality(system.get_stdin():match("Neovim context for rewriting only"), nil)
  MiniTest.expect.equality(system.get_stdin():match('"type":"prompt"'), nil)
  system.stdout("Fix the selected code while preserving behavior.\n")
  system.exit(0, 0)

  local text = child.lua_get([[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")]])
  MiniTest.expect.no_equality(text:match("fix this maybe"), nil)
  MiniTest.expect.no_equality(text:match("Fix the selected code while preserving behavior%."), nil)
  MiniTest.expect.no_equality(text:match("Status: optimized"), nil)
  MiniTest.expect.no_equality(text:match("Shortcuts:"), nil)
end

local function test_prompt_popup_rewrite_uses_range_context()
  setup_test_env('require("pi").setup({ context = { max_bytes = 1000, selection = { surrounding_lines = 1 } } })')
  child.lua([[require("pi.config").get().prompt.popup = true; require("pi.config").get().prompt.rewrite_key = "<Space>r"]])
  setup_buffer({ "line1", "line2", "line3" }, "/test/prompt-rewrite-range.lua")
  local system = mock_system()

  child.cmd("2,3PiQuestion")
  child.cmd("stopinsert")
  child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "# Prompt",
    "",
    "what does this do?",
    "",
    "# Optimized Prompt",
    "",
    "",
    "---",
    "Shortcuts:",
  })]])
  child.lua([[vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<Space>r", true, false, true), "xt")]])
  flush()

  local stdin = system.get_stdin()
  MiniTest.expect.no_equality(stdin:match("Selected lines: 2%-3"), nil)
  MiniTest.expect.no_equality(stdin:match("line2"), nil)
  MiniTest.expect.no_equality(stdin:match("line3"), nil)

  system.stdout("Explain the selected lines.\n")
  system.exit(0, 0)
end

local function test_prompt_popup_rewrites_from_print_stdout_without_newline()
  setup_test_env()
  child.lua([[require("pi.config").get().prompt.popup = true; require("pi.config").get().prompt.rewrite_key = "<Space>r"]])
  setup_buffer({ "code" }, "/test/prompt-rewrite-final.lua")
  local system = mock_system()

  child.cmd("PiQuestion")
  child.cmd("stopinsert")
  child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "# Prompt",
    "",
    "explain this",
    "",
    "# Optimized Prompt",
    "",
    "",
    "---",
    "Shortcuts:",
  })]])
  child.lua([[vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<Space>r", true, false, true), "xt")]])
  flush()

  system.stdout("Explain this file purpose and main sections.")
  system.exit(0, 0)

  local text = child.lua_get([[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")]])
  MiniTest.expect.no_equality(text:match("Explain this file purpose and main sections%."), nil)
end

local T = MiniTest.new_set()

T["PiEdit"] = MiniTest.new_set()
T["PiEdit"]["uses vim.system command"] = test_pi_edit_uses_vim_system_command
T["PiEdit"]["includes prompt message and context"] = test_pi_edit_includes_context_and_message
T["PiEdit"]["requires a file"] = test_pi_edit_requires_file
T["PiEdit"]["trims context for speed"] = test_context_is_trimmed_for_speed
T["PiEdit"]["uses context around cursor"] = test_pi_edit_uses_context_around_cursor
T["PiEdit"]["uses range context when range is provided"] = test_edit_uses_range_context_when_range_is_provided
T["PiEdit"]["blocks second request while running"] = test_second_request_is_blocked_while_running
T["PiEdit"]["overwrites modified buffer with disk edits on success"] = test_success_overwrites_modified_buffer_with_disk_edits
T["PiEdit"]["reloads unmodified buffer on success"] = test_success_reloads_unmodified_buffer
T["PiEdit"]["reloaded buffer can be written without changed-since-reading warning"] = test_reloaded_buffer_can_be_written_without_changed_since_reading_warning
T["PiEdit"]["reloads all changed loaded buffers on success"] = test_success_reloads_all_changed_loaded_buffers
T["PiEdit"]["skills option disables skills"] = test_skills_option_disables_skills
T["PiEdit"]["extensions option disables extensions"] = test_extensions_option_disables_extensions
T["PiEdit"]["default thinking is off"] = test_default_thinking_is_off
T["PiEdit"]["thinking option adds cli flag"] = test_thinking_option_adds_cli_flag
T["PiEdit"]["invalid thinking option errors"] = test_invalid_thinking_option_errors
T["PiEdit"]["append_system_prompt is concatenated with plugin prompt"] = test_append_system_prompt_is_concatenated
T["PiEdit"]["visual range uses nearby context"] = test_selection_uses_nearby_context
T["PiEdit"]["captures assistant text in history without answer popup"] = test_edit_history_captures_assistant_text_without_answer_popup

T["PiQuestion"] = MiniTest.new_set()
T["PiQuestion"]["allows read/search/web tools and streams answer"] = test_question_allows_read_search_web_tools_and_streams_answer
T["PiQuestion"]["uses range context when range is provided"] = test_question_uses_range_context_when_range_is_provided
T["PiQuestion"]["warns when web tools need disabled extensions"] = test_web_tool_warning_when_extensions_disabled

T["PiResearch"] = MiniTest.new_set()
T["PiResearch"]["allows read/search/bash/web tools"] = test_research_allows_read_search_bash_web_tools

T["PiReview"] = MiniTest.new_set()
T["PiReview"]["allows read/search tools and uses review prompt"] = test_review_allows_read_search_tools_and_uses_review_prompt
T["PiReview"]["uses range context when range is provided"] = test_review_uses_range_context_when_range_is_provided
T["PiReview"]["popup is prefilled with review prompt"] = test_review_popup_is_prefilled_with_review_prompt

T["PiSession"] = MiniTest.new_set()
T["PiSession"]["QA opens terminal without rpc or sessionless flags"] = test_session_qa_opens_terminal_without_rpc_or_sessionless_flags
T["PiSession"]["keeps tools enabled"] = test_session_keeps_tools_enabled
T["PiSession"]["context includes open buffers"] = test_session_context_includes_open_buffers
T["PiSession"]["review opens terminal with review tools"] = test_session_review_opens_terminal_with_review_tools

T["PiHistory"] = MiniTest.new_set()
T["PiHistory"]["saves request and answer for RPC commands"] = test_history_saves_request_and_answer_for_rpc_commands
T["PiHistory"]["commands open markdown buffers"] = test_history_commands_open_markdown_buffers

T["PromptEditor"] = MiniTest.new_set()
T["PromptEditor"]["submits multiline prompt"] = test_prompt_popup_submits_multiline_prompt
T["PromptEditor"]["sends optimized prompt when present"] = test_prompt_popup_sends_optimized_prompt_when_present
T["PromptEditor"]["rewrites prompt with ai"] = test_prompt_popup_rewrites_prompt_with_ai
T["PromptEditor"]["rewrite uses range context"] = test_prompt_popup_rewrite_uses_range_context
T["PromptEditor"]["rewrites from print stdout without newline"] = test_prompt_popup_rewrites_from_print_stdout_without_newline

T["Commands"] = MiniTest.new_set()
T["Commands"]["removed selection-specific commands are absent"] = test_removed_selection_commands_are_not_registered

T["Session"] = MiniTest.new_set()
T["Session"]["handles chunked stdout and notifies on success"] = test_chunked_stdout_updates_and_success_notifies_done
T["Session"]["activity popup shows status and tools"] = test_activity_popup_shows_status_and_tools
T["Session"]["notifies and clears UI state on error"] = test_error_notifies_and_clears_ui_state
T["Session"]["clean exit without terminal event is an error"] = test_clean_exit_without_agent_end_is_an_error
T["Session"]["turn_end does not finish session (multi-turn tool use)"] = test_turn_end_does_not_finish_session
T["Session"]["turn_end followed by agent_end completes"] = test_turn_end_followed_by_agent_end_completes
T["Session"]["cancel closes immediately"] = test_cancel_kills_process_and_closes_immediately

return T
