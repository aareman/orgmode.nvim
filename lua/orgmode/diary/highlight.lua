-- Extmark-based highlighting for diary sexp entries in org buffers.
-- The tree-sitter grammar parses <%%(...)> as a timestamp/tsexp node, but
-- bare %%(...) lines are plain text, and predicate-based queries proved
-- unreliable across nvim versions, so we highlight with regex extmarks.
local config = require('orgmode.config')

---@class OrgDiaryHighlighter
local DiaryHighlight = {
  namespace = vim.api.nvim_create_namespace('org_diary_sexp_highlight'),
  attached = {},
}

vim.api.nvim_set_hl(0, '@org.diary.sexp', { fg = '#b16286', italic = true, default = true })
vim.api.nvim_set_hl(0, '@org.diary.time', { fg = '#b16286', bold = true, default = true })

---Highlight all diary sexp entries in a buffer.
---@param bufnr integer
local function highlight_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, DiaryHighlight.namespace, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local from = 1
    while true do
      local start_col = line:find('%%(', from, true)
      if not start_col then
        break
      end
      -- Find the balanced closing paren of the expression
      local depth = 1
      local j = start_col + 3
      local close_col = nil
      while j <= #line do
        local ch = line:sub(j, j)
        if ch == '(' then
          depth = depth + 1
        elseif ch == ')' then
          depth = depth - 1
          if depth == 0 then
            close_col = j
            break
          end
        end
        j = j + 1
      end
      if not close_col then
        break
      end
      -- 0-based extmark ranges
      vim.api.nvim_buf_set_extmark(bufnr, DiaryHighlight.namespace, i - 1, start_col - 1, {
        end_row = i - 1,
        end_col = close_col,
        hl_group = '@org.diary.sexp',
        priority = 60,
      })
      -- Optional HH:MM time after the expression
      local h, m = line:match('^%s+(%d%d?):(%d%d)', close_col + 1)
      if h and m then
        local time_start, time_end = line:find('%s+%d%d?:%d%d', close_col + 1, false)
        if time_start then
          vim.api.nvim_buf_set_extmark(bufnr, DiaryHighlight.namespace, i - 1, time_start - 1, {
            end_row = i - 1,
            end_col = time_end,
            hl_group = '@org.diary.time',
            priority = 60,
          })
        end
      end
      from = close_col + 1
    end
  end
end

---Attach the diary sexp highlighter to an org buffer (idempotent).
---@param bufnr integer
function DiaryHighlight.attach(bufnr)
  if DiaryHighlight.attached[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  DiaryHighlight.attached[bufnr] = true

  highlight_buffer(bufnr)

  local group = vim.api.nvim_create_augroup('org_diary_sexp_highlight', { clear = false })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = bufnr,
    callback = function()
      DiaryHighlight.attached[bufnr] = nil
    end,
  })

  -- on_lines catches both user edits and API-driven changes
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      if DiaryHighlight.attached[bufnr] then
        highlight_buffer(bufnr)
      end
    end,
    on_detach = function()
      DiaryHighlight.attached[bufnr] = nil
    end,
  })
end

function DiaryHighlight.setup()
  if not config.org_highlight_diary_sexp then
    return
  end
  local group = vim.api.nvim_create_augroup('org_diary_sexp_highlight_attach', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'org',
    callback = function(args)
      DiaryHighlight.attach(args.buf)
    end,
  })
  -- Attach to already-open org buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[bufnr].filetype == 'org' then
      DiaryHighlight.attach(bufnr)
    end
  end
end

return DiaryHighlight
