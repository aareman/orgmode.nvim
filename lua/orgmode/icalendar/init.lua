-- iCalendar export: generates an .ics file from agenda files.
-- - SCHEDULED/DEADLINE dates (with repeaters) are expanded into concrete
--   occurrences over a configurable horizon.
-- - Diary sexp entries are expanded using the diary sexp evaluator.
-- - Every event gets a deterministic UID derived from file + headline +
--   occurrence date, so re-exports update/remove events in place on
--   subscribed clients (ICSx5, Google Calendar, etc).
local Date = require('orgmode.objects.date')
local config = require('orgmode.config')
local utils = require('orgmode.utils')

local M = {}

---@param s string
---@return string
local function escape_text(s)
  s = tostring(s or '')
  s = s:gsub('\\', '\\\\')
  s = s:gsub(';', '\\;')
  s = s:gsub(',', '\\,')
  s = s:gsub('\r?\n', '\\n')
  return s
end

---Deterministic event UID: stable across exports as long as the underlying
---org content (file, headline identity, occurrence date) is unchanged.
---@param parts string[]
---@return string
local function make_uid(parts)
  local hash = vim.fn.sha256(table.concat(parts, '\31'))
  return vim.fn.strcharpart(hash, 1, 32) .. '@nvim-orgmode'
end

---@param date OrgDate
---@return string YYYYMMDD
local function fmt_date(date)
  return ('%04d%02d%02d'):format(date.year, date.month, date.day)
end

---@param date OrgDate
---@return string
local function fmt_datetime(date)
  return ('%04d%02d%02dT%02d%02d00'):format(date.year, date.month, date.day, date.hour or 0, date.min or 0)
end

---@param title string
---@param todo string|nil
---@return string
local function event_summary(title, todo)
  -- Strip trailing tags and emphasis markup noise is left as-is; tags are
  -- rendered into CATEGORIES instead.
  title = title:gsub('%s+:[%w@#%%_:]+:%s*$', '')
  if todo and todo ~= '' then
    return todo .. ' ' .. title
  end
  return title
end

---@class IcsEvent
---@field uid string
---@field summary string
---@field date OrgDate Occurrence (with time if the entry has one)
---@field all_day boolean
---@field description string|nil
---@field categories string|nil

---@param event IcsEvent
---@param dtstamp string
---@return string[]
local function render_event(event, dtstamp)
  local lines = {
    'BEGIN:VEVENT',
    'UID:' .. event.uid,
    'DTSTAMP:' .. dtstamp,
  }
  if event.all_day then
    table.insert(lines, 'DTSTART;VALUE=DATE:' .. fmt_date(event.date))
  else
    table.insert(lines, 'DTSTART:' .. fmt_datetime(event.date))
  end
  table.insert(lines, 'SUMMARY:' .. escape_text(event.summary))
  if event.description and event.description ~= '' then
    table.insert(lines, 'DESCRIPTION:' .. escape_text(event.description))
  end
  if event.categories and event.categories ~= '' then
    table.insert(lines, 'CATEGORIES:' .. escape_text(event.categories))
  end
  table.insert(lines, 'END:VEVENT')
  return lines
end

---Expand a headline planning date into events over the horizon.
---@param events IcsEvent[]
---@param headline OrgHeadline
---@param date OrgDate
---@param from OrgDate
---@param days integer
local function expand_headline_date(events, headline, date, from, days)
  if not date.active or date:is_closed() then
    return
  end
  local todo = headline:get_todo()
  local title = headline:get_title()
  local category = headline:get_category()
  local tags = vim.tbl_map(function(t)
    return tostring(t)
  end, headline:get_tags() or {})
  local repeater = date:get_repeater()
  local summary = event_summary(title, todo)
  local description = ('Source: %s'):format(headline.file.filename)

  for i = 0, days do
    local day = from:add({ day = i })
    local occurs = false
    local event_date = date
    if repeater then
      -- Compute the occurrence that lands on this day (repeats keep time)
      event_date = date:apply_repeater_until(day)
      occurs = event_date:is_same(day, 'day')
    else
      occurs = date:is_same(day, 'day') and not date:is_before(from, 'day')
    end
    if occurs then
      table.insert(events, {
        uid = make_uid({ headline.file.filename, title, fmt_date(day), date.type }),
        summary = summary,
        date = event_date,
        all_day = date.date_only,
        description = description,
        categories = category .. (next(tags) and ',' .. table.concat(tags, ',') or ''),
      })
    end
  end
