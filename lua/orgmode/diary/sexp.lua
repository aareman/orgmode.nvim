-- Diary sexp evaluator: a small, self-contained S-expression interpreter
-- specialized for diary-style date predicates (Emacs diary-sexp compatible
-- subset) plus a %%(...lua "chunk") escape for Lua expressions.
---@class OrgDiarySexp
---@field _eval fun(self: OrgDiarySexp, date: OrgDate): boolean
---@field _expr string
local OrgDiarySexp = {}
OrgDiarySexp.__index = OrgDiarySexp

---@param fn fun(date: OrgDate): boolean
---@param raw_expr? string
---@return OrgDiarySexp
function OrgDiarySexp:new(fn, raw_expr)
  return setmetatable({ _eval = fn, _expr = raw_expr or '' }, self)
end

---@param date OrgDate
---@return boolean
function OrgDiarySexp:matches(date)
  local ok, res = pcall(self._eval, date)
  if not ok then
    return false
  end
  return res and true or false
end

--------------------------------------------------------------------------------
-- Tokenizer / parser
--------------------------------------------------------------------------------

---@param input string
---@return string[]
local function tokenize(input)
  local tokens = {}
  local i = 1
  local len = #input
  while i <= len do
    local ch = input:sub(i, i)
    if ch == '(' or ch == ')' or ch == "'" then
      table.insert(tokens, ch)
      i = i + 1
    elseif ch == '"' then
      local j = i + 1
      while j <= len do
        local cj = input:sub(j, j)
        if cj == '\\' then
          j = j + 2
        elseif cj == '"' then
          break
        else
          j = j + 1
        end
      end
      table.insert(tokens, input:sub(i, math.min(j, len)))
      i = j + 1
    elseif ch:match('%s') then
      i = i + 1
    else
      local j = i
      while j <= len do
        local cj = input:sub(j, j)
        if cj:match('%s') or cj == '(' or cj == ')' or cj == "'" or cj == '"' then
          break
        end
        j = j + 1
      end
      table.insert(tokens, input:sub(i, j - 1))
      i = j
    end
  end
  return tokens
end

---@param tokens string[]
---@param idx integer
---@return any, integer
local function parse_expr(tokens, idx)
  local tok = tokens[idx]
  if not tok then
    return nil, idx
  end
  if tok == "'" then
    local node
    node, idx = parse_expr(tokens, idx + 1)
    if not node then
      return nil, idx
    end
    return { 'quote', node }, idx
  end
  if tok == '(' then
    local list = {}
    idx = idx + 1
    while tokens[idx] ~= ')' do
      local node
      node, idx = parse_expr(tokens, idx)
      if node == nil then
        return nil, idx
      end
      table.insert(list, node)
      if not tokens[idx] then
        return nil, idx
      end
    end
    return list, idx + 1
  elseif tok == ')' then
    return nil, idx + 1
  else
    if tok:sub(1, 1) == '"' and #tok >= 2 and tok:sub(-1) == '"' then
      local inner = tok:sub(2, -2):gsub('\\(.)', '%1')
      return { 'string', inner }, idx + 1
    end
    local lower = tok:lower()
    if lower == 't' then
      return true, idx + 1
    end
    if lower == 'nil' then
      return false, idx + 1
    end
    local num = tonumber(tok)
    if num ~= nil then
      return num, idx + 1
    end
    return lower, idx + 1
  end
end

---@param sexp string
---@return any
local function parse_ast(sexp)
  local tokens = tokenize(sexp)
  local expr, next_idx = parse_expr(tokens, 1)
  if not expr or next_idx <= 1 or tokens[next_idx] then
    return nil
  end
  return expr
end

--------------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------------

local dayname_to_dow = {
  sun = 0,
  sunday = 0,
  mon = 1,
  monday = 1,
  tue = 2,
  tues = 2,
  tuesday = 2,
  wed = 3,
  wednesday = 3,
  thu = 4,
  thur = 4,
  thurs = 4,
  thursday = 4,
  fri = 5,
  friday = 5,
  sat = 6,
  saturday = 6,
}

---@param date OrgDate
---@return table<string, number>
local function build_variables(date)
  local dow = (date:get_weekday() - 1) % 7 -- 0..6, 0 = Sunday (Emacs convention)
  return {
    year = date.year,
    month = date.month,
    day = date.day,
    dow = dow,
    isoweekday = date:get_isoweekday(), -- 1..7, 1 = Monday
  }
end

