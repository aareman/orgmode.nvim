local Date = require('orgmode.objects.date')
local config = require('orgmode.config')
local utils = require('orgmode.utils')
local NotificationPopup = require('orgmode.notifications.notification_popup')
local current_file_path = string.sub(debug.getinfo(1, 'S').source, 2)
local root_path = vim.fn.fnamemodify(current_file_path, ':p:h:h:h:h')

---@class OrgNotifications
---@field timer table
---@field files OrgFiles
local Notifications = {}

---@param opts { files: OrgFiles }
function Notifications:new(opts)
  local data = {
    timer = nil,
    files = opts.files,
  }
  setmetatable(data, self)
  self.__index = self
  return data
end

function Notifications:start_timer()
  self:stop_timer()
  self.timer = vim.uv.new_timer()
  self:notify(Date.now())
  self.timer:start(
    (60 - os.date('%S')) * 1000,
    60000,
    vim.schedule_wrap(function()
      self:notify(Date.now())
    end)
  )
end

function Notifications:stop_timer()
  if self.timer then
    self.timer:close()
    self.timer = nil
  end
end

---@param time OrgDate
function Notifications:notify(time)
  local tasks = self:get_tasks(time)

  if type(config.notifications.notifier) == 'function' then
    return config.notifications.notifier(tasks)
  end

  local result = {}
  for _, task in ipairs(tasks) do
    utils.concat(result, {
      string.format('# %s (%s)', task.category, task.humanized_duration),
      string.format('%s %s %s', string.rep('*', task.level), task.todo or '', task.title),
      string.format('%s: <%s>', task.type, task.time:to_string()),
    })
  end

  if not vim.tbl_isempty(result) then
    NotificationPopup:new({ content = result, border = config.win_border })
  end
end

function Notifications:cron()
  local tasks = self:get_tasks(Date.now())
  if type(config.notifications.cron_notifier) == 'function' then
    config.notifications.cron_notifier(tasks)
  else
    self:_cron_notifier(tasks)
  end
  vim.cmd([[qall!]])
end

---@param tasks table[]
function Notifications:_cron_notifier(tasks)
  for _, task in ipairs(tasks) do
    local title = string.format('%s (%s)', task.category, task.humanized_duration)
    local subtitle = string.format('%s %s %s', string.rep('*', task.level), task.todo or '', task.title)
    local date = string.format('%s: %s', task.type, task.time:to_string())

    if vim.fn.executable('notify-send') == 1 then
      vim.system({
        'notify-send',
        ('--icon=%s/assets/nvim-orgmode-small.png'):format(root_path),
        '--app-name=orgmode',
        title,
        string.format('%s\n%s', subtitle, date),
      })
    end

    if vim.fn.executable('terminal-notifier') == 1 then
      vim.system({ 'terminal-notifier', '-title', title, '-subtitle', subtitle, '-message', date })
    end
  end
end

---@param time OrgDate
function Notifications:get_tasks(time)
  local tasks = {}
  for _, orgfile in ipairs(self.files:all()) do
    for _, headline in ipairs(orgfile:get_opened_unfinished_headlines()) do
      for _, date in ipairs(headline:get_deadline_and_scheduled_dates()) do
        local reminders = self:_check_reminders(date, time)
        for _, reminder in ipairs(reminders) do
          table.insert(tasks, {
            file = orgfile.filename,
            todo = headline:get_todo(),
            category = headline:get_category(),
            priority = headline:get_priority(),
            title = headline:get_title(),
            level = headline:get_level(),
            tags = headline:get_tags(),
            original_time = date,
            time = reminder.time,
            reminder_type = reminder.reminder_type,
            minutes = reminder.minutes,
            humanized_duration = utils.humanize_minutes(reminder.minutes),
            type = date.type,
            range = headline:get_range(),
          })
        end
      end
    end

    -- Diary sexp entries: evaluated per day, notified like other timed
    -- entries when they match today and carry a time of day.
    if config.notifications.diary_reminder then
      self:_add_diary_tasks(orgfile, time, tasks)
    end
  end

  return tasks
end

