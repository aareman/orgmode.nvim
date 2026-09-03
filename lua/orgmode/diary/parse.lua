-- Shared extraction of diary sexp entries from raw org text.
-- Supported forms:
--   <%%(sexp) [HH:MM]>   active diary entry with optional time of day
--   [%%(sexp)]           inactive diary entry
--   %%(sexp) text        file-level diary entry (Emacs diary style)
local M = {}

---Parse an optional HH:MM time after a sexp expression, up to an optional
---closing bracket character.
---@param tail string Text after the closing paren of the sexp
---@param close_char string|nil Expected closing char ('>' / ']' or nil for file-level)
---@return string|nil time
---@return string remainder Text after the time/closing char
local function extract_time(tail, close_char)
  local time = nil
  local remainder = tail

  local h, m = tail:match('^%s+(%d%d?):(%d%d)')
  if h and m then
    if tonumber(h) > 23 or tonumber(m) > 59 then
      return nil, remainder
    end
    time = ('%02d:%02d'):format(tonumber(h), tonumber(m))
    local pos = tail:match('^%s+%d%d?:%d%d()')
    remainder = pos and tail:sub(pos) or tail
  end

  if close_char then
    -- Wrapped entries are single-line: don't leak text across newlines
    local nl = remainder:find('\n', 1, true)
    if nl then
      remainder = remainder:sub(1, nl - 1)
    end
    local idx = remainder:find(close_char, 1, true)
    if idx then
      remainder = remainder:sub(idx + 1)
    else
      -- Unterminated entry; treat everything as remainder
      return time, ''
    end
  end

  return time, remainder
end

---Find all diary sexp entries in a chunk of text.
---@param text string Raw text to scan
---@param base_line integer 1-based line number of the first line of `text`
---@param base_col integer 0-based column offset of `text` start within its line (usually 0)
---@param opts? { file_level_only?: boolean, wrapped_only?: boolean, active_only?: boolean }
---@return { expr: string, time: string|nil, text: string, active: boolean, line: integer, range: OrgRange }[]
function M.find_sexps(text, base_line, base_col, opts)
  opts = opts or {}
  local results = {}
  local search_from = 1
  while true do
    local start_idx = text:find('%%(', search_from, true)
    if not start_idx then
      break
    end
    local prev = start_idx > 1 and text:sub(start_idx - 1, start_idx - 1) or ''
    local open_char = (prev == '<' or prev == '[') and prev or nil

    if (opts.file_level_only and open_char) or (opts.wrapped_only and not open_char) then
      search_from = start_idx + 3
    else
      local expr_start = start_idx + 3 -- after "%%("
      local depth = 1
      local j = expr_start
      local close_idx = nil
      while j <= #text do
        local ch = text:sub(j, j)
        if ch == '(' then
          depth = depth + 1
        elseif ch == ')' then
          depth = depth - 1
          if depth == 0 then
            close_idx = j
            break
          end
        end
        j = j + 1
      end

      if not close_idx then
        -- Unbalanced: skip past this occurrence
        search_from = start_idx + 3
      else
        local expr = text:sub(expr_start, close_idx - 1)
        local close_char = open_char == '<' and '>' or (open_char == '[' and ']' or nil)
        local tail = text:sub(close_idx + 1)
        local time, remainder = extract_time(tail, close_char)
        local entry_text = vim.trim(remainder)
        local line = base_line
        local prefix = text:sub(1, start_idx - 1)
        -- Text is scanned per line, so newlines shouldn't occur, but
        -- count them defensively for correct line reporting.
        for nl in prefix:gmatch('\n') do
          line = line + 1
        end
        local last_nl = prefix:match('[^\n]*$')
        local col = base_col + #prefix - #last_nl

        table.insert(results, {
          expr = expr,
          time = time,
          text = entry_text,
          active = open_char == nil or open_char == '<',
          line = line,
          range = require('orgmode.files.elements.range').from_line(line),
          _col = col,
        })
        search_from = close_idx + 1
      end
    end
  end
  return results
end

return M