---@param v any
---@param vars table<string, any>
---@return any
local function resolve(v, vars)
  if type(v) == 'string' then
    if vars[v] ~= nil then
      return vars[v]
    end
    if v == 't' then
      return true
    end
    if v == 'nil' then
      return false
    end
    local d = dayname_to_dow[v]
    if d ~= nil then
      return d
    end
  end
  return v
end

---Warn once per expression string so typos surface instead of silently
---never matching.
---@param expr string
---@param msg string
local warned = {}
local function warn_once(expr, msg)
  if warned[expr] then
    return
  end
  warned[expr] = true
  vim.schedule(function()
    vim.notify(('orgmode diary sexp: %s (expr: %s)'):format(msg, expr), vim.log.levels.WARN)
  end)
end

-- Chunk cache: expr -> function | false (invalid)
local lua_chunks = {}

---@param ast any
---@param date OrgDate
---@param raw_expr string
---@return any
local function eval(ast, date, raw_expr)
  if type(ast) ~= 'table' then
    return resolve(ast, build_variables(date))
  end
  if ast[1] == 'string' then
    return ast[2]
  end
  if #ast == 0 then
    return false
  end
  local op = ast[1]
  local args = {}
  for i = 2, #ast do
    args[#args + 1] = ast[i]
  end
  local function eval_arg(a)
    return eval(a, date, raw_expr)
  end

  if op == 'and' then
    for _, a in ipairs(args) do
      if not eval_arg(a) then
        return false
      end
    end
    return true
  end
  if op == 'or' then
    for _, a in ipairs(args) do
      if eval_arg(a) then
        return true
      end
    end
    return false
  end
  if op == 'not' then
    return not eval_arg(args[1])
  end
  if op == '=' then
    if #args < 2 then
      return false
    end
    local first = eval_arg(args[1])
    for i = 2, #args do
      if eval_arg(args[i]) ~= first then
        return false
      end
    end
    return true
  end
  if op == '<' or op == '>' or op == '<=' or op == '>=' then
    if #args ~= 2 then
      return false
    end
    local a = eval_arg(args[1])
    local b = eval_arg(args[2])
    if type(a) ~= 'number' or type(b) ~= 'number' then
      warn_once(raw_expr, ('non-numeric argument to %s'):format(op))
      return false
    end
    if op == '<' then
      return a < b
    elseif op == '>' then
      return a > b
    elseif op == '<=' then
      return a <= b
    else
      return a >= b
    end
  end
  if op == '+' or op == '-' or op == '*' or op == '/' then
    local acc = eval_arg(args[1])
    if type(acc) ~= 'number' then
      warn_once(raw_expr, ('non-numeric argument to %s'):format(op))
      return 0
    end
    for i = 2, #args do
      local n = eval_arg(args[i])
      if type(n) ~= 'number' then
        warn_once(raw_expr, ('non-numeric argument to %s'):format(op))
        return 0
      end
      if op == '+' then
        acc = acc + n
      elseif op == '-' then
        acc = acc - n
      elseif op == '*' then
        acc = acc * n
      else
        acc = acc / n
      end
    end
    return acc
  end
  if op == 'mod' or op == '%' then
    if #args ~= 2 then
      return 0
    end
    local a = tonumber(eval_arg(args[1])) or 0
    local b = tonumber(eval_arg(args[2])) or 1
    if b == 0 then
      return 0
    end
    return a % b
  end
  if op == 'min' or op == 'max' then
    local best = nil
    for _, a in ipairs(args) do
      local n = tonumber(eval_arg(a))
      if n ~= nil and (best == nil or (op == 'min' and n < best) or (op == 'max' and n > best)) then
        best = n
      end
    end
    return best or 0
  end

  if op == 'diary-date' then
    -- (diary-date month day [year]); args may be t (any)
    local month, day, year = eval_arg(args[1]), eval_arg(args[2]), args[3] and eval_arg(args[3]) or nil
    if month ~= true and date.month ~= month then
      return false
    end
    if day ~= true and date.day ~= day then
      return false
    end
    if year ~= nil and year ~= true and date.year ~= year then
      return false
    end
    return true
  end

  if op == 'org-anniversary' then
    -- (org-anniversary year month day)
    local year = tonumber(eval_arg(args[1]))
    local month = tonumber(eval_arg(args[2]))
    local day = tonumber(eval_arg(args[3]))
    if not year or not month or not day then
      warn_once(raw_expr, 'org-anniversary expects (year month day)')
      return false
    end
    if date.month == month and date.day == day then
      if month == 2 and day == 29 and not (date.year % 4 == 0 and (date.year % 100 ~= 0 or date.year % 400 == 0)) then
        -- Feb 29 anniversary: match Mar 1 in non-leap years (Emacs behavior)
        return date.month == 3 and date.day == 1 or (date.month == 2 and date.day == 29)
      end
      return true
    end
    -- Feb 29 anniversary falls back to Mar 1 in non-leap years
    if month == 2 and day == 29 and date.month == 3 and date.day == 1 then
      local y = date.year
      return not (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0))
    end
    return false
  end

  if op == 'diary-anniversary' then
    -- (diary-anniversary month day year) in American style, or
    -- (diary-anniversary year month day). Disambiguated by a number >= 1000.
    local a1 = tonumber(eval_arg(args[1]))
    local a2 = tonumber(eval_arg(args[2]))
    local a3 = tonumber(eval_arg(args[3]))
    if not a1 or not a2 or not a3 then
      warn_once(raw_expr, 'diary-anniversary expects (month day year) or (year month day)')
      return false
    end
    local year, month, day
    if a1 >= 1000 then
      year, month, day = a1, a2, a3
    else
      month, day, year = a1, a2, a3
    end
    if date.month == month and date.day == day then
      return true
    end
    if month == 2 and day == 29 and date.month == 3 and date.day == 1 then
      local y = date.year
      return not (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0))
    end
    return false
  end

  if op == 'diary-float' then
    -- (diary-float month dayname nth); month/dayname may be t
    local month = eval_arg(args[1])
    local dow = eval_arg(args[2])
    local nth = eval_arg(args[3])
    if month ~= true and date.month ~= month then
      return false
    end
    local date_dow = (date:get_weekday() - 1) % 7 -- 0..6, 0 = Sunday
    if dow ~= true and date_dow ~= dow then
      return false
    end
    if nth == true then
      return true
    end
    local first_of_month = date:set({ day = 1 })
    local first_dow = (first_of_month:get_weekday() - 1) % 7
    local first_target
    if first_dow <= date_dow then
      first_target = 1 + (date_dow - first_dow)
    else
      first_target = 1 + (7 - (first_dow - date_dow))
    end
    if nth >= 0 then
      -- nth is 1-based in Emacs; treat 0 as the first occurrence
      local candidate = first_target + math.max(nth - 1, 0) * 7
      return date.day == candidate
    end
    -- Negative nth: count from end of month
    local last_day = date:last_day_of_month().day
    local last_target = first_target
    while last_target + 7 <= last_day do
      last_target = last_target + 7
    end
    local candidate = last_target + (nth + 1) * 7
    if candidate < 1 then
      return false
    end
    return date.day == candidate
  end

  if op == 'diary-cyclic' then
    -- (diary-cyclic n month day): every n days starting from month/day
    local n = tonumber(eval_arg(args[1]))
    local month = tonumber(eval_arg(args[2]))
    local day = tonumber(eval_arg(args[3]))
    if not n or n <= 0 or not month or not day then
      warn_once(raw_expr, 'diary-cyclic expects (n month day)')
      return false
    end
    local function diff_from(y)
      local base = date:set({ year = y, month = month, day = day })
      local d = date:diff(base, 'day')
      return d
    end
    -- Check this year and the previous year so spans across Jan 1 work
    local d = diff_from(date.year)
    if d >= 0 and d % n == 0 then
      return true
    end
    d = diff_from(date.year - 1)
    return d >= 0 and d % n == 0
  end

  if op == 'diary-remind' then
    -- (diary-remind '(inner) days): fires on each of the N days before the
    -- event (and on the event day). Brute-force over the window is correct
    -- for arbitrary inner predicates.
    local inner = args[1]
    if type(inner) == 'table' and inner[1] == 'quote' then
      inner = inner[2]
    end
    if type(inner) ~= 'table' then
      warn_once(raw_expr, 'diary-remind expects a quoted inner expression')
      return false
    end
    local days = tonumber(eval_arg(args[2]))
    if not days or days < 0 then
      warn_once(raw_expr, 'diary-remind expects a non-negative number of days')
      return false
    end
    for k = 0, days do
      local d = date:add({ day = k })
      if eval(inner, d, raw_expr) then
        return true
      end
    end
    return false
  end

  if op == 'org-hebrew-anniversary' or op == 'diary-hebrew-anniversary' or op == 'hebrew-birthday' then
    -- (org-hebrew-anniversary year month day) / (diary-hebrew-anniversary month day year)
    -- Month may be a number or a name (e.g. Elul, Teves, Adar II).
    -- Matches the Gregorian date whose Hebrew date is the anniversary.
    -- Adar in a leap year is observed as Adar II; a day that doesn't
    -- exist in the observation year (e.g. Kislev 30) is observed on the
    -- 1st of the following month.
    local Hebrew = require('orgmode.diary.hebrew')
    local a1, a2, a3 = eval_arg(args[1]), eval_arg(args[2]), eval_arg(args[3])
    local hyear, hmonth, hday
    if op == 'org-hebrew-anniversary' then
      hyear, hmonth, hday = tonumber(a1), a2, tonumber(a3)
    else
      hmonth, hday, hyear = a1, tonumber(a2), tonumber(a3)
    end
    if type(hmonth) == 'string' then
      local resolved = Hebrew.month_from_name(hmonth)
      if not resolved then
        warn_once(raw_expr, ('unknown Hebrew month name: %s'):format(hmonth))
        return false
      end
      hmonth = resolved
    end
    hmonth = tonumber(hmonth)
    if not hyear or not hmonth or not hday then
      warn_once(raw_expr, 'hebrew anniversary expects (year month day) with a valid Hebrew month')
      return false
    end
    local hebrew_date = Hebrew.from_gregorian(date.year, date.month, date.day)
    local month, day = Hebrew.resolve_anniversary(hebrew_date.year, hmonth, hday)
    return hebrew_date.month == month and hebrew_date.day == day
  end

  if op == 'lua' then
    -- (lua "expr"): evaluated with year, month, day, dow, isoweekday and
    -- the OrgDate `date` in scope. Wrapped in a parameterized function so
    -- globals are never touched and the chunk is compiled exactly once.
    local chunk_src = eval_arg(args[1])
    if type(chunk_src) ~= 'string' then
      warn_once(raw_expr, 'lua operator expects a string expression')
      return false
    end
    local chunk = lua_chunks[chunk_src]
    if chunk == nil then
      local fn, err = load(
        ('return function(year, month, day, dow, isoweekday, date) return (%s) end'):format(chunk_src),
        '=diary-sexp'
      )
      if not fn then
        warn_once(raw_expr, ('invalid lua chunk: %s'):format(err))
        lua_chunks[chunk_src] = false
        return false
      end
      local ok, wrapped = pcall(fn)
      if not ok or type(wrapped) ~= 'function' then
        warn_once(raw_expr, 'invalid lua chunk')
        lua_chunks[chunk_src] = false
        return false
      end
      chunk = wrapped
      lua_chunks[chunk_src] = chunk
    end
    if chunk == false then
      return false
    end
    local vars = build_variables(date)
    local ok, res = pcall(chunk, vars.year, vars.month, vars.day, vars.dow, vars.isoweekday, date)
    if not ok then
      warn_once(raw_expr, ('lua chunk error: %s'):format(res))
      return false
    end
    return res and true or false
  end

  warn_once(raw_expr, ('unknown diary sexp operator: %s'):format(tostring(op)))
  return false
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local parse_cache = {}

---@param expr string
---@return OrgDiarySexp|nil
local function compile(expr)
  local ok, ast = pcall(parse_ast, expr)
  if not ok or not ast then
    return nil
  end
  return OrgDiarySexp:new(function(date)
    return eval(ast, date, expr) and true or false
  end, expr)
end

---@param expr string
---@return OrgDiarySexp|nil
local function compile_cached(expr)
  local cached = parse_cache[expr]
  if cached ~= nil then
    return cached or nil
  end
  local matcher = compile(expr)
  parse_cache[expr] = matcher or false
  return matcher
end

local M = {}

---Parse a diary sexp expression (without the leading %%() into a matcher.
---A bare day name (e.g. "mon") is also accepted as a shorthand.
---@param expr string
---@return OrgDiarySexp|nil
function M.parse(expr)
  if type(expr) ~= 'string' then
    return nil
  end
  local trimmed = vim.trim(expr)
  if trimmed == '' then
    return nil
  end
  if not trimmed:match('^%(') then
    local dn = dayname_to_dow[trimmed:lower()]
    if dn == nil then
      trimmed = '(' .. trimmed .. ')'
    else
      -- Day name shorthand (e.g. "fri") matches that weekday every week
      local cached = parse_cache[trimmed:lower()]
      if cached ~= nil then
        return cached or nil
      end
      local matcher = OrgDiarySexp:new(function(date)
        return build_variables(date).dow == dn
      end, trimmed:lower())
      parse_cache[trimmed:lower()] = matcher
      return matcher
    end
  end
  return compile_cached(trimmed)
end

M._reset_caches = function()
  parse_cache = {}
  lua_chunks = {}
  warned = {}
end

M._dayname_to_dow = dayname_to_dow

return M
