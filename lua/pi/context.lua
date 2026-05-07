local M = {}

local EDIT_SYSTEM_PROMPT = [[You are running inside the pi.nvim Neovim plugin. The user has sent an edit request and will not be able to reply back. You must complete the task immediately without asking any questions or requesting clarification. Take action now and do what was asked.

IMPORTANT: Any file content included in the provided Context comes from the user's current Neovim buffer and may be newer than the on-disk file. Treat the provided Context as the source of truth for that file content. Do not read the same file just to verify its contents before editing, because the filesystem copy may be stale if the user has unsaved changes. Base edits on the provided buffer/selection content whenever possible.]]

local QUESTION_SYSTEM_PROMPT = [[You are running inside the pi.nvim Neovim plugin in question-answering mode. Answer the user's question using the provided Context and read/search/web tools when useful. Do not edit, write, or mutate files. If the context is insufficient, inspect relevant files instead of guessing. If you use web tools, cite the URLs you used.]]

local RESEARCH_SYSTEM_PROMPT = [[You are running inside the pi.nvim Neovim plugin in research mode. Investigate and report findings using the provided Context plus read/search/bash/web tools when useful. Do not edit, write, or mutate files, and do not run destructive shell commands. Prefer concise evidence-backed findings and cite URLs when web tools are used.]]

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

return M