end

---Expand diary sexp entries into concrete events over the horizon.
---@param events IcsEvent[]
---@param orgfile OrgFile
---@param from OrgDate
---@param days integer
local function expand_diary_sexps(events, orgfile, from, days)
  local DiarySexp = require('orgmode.diary.sexp')
  local DiaryFormat = require('orgmode.diary.format')
  local DiaryHeadline = require('orgmode.diary.headline')

  local function expand(matcher, expr, diary_time, text, headline, title)
    for i = 0, days do
      local day = from:add({ day = i })
      if matcher:matches(day) then
        local hour, min = nil, nil
        if diary_time then
          hour, min = diary_time:match('^(%d%d):(%d%d)$')
        end
        local event_date = Date:new({
          year = day.year,
          month = day.month,
          day = day.day,
          hour = hour and tonumber(hour) or nil,
          min = min and tonumber(min) or nil,
          active = true,
          type = 'NONE',
        })
        table.insert(events, {
          uid = make_uid({ orgfile.filename, title, expr, fmt_date(day) }),
          summary = DiaryFormat.interpolate(text, expr, day),
          date = event_date,
          all_day = not diary_time,
          description = ('Source: %s'):format(orgfile.filename),
          categories = orgfile:get_category(),
          rrule = nil,
        })
      end
    end
  end

  for _, headline in ipairs(orgfile:get_opened_unfinished_headlines()) do
    for _, sexp in ipairs(headline:get_diary_sexps()) do
      if sexp.active then
        local matcher = DiarySexp.parse(sexp.expr)
        if matcher then
          expand(matcher, sexp.expr, sexp.time, headline:get_title(), headline, headline:get_title())
        end
      end
    end
  end

  for _, sexp in ipairs(orgfile:get_diary_sexps()) do
    local matcher = DiarySexp.parse(sexp.expr)
    if matcher then
      local title = sexp.text ~= '' and sexp.text or 'Diary entry'
      expand(matcher, sexp.expr, sexp.time, title, DiaryHeadline:new({ file = orgfile }), title)
    end
  end
end

---@param files OrgFiles
---@param opts? { days?: integer }
---@return string
function M.generate(files, opts)
  opts = opts or {}
  local days = opts.days or config.org_icalendar_days or 60
  local from = Date.today()
  local dtstamp = os.date('!%Y%m%dT%H%M%SZ')
  local events = {}

  if files.load_state ~= 'loaded' then
    files:load_sync(true, 20000)
  end

  for _, orgfile in ipairs(files:all()) do
    for _, headline in ipairs(orgfile:get_opened_unfinished_headlines()) do
      for _, date in ipairs(headline:get_deadline_and_scheduled_dates()) do
        expand_headline_date(events, headline, date, from, days)
      end
    end
    expand_diary_sexps(events, orgfile, from, days)
  end

  table.sort(events, function(a, b)
    return a.uid < b.uid
  end)

  local out = {
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//nvim-orgmode//icalendar export//EN',
    'CALSCALE:GREGORIAN',
  }
  for _, event in ipairs(events) do
    vim.list_extend(out, render_event(event, dtstamp))
  end
  table.insert(out, 'END:VCALENDAR')
  return (table.concat(out, '\r\n') .. '\r\n')
end

---Export the agenda files to the configured ICS file.
---@param opts? { path?: string, days?: integer }
---@return string|nil path Written path
function M.export(opts)
  opts = opts or {}
  local path = opts.path or config.org_icalendar_file
  if not path or path == '' then
    return nil
  end
  local files = require('orgmode.files'):new({
    paths = config.org_agenda_files,
  })
  files:load_sync(true, 20000)
  local content = M.generate(files, { days = opts.days })
  path = vim.fn.expand(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':p:h'), 'p')
  vim.fn.writefile(vim.split(content, '\r\n'), path, 'b')
  return path
end

return M
