-- Interpolation of diary entry text, Emacs-org style:
--   %d -> years since the anniversary year (age)
--   %s -> ordinal suffix for %d ("st"/"nd"/"rd"/"th")
--   %% -> literal %
local M = {}

---@param n integer
---@return string
local function ordinal_suffix(n)
  local teen = n % 100
  if teen == 11 or teen == 12 or teen == 13 then
    return 'th'
  end
  local last = n % 10
  if last == 1 then
    return 'st'
  elseif last == 2 then
    return 'nd'
  elseif last == 3 then
    return 'rd'
  end
  return 'th'
end

---Extract the anniversary year from a sexp expression, if any.
---@param expr string
---@return integer|nil
function M.anniversary_year(expr)
  if type(expr) ~= 'string' then
    return nil
  end
  local y = expr:match('org%-anniversary%s+(%d+)%s+(%d+)%s+(%d+)')
  if y then
    return tonumber(y)
  end
  -- diary-anniversary: (m d y) or (y m d) — first number >= 1000 wins
  if expr:match('diary%-anniversary') then
    local nums = {}
    for num in expr:gmatch('(%d+)') do
      nums[#nums + 1] = tonumber(num)
    end
    if #nums >= 3 then
      if nums[1] >= 1000 then
        return nums[1]
      end
      return nums[3]
    end
  end
  return nil
end

---Interpolate %d/%s placeholders in diary entry text.
---@param text string
---@param expr string
---@param date OrgDate
---@return string
function M.interpolate(text, expr, date)
  if type(text) ~= 'string' or not text:find('%', 1, true) then
    return text
  end
  local year = M.anniversary_year(expr)
  if not year then
    return text:gsub('%%%%', '%%')
  end
  local age = date.year - year
  local out = text:gsub('%%%%', '\027')
  out = out:gsub('%%d', tostring(age))
  out = out:gsub('%%s', ordinal_suffix(age))
  out = out:gsub('\027', '%%')
  return out
end

return M
