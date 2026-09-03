local Date = require('orgmode.objects.date')
local Hebrew = require('orgmode.diary.hebrew')
local DiarySexp = require('orgmode.diary.sexp')

describe('Hebrew calendar conversion', function()
  it('converts known Rosh Hashanah dates', function()
    local function g(y, m, d)
      local x = Hebrew.to_gregorian(y, m, d)
      return ('%04d-%02d-%02d'):format(x.year, x.month, x.day)
    end
    assert.are.equal('2023-09-16', g(5784, 7, 1))
    assert.are.equal('2024-10-03', g(5785, 7, 1))
    assert.are.equal('2016-10-03', g(5777, 7, 1))
    assert.are.equal('2021-09-07', g(5782, 7, 1))
  end)

  it('converts known Gregorian dates to Hebrew dates', function()
    local function h(y, m, d)
      local x = Hebrew.from_gregorian(y, m, d)
      return ('%d %s %d'):format(x.day, Hebrew.month_name(x.year, x.month), x.year)
    end
    assert.are.equal('17 Elul 5753', h(1993, 9, 3))
    assert.are.equal('8 Tevet 5756', h(1995, 12, 31))
    assert.are.equal('14 Av 5780', h(2020, 8, 4))
    assert.are.equal('27 Av 5782', h(2022, 8, 24))
    assert.are.equal('26 Cheshvan 5785', h(2024, 11, 27))
  end)

  it('handles known holiday anchors', function()
    local function g(y, m, d)
      local x = Hebrew.to_gregorian(y, m, d)
      return ('%04d-%02d-%02d'):format(x.year, x.month, x.day)
    end
    -- Purim 5784 = 14 Adar II (leap year)
    assert.are.equal('2024-03-24', g(5784, 13, 14))
    -- Tisha B'Av 5784 = 9 Av
    assert.are.equal('2024-08-13', g(5784, 5, 9))
    -- Chanukah day 1, 25 Kislev 5785
    assert.are.equal('2024-12-26', g(5785, 9, 25))
  end)

  it('roundtrips Gregorian <-> Hebrew across two centuries', function()
    for year = 1900, 2100 do
      local h = Hebrew.from_gregorian(year, 6, 1)
      local back = Hebrew.to_gregorian(h.year, h.month, h.day)
      assert.are.equal(year, back.year)
      assert.are.equal(6, back.month)
      assert.are.equal(1, back.day)
    end
  end)

  it('resolves Adar in a leap year to Adar II', function()
    local month, day = Hebrew.resolve_anniversary(5784, 12, 15)
    assert.are.equal(13, month)
    assert.are.equal(15, day)
    -- In a common year Adar stays Adar
    local month2, day2 = Hebrew.resolve_anniversary(5785, 12, 15)
    assert.are.equal(12, month2)
    assert.are.equal(15, day2)
  end)

  it('resolves a nonexistent day to the 1st of the following month', function()
    -- 5784 was a deficient leap year (383 days): Kislev has only 29 days,
    -- so Kislev 30 falls on 1 Tevet.
    local month, day = Hebrew.resolve_anniversary(5784, 9, 30)
    assert.are.equal(10, month)
    assert.are.equal(1, day)
  end)
end)

describe('Hebrew anniversary sexp expressions', function()
  after_each(function()
    DiarySexp._reset_caches()
  end)

  it('org-hebrew-anniversary (year month day) matches the right date', function()
    local matcher = assert(DiarySexp.parse('(org-hebrew-anniversary 5753 6 17)'))
    assert.is_true(matcher:matches(Date.from_string('1993-09-03 Fri')))
    assert.is_false(matcher:matches(Date.from_string('1993-09-04 Sat')))
    assert.is_true(matcher:matches(Date.from_string('2025-09-10 Wed')))
  end)

  it('diary-hebrew-anniversary (month day year) matches the right date', function()
    local matcher = assert(DiarySexp.parse('(diary-hebrew-anniversary 9 25 5785)'))
    assert.is_true(matcher:matches(Date.from_string('2024-12-26 Thu')))
    assert.is_false(matcher:matches(Date.from_string('2024-12-25 Wed')))
  end)

  it('accepts Hebrew month names', function()
    local matcher = assert(DiarySexp.parse('(org-hebrew-anniversary 5780 Elul 3)'))
    assert.is_false(matcher:matches(Date.from_string('2020-08-04 Tue')))
    local m2 = assert(DiarySexp.parse('(diary-hebrew-anniversary Av 14 5780)'))
    assert.is_true(m2:matches(Date.from_string('2020-08-04 Tue')))
  end)

  it('observes Adar birthdays on Adar II in leap years', function()
    -- Someone born 15 Adar: in leap year 5784 the anniversary falls on
    -- 15 Adar II = 2024-03-25
    local matcher = assert(DiarySexp.parse('(org-hebrew-anniversary 5700 12 15)'))
    assert.is_true(matcher:matches(Date.from_string('2024-03-25 Mon')))
    assert.is_false(matcher:matches(Date.from_string('2024-02-25 Sun')))
  end)

  it('hebrew-birthday is an alias of diary-hebrew-anniversary', function()
    local matcher = assert(DiarySexp.parse('(hebrew-birthday 6 17 5753)'))
    assert.is_true(matcher:matches(Date.from_string('1993-09-03 Fri')))
  end)
end)
