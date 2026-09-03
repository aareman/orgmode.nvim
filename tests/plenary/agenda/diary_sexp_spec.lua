local helpers = require('tests.plenary.helpers')
local AgendaType = require('orgmode.agenda.types.agenda')
local Date = require('orgmode.objects.date')
local DiarySexp = require('orgmode.diary.sexp')
local DiaryFormat = require('orgmode.diary.format')
local DiaryHeadline = require('orgmode.diary.headline')

---Build a rendered agenda view for a given date string
---@param date_str string
---@param files table
---@param span? string
---@return table
local function render_agenda(date_str, files, span)
  local org = require('orgmode')
  local AgendaFilter = require('orgmode.agenda.filter')
  local agenda = AgendaType:new({
    files = org.files,
    highlighter = org.highlighter,
    agenda_filter = AgendaFilter:new(),
    span = span or 'day',
    from = Date.from_string(date_str),
  })
  agenda:prepare():wait()
  return agenda:render(0)
end

---@param view table
---@return string[]
local function view_contents(view)
  local contents = {}
  for _, line in ipairs(view.lines) do
    table.insert(contents, line:compile().content)
  end
  return contents
end

---@param view table
---@param pattern string
---@return boolean
local function view_has(view, pattern)
  for _, content in ipairs(view_contents(view)) do
    if content:match(pattern) then
      return true
    end
  end
  return false
end

describe('Diary sexp evaluator', function()
  after_each(function()
    DiarySexp._reset_caches()
  end)

  it('diary-date matches month/day', function()
    local matcher = assert(DiarySexp.parse('(diary-date 3 14)'))
    assert.is_true(matcher:matches(Date.from_string('2025-03-14 Fri')))
    assert.is_true(matcher:matches(Date.from_string('2026-03-14 Sat')))
    assert.is_false(matcher:matches(Date.from_string('2025-03-15 Sat')))
  end)

  it('diary-date with year matches only that year', function()
    local matcher = assert(DiarySexp.parse('(diary-date 12 25 2025)'))
    assert.is_true(matcher:matches(Date.from_string('2025-12-25 Thu')))
    assert.is_false(matcher:matches(Date.from_string('2026-12-25 Fri')))
  end)

  it('diary-anniversary supports both argument orders', function()
    local us = assert(DiarySexp.parse('(diary-anniversary 10 31 1948)'))
    assert.is_true(us:matches(Date.from_string('2025-10-31 Fri')))
    local iso = assert(DiarySexp.parse('(diary-anniversary 1948 10 31)'))
    assert.is_true(iso:matches(Date.from_string('2025-10-31 Fri')))
  end)

  it('anniversary matches Mar 1 in non-leap years for Feb 29', function()
    local matcher = assert(DiarySexp.parse('(org-anniversary 2000 2 29)'))
    assert.is_true(matcher:matches(Date.from_string('2024-02-29 Thu')))
    assert.is_true(matcher:matches(Date.from_string('2025-03-01 Sat')))
    assert.is_false(matcher:matches(Date.from_string('2025-02-28 Fri')))
  end)

  it('diary-float matches nth weekday of month', function()
    local matcher = assert(DiarySexp.parse('(diary-float 3 1 2)'))
    -- 2nd Monday of March 2025 is March 10
    assert.is_true(matcher:matches(Date.from_string('2025-03-10 Mon')))
    assert.is_false(matcher:matches(Date.from_string('2025-03-03 Mon')))
    assert.is_false(matcher:matches(Date.from_string('2025-04-14 Mon')))
  end)

  it('diary-float with t matches any month', function()
    local matcher = assert(DiarySexp.parse('(diary-float t 5 1)'))
    assert.is_true(matcher:matches(Date.from_string('2025-01-03 Fri')))
    assert.is_true(matcher:matches(Date.from_string('2025-02-07 Fri')))
    assert.is_false(matcher:matches(Date.from_string('2025-01-10 Fri')))
  end)

  it('diary-float with negative nth counts from end of month', function()
    local matcher = assert(DiarySexp.parse('(diary-float 3 5 -1)'))
    -- Last Friday of March 2025 is March 28
    assert.is_true(matcher:matches(Date.from_string('2025-03-28 Fri')))
    assert.is_false(matcher:matches(Date.from_string('2025-03-21 Fri')))
  end)

  it('diary-float matches every 2nd Wednesday of any month', function()
    -- Mon/Wed 9am style check via week-day arithmetic
    local matcher = assert(DiarySexp.parse('(or (= dow 1) (= dow 3))'))
    assert.is_true(matcher:matches(Date.from_string('2026-09-07 Mon')))
    assert.is_true(matcher:matches(Date.from_string('2026-09-09 Wed')))
    assert.is_false(matcher:matches(Date.from_string('2026-09-08 Tue')))
  end)

  it('diary-cyclic fires every n days from month/day', function()
    local matcher = assert(DiarySexp.parse('(diary-cyclic 14 1 1)'))
    assert.is_true(matcher:matches(Date.from_string('2025-01-01 Wed')))
    assert.is_true(matcher:matches(Date.from_string('2025-01-15 Wed')))
    assert.is_false(matcher:matches(Date.from_string('2025-01-14 Tue')))
  end)

  it('diary-remind matches only within N days before the event', function()
    local matcher = assert(DiarySexp.parse("(diary-remind '(org-anniversary 2000 10 31) 14)"))
    assert.is_false(matcher:matches(Date.from_string('2000-10-15 Sun')))
    assert.is_true(matcher:matches(Date.from_string('2000-10-20 Fri')))
    assert.is_true(matcher:matches(Date.from_string('2000-10-31 Tue')))
    assert.is_false(matcher:matches(Date.from_string('2000-11-01 Wed')))
  end)

  it('boolean combinators and comparisons', function()
    local m1 = assert(DiarySexp.parse('(and (diary-date 3 14) (= year 2025))'))
    assert.is_true(m1:matches(Date.from_string('2025-03-14 Fri')))
    assert.is_false(m1:matches(Date.from_string('2026-03-14 Sat')))

    local m2 = assert(DiarySexp.parse('(not (= dow 0))'))
    assert.is_true(m2:matches(Date.from_string('2025-03-17 Mon')))
    assert.is_false(m2:matches(Date.from_string('2025-03-16 Sun')))

    local m3 = assert(DiarySexp.parse('(= (mod year 2) 0)'))
    assert.is_true(m3:matches(Date.from_string('2024-01-01 Mon')))
    assert.is_false(m3:matches(Date.from_string('2025-01-01 Wed')))
  end)

  it('day names are accepted as shorthand', function()
    local matcher = assert(DiarySexp.parse('fri'))
    assert.is_true(matcher:matches(Date.from_string('2025-03-14 Fri')))
    assert.is_false(matcher:matches(Date.from_string('2025-03-15 Sat')))
  end)

  it('lua operator evaluates expressions with date variables', function()
    local matcher = assert(DiarySexp.parse('(lua "year >= 2025 and dow == 5")'))
    assert.is_true(matcher:matches(Date.from_string('2025-03-14 Fri')))
    assert.is_false(matcher:matches(Date.from_string('2024-03-15 Fri')))
  end)

  it('malformed and unknown expressions do not match', function()
    assert.is_nil(DiarySexp.parse('((('))
    assert.is_nil(DiarySexp.parse(''))
    assert.is_nil(DiarySexp.parse(nil))
    local matcher = DiarySexp.parse('(diary-aniversary 10 31 1948)')
    if matcher then
      assert.is_false(matcher:matches(Date.from_string('2025-10-31 Fri')))
    end
  end)
end)

