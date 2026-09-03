-- Hebrew calendar conversion, ported from Emacs calendar-hebrew.el
-- (Reingold & Dershowitz algorithm). Pure Lua, no external dependencies.
--
-- Hebrew months are numbered 1..13 with Tishri = 7:
--   1 Nisan, 2 Iyar, 3 Sivan, 4 Tammuz, 5 Av, 6 Elul,
--   7 Tishri, 8 Cheshvan, 9 Kislev, 10 Tevet, 11 Shevat,
--   12 Adar (I), 13 Adar II (only exists in leap years)
local M = {}

local HEBREW_EPOCH = -1373428

---@param year integer
---@return boolean
function M.is_leap_year(year)
  return (year * 7 + 1) % 19 < 7
end

---@param year integer
---@return integer 12 or 13
function M.months_in_year(year)
  return M.is_leap_year(year) and 13 or 12
end

---Days to the mean conjunction of Tishri of Hebrew YEAR, measured from the
---(imaginary) Gregorian Sunday, December 31, 1 BC (i.e. RD of Rosh Hashanah
---of Hebrew year 1 is elapsed_days(1) + 1). Includes the dehiyyot
---(postponement) rules. Ported from Emacs calendar-hebrew.el.
---@param year integer
---@return integer
function M.elapsed_days(year)
  local y = year - 1
  local months_elapsed = 235 * math.floor(y / 19) + 12 * (y % 19) + math.floor((1 + 7 * (y % 19)) / 19)
  local parts_elapsed = 204 + 793 * (months_elapsed % 1080)
  local hours = 5 + 12 * months_elapsed + 793 * math.floor(months_elapsed / 1080) + math.floor(parts_elapsed / 1080)
  local parts = 1080 * (hours % 24) + parts_elapsed % 1080
  local day = 1 + 29 * months_elapsed + math.floor(hours / 24)

  local alternative
  if parts >= 19440 then
    -- Molad at or after midday: postpone by one day
    alternative = day + 1
  elseif day % 7 == 2 and parts >= 9924 and not M.is_leap_year(year) then
    -- GaTRaD: Tuesday at 9h 204p or later in a common year
    alternative = day + 1
  elseif day % 7 == 1 and parts >= 16789 and M.is_leap_year(year - 1) then
    -- BeTUTaKaPaT: Monday at 15h 589p or later after a leap year
    alternative = day + 1
  else
    alternative = day
  end

  -- Lo ADU Rosh: Rosh Hashanah cannot fall on Sunday, Wednesday or Friday
  local dow = alternative % 7
  if dow == 0 or dow == 3 or dow == 5 then
    alternative = alternative + 1
  end
  return alternative
end

---@param year integer
---@return integer
function M.days_in_year(year)
  return M.elapsed_days(year + 1) - M.elapsed_days(year)
end

---@param month integer
---@param year integer
---@return integer
function M.days_in_month(month, year)
  if month == 2 or month == 4 or month == 6 or month == 10 or month == 13 then
    return 29
  end
  if month == 12 then
    return M.is_leap_year(year) and 30 or 29
  end
  if month == 8 then
    -- Cheshvan has 30 days only in a "complete" year
    return M.days_in_year(year) % 10 == 5 and 30 or 29
  end
  if month == 9 then
    -- Kislev has 29 days only in a "deficient" year
    return M.days_in_year(year) % 10 == 3 and 29 or 30
  end
  return 30
end

---RD (Rata Die) of the Hebrew date: days since 0001-01-01 (proleptic
---Gregorian, RD 1 = January 1, 1 CE).
---@param year integer
---@param month integer
---@param day integer
---@return integer
function M.to_absolute(year, month, day)
  local abs = day - 1
  if month < 7 then
    -- Days in prior months this year after Nisan, then before Nisan
    for m = 7, M.months_in_year(year) do
      abs = abs + M.days_in_month(m, year)
    end
    for m = 1, month - 1 do
      abs = abs + M.days_in_month(m, year)
    end
  else
    for m = 7, month - 1 do
      abs = abs + M.days_in_month(m, year)
    end
  end
  return abs + M.elapsed_days(year) + HEBREW_EPOCH
end

---@param y integer
---@param m integer
---@param d integer
---@return boolean
local function gregorian_leap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local gregorian_cum = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 }

---RD of the Gregorian date.
---@param year integer
---@param month integer
---@param day integer
---@return integer
local function gregorian_to_absolute(year, month, day)
  local rd = 365 * (year - 1)
    + math.floor((year - 1) / 4)
    - math.floor((year - 1) / 100)
    + math.floor((year - 1) / 400)
    + gregorian_cum[month]
    + day
  if month > 2 and gregorian_leap(year) then
    rd = rd + 1
  end
  return rd
end

---Hebrew year for an RD, found by search around an estimate.
---@param rd integer
---@return integer
local function hebrew_year_of_rd(rd)
  local year = math.floor((rd - HEBREW_EPOCH) / 365.2468) + 1
  while M.to_absolute(year + 1, 7, 1) <= rd do
    year = year + 1
  end
  while M.to_absolute(year, 7, 1) > rd do
    year = year - 1
  end
  return year
end

