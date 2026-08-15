-- md-review — read markdown rendered in the buffer, leave review comments an agent
-- acts on, and (in batch mode) fly through a whole review set without leaving nvim.
--
--   render-markdown.nvim   renders headings/bold/code/tables in-buffer (raw on the
--                          cursor line, so editing stays normal).
--   comment keys (markdown buffers):
--     <leader>mc  inline comment           <!-- 💬 … -->  on the line below
--     <leader>mC  whole-doc comment        <!-- 💬 (doc) … -->  at the top
--     <leader>mv  inline comment + voice   (also starts SuperWhisper for you)
--     <leader>mV  whole-doc comment + voice
--   review-set navigation (when `mdr a.md b.md …` opened a set):
--     <leader>ma                approve: stamp reviewed_at (pk review) + next
--     <leader>mn / <leader>mp   save + next / prev doc
--     <leader>ml                review navigator (floating list, ✓/○/●, jump)
--     <leader>ms                submit all → fires one /md-review, quits
--   a winbar shows the menu + progress in every review buffer.
--
--   `mdc <file>` (bash) collects the 💬 comments; `/md-review` hands them to an agent.
-- HTML comments are invisible in rendered output, greppable, and move with the text.

return {
  {
    'MeanderingProgrammer/render-markdown.nvim',
    dependencies = { 'nvim-treesitter/nvim-treesitter' },
    ft = { 'markdown' },
    opts = {
      anti_conceal = { enabled = true }, -- raw text on the cursor line, rendered elsewhere
      overrides = {},
    },
    config = function(_, opts)
      require('render-markdown').setup(opts)

      -- Fix a crash when render-markdown deep-parses a fenced code block (nvim 0.11+
      -- maps a capture id → a LIST of nodes; nvim-treesitter's frozen directive assumes
      -- one node). Re-register it 0.11+-correctly (force wins).
      local alias = {
        py = 'python', js = 'javascript', ts = 'typescript', sh = 'bash',
        shell = 'bash', zsh = 'bash', rs = 'rust', rb = 'ruby', yml = 'yaml',
      }
      pcall(vim.treesitter.query.add_directive, 'set-lang-from-info-string!',
        function(match, _, bufnr, pred, metadata)
          local node = match[pred[2]]
          if type(node) == 'table' then node = node[1] end
          if not node then return end
          local info = vim.treesitter.get_node_text(node, bufnr):lower():gsub('%s+', '')
          if info ~= '' then metadata['injection.language'] = alias[info] or info end
        end, { force = true })

      -- highlight <!-- 💬 … --> lines so review notes pop while you work
      vim.api.nvim_set_hl(0, 'MdReviewComment', { fg = '#ffd27f', italic = true })
      vim.api.nvim_set_hl(0, 'MdReviewBar', { fg = '#ffd27f', bg = '#2a2a17', bold = true })
      local function highlight()
        vim.fn.matchadd('MdReviewComment', '<!-- 💬.*-->')
      end

      -- review-queue context header: when reviewq launched this batch it wrote a
      -- <abspath>\t<context> map; render the matching line as a display-only
      -- virtual header at the top of the doc. Never touches the file. Absent for
      -- session-local batches (no map entry) — context shows only when it helps.
      local ctx_ns = vim.api.nvim_create_namespace 'mdr_review_context'
      local function show_review_context(bufnr)
        local state = os.getenv 'XDG_STATE_HOME' or (os.getenv 'HOME' .. '/.local/state')
        local ok, lines = pcall(vim.fn.readfile, state .. '/stack-session/review-context.tsv')
        if not ok then return end
        local abs = vim.api.nvim_buf_get_name(bufnr)
        local ctx
        for _, l in ipairs(lines) do
          local f, c = l:match '^(.-)\t(.+)$'
          if f == abs then ctx = c; break end
        end
        if not ctx then return end
        vim.api.nvim_buf_clear_namespace(bufnr, ctx_ns, 0, -1)
        vim.api.nvim_buf_set_extmark(bufnr, ctx_ns, 0, 0, {
          virt_lines_above = true,
          virt_lines = {
            { { '  ⟪ ' .. ctx .. ' ⟫', 'MdReviewComment' } },
            { { '', 'Normal' } },
          },
        })
      end

      -- Start SuperWhisper by simulating the user's Option+Space global hotkey.
      -- (The superwhisper CLI is read-only; the hotkey is the reliable trigger.)
      -- Deferred so insert mode is live first — SuperWhisper types its result into
      -- whatever field is focused when it STOPS, i.e. the comment we just opened.
      local function trigger_superwhisper()
        vim.defer_fn(function()
          vim.fn.jobstart(
            { 'osascript', '-e', 'tell application "System Events" to key code 49 using {option down}' },
            { detach = true })
        end, 150)
      end

      -- Drop a comment and land the cursor inside it in insert mode.
      --   opts.doc   → whole-doc note at the top (<!-- 💬 (doc) … -->)
      --   opts.voice → also start SuperWhisper
      local function drop(opts)
        opts = opts or {}
        local prefix, row
        if opts.doc then
          prefix, row = '<!-- 💬 (doc) ', 0 -- top of file
        else
          prefix, row = '<!-- 💬 ', vim.api.nvim_win_get_cursor(0)[1] -- below cursor
        end
        vim.api.nvim_buf_set_lines(0, row, row, false, { prefix .. ' -->' })
        -- #prefix is BYTE length (💬 is multi-byte) — matches nvim's byte column.
        vim.api.nvim_win_set_cursor(0, { row + 1, #prefix })
        vim.cmd 'startinsert'
        if opts.voice then trigger_superwhisper() end
      end

      -- ---- review state (per doc: reviewed / skipped) — persisted so it survives
      -- reopening the set, and readable by the agent to know what you did NOT review ----
      local STATE = (os.getenv 'MDR_STATE' or (os.getenv 'HOME' .. '/.local/state/mdr'))
        .. '/review-state'
      local review_state = {} -- abs file -> 'reviewed' | 'skipped'
      local function load_state()
        local ok, lines = pcall(vim.fn.readfile, STATE)
        if not ok then return end
        for _, l in ipairs(lines) do
          local st, f = l:match '^(%S+)\t(.+)$'
          if st and f then review_state[f] = st end
        end
      end
      local function save_state()
        vim.fn.mkdir(vim.fn.fnamemodify(STATE, ':h'), 'p')
        local lines = {}
        for f, st in pairs(review_state) do lines[#lines + 1] = st .. '\t' .. f end
        pcall(vim.fn.writefile, lines, STATE)
      end
      load_state()

      -- ---- review-set navigation (nvim arglist == the review set) ----
      -- mark the current doc, then advance. status='reviewed' (looked, fine/commented)
      -- or 'skipped' (did NOT review — flagged so it's not mistaken for approved).
      local function mark_and_next(status)
        local f = vim.fn.expand '%:p'
        if f ~= '' then review_state[f] = status; save_state() end
        if vim.bo.modifiable and vim.bo.modified then vim.cmd 'update' end
        if vim.fn.argidx() + 1 >= vim.fn.argc() then
          vim.notify('md-review: last doc (' .. status .. ') — <leader>ms to submit', vim.log.levels.INFO)
        else
          vim.cmd 'next'
        end
      end
      -- approve: stamp reviewed_at frontmatter (via `pk review`), then advance.
      -- mdr is the review UI; pk stores the durable trail + logs it to status.md.
      local function approve_and_next()
        local f = vim.fn.expand '%:p'
        if f == '' then return end
        if vim.bo.modifiable and vim.bo.modified then vim.cmd 'update' end -- save comments first
        local by = os.getenv 'MDR_SESSION' or 'me'
        local out = vim.fn.system { 'pk', 'review', f, '-b', by }
        if vim.v.shell_error ~= 0 then
          vim.notify('md-review: pk review failed — ' .. out, vim.log.levels.ERROR)
          return
        end
        vim.cmd 'edit' -- reload buffer to show the stamped frontmatter
        review_state[f] = 'reviewed'; save_state()
        if vim.fn.argidx() + 1 >= vim.fn.argc() then
          vim.notify('md-review: approved (last) — <leader>ms to submit', vim.log.levels.INFO)
        else
          vim.cmd 'next'
        end
      end
      local function save_prev()
        if vim.bo.modifiable and vim.bo.modified then vim.cmd 'update' end
        if vim.fn.argidx() <= 0 then
          vim.notify('md-review: first doc', vim.log.levels.INFO)
        else
          vim.cmd 'previous'
        end
      end
      local function submit()
        vim.cmd 'wall' -- write every changed buffer
        vim.cmd 'quitall' -- quit → the mdr wrapper fires one /md-review on the changed docs
      end

      -- does a file (loaded buffer preferred, else on disk) carry a 💬 comment?
      local function has_comment(file)
        local bufnr = vim.fn.bufnr(file)
        local lines
        if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
          lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        else
          local ok, content = pcall(vim.fn.readfile, file)
          lines = ok and content or {}
        end
        for _, l in ipairs(lines) do
          if l:find('💬', 1, true) then return true end
        end
        return false
      end

      -- ---- review navigator: floating list of the whole set (✓ commented / ○ left / ● current) ----
      local function review_list()
        local args = vim.fn.argv()
        if type(args) == 'string' then args = { args } end
        if #args == 0 then
          vim.notify('md-review: no review set open', vim.log.levels.WARN)
          return
        end
        local cur = vim.fn.argidx() -- 0-based
        -- glyphs:  ● current · 💬 commented · ✓ reviewed-clean · ⊘ not reviewed · ○ untouched
        local lines, n = {}, { comment = 0, reviewed = 0, skipped = 0, left = 0 }
        for i, f in ipairs(args) do
          local mark
          if has_comment(f) then mark = '💬'; n.comment = n.comment + 1
          elseif review_state[f] == 'reviewed' then mark = '✓'; n.reviewed = n.reviewed + 1
          elseif review_state[f] == 'skipped' then mark = '⊘'; n.skipped = n.skipped + 1
          else mark = '○'; n.left = n.left + 1 end
          if i - 1 == cur then mark = '●' end
          lines[i] = string.format(' %s %2d  %s', mark, i, vim.fn.fnamemodify(f, ':~:.'))
        end
        local title = string.format(' 💬%d  ✓%d  ⊘%d  ○%d  (of %d) ',
          n.comment, n.reviewed, n.skipped, n.left, #args)
        local width = #title
        for _, l in ipairs(lines) do width = math.max(width, #l) end
        width = width + 2
        local height = math.min(#lines, 20)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        local win = vim.api.nvim_open_win(buf, true, {
          relative = 'editor', width = width, height = height,
          row = math.floor((vim.o.lines - height) / 2 - 1),
          col = math.floor((vim.o.columns - width) / 2),
          style = 'minimal', border = 'rounded', title = title, title_pos = 'center',
        })
        vim.api.nvim_win_set_cursor(win, { cur + 1, 0 })
        local o = { buffer = buf, nowait = true, silent = true }
        vim.keymap.set('n', '<CR>', function()
          local idx = vim.api.nvim_win_get_cursor(win)[1]
          vim.api.nvim_win_close(win, true)
          if vim.bo.modifiable and vim.bo.modified then vim.cmd 'update' end
          vim.cmd('argument ' .. idx)
        end, o)
        vim.keymap.set('n', 'q', function() vim.api.nvim_win_close(win, true) end, o)
        vim.keymap.set('n', '<Esc>', function() vim.api.nvim_win_close(win, true) end, o)
      end

      -- winbar progress (global fn so the winbar %{} can call it)
      function _G.MdReview_pos()
        return string.format('%d/%d', vim.fn.argidx() + 1, vim.fn.argc())
      end

      vim.api.nvim_create_autocmd('FileType', {
        pattern = 'markdown',
        callback = function(ev)
          highlight()
          show_review_context(ev.buf)
          local o = function(desc) return { buffer = ev.buf, desc = desc } end
          vim.keymap.set('n', '<leader>mc', function() drop {} end, o 'md: inline comment')
          vim.keymap.set('n', '<leader>mC', function() drop { doc = true } end, o 'md: whole-doc comment')
          vim.keymap.set('n', '<leader>mv', function() drop { voice = true } end, o 'md: inline comment + voice')
          vim.keymap.set('n', '<leader>mV', function() drop { doc = true, voice = true } end, o 'md: whole-doc comment + voice')
          vim.keymap.set('n', '<leader>ma', approve_and_next, o 'md: approve (stamp reviewed_at) + next')
          vim.keymap.set('n', '<leader>mn', function() mark_and_next 'reviewed' end, o 'md: mark reviewed + next')
          vim.keymap.set('n', '<leader>mk', function() mark_and_next 'skipped' end, o 'md: mark NOT reviewed (skip) + next')
          vim.keymap.set('n', '<leader>mp', save_prev, o 'md: prev doc')
          vim.keymap.set('n', '<leader>ml', review_list, o 'md: review navigator')
          vim.keymap.set('n', '<leader>ms', submit, o 'md: submit all (/md-review)')
          -- winbar menu, only when a review SET is open (batch)
          if vim.fn.argc() > 1 then
            vim.wo.winbar = '%#MdReviewBar# review %{v:lua.MdReview_pos()} '
              .. ' [ma]approve [mn]next·ok [mk]skip [mp]prev [ml]list  [mc]note [mv]voice  [ms]submit '
          end
        end,
      })

      pcall(function()
        require('which-key').add { { '<leader>m', group = '[M]arkdown review', mode = 'n' } }
      end)
    end,
  },
}
