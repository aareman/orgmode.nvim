local helpers = require('tests.plenary.helpers')
local Date = require('orgmode.objects.date')

describe('iCalendar export', function()
  it('generates VEVENTs for scheduled headlines with repeaters', function()
    local f = helpers.create_agenda_file({
      '* TODO Train with Kenny :works:',
      '  SCHEDULED: <2026-08-31 Mon 15:45 +1w>',
    })
    local icalendar = require('orgmode.icalendar')
    local content = icalendar.generate(require('orgmode').files, { days = 30 })
    assert.is_true(content:find('DTSTART:20260907T154500', 1, true) ~= nil)
    assert.is_true(content:find('DTSTART:20260914T154500', 1, true) ~= nil)
    assert.is_true(content:find('CATEGORIES:.-works', 1, false) ~= nil)
    assert.is_true(content:find('END:VCALENDAR', 1, true) ~= nil)
  end)

  it('expands diary sexp entries over the horizon', function()
    local f = helpers.create_agenda_file({
      '* TODO Train with Kenny :works:',
      '  <%%(= dow 1) 15:45> Train with Kenny',
      '%%(diary-anniversary 10 31 1948) Arthur birthday',
    })
    local icalendar = require('orgmode.icalendar')
    local content = icalendar.generate(require('orgmode').files, { days = 60 })
    assert.is_true(content:find('SUMMARY:Train with Kenny', 1, true) ~= nil)
    assert.is_true(content:find('DTSTART;VALUE=DATE:20261031', 1, true) ~= nil)
    -- Monday occurrences exist
    assert.is_true(content:find('DTSTART:20260907T154500', 1, true) ~= nil)
    assert.is_true(content:find('DTSTART:20260914T154500', 1, true) ~= nil)
  end)

  it('exports all-day diary entries without a time', function()
    local f = helpers.create_agenda_file({
      '%%(diary-date 12 25) Christmas',
    })
    local icalendar = require('orgmode.icalendar')
    local content = icalendar.generate(require('orgmode').files, { days = 365 })
    assert.is_true(content:find('DTSTART;VALUE=DATE:20261225', 1, true) ~= nil)
  end)

  it('produces stable UIDs across exports', function()
    local f = helpers.create_agenda_file({
      '* TODO Train',
      '  SCHEDULED: <2026-08-31 Mon 15:45 +1w>',
    })
    local icalendar = require('orgmode.icalendar')
    local files = require('orgmode').files
    local function uids()
      local content = icalendar.generate(files, { days = 30 })
      local found = {}
      for uid in content:gmatch('UID:(%S+)') do
        found[uid] = true
      end
      return found
    end
    local first, second = uids(), uids()
    for uid in pairs(first) do
      assert.is_true(second[uid] ~= nil)
    end
  end)
end)