---@param year integer
---@param month integer
---@param day integer
---@return { year: integer, month: integer, day: integer }
function M.from_absolute(year, day)
  -- Month sequence starting from Tishri: 7..last, 1..6
  local sequence = {}
  local last = M.months_in_year(year)
  for m = 7, last do
    sequence[#sequence + 1] = m
  end
  for m = 1, 6 do
    sequence[#sequence + 1] = m
  end

  local rh = M.to_absolute(year, 7, 1)
  local offset = day - rh -- 0-based day within the Hebrew year
  for _, m in ipairs(sequence) do
    local dim = M.days_in_month(m, year)
    if offset < dim then
      return { year = year, month = m, day = offset + 1 }
    end
    offset = offset - dim
  end
  -- Should be unreachable
  return { year = year, month = month, day = day }
end

---@param year integer Gregorian year
---@param month integer 1-12
---@param day integer
---@return { year: integer, month: integer, day: integer }
function M.from_gregorian(year, month, day)
  local rd = gregorian_to_absolute(year, month, day)
  local hyear = hebrew_year_of_rd(rd)
  return M.from_absolute(hyear, rd)
end

---@param hyear integer
---@param hmonth integer
---@param hday integer
---@return { year: integer, month: integer, day: integer }
function M.to_gregorian(hyear, hmonth, hday)
  local rd = M.to_absolute(hyear, hmonth, hday)
  -- Invert RD to Gregorian by search around an estimate
  local year = math.floor(rd / 365.2425) + 1
  while gregorian_to_absolute(year + 1, 1, 1) <= rd do
    year = year + 1
  end
  while gregorian_to_absolute(year, 1, 1) > rd do
    year = year - 1
  end
  local cum = gregorian_cum[12] + (gregorian_leap(year) and 1 or 0)
  local doy = rd - gregorian_to_absolute(year, 1, 1) -- 0-based day of year
  local month = 1
  for m = 12, 1, -1 do
    local before = gregorian_cum[m] + ((m >= 3 and gregorian_leap(year)) and 1 or 0)
    if doy >= before then
      month = m
      doy = doy - before
      break
    end
  end
  return { year = year, month = month, day = doy + 1 }
end

M.MONTH_NAMES = {
  nisan = 1,
  niisan = 1,
  iyar = 2,
  iyyar = 2,
  sivan = 3,
  tammuz = 4,
  tamuz = 4,
  av = 5,
  elul = 6,
  tishri = 7,
  tishrei = 7,
  tishre = 7,
  cheshvan = 8,
  heshvan = 8,
  chesvan = 8,
  kislev = 9,
  chislev = 9,
  tevet = 10,
  teves = 10,
  teis = 10,
  shevat = 11,
  shvat = 11,
  adar = 12,
  ['adar i'] = 12,
  adar1 = 12,
  ['adar ii'] = 13,
  adar2 = 13,
}

---@param name string
---@return integer|nil
function M.month_from_name(name)
  return M.MONTH_NAMES[tostring(name):lower():gsub('%s+', '')]
end

---English month/day names for a Hebrew date.
---@param hyear integer
---@param hmonth integer
---@return string
function M.month_name(hyear, hmonth)
  local names = {
    [1] = 'Nisan',
    [2] = 'Iyar',
    [3] = 'Sivan',
    [4] = 'Tammuz',
    [5] = 'Av',
    [6] = 'Elul',
    [7] = 'Tishri',
    [8] = 'Cheshvan',
    [9] = 'Kislev',
    [10] = 'Tevet',
    [11] = 'Shevat',
    [12] = M.is_leap_year(hyear) and 'Adar I' or 'Adar',
    [13] = 'Adar II',
  }
  return names[hmonth] or tostring(hmonth)
end

---Resolve the Hebrew month/day that a birthday/yahrzeit set on Hebrew
---month `month`, day `day` falls on in Hebrew year `hyear`:
--- - Adar (12) in a leap year is observed as Adar II (13)
--- - a day that doesn't exist in that year (e.g. Kislev 30 in a year
---   where Kislev has 29) is observed on the 1st of the following month
---@param hyear integer
---@param hmonth integer
---@param hday integer
---@return integer month
---@return integer day
function M.resolve_anniversary(hyear, hmonth, hday)
  local month = hmonth
  if hmonth == 12 and M.is_leap_year(hyear) then
    month = 13
  elseif hmonth == 13 and not M.is_leap_year(hyear) then
    month = 12
  end
  local day = hday
  if day > M.days_in_month(month, hyear) then
    day = 1
    month = month + 1
    if month > M.months_in_year(hyear) then
      -- Wrapped past Adar into Nisan of the next year
      month = 1
      hyear = hyear + 1
    end
  end
  return month, day
end

---Gregorian (y, m, d) of the Nth anniversary of a Hebrew date.
---N is ignored here (the caller computes the age); this returns the
---Gregorian date of the anniversary in the Hebrew year containing the
---Hebrew anniversary after `hyear` of the original event.
---@param hyear integer
---@param hmonth integer
---@param hday integer
---@param gregorian_year integer The Gregorian year to find the anniversary in
---@return { year: integer, month: integer, day: integer }|nil
function M.anniversary_in_gregorian_year(hyear, hmonth, hday, gregorian_year)
  -- The Hebrew year that overlaps the bulk of gregorian_year
  local probe = M.from_gregorian(gregorian_year, 6, 1)
  for _, hyear_candidate in ipairs({ probe.year - 1, probe.year, probe.year + 1 }) do
    local month, day = M.resolve_anniversary(hyear_candidate, hmonth, hday)
    local rd = M.to_absolute(hyear_candidate, month, day)
    local g = M.to_gregorian(hyear_candidate, month, day)
    if g.year == gregorian_year then
      return g
    end
  end
  return nil
end

return M
