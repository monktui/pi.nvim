local M = {}

local VALID_THINKING_LEVELS = {
  off = true,
  minimal = true,
  low = true,
  medium = true,
  high = true,
  xhigh = true,
}

M.defaults = {
  provider = nil,
  model = nil,
  thinking = "off",
  system_prompt = nil,
  append_system_prompt = nil,
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
}

local values = vim.deepcopy(M.defaults)

local function validate_number(name, value)
  if type(value) ~= "number" or value < 1 then
    error(string.format("pi.nvim: %s must be a positive number", name))
  end
end

function M.validate(opts)
  local context = opts.context
  if context ~= nil then
    if type(context) ~= "table" then
      error("pi.nvim: context must be a table")
    end
    if context.max_bytes ~= nil then
      validate_number("context.max_bytes", context.max_bytes)
    end
    if context.ask ~= nil then
      if type(context.ask) ~= "table" then
        error("pi.nvim: context.ask must be a table")
      end
      if context.ask.surrounding_lines ~= nil then
        validate_number("context.ask.surrounding_lines", context.ask.surrounding_lines)
      end
    end
    if context.selection ~= nil then
      if type(context.selection) ~= "table" then
        error("pi.nvim: context.selection must be a table")
      end
      if context.selection.surrounding_lines ~= nil then
        validate_number("context.selection.surrounding_lines", context.selection.surrounding_lines)
      end
    end
  end
  if opts.skills ~= nil and type(opts.skills) ~= "boolean" then
    error("pi.nvim: skills must be a boolean")
  end
  if opts.extensions ~= nil and type(opts.extensions) ~= "boolean" then
    error("pi.nvim: extensions must be a boolean")
  end
  if opts.prompt ~= nil then
    if type(opts.prompt) ~= "table" then
      error("pi.nvim: prompt must be a table")
    end
    if opts.prompt.popup ~= nil and type(opts.prompt.popup) ~= "boolean" then
      error("pi.nvim: prompt.popup must be a boolean")
    end
    if opts.prompt.ai_rewrite ~= nil and type(opts.prompt.ai_rewrite) ~= "boolean" then
      error("pi.nvim: prompt.ai_rewrite must be a boolean")
    end
  end
  if opts.session ~= nil then
    if type(opts.session) ~= "table" then
      error("pi.nvim: session must be a table")
    end
    if opts.session.continue ~= nil and type(opts.session.continue) ~= "boolean" then
      error("pi.nvim: session.continue must be a boolean")
    end
    if opts.session.inject_context ~= nil and type(opts.session.inject_context) ~= "boolean" then
      error("pi.nvim: session.inject_context must be a boolean")
    end
    if opts.session.include_open_buffers ~= nil and type(opts.session.include_open_buffers) ~= "boolean" then
      error("pi.nvim: session.include_open_buffers must be a boolean")
    end
    if opts.session.scope ~= nil and opts.session.scope ~= "cwd" and opts.session.scope ~= "global" then
      error('pi.nvim: session.scope must be "cwd" or "global"')
    end
    if opts.session.max_buffer_bytes ~= nil then
      validate_number("session.max_buffer_bytes", opts.session.max_buffer_bytes)
    end
    if opts.session.max_total_context_bytes ~= nil then
      validate_number("session.max_total_context_bytes", opts.session.max_total_context_bytes)
    end
  end
  if opts.thinking ~= nil then
    if type(opts.thinking) ~= "string" then
      error("pi.nvim: thinking must be a string")
    end
    if not VALID_THINKING_LEVELS[opts.thinking] then
      error("pi.nvim: thinking must be one of: off, minimal, low, medium, high, xhigh")
    end
  end
  if opts.system_prompt ~= nil and type(opts.system_prompt) ~= "string" then
    error("pi.nvim: system_prompt must be a string")
  end
  if opts.append_system_prompt ~= nil and type(opts.append_system_prompt) ~= "string" then
    error("pi.nvim: append_system_prompt must be a string")
  end
end

function M.setup(opts)
  opts = opts or {}
  M.validate(opts)
  values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  return values
end

function M.get()
  return values
end

return M
