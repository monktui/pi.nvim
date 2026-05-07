local M = {}

local PROMPT_HEADING = "# Prompt"
local OPTIMIZED_HEADING = "# Optimized Prompt"
local SHORTCUTS_SEPARATOR = "---"
local SHORTCUTS_HEADING = "Shortcuts:"

local function cfg_value(value, fallback)
  if value == nil then
    return fallback
  end
  return value
end

local function dimension(value, total, fallback_ratio, min_value)
  if type(value) == "number" then
    if value > 0 and value < 1 then
      return math.max(min_value, math.floor(total * value))
    end
    if value >= 1 then
      return math.floor(value)
    end
  end
  return math.max(min_value, math.floor(total * fallback_ratio))
end

local function split_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    return { "" }
  end
  return lines
end

local function trim_lines(lines)
  lines = vim.deepcopy(lines or {})
  while #lines > 0 and lines[1] == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

local function section_text(lines)
  return table.concat(trim_lines(lines), "\n")
end

local function find_line(lines, text, start_at)
  for i = start_at or 1, #lines do
    if lines[i] == text then
      return i
    end
  end
  return nil
end

local function shortcut_lines(prompt_cfg)
  local send_key = cfg_value(prompt_cfg.send_key, "<C-s>")
  local send_normal_key = cfg_value(prompt_cfg.send_normal_key, "<leader><CR>")
  local rewrite_key = cfg_value(prompt_cfg.rewrite_key, "<leader>r")
  local cancel_key = cfg_value(prompt_cfg.cancel_key, "q")

  return {
    SHORTCUTS_SEPARATOR,
    SHORTCUTS_HEADING,
    string.format("%s         Send optimized prompt", send_key),
    string.format("%s Send optimized prompt", send_normal_key),
    string.format("%s    Optimize prompt", rewrite_key),
    string.format("%s            Cancel", cancel_key),
  }
end

local function initial_lines(initial, prompt_cfg)
  local lines = { PROMPT_HEADING, "" }
  vim.list_extend(lines, split_lines(initial or ""))
  vim.list_extend(lines, { "", OPTIMIZED_HEADING, "", "" })
  vim.list_extend(lines, shortcut_lines(prompt_cfg))
  return lines
end

local function sections(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local prompt_idx = find_line(lines, PROMPT_HEADING)
  local optimized_idx = find_line(lines, OPTIMIZED_HEADING, (prompt_idx or 0) + 1)
  local shortcuts_idx = find_line(lines, SHORTCUTS_SEPARATOR, (optimized_idx or 0) + 1)

  if not prompt_idx or not optimized_idx or not shortcuts_idx or prompt_idx >= optimized_idx or optimized_idx >= shortcuts_idx then
    return nil, "Prompt sections are missing"
  end

  return {
    lines = lines,
    prompt = vim.list_slice(lines, prompt_idx + 1, optimized_idx - 1),
    optimized = vim.list_slice(lines, optimized_idx + 1, shortcuts_idx - 1),
    optimized_start = optimized_idx,
    optimized_end = shortcuts_idx - 1,
  }
end

local function prompt_text(bufnr)
  local parsed, err = sections(bufnr)
  if not parsed then
    return nil, err
  end
  return section_text(parsed.prompt)
end

local function submit_text(bufnr)
  local parsed, err = sections(bufnr)
  if not parsed then
    return nil, err
  end
  local optimized = section_text(parsed.optimized)
  if optimized ~= "" then
    return optimized
  end
  return section_text(parsed.prompt)
end

local function replace_optimized(bufnr, text)
  local parsed, err = sections(bufnr)
  if not parsed then
    return nil, err
  end

  local replacement = { "" }
  vim.list_extend(replacement, split_lines(text or ""))
  table.insert(replacement, "")

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, parsed.optimized_start, parsed.optimized_end, false, replacement)
  vim.bo[bufnr].modifiable = true
  return true
end

local function close_window(winid, bufnr)
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

function M.open(opts)
  opts = opts or {}
  local prompt_cfg = opts.config or {}
  local width = dimension(prompt_cfg.width, vim.o.columns, 0.65, 50)
  local height = dimension(prompt_cfg.height, vim.o.lines, 0.35, 8)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "Pi prompt") .. " ",
    title_pos = "center",
  })

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_name(bufnr, "pi-prompt://" .. tostring(vim.loop.hrtime()))
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, initial_lines(opts.initial, prompt_cfg))

  local closed = false
  local function cancel()
    if closed then
      return
    end
    closed = true
    close_window(winid, bufnr)
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  local function submit()
    if closed then
      return
    end
    local text, err = submit_text(bufnr)
    if not text then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    if text == "" then
      vim.notify("No message provided", vim.log.levels.ERROR)
      return
    end
    closed = true
    close_window(winid, bufnr)
    opts.on_submit(text)
  end

  local function rewrite()
    if not opts.on_rewrite then
      return
    end
    local text, err = prompt_text(bufnr)
    if not text then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    if text == "" then
      vim.notify("No prompt to rewrite", vim.log.levels.ERROR)
      return
    end
    vim.bo[bufnr].modifiable = false
    opts.on_rewrite(text, function(rewritten)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local ok, replace_err = replace_optimized(bufnr, rewritten)
      if not ok then
        vim.notify(replace_err, vim.log.levels.ERROR)
        return
      end
      if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_set_current_win(winid)
        vim.cmd("normal! G$")
      end
    end, function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.bo[bufnr].modifiable = true
      end
    end)
  end

  local map_opts = { buffer = bufnr, silent = true, nowait = true }
  local send_key = cfg_value(prompt_cfg.send_key, "<C-s>")
  local send_normal_key = cfg_value(prompt_cfg.send_normal_key, "<leader><CR>")
  local rewrite_key = cfg_value(prompt_cfg.rewrite_key, "<leader>r")
  local cancel_key = cfg_value(prompt_cfg.cancel_key, "q")

  vim.keymap.set({ "n", "i" }, send_key, submit, vim.tbl_extend("force", map_opts, { desc = "Send pi prompt" }))
  vim.keymap.set("n", send_normal_key, submit, vim.tbl_extend("force", map_opts, { desc = "Send pi prompt" }))
  vim.keymap.set({ "n", "v" }, rewrite_key, rewrite, vim.tbl_extend("force", map_opts, { desc = "Rewrite pi prompt" }))
  vim.keymap.set("n", cancel_key, cancel, vim.tbl_extend("force", map_opts, { desc = "Cancel pi prompt" }))

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      closed = true
    end,
  })

  vim.api.nvim_win_set_cursor(winid, { 3, 0 })
  vim.cmd("startinsert")
  return { bufnr = bufnr, winid = winid }
end

return M
