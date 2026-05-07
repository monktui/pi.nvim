local M = {}

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

local function buffer_text(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  while #lines > 0 and lines[1] == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

local function replace_buffer(bufnr, text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = true
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
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(opts.initial or "", "\n", { plain = true }))

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
    local text = buffer_text(bufnr)
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
    local text = buffer_text(bufnr)
    if text == "" then
      vim.notify("No prompt to rewrite", vim.log.levels.ERROR)
      return
    end
    vim.bo[bufnr].modifiable = false
    opts.on_rewrite(text, function(rewritten)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      replace_buffer(bufnr, rewritten)
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

  vim.cmd("startinsert")
  return { bufnr = bufnr, winid = winid }
end

return M