---Add notification tasks for diary sexp entries matching today.
---Only entries with a time of day can notify (there is no meaningful
---reminder time for all-day diary entries).
---@private
---@param orgfile OrgFile
---@param time OrgDate Current time
---@param tasks table[] Task list to append to
function Notifications:_add_diary_tasks(orgfile, time, tasks)
  local DiarySexp = require('orgmode.diary.sexp')
  local DiaryFormat = require('orgmode.diary.format')
  local notification_config = config.notifications or {}
  local times = notification_config.reminder_time and utils.ensure_array(notification_config.reminder_time) or {}

  local function add_task(headline, expr, diary_time, text)
    if not diary_time then
      return
    end
    local h, m = diary_time:match('^(%d%d):(%d%d)$')
    if not h or not m then
      return
    end
    local event = Date:new({
      year = time.year,
      month = time.month,
      day = time.day,
      hour = tonumber(h),
      min = tonumber(m),
      active = true,
      type = 'NONE',
    })
    local minutes = event:diff(time, 'minute')
    if not vim.tbl_contains(times, minutes) then
      return
    end
    local title = text and DiaryFormat.interpolate(text, expr, time) or headline:get_title()
    table.insert(tasks, {
      file = orgfile.filename,
      todo = headline:get_todo(),
      category = headline:get_category(),
      priority = headline:get_priority(),
      title = title,
      level = headline.is_diary and 1 or headline:get_level(),
      tags = headline:get_tags(),
      original_time = event,
      time = event,
      reminder_type = 'time',
      minutes = minutes,
      humanized_duration = utils.humanize_minutes(minutes),
      type = 'DIARY',
      range = nil,
    })
  end

  for _, headline in ipairs(orgfile:get_opened_unfinished_headlines()) do
    for _, sexp in ipairs(headline:get_diary_sexps()) do
      if sexp.active and sexp.time then
        local matcher = DiarySexp.parse(sexp.expr)
        if matcher and matcher:matches(time) then
          add_task(headline, sexp.expr, sexp.time, nil)
        end
      end
    end
  end

  for _, sexp in ipairs(orgfile:get_diary_sexps()) do
    if sexp.time then
      local matcher = DiarySexp.parse(sexp.expr)
      if matcher and matcher:matches(time) then
        add_task(require('orgmode.diary.headline'):new({ file = orgfile }), sexp.expr, sexp.time, sexp.text)
      end
    end
  end
end

---@param date OrgDate - date to check
---@param time OrgDate - time to check agains
---@returns table|nil
function Notifications:_check_reminders(date, time)
  local result = {}
  local notifications = config.notifications or {}
  if date:is_deadline() and not notifications.deadline_reminder then
    return result
  end
  if date:is_scheduled() and not notifications.scheduled_reminder then
    return result
  end

  if notifications.repeater_reminder_time and date:get_repeater() then
    local repeater_time = date:apply_repeater_until(time)
    local times = utils.ensure_array(notifications.repeater_reminder_time)
    local minutes = repeater_time:diff(time, 'minute')
    if not date:is_same(repeater_time) and vim.tbl_contains(times, minutes) then
      table.insert(result, {
        reminder_type = 'repeater',
        time = repeater_time:without_adjustments(),
        minutes = minutes,
      })
    end
  end

  if notifications.deadline_warning_reminder_time and date:is_deadline() and date:get_negative_adjustment() then
    local warning_time = date:with_negative_adjustment()
    local times = utils.ensure_array(notifications.deadline_warning_reminder_time)
    local minutes = warning_time:diff(time, 'minute')
    if vim.tbl_contains(times, minutes) then
      local real_minutes = date:diff(time, 'minute')
      table.insert(result, {
        reminder_type = 'warning',
        time = date:without_adjustments(),
        minutes = real_minutes,
      })
    end
  end

  if notifications.reminder_time then
    local times = utils.ensure_array(notifications.reminder_time)
    local minutes = date:diff(time, 'minute')
    if vim.tbl_contains(times, minutes) then
      table.insert(result, {
        reminder_type = 'time',
        time = date:without_adjustments(),
        minutes = minutes,
      })
    end
  end

  return result
end

return Notifications
