local M = {}

local function history_dir()
  if _G.__pi_test_history_path then
    return vim.fn.fnamemodify(_G.__pi_test_history_path, ":h")
  end
  return vim.fn.stdpath("data") .. "/pi.nvim"
end

local function history_path()
  if _G.__pi_test_history_path then
    return _G.__pi_test_history_path
  end
  return history_dir() .. "/history.md"
end

local function display_value(value)
  if value == nil or value == "" then
    return "_none_"
  end
  return string.format("`%s`", tostring(value))
end

local function markdown_text(value)
  if value == nil or value == "" then
    return "_empty_"
  end
  return tostring(value)
end

local function assistant_text(session, status)
  if session.answer and session.answer ~= "" then
    return session.answer
  end
  if status == "cancelled" or session.cancelled then
    return "_Cancelled before assistant response._"
  end
  if status == "error" and session.last_error then
    return tostring(session.last_error)
  end
  return "_No assistant text emitted._"
end

local function range_text(range)
  if not range then
    return nil
  end
  return string.format("%d-%d", range.start, range["end"])
end

local function entry_lines(session, status)
  local command = session.command_name or "pi"
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  return {
    string.format("## %s · %s · %s", timestamp, command, status),
    "",
    "Source: " .. display_value(session.source_path),
    "Range: " .. display_value(range_text(session.context_range)),
    "Cwd: " .. display_value(session.cwd or vim.fn.getcwd()),
    "",
    "### Request",
    "",
    markdown_text(session.last_message),
    "",
    "### Assistant",
    "",
    markdown_text(assistant_text(session, status)),
    "",
    "---",
    "",
  }
end

function M.path()
  return history_path()
end

function M.append(session, status)
  if not session or not session.last_message then
    return
  end
  vim.fn.mkdir(history_dir(), "p")
  vim.fn.writefile(entry_lines(session, status), history_path(), "a")
end

local function open_lines(lines, title)
  vim.cmd("new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_name(bufnr, title)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.cmd("normal! G")
end

function M.show()
  local path = history_path()
  if vim.fn.filereadable(path) == 0 then
    vim.notify("pi.nvim: history file not found at " .. path, vim.log.levels.INFO)
    return
  end
  vim.cmd("new")
  vim.cmd("read " .. vim.fn.fnameescape(path))
  vim.cmd("1d")
  vim.bo.modifiable = false
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "hide"
  vim.bo.filetype = "markdown"
  vim.cmd("normal! G")
end

function M.show_last()
  local path = history_path()
  if vim.fn.filereadable(path) == 0 then
    vim.notify("pi.nvim: history file not found at " .. path, vim.log.levels.INFO)
    return
  end
  local lines = vim.fn.readfile(path)
  local start_idx = nil
  for i = #lines, 1, -1 do
    if lines[i]:match("^## ") then
      start_idx = i
      break
    end
  end
  if not start_idx then
    vim.notify("pi.nvim: history is empty", vim.log.levels.INFO)
    return
  end
  open_lines(vim.list_slice(lines, start_idx, #lines), "pi-history-last://latest")
end

return M
