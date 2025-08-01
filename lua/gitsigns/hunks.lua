local log = require('gitsigns.debug.log')
local util = require('gitsigns.util')
local config = require('gitsigns.config').config

local min, max = math.min, math.max

--- @alias Gitsigns.Hunk.Type
--- | "add"
--- | "change"
--- | "delete"

--- @class (exact) Gitsigns.Hunk.Node
--- @field start integer
--- @field count integer
--- @field lines string[]
--- @field no_nl_at_eof? true

--- @class (exact) Gitsigns.Hunk.Hunk
--- @field type Gitsigns.Hunk.Type
--- @field head string
--- @field added Gitsigns.Hunk.Node
--- @field removed Gitsigns.Hunk.Node
--- @field vend integer

--- @class (exact) Gitsigns.Hunk.Hunk_Public
--- @field type Gitsigns.Hunk.Type
--- @field head string
--- @field lines string[]
--- @field added Gitsigns.Hunk.Node
--- @field removed Gitsigns.Hunk.Node

--- @class gitsigns.hunks
local M = {}

--- @param old_start integer
--- @param old_count integer
--- @param new_start integer
--- @param new_count integer
--- @return Gitsigns.Hunk.Hunk
function M.create_hunk(old_start, old_count, new_start, new_count)
  return {
    removed = { start = old_start, count = old_count, lines = {} },
    added = { start = new_start, count = new_count, lines = {} },
    head = ('@@ -%d%s +%d%s @@'):format(
      old_start,
      old_count > 0 and ',' .. old_count or '',
      new_start,
      new_count > 0 and ',' .. new_count or ''
    ),

    vend = new_start + math.max(new_count - 1, 0),
    type = new_count == 0 and 'delete' or old_count == 0 and 'add' or 'change',
  }
end

--- @param hunks Gitsigns.Hunk.Hunk[]
--- @param top integer
--- @param bot integer
--- @return Gitsigns.Hunk.Hunk?
function M.create_partial_hunk(hunks, top, bot)
  local pretop, precount = top, bot - top + 1
  local unused = 0
  for _, h in ipairs(hunks) do
    local added_in_hunk = h.added.count - h.removed.count

    local added_in_range = 0
    if h.added.start >= top and h.vend <= bot then
      -- Range contains hunk
      added_in_range = added_in_hunk
    else
      local added_above_bot = max(0, bot + 1 - (h.added.start + h.removed.count))
      local added_above_top = max(0, top - (h.added.start + h.removed.count))

      if h.added.start >= top and h.added.start <= bot then
        -- Range top intersects hunk
        added_in_range = added_above_bot
      elseif h.vend >= top and h.vend <= bot then
        -- Range bottom intersects hunk
        added_in_range = added_in_hunk - added_above_top
        pretop = pretop - added_above_top
      elseif h.added.start <= top and h.vend >= bot then
        -- Range within hunk
        added_in_range = added_above_bot - added_above_top
        pretop = pretop - added_above_top
      else
        -- No intersection
        unused = unused + 1
      end

      if top > h.vend then
        pretop = pretop - added_in_hunk
      end
    end

    precount = precount - added_in_range
  end

  if unused == #hunks then
    -- top and bot are not in any hunk
    return
  end

  if precount == 0 then
    pretop = pretop - 1
  end

  return M.create_hunk(pretop, precount, top, bot - top + 1)
end

