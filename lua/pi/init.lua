local config = require("pi.config")
local context = require("pi.context")
local runner = require("pi.runner")
local session_mod = require("pi.session")
local ui = require("pi.ui")
local log = require("pi.log")
local history = require("pi.history")

local M = {}

local active_session = nil
local last_session = nil
local warned_extensions_disabled_for_web_tools = false

local QA_TOOLS = { "read", "grep", "find", "ls", "web_search", "web_fetch" }
local RESEARCH_TOOLS = { "read", "grep", "find", "ls", "bash", "web_search", "web_fetch" }

local MODE_CONFIGS = {
  edit = { command = "PiEdit", prompt = "edit", auto_answer = false },
  question = { command = "PiQuestion", prompt = "question", auto_answer = true, tools = QA_TOOLS },
  research = { command = "PiResearch", prompt = "research", auto_answer = true, tools = RESEARCH_TOOLS },
  session = { command = "PiSession", prompt = "edit" },
  session_qa = { command = "PiSessionQA", prompt = "research", tools = RESEARCH_TOOLS },
}

local function assert_supported_version()
  if vim.fn.has("nvim-0.10") == 0 then
    error("pi.nvim requires Neovim 0.10+")
  end
end

local function ensure_file_backed_buffer(command_name)
  local bufnr = vim.api.nvim_get_current_buf()
  if not context.buffer_is_file_backed(bufnr) then
    vim.notify(string.format("%s requires a file", command_name), vim.log.levels.ERROR)
    return nil
  end
  return bufnr
end

local function system_prompt_for(prompt_kind)
  if prompt_kind == "question" then
    return context.get_question_system_prompt()
  end
  if prompt_kind == "research" then
    return context.get_research_system_prompt()
  end
  return context.get_edit_system_prompt()
end

local function build_append_system_prompt(cfg, prompt_kind)
  local prompts = { system_prompt_for(prompt_kind) }
  if cfg.append_system_prompt and cfg.append_system_prompt ~= "" then
    table.insert(prompts, cfg.append_system_prompt)
  end
  return table.concat(prompts, "\n\n")
end

local function add_common_cli_flags(cmd, cfg, opts)
  opts = opts or {}
  if opts.tools then
    table.insert(cmd, "--tools")
    table.insert(cmd, table.concat(opts.tools, ","))
  end
  if opts.rpc and opts.no_session ~= false then
    table.insert(cmd, "--no-session")
  end
  if not cfg.extensions then
    table.insert(cmd, "--no-extensions")
  end
  if not cfg.skills then
    table.insert(cmd, "--no-skills")
  end
  if cfg.provider then
    table.insert(cmd, "--provider")
    table.insert(cmd, cfg.provider)
  end
  if cfg.model then
    table.insert(cmd, "--model")
    table.insert(cmd, cfg.model)
  end
  if cfg.thinking then
    table.insert(cmd, "--thinking")
    table.insert(cmd, cfg.thinking)
  end
  if cfg.system_prompt then
    table.insert(cmd, "--system-prompt")
    table.insert(cmd, cfg.system_prompt)
  end
  table.insert(cmd, "--append-system-prompt")
  table.insert(cmd, build_append_system_prompt(cfg, opts.prompt))
end

local warn_if_web_tools_need_extensions

local function get_pi_cmd(opts)
  local cfg = config.get()
  opts = opts or {}
  warn_if_web_tools_need_extensions(cfg, opts.tools)
  local cmd = { "pi" }
  if opts.rpc ~= false then
    table.insert(cmd, "--mode")
    table.insert(cmd, "rpc")
    opts.rpc = true
  end
  add_common_cli_flags(cmd, cfg, opts)
  return cmd
end

local function prompt_payload(message, built_context)
  return message .. "\n\nContext:\n" .. built_context
end

local function explicit_range(command_opts)
  if command_opts and command_opts.range and command_opts.range > 0 then
    return { start = command_opts.line1, ["end"] = command_opts.line2 }
  end
  return nil
end

local function build_context_for_range(bufnr, range)
  if range then
    return context.get_visual_context(bufnr, config.get(), range)
  end
  return context.get_buffer_context(bufnr, config.get())
end

local function tools_include_web(tools)
  if not tools then
    return false
  end
  for _, tool in ipairs(tools) do
    if tool == "web_search" or tool == "web_fetch" then
      return true
    end
  end
  return false
end

warn_if_web_tools_need_extensions = function(cfg, tools)
  if cfg.extensions or warned_extensions_disabled_for_web_tools or not tools_include_web(tools) then
    return
  end
  warned_extensions_disabled_for_web_tools = true
  vim.notify("pi.nvim: web_search/web_fetch require extensions = true and pi-search", vim.log.levels.WARN)
end

local function set_status(session, status, message)
  if not session or session.closing then
    return
  end
  session.status = status
  if message then
    session_mod.push(session, message)
  end
  ui.update(session)
