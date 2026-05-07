-- pi.nvim - Neovim plugin for pi coding agent
-- Maintainer: pablopunk
-- License: MIT

-- Prevent the plugin from being loaded more than once.
if vim.g.loaded_pi_nvim then
  return
end
vim.g.loaded_pi_nvim = true

-- Register user-facing commands exposed by the plugin.

vim.api.nvim_create_user_command("PiEdit", function(opts)
  require("pi").edit(opts)
end, { range = true, desc = "Ask pi to edit using selection or buffer context" })

vim.api.nvim_create_user_command("PiQuestion", function(opts)
  require("pi").question(opts)
end, { range = true, desc = "Ask pi a quick read-only question using selection or buffer context" })

vim.api.nvim_create_user_command("PiResearch", function(opts)
  require("pi").research(opts)
end, { range = true, desc = "Ask pi to research using selection or buffer context" })

vim.api.nvim_create_user_command("PiReview", function(opts)
  require("pi").review(opts)
end, { range = true, desc = "Ask pi to review selection or buffer context" })

vim.api.nvim_create_user_command("PiSession", function(opts)
  require("pi").session(opts)
end, { range = true, desc = "Open a full pi coding session using selection or buffer context" })

vim.api.nvim_create_user_command("PiSessionQA", function(opts)
  require("pi").session_qa(opts)
end, { range = true, desc = "Open a full pi QA/research session using selection or buffer context" })

vim.api.nvim_create_user_command("PiSessionReview", function(opts)
  require("pi").session_review(opts)
end, { range = true, desc = "Open a full pi review session using selection or buffer context" })

vim.api.nvim_create_user_command("PiHistory", function()
  require("pi").show_history()
end, { desc = "Show pi request/answer history" })

vim.api.nvim_create_user_command("PiHistoryLast", function()
  require("pi").show_last_history()
end, { desc = "Show latest pi request/answer history entry" })

vim.api.nvim_create_user_command("PiActivity", function()
  require("pi").show_activity()
end, { desc = "Toggle pi activity for the active or latest request" })

-- Cancel the currently running pi request, if there is one.
vim.api.nvim_create_user_command("PiCancel", function()
  require("pi").cancel()
end, { desc = "Cancel the active pi request" })

-- Show the pi.nvim session log
vim.api.nvim_create_user_command("PiLog", function()
  require("pi").show_log()
end, { desc = "Show pi session log" })
