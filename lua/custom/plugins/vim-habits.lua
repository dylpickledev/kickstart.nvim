-- vim-habits — carry Dylan's VS Code (vscodevim) muscle memory into nvim.
-- Mined from ~/Library/Application Support/Code/User/settings.json + keybindings.json.
-- These are plain keymaps, not a plugin: lazy `require`s this module at import time
-- (to read the spec), which runs the top-level code below; `return {}` hands back an
-- empty spec. Additive — touches none of kickstart's own files.
--
-- Already matched by kickstart, so NOT repeated here: relativenumber, system
-- clipboard, leader=<Space>, <C-hjkl> window focus, \\ = Neotree reveal.

-- Run AFTER lazy has wired every plugin's `keys` (VimEnter), so our overrides win.
-- Notably kickstart registers conform on <leader>f as a lazy key stub during setup;
-- setting ours at import time would lose to it. VimEnter fires once, after all that.
vim.api.nvim_create_autocmd('VimEnter', {
  callback = function()
    local map = vim.keymap.set

-- Keep the cursor centered on big jumps (your <C-d>zz / <C-u>zz / <space>z=zz).
map('n', '<C-d>', '<C-d>zz', { desc = 'Half page down (centered)' })
map('n', '<C-u>', '<C-u>zz', { desc = 'Half page up (centered)' })
map('n', 'n', 'nzzzv', { desc = 'Next search (centered)' })
map('n', 'N', 'Nzzzv', { desc = 'Prev search (centered)' })
map('n', '<leader>z', 'zz', { desc = 'Center cursor line' })

-- H / L = buffer prev / next (your <S-h> / <S-l>).
map('n', '<S-h>', '<cmd>bprevious<CR>', { desc = 'Buffer previous' })
map('n', '<S-l>', '<cmd>bnext<CR>', { desc = 'Buffer next' })

-- Your two most-used leader verbs, mapped to match VS Code exactly:
--   leaderf = open file (quickOpen)  ·  leaderp = format document
-- This intentionally overrides kickstart's <leader>f (which was format) so format
-- moves to <leader>p, giving you your VS Code layout back.
map('n', '<leader>f', function() require('telescope.builtin').find_files() end, { desc = '[F]ind files' })
map('n', '<leader>p', function() require('conform').format { async = true, lsp_format = 'fallback' } end, { desc = 'Format document' })

-- LSP verbs you had: <leader>ca = code action (fits kickstart's [C]ode group), gh = hover.
map('n', '<leader>ca', vim.lsp.buf.code_action, { desc = '[C]ode [A]ction' })
map('n', 'gh', vim.lsp.buf.hover, { desc = 'Hover (definition preview)' })

-- File explorer toggle, VS-Code-sidebar style (kickstart's \\ only reveals).
map('n', '<leader>e', '<cmd>Neotree toggle<CR>', { desc = '[E]xplorer (Neotree)' })

-- Visual mode: keep selection after indent; move selected lines (your < > J K).
map('v', '<', '<gv', { desc = 'Outdent, keep selection' })
map('v', '>', '>gv', { desc = 'Indent, keep selection' })
map('v', 'J', ":m '>+1<CR>gv=gv", { desc = 'Move selection down' })
map('v', 'K', ":m '<-2<CR>gv=gv", { desc = 'Move selection up' })
  end,
})

return {}
