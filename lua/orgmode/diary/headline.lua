-- A minimal headline implementation for file-level diary sexp entries, which
-- have no headline of their own. Unlike a no-op __index shim, any method not
-- part of the interface errors loudly, so interface drift is caught instead
-- of silently swallowed.
---@class OrgDiaryHeadline
---@field file OrgFile
---@field _title string
local DiaryHeadline = {}
DiaryHeadline.__index = DiaryHeadline

---@param opts { file: OrgFile, title: string }
---@return OrgDiaryHeadline
function DiaryHeadline:new(opts)
  local data = {
    file = opts.file,
    _title = opts.title or '',
  }
  return setmetatable(data, self)
end

---@return string
function DiaryHeadline:get_title()
  return self._title
end

---@return string
function DiaryHeadline:get_category()
  return self.file:get_category()
end

---@return nil
function DiaryHeadline:get_todo()
  return nil
end

---@return string
function DiaryHeadline:get_priority()
  return ''
end

---@return number
function DiaryHeadline:get_priority_sort_value()
  return math.huge
end

---@return table
function DiaryHeadline:get_tags()
  return {}
end

---@return string
function DiaryHeadline:tags_to_string()
  return ''
end

---@param _ string
---@return boolean
function DiaryHeadline:has_tag(_)
  return false
end

---@param _ string
---@return boolean
function DiaryHeadline:matches_category(_)
  return false
end

---@return boolean
function DiaryHeadline:is_done()
  return false
end

---@return boolean
function DiaryHeadline:is_archived()
  return false
end

---@return boolean
function DiaryHeadline:is_clocked_in()
  return false
end

---Marker used by the agenda view to skip treesitter markup
---@return boolean
function DiaryHeadline:is_diary()
  return true
end

---@return nil
function DiaryHeadline:node()
  return nil
end

return DiaryHeadline