--- @param hunk Gitsigns.Hunk.Hunk
--- @param fileformat string
--- @return string[]
function M.patch_lines(hunk, fileformat)
  local lines = {} --- @type string[]
  for _, l in ipairs(hunk.removed.lines) do
    lines[#lines + 1] = '-' .. l
  end
  for _, l in ipairs(hunk.added.lines) do
    lines[#lines + 1] = '+' .. l
  end

  if fileformat == 'dos' then
    lines = util.strip_cr(lines)
  end
  return lines
end

local function tointeger(x)
  return tonumber(x) --[[@as integer]]
end

--- @param line string
--- @return Gitsigns.Hunk.Hunk
function M.parse_diff_line(line)
  local diffkey = vim.trim(assert(vim.split(line, '@@', { plain = true })[2]))

  -- diffKey: "-xx,n +yy"
  -- pre: {xx, n}, now: {yy}
  local p = vim.tbl_map(
    --- @param s string
    --- @return [string, string]
    function(s)
      return vim.split(s:sub(2), ',')
    end,
    vim.split(diffkey, ' ')
  )

  --- @type [string,string?], [string,string?]
  local pre, now = p[1], p[2]

  local hunk = M.create_hunk(
    tointeger(pre[1]),
    (tointeger(pre[2]) or 1),
    tointeger(now[1]),
    (tointeger(now[2]) or 1)
  )

  hunk.head = line

  return hunk
end

--- @param hunk Gitsigns.Hunk.Hunk
--- @return integer
local function change_end(hunk)
  if hunk.added.count == 0 then
    -- delete
    return hunk.added.start
  elseif hunk.removed.count == 0 then
    -- add
    return hunk.added.start + hunk.added.count - 1
  else
    -- change
    return hunk.added.start + min(hunk.added.count, hunk.removed.count) - 1
  end
end

--- Calculate signs needed to be applied from a hunk for a specified line range.
--- @param hunk Gitsigns.Hunk.Hunk
--- @param next Gitsigns.Hunk.Hunk?
--- @param min_lnum integer
--- @param max_lnum integer
--- @param untracked? boolean
--- @return Gitsigns.Sign[]
local function calc_signs(hunk, next, min_lnum, max_lnum, untracked)
  local start, added, removed = hunk.added.start, hunk.added.count, hunk.removed.count

  if hunk.type == 'delete' and start == 0 then
    if min_lnum <= 1 then
      -- topdelete signs get placed one row lower
      return { { type = 'topdelete', count = removed, lnum = 1 } }
    else
      return {}
    end
  end

  --- @type Gitsigns.Sign[]
  local signs = {}

  local cend = change_end(hunk)

  -- if this is a change hunk, mark changedelete if lines were removed or if the
  -- next hunk removes on this hunks last line
  local changedelete = hunk.type == 'change'
    and (
      removed > added
      or (
        (next and next.type == 'delete')
        and hunk.added.start + hunk.added.count - 1 == next.added.start
      )
    )

  for lnum = max(start, min_lnum), min(cend, max_lnum) do
    signs[#signs + 1] = {
      type = (changedelete and lnum == cend) and 'changedelete'
        or untracked and 'untracked'
        or hunk.type,
      count = lnum == start and (hunk.type == 'add' and added or removed) or nil,
      lnum = lnum,
    }
  end

  if hunk.type == 'change' and added > removed and hunk.vend >= min_lnum and cend <= max_lnum then
    for lnum = max(cend, min_lnum), min(hunk.vend, max_lnum) do
      signs[#signs + 1] = {
        type = 'add',
        count = lnum == hunk.vend and (added - removed) or nil,
        lnum = lnum,
      }
    end
  end

  return signs
end

--- Calculate signs needed to be applied from a hunk for a specified line range.
--- @param prev_hunk Gitsigns.Hunk.Hunk?
--- @param hunk Gitsigns.Hunk.Hunk
--- @param next_hunk Gitsigns.Hunk.Hunk?
--- @param min_lnum? integer
--- @param max_lnum? integer
--- @param untracked? boolean
--- @return Gitsigns.Sign[]
function M.calc_signs(prev_hunk, hunk, next_hunk, min_lnum, max_lnum, untracked)
  if not (not untracked or hunk.type == 'add') then
    log.eprintf('Invalid hunk with untracked=%s hunk="%s"', untracked, hunk.head)
    return {}
  end
  min_lnum = math.max(1, min_lnum or 1)
  max_lnum = max_lnum or math.huge --[[@as integer]]

  if not config._new_sign_calc then
    return calc_signs(hunk, next_hunk, min_lnum, max_lnum, untracked)
  end

  local start, added, removed = hunk.added.start, hunk.added.count, hunk.removed.count

  local cend = change_end(hunk)

  local topdelete = hunk.type == 'delete'
    and (start == 0 or prev_hunk and change_end(prev_hunk) == start)
    and (not next_hunk or next_hunk.added.start ~= start + 1)

  if topdelete and min_lnum == 1 then
    min_lnum = 0
  end

  --- @type Gitsigns.Sign[]
  local signs = {}

  for lnum = max(start, min_lnum), min(cend, max_lnum) do
    local changedelete = hunk.type == 'change'
      and (removed > added and lnum == cend or prev_hunk and prev_hunk.added.start == 0)

    signs[#signs + 1] = {
      type = topdelete and 'topdelete'
        or changedelete and 'changedelete'
        or untracked and 'untracked'
        or hunk.type,
      count = lnum == start and (hunk.type == 'add' and added or removed) or nil,
      lnum = lnum + (topdelete and 1 or 0),
    }
  end

  if hunk.type == 'change' and added > removed and hunk.vend >= min_lnum and cend <= max_lnum then
    for lnum = max(cend, min_lnum), min(hunk.vend, max_lnum) do
      signs[#signs + 1] = {
        type = 'add',
        count = lnum == hunk.vend and (added - removed) or nil,
        lnum = lnum,
      }
    end
  end

  return signs
end

--- @param relpath string
--- @param hunks Gitsigns.Hunk.Hunk[]
--- @param mode_bits string
--- @param invert? boolean
--- @return string[]
function M.create_patch(relpath, hunks, mode_bits, invert)
  invert = invert or false

  local results = {
    string.format('diff --git a/%s b/%s', relpath, relpath),
    'index 000000..000000 ' .. mode_bits,
    '--- a/' .. relpath,
    '+++ b/' .. relpath,
  }

  local offset = 0

  for _, process_hunk in ipairs(hunks) do
    local start, pre_count, now_count =
      process_hunk.removed.start, process_hunk.removed.count, process_hunk.added.count

    if process_hunk.type == 'add' then
      start = start + 1
    end

    local pre_lines = process_hunk.removed.lines
    local now_lines = process_hunk.added.lines

    if invert then
      pre_count, now_count = now_count, pre_count --- @type integer, integer
      pre_lines, now_lines = now_lines, pre_lines --- @type string[], string[]
    end

    table.insert(
      results,
      ('@@ -%s,%s +%s,%s @@'):format(start, pre_count, start + offset, now_count)
    )
    for _, l in ipairs(pre_lines) do
      results[#results + 1] = '-' .. l
    end

    if process_hunk.removed.no_nl_at_eof then
      results[#results + 1] = '\\ No newline at end of file'
    end

    for _, l in ipairs(now_lines) do
      results[#results + 1] = '+' .. l
    end

    if process_hunk.added.no_nl_at_eof then
      results[#results + 1] = '\\ No newline at end of file'
    end

    process_hunk.removed.start = start + offset
    offset = offset + (now_count - pre_count)
  end

  return results
end

--- @param hunks Gitsigns.Hunk.Hunk[]
--- @return Gitsigns.StatusObj
function M.get_summary(hunks)
  local status = { added = 0, changed = 0, removed = 0 }

  for _, hunk in ipairs(hunks or {}) do
    if hunk.type == 'add' then
      status.added = status.added + hunk.added.count
    elseif hunk.type == 'delete' then
      status.removed = status.removed + hunk.removed.count
    elseif hunk.type == 'change' then
      local add, remove = hunk.added.count, hunk.removed.count
      local delta = min(add, remove)
      status.changed = status.changed + delta
      status.added = status.added + add - delta
      status.removed = status.removed + remove - delta
    end
  end

  return status
end

--- @param lnum integer
--- @param hunks Gitsigns.Hunk.Hunk[]?
--- @return Gitsigns.Hunk.Hunk?, integer?
function M.find_hunk(lnum, hunks)
  for i, hunk in ipairs(hunks or {}) do
    if lnum == 1 and hunk.added.start == 0 and hunk.vend == 0 then
      return hunk, i
    end

    if hunk.added.start <= lnum and hunk.vend >= lnum then
      return hunk, i
    end
  end
end

--- @param lnum integer
--- @param hunks Gitsigns.Hunk.Hunk[]
--- @param direction 'first'|'last'|'next'|'prev'
--- @param wrap? boolean
--- @return integer?
function M.find_nearest_hunk(lnum, hunks, direction, wrap)
  if #hunks == 0 then
    return
  elseif direction == 'first' then
    return 1
  elseif direction == 'last' then
    return #hunks
  elseif direction == 'next' then
    if assert(hunks[1]).added.start > lnum then
      return 1
    end
    for i = #hunks, 1, -1 do
      if assert(hunks[i]).added.start <= lnum then
        if i + 1 <= #hunks and assert(hunks[i + 1]).added.start > lnum then
          return i + 1
        elseif wrap then
          return 1
        end
      end
    end
  elseif direction == 'prev' then
    if math.max(assert(hunks[#hunks]).vend) < lnum then
      return #hunks
    end
    for i = 1, #hunks do
      if lnum <= math.max(hunks[i].vend, 1) then
        if i > 1 and math.max(assert(hunks[i - 1]).vend, 1) < lnum then
          return i - 1
        elseif wrap then
          return #hunks
        end
      end
    end
  end
end

--- @param a Gitsigns.Hunk.Hunk[]?
--- @param b Gitsigns.Hunk.Hunk[]?
--- @return boolean
function M.compare_heads(a, b)
  if (a == nil) ~= (b == nil) then
    return true
  elseif a and #a ~= #b then
    return true
  end
  for i, ah in ipairs(a or {}) do
    --- @diagnostic disable-next-line:need-check-nil
    if b[i].head ~= ah.head then
      return true
    end
  end
  return false
end

--- @param a Gitsigns.Hunk.Hunk
--- @param b Gitsigns.Hunk.Hunk
--- @return boolean
local function compare_new(a, b)
  if a.added.start ~= b.added.start then
    return false
  end

  if a.added.count ~= b.added.count then
    return false
  end

  for i = 1, a.added.count do
    if a.added.lines[i] ~= b.added.lines[i] then
      return false
    end
  end

  return true
end

--- Return hunks in a using b's hunks as a filter. Only compare the 'new' section
--- of the hunk.
---
--- Eg. Given:
---
---       a = {
---             1 = '@@ -24 +25,1 @@',
---             2 = '@@ -32 +34,1 @@',
---             3 = '@@ -37 +40,1 @@'
---       }
---
---       b = {
---             1 = '@@ -26 +25,1 @@'
---       }
---
--- Since a[1] and b[1] introduce the same changes to the buffer (both have
--- +25,1), we exclude this hunk in the output so we return:
---
---       {
---             1 = '@@ -32 +34,1 @@',
---             2 = '@@ -37 +40,1 @@'
---       }
---
--- @param a Gitsigns.Hunk.Hunk[]
--- @param b Gitsigns.Hunk.Hunk[]
--- @return Gitsigns.Hunk.Hunk[]?
function M.filter_common(a, b)
  if not a and not b then
    return
  end

  a, b = a or {}, b or {}

  local a_i = 1
  local b_i = 1

  --- @type Gitsigns.Hunk.Hunk[]
  local ret = {}

  -- Need an offset of 1 in order to process when we hit the end of either
  -- a or b
  for _ = 1, math.max(#a, #b) + 1 do
    local a_h, b_h = a[a_i], b[b_i]

    if not a_h then
      -- Reached the end of a
      break
    end

    if not b_h then
      -- Reached the end of b, add remainder of a
      for i = a_i, #a do
        ret[#ret + 1] = a[i]
      end
      break
    end

    if a_h.added.start > b_h.added.start then
      -- a pointer is ahead of b; increment b pointer
      b_i = b_i + 1
    elseif a_h.added.start < b_h.added.start then
      -- b pointer is ahead of a; add a_h to ret and increment a pointer
      ret[#ret + 1] = a_h
      a_i = a_i + 1
    else -- a_h.start == b_h.start
      -- a_h and b_h start on the same line, if hunks have the same changes then
      -- skip (filtered) otherwise add a_h to ret. Increment both hunk
      -- pointers
      -- TODO(lewis6991): Be smarter; if bh intercepts then break down ah.
      if not compare_new(a_h, b_h) then
        ret[#ret + 1] = a_h
      end
      a_i = a_i + 1
      b_i = b_i + 1
    end
  end

  return ret
end

--- @param hunk Gitsigns.Hunk.Hunk
--- @param fileformat string
--- @return Gitsigns.LineSpec[]
function M.linespec_for_hunk(hunk, fileformat)
  local hls = {} --- @type [string, string|Gitsigns.HlMark[], string?][][]

  local removed, added = hunk.removed.lines, hunk.added.lines

  if fileformat == 'dos' then
    removed = util.strip_cr(removed)
    added = util.strip_cr(added)
  end

  for _, spec in ipairs({
    { sym = '-', lines = removed, hl = 'GitSignsDeletePreview' },
    { sym = '+', lines = added, hl = 'GitSignsAddPreview' },
  }) do
    for _, l in ipairs(spec.lines) do
      --- @type Gitsigns.HlMark
      local mark = {
        start_row = 0,
        hl_group = spec.hl,
        end_row = 1, -- Highlight whole line
      }
      hls[#hls + 1] = { { spec.sym .. l, { mark } } }
    end
  end

  if config.diff_opts.internal then
    local removed_regions, added_regions =
      require('gitsigns.diff_int').run_word_diff(removed, added)

    for _, region in ipairs(removed_regions) do
      local i = region[1]
      local hlm = assert(assert(hls[i])[1])[2]
      hlm[#hlm + 1] = {
        start_row = 0,
        hl_group = 'GitSignsDeleteInline',
        start_col = region[3],
        end_col = region[4],
      }
    end

    for _, region in ipairs(added_regions) do
      local i = hunk.removed.count + region[1]
      local hlm = assert(assert(hls[i])[1])[2]
      hlm[#hlm + 1] = {
        start_row = 0,
        hl_group = 'GitSignsAddInline',
        start_col = region[3],
        end_col = region[4],
      }
    end
  end

  return hls
end

return M
