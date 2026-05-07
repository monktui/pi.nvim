local M = {}

local EDIT_SYSTEM_PROMPT = [[You are running inside the pi.nvim Neovim plugin. The user has sent an edit request and will not be able to reply back. You must complete the task immediately without asking any questions or requesting clarification. Take action now and do what was asked.

IMPORTANT: Any file content included in the provided Context comes from the user's current Neovim buffer and may be newer than the on-disk file. Treat the provided Context as the source of truth for that file content. Do not read the same file just to verify its contents before editing, because the filesystem copy may be stale if the user has unsaved changes. Base edits on the provided buffer/selection content whenever possible.]]

local QUESTION_SYSTEM_PROMPT = [[You are running inside the pi.nvim Neovim plugin in question-answering mode. Answer the user's question using the provided Context and read/search/web tools when useful. Do not edit, write, or mutate files. If the context is insufficient, inspect relevant files instead of guessing. If you use web tools, cite the URLs you used.]]

local RESEARCH_SYSTEM_PROMPT = [[You are running inside the pi.nvim Neovim plugin in research mode. Investigate and report findings using the provided Context plus read/search/bash/web tools when useful. Do not edit, write, or mutate files, and do not run destructive shell commands. Prefer concise evidence-backed findings and cite URLs when web tools are used.]]

local REVIEW_SYSTEM_PROMPT = [[You are running inside the pi.nvim Neovim plugin in code review mode. Review the provided Context for bugs, behavioral regressions, security risks, edge cases, and missing tests. Do not edit, write, or mutate files. Prioritize findings first, ordered by severity, with file/line references when possible. Do not provide broad summaries before findings. If there are no findings, say so and mention residual risks or testing gaps.]]

local BUFFER_SOURCE_OF_TRUTH_NOTE = [[NOTE: The context below comes from the current Neovim buffer and may include unsaved changes that are newer than the on-disk file. Treat this context as the source of truth for the file content, and do not read the same file only to confirm its current contents before editing.]]

local EMPTY_FILE_NOTE = [[NOTE: This file is currently empty. Please create or populate it directly by applying the necessary edits so pi.nvim can write the file.]]

local function buffer_is_empty(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:match("%S") then
      return false
    end
  end
  return true
end

function M.buffer_is_file_backed(bufnr)
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local filename = vim.api.nvim_buf_get_name(bufnr)
  return filename ~= nil and filename ~= ""
end

function M.get_visual_selection_range()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  if not start_pos or not end_pos then
    return nil
  end
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  return { start = start_line, ["end"] = end_line }
end

function M.format_prompt_label(bufnr, selection_range)
  local components = {}
  local filename = vim.api.nvim_buf_get_name(bufnr)
  if filename ~= "" then
    table.insert(components, vim.fn.fnamemodify(filename, ":t"))
  end
  if selection_range and selection_range.start and selection_range["end"] then
    table.insert(components, string.format("%d:%d", selection_range.start, selection_range["end"]))
  end
  if #components == 0 then
    return "ask pi: "
  end
  return string.format("ask pi (%s): ", table.concat(components, ":"))
end

local function filetype_for(bufnr)
  return vim.bo[bufnr].filetype ~= "" and vim.bo[bufnr].filetype or "text"
end

local function slice_lines_around(lines, center_line, surrounding_lines)
  local start_line = math.max(1, center_line - surrounding_lines)
  local end_line = math.min(#lines, center_line + surrounding_lines)
  return vim.list_slice(lines, start_line, end_line), start_line, end_line
end

local function truncate_to_bytes(text, max_bytes)
  if #text <= max_bytes then
    return text, false
  end
  return text:sub(1, max_bytes), true
end

local function content_block(label, text)
  return string.format("%s:\n```\n%s\n```", label, text)
end

local function buffer_metadata(bufnr, current_bufnr)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  return {
    bufnr = bufnr,
    filename = filename,
    filetype = filetype_for(bufnr),
    line_count = vim.api.nvim_buf_line_count(bufnr),
    modified = vim.bo[bufnr].modified,
    current = bufnr == current_bufnr,
  }
end

local function loaded_file_buffers(current_bufnr, include_open_buffers)
  local buffers = {}
  local seen = {}

  if vim.api.nvim_buf_is_loaded(current_bufnr) and M.buffer_is_file_backed(current_bufnr) then
    table.insert(buffers, current_bufnr)
    seen[current_bufnr] = true
  end

  if include_open_buffers == false then
    return buffers
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if not seen[bufnr] and vim.api.nvim_buf_is_loaded(bufnr) and M.buffer_is_file_backed(bufnr) then
      table.insert(buffers, bufnr)
      seen[bufnr] = true
    end
  end

  return buffers
end

local function buffer_section(meta, max_buffer_bytes, selection_range)
  local lines = vim.api.nvim_buf_get_lines(meta.bufnr, 0, -1, false)
  local text, trimmed = truncate_to_bytes(table.concat(lines, "\n"), max_buffer_bytes)
  local parts = {
    string.format("File: %s", meta.filename),
    string.format("Role: %s", meta.current and "current" or "open-buffer"),
    string.format("Filetype: %s", meta.filetype),
    string.format("Modified: %s", meta.modified and "true" or "false"),
    string.format("Line count: %d", meta.line_count),
  }

  if meta.current and selection_range then
    parts[#parts + 1] = string.format("Selected lines: %d-%d", selection_range.start, selection_range["end"])
  end

  parts[#parts + 1] = BUFFER_SOURCE_OF_TRUTH_NOTE

  if meta.current and selection_range then
    local selected_lines = vim.api.nvim_buf_get_lines(meta.bufnr, selection_range.start - 1, selection_range["end"], false)
    local selected_text, selected_trimmed = truncate_to_bytes(table.concat(selected_lines, "\n"), max_buffer_bytes)
    parts[#parts + 1] = content_block("Selected content", selected_text)
    if selected_trimmed then
      parts[#parts + 1] = string.format("NOTE: Selected content was trimmed (max_buffer_bytes=%d).", max_buffer_bytes)
    end
  end

  parts[#parts + 1] = content_block("Buffer content", text)

  if trimmed then
    parts[#parts + 1] = string.format("NOTE: Buffer content was trimmed (max_buffer_bytes=%d).", max_buffer_bytes)
  end
  if buffer_is_empty(meta.bufnr) then
    parts[#parts + 1] = EMPTY_FILE_NOTE
  end

  return table.concat(parts, "\n")
end

function M.get_system_prompt()
  return EDIT_SYSTEM_PROMPT
end

function M.get_edit_system_prompt()
  return EDIT_SYSTEM_PROMPT
end

function M.get_question_system_prompt()
  return QUESTION_SYSTEM_PROMPT
end

function M.get_research_system_prompt()
  return RESEARCH_SYSTEM_PROMPT
end

function M.get_review_system_prompt()
  return REVIEW_SYSTEM_PROMPT
end

function M.get_buffer_context(bufnr, config)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local surrounding_lines = config.context.ask.surrounding_lines
  local nearby_lines, start_line, end_line = slice_lines_around(lines, cursor_line, surrounding_lines)
  local content, did_trim_bytes = truncate_to_bytes(table.concat(nearby_lines, "\n"), config.context.max_bytes)
  local filename = vim.api.nvim_buf_get_name(bufnr)

  local parts = {
    string.format("File: %s", filename),
    string.format("Cwd: %s", vim.fn.getcwd()),
    string.format("Filetype: %s", filetype_for(bufnr)),
    string.format("Current line: %d", cursor_line),
    BUFFER_SOURCE_OF_TRUTH_NOTE,
    content_block(string.format("Nearby context (%d-%d)", start_line, end_line), content),
  }

  if did_trim_bytes then
    parts[#parts + 1] = string.format(
      "NOTE: Context was trimmed for speed (max_bytes=%d).",
      config.context.max_bytes
    )
  end

  if buffer_is_empty(bufnr) then
    parts[#parts + 1] = EMPTY_FILE_NOTE
  end

  return table.concat(parts, "\n\n")
end

function M.get_visual_context(bufnr, config, selection_range)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  selection_range = selection_range or M.get_visual_selection_range() or { start = 1, ["end"] = #all_lines }
  local surrounding_lines = config.context.selection.surrounding_lines
  local before = math.max(1, selection_range.start - surrounding_lines)
  local after = math.min(#all_lines, selection_range["end"] + surrounding_lines)

  local nearby_lines = vim.api.nvim_buf_get_lines(bufnr, before - 1, after, false)
  local selected_lines = vim.api.nvim_buf_get_lines(bufnr, selection_range.start - 1, selection_range["end"], false)
  local nearby_text, nearby_trimmed = truncate_to_bytes(table.concat(nearby_lines, "\n"), config.context.max_bytes)
  local selected_text, selected_trimmed = truncate_to_bytes(table.concat(selected_lines, "\n"), config.context.max_bytes)

  local parts = {
    string.format("File: %s", filename),
    string.format("Cwd: %s", vim.fn.getcwd()),
    string.format("Filetype: %s", filetype_for(bufnr)),
    string.format("Selected lines: %d-%d", selection_range.start, selection_range["end"]),
    BUFFER_SOURCE_OF_TRUTH_NOTE,
    content_block("Selected content", selected_text),
    content_block(string.format("Nearby context (%d-%d)", before, after), nearby_text),
  }

  if nearby_trimmed or selected_trimmed then
    parts[#parts + 1] = string.format(
      "NOTE: Selection context was trimmed for speed (max_bytes=%d).",
      config.context.max_bytes
    )
  end

  if buffer_is_empty(bufnr) then
    parts[#parts + 1] = EMPTY_FILE_NOTE
  end

  return table.concat(parts, "\n\n")
end

function M.get_workspace_context(current_bufnr, config, selection_range)
  local session_config = config.session or {}
  local max_buffer_bytes = session_config.max_buffer_bytes or config.context.max_bytes
  local max_total_context_bytes = session_config.max_total_context_bytes or (config.context.max_bytes * 3)
  local buffers = loaded_file_buffers(current_bufnr, session_config.include_open_buffers)
  local metas = {}
  local current_filename = vim.api.nvim_buf_get_name(current_bufnr)

  for _, bufnr in ipairs(buffers) do
    metas[#metas + 1] = buffer_metadata(bufnr, current_bufnr)
  end

  table.sort(metas, function(a, b)
    if a.current ~= b.current then
      return a.current
    end
    if a.modified ~= b.modified then
      return a.modified
    end
    return a.filename < b.filename
  end)

  local summary = {
    string.format("Cwd: %s", vim.fn.getcwd()),
    string.format("Current file: %s", current_filename),
  }

  if selection_range then
    summary[#summary + 1] = string.format("Selected lines: %d-%d", selection_range.start, selection_range["end"])
  else
    summary[#summary + 1] = string.format("Current line: %d", vim.api.nvim_win_get_cursor(0)[1])
  end

  summary[#summary + 1] = "Open buffers:"
  for _, meta in ipairs(metas) do
    local flags = {}
    if meta.current then
      flags[#flags + 1] = "current"
    end
    if meta.modified then
      flags[#flags + 1] = "modified"
    end
    local suffix = #flags > 0 and string.format(" (%s)", table.concat(flags, ", ")) or ""
    summary[#summary + 1] = string.format("- %s%s", meta.filename, suffix)
  end

  local parts = {
    "Neovim workspace context",
    table.concat(summary, "\n"),
    "All file content below comes from currently loaded Neovim buffers and may include unsaved changes. Treat it as source of truth for these files.",
  }

  for _, meta in ipairs(metas) do
    parts[#parts + 1] = buffer_section(meta, max_buffer_bytes, selection_range)
  end

  local text, trimmed = truncate_to_bytes(table.concat(parts, "\n\n"), max_total_context_bytes)
  if trimmed then
    text = text .. string.format("\n\nNOTE: Workspace context was trimmed (max_total_context_bytes=%d).", max_total_context_bytes)
  end

  return text
end

return M