describe('Diary sexp text interpolation', function()
  it('interpolates age and ordinal suffix', function()
    local text = DiaryFormat.interpolate(
      "Arthur's %d%s birthday",
      '(diary-anniversary 10 31 1948)',
      Date.from_string('1990-10-31 Wed')
    )
    assert.are.equal("Arthur's 42nd birthday", text)
  end)

  it('handles escaped percent signs', function()
    local text =
      DiaryFormat.interpolate('100%% done', '(diary-anniversary 10 31 1948)', Date.from_string('1990-10-31 Wed'))
    assert.are.equal('100% done', text)
  end)

  it('returns text unchanged without placeholders', function()
    local text = DiaryFormat.interpolate('plain text', '', Date.from_string('2025-01-01 Wed'))
    assert.are.equal('plain text', text)
  end)
end)

describe('DiaryHeadline', function()
  it('implements the headline interface explicitly', function()
    local helpers_file = helpers.create_agenda_file({ '* foo' })
    local headline = DiaryHeadline:new({ file = helpers_file, title = 'test' })
    assert.are.equal('test', headline:get_title())
    assert.are.equal('', headline:get_priority())
    assert.is_false(headline:is_done())
    assert.is_false(headline:is_archived())
    assert.is_true(headline:is_diary())
    assert.is_nil(headline:node())
    assert.error_matches(function()
      headline:this_method_does_not_exist()
    end, 'this_method_does_not_exist')
  end)
end)

describe('Diary sexp in agenda', function()
  after_each(function()
    DiarySexp._reset_caches()
  end)

  it('shows file-level diary entries on matching days', function()
    helpers.create_agenda_file({
      "%%(diary-anniversary 10 31 1948) Arthur's %d%s birthday",
    })
    local view = render_agenda('1990-10-31 Wed')
    assert.is_true(view_has(view, "Arthur's 42nd birthday"))
  end)

  it('does not show file-level diary entries on other days', function()
    helpers.create_agenda_file({
      "%%(diary-anniversary 10 31 1948) Arthur's %d%s birthday",
    })
    local view = render_agenda('1990-10-30 Tue')
    assert.is_false(view_has(view, 'Arthur'))
  end)

  it('shows headline-level diary entries', function()
    helpers.create_agenda_file({
      '* Birthdays',
      '  <%%(diary-anniversary 10 31 1948)> Someone',
    })
    local view = render_agenda('2025-10-31 Fri')
    assert.is_true(view_has(view, 'Birthdays'))
  end)

  it('supports time of day in wrapped entries', function()
    helpers.create_agenda_file({
      '* Standup',
      '  <%%(or (= dow 1) (= dow 3)) 09:00> Standup meeting',
    })
    local view = render_agenda('2026-09-07 Mon')
    local contents = view_contents(view)
    -- The headline shows up with its 09:00 time label
    local found_with_time = false
    for _, content in ipairs(contents) do
      if content:match('Standup') and content:match('09:00') then
        found_with_time = true
      end
    end
    assert.is_true(found_with_time)
  end)

  it('diary-remind entries show inside the reminder window', function()
    helpers.create_agenda_file({
      "%%(diary-remind '(org-anniversary 2000 10 31) 14) %d. Test reminder",
    })
    local view = render_agenda('2000-10-20 Fri')
    assert.is_true(view_has(view, 'Test reminder'))

    local outside = render_agenda('2000-10-15 Sun')
    assert.is_false(view_has(outside, 'Test reminder'))
  end)
end)