end

local function normalize_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function file_signature(path)
  local stat = vim.loop.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end

  return {
    size = stat.size,
    mtime_sec = stat.mtime and stat.mtime.sec or 0,
    mtime_nsec = stat.mtime and stat.mtime.nsec or 0,
  }
end

local function signatures_equal(a, b)
  if not a or not b then
    return a == b
  end

  return a.size == b.size and a.mtime_sec == b.mtime_sec and a.mtime_nsec == b.mtime_nsec
end

local function snapshot_loaded_file_buffers()
  local snapshots = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and context.buffer_is_file_backed(bufnr) then
      local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
      snapshots[path] = file_signature(path)
    end
  end

  return snapshots
end

local function reload_buffer_from_disk(bufnr, path)
  if vim.fn.filereadable(path) ~= 1 then
    return false
  end

  local ok = pcall(function()
    vim.api.nvim_buf_call(bufnr, function()
      local view = vim.api.nvim_get_current_buf() == bufnr and vim.fn.winsaveview() or nil
      vim.cmd("silent edit!")
      if view then
        vim.fn.winrestview(view)
      end
    end)
  end)

  return ok
end

local function reload_changed_file_buffers(session)
  local before_snapshots = session.file_snapshots or {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and context.buffer_is_file_backed(bufnr) then
      local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
      local before = before_snapshots[path]
      local after = file_signature(path)

      if not signatures_equal(before, after) then
        reload_buffer_from_disk(bufnr, path)
      end
    end
  end
end

local function finish_session(session, status, opts)
  opts = opts or {}
  if not session or session.closing then
    return
  end

  session.closing = true
  session.status = status
  session.ended_at = vim.loop.hrtime()

  if opts.error then
    session.last_error = opts.error
    session_mod.push(session, opts.error)
    ui.update(session)
    runner.finish(session)
  elseif status == "error" then
    ui.update(session)
    runner.finish(session)
  else
    reload_changed_file_buffers(session)
    ui.close(session)
    runner.finish(session)
  end

  if active_session == session then
    active_session = nil
  end
  last_session = session

  if session.is_rpc then
    history.append(session, status)
  end
  log.append_session(nil, session, session.last_message, status, session.source_path)
end

local function start_session(message, build_context, opts)
  opts = opts or {}
  local mode_config = MODE_CONFIGS[opts.mode or "edit"] or MODE_CONFIGS.edit
  if active_session then
    vim.notify("pi is already running, please wait", vim.log.levels.WARN)
    return
  end

  if not message or message == "" then
    vim.notify("No message provided", vim.log.levels.ERROR)
    return
  end

  local source_bufnr = vim.api.nvim_get_current_buf()
  local session = session_mod.new(source_bufnr)
  session.file_snapshots = snapshot_loaded_file_buffers()
  session.last_message = message
  session.is_rpc = true
  session.command_name = mode_config.command
  session.mode = opts.mode or "edit"
  session.context_range = opts.range
  session.cwd = vim.fn.getcwd()
  active_session = session
  last_session = session
  if mode_config.auto_answer then
    ui.open_answer(session)
  else
    ui.open(session)
  end
  set_status(session, "collecting_context")

  local ok, built_context = pcall(build_context)
  if not ok then
    finish_session(session, "error", { error = built_context })
    return
  end

  local payload = vim.json.encode({
    type = "prompt",
    message = prompt_payload(message, built_context),
  }) .. "\n"

  set_status(session, "starting")

  local process, err = runner.start(session, get_pi_cmd({ prompt = mode_config.prompt, tools = mode_config.tools }), payload, {
    on_event = function(event)
      if not active_session or active_session ~= session or session.cancelled then
        return
      end
      if event.type == "thinking" then
        set_status(session, "thinking")
      elseif event.type == "tool_start" then
        session.active_tool = event.tool
        set_status(session, "running_tool")
      elseif event.type == "tool_end" then
        session.active_tool = nil
        set_status(session, "thinking")
      elseif event.type == "text" then
        if mode_config.auto_answer then
          ui.append_answer(session, event.text)
        else
          session.answer = (session.answer or "") .. (event.text or "")
        end
      elseif event.type == "done" then
        session.saw_terminal_event = true
        finish_session(session, "done")
      elseif event.type == "error" then
        session.saw_terminal_event = true
        finish_session(session, "error", { error = event.message })
      end
    end,
    on_stderr = function(line)
      if not active_session or active_session ~= session or session.cancelled then
        return
      end
      session_mod.push(session, line)
      ui.update(session)
    end,
    on_error = function(error_message)
      if not active_session or active_session ~= session or session.cancelled then
        return
      end
      finish_session(session, "error", { error = tostring(error_message) })
    end,
    on_exit = function(result)
      if session.cancelled then
        return
      end
      if session.closing then
        return
      end
      if result.code ~= 0 and result.code ~= 143 and result.code ~= 124 then
        finish_session(session, "error", { error = "pi exited with code " .. result.code })
        return
      end
      if not session.saw_terminal_event then
        finish_session(session, "error", { error = "pi exited before completing request" })
        return
      end
      finish_session(session, "done")
    end,
  })

  if not process then
    finish_session(session, "error", { error = tostring(err) })
    return
  end

  session.process = process
end

local function start_terminal_session(message, build_context, opts)
  opts = opts or {}
  local mode_config = MODE_CONFIGS[opts.mode or "session"] or MODE_CONFIGS.session
  if not message or message == "" then
    vim.notify("No message provided", vim.log.levels.ERROR)
    return
  end

  local ok, built_context = pcall(build_context)
  if not ok then
    vim.notify(tostring(built_context), vim.log.levels.ERROR)
    return
  end

  local cmd = get_pi_cmd({ rpc = false, prompt = mode_config.prompt, tools = mode_config.tools })
  vim.cmd("botright split")
  vim.cmd("resize 15")

  local job_id = vim.fn.termopen(cmd)
  if job_id <= 0 then
    vim.notify("Failed to start pi terminal session", vim.log.levels.ERROR)
    return
  end

  vim.bo.bufhidden = "hide"
  vim.bo.swapfile = false
  vim.fn.chansend(job_id, prompt_payload(message, built_context) .. "\n")
  vim.cmd("startinsert")
end

local function prompt_for_command(command_name, command_opts, callback)
  local bufnr = ensure_file_backed_buffer(command_name)
  if not bufnr then
    return
  end

  local range = explicit_range(command_opts)
  vim.ui.input({ prompt = context.format_prompt_label(bufnr, range) }, function(input)
    if input then
      callback(input, function()
        return build_context_for_range(bufnr, range)
      end, range)
    end
  end)
end

function M.setup(opts)
  assert_supported_version()
  config.setup(opts)
end

function M.edit(command_opts)
  assert_supported_version()
  prompt_for_command("PiEdit", command_opts, function(input, build_context, range)
    start_session(input, build_context, { mode = "edit", range = range })
  end)
end

function M.edit_selection(command_opts)
  return M.edit(command_opts)
end

function M.question(command_opts)
  assert_supported_version()
  prompt_for_command("PiQuestion", command_opts, function(input, build_context, range)
    start_session(input, build_context, { mode = "question", range = range })
  end)
end

function M.question_selection(command_opts)
  return M.question(command_opts)
end

function M.research(command_opts)
  assert_supported_version()
  prompt_for_command("PiResearch", command_opts, function(input, build_context, range)
    start_session(input, build_context, { mode = "research", range = range })
  end)
end

function M.session(command_opts)
  assert_supported_version()
  prompt_for_command("PiSession", command_opts, function(input, build_context)
    start_terminal_session(input, build_context, { mode = "session" })
  end)
end

function M.session_edit(command_opts)
  return M.session(command_opts)
end

function M.session_edit_selection(command_opts)
  return M.session(command_opts)
end

function M.session_qa(command_opts)
  assert_supported_version()
  prompt_for_command("PiSessionQA", command_opts, function(input, build_context)
    start_terminal_session(input, build_context, { mode = "session_qa" })
  end)
end

function M.session_question_selection(command_opts)
  return M.session_qa(command_opts)
end

function M.session_question(command_opts)
  return M.session_qa(command_opts)
end

function M.prompt_with_buffer(command_opts)
  return M.edit(command_opts)
end

function M.prompt_with_selection(command_opts)
  return M.edit(command_opts)
end

function M.cancel()
  if not active_session then
    return
  end
  active_session.cancelled = true
  runner.cancel(active_session)
  last_session = active_session
  ui.close(active_session)
  active_session = nil
end

function M.is_running()
  return active_session ~= nil
end

function M._get_active_session()
  return active_session
end

function M._get_last_session()
  return last_session
end

function M.show_log()
  local log_path = log.DEFAULT_PATH

  if vim.fn.filereadable(log_path) == 0 then
    vim.notify("pi.nvim: log file not found at " .. log_path, vim.log.levels.INFO)
    return
  end

  vim.cmd("new")
  vim.cmd("read " .. vim.fn.fnameescape(log_path))
  vim.cmd("1d")
  vim.bo.modifiable = false
  vim.bo.buftype = "nofile"
  vim.bo.filetype = "log"
  vim.cmd("normal! G")
end

function M.show_history()
  history.show()
end

function M.show_last_history()
  history.show_last()
end

function M.get_buffer_context()
  return context.get_buffer_context(vim.api.nvim_get_current_buf(), config.get())
end

function M.get_visual_context()
  return context.get_visual_context(vim.api.nvim_get_current_buf(), config.get())
end

return M
