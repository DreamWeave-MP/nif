--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
How the generators lay a statement out. They write each statement on one line; `wrap` breaks one
that is too long the way the rest of the repository's Luau is written: a short assignment's value
on the line below, a chain of `and`/`or` one operand a line, an `if` expression one branch a line,
and a call's arguments or a table's items one a line. What comes back is the same statement.
]]

--- The longest line the generated code has, where a statement can be broken at all.
local Width = 100

--- What `place` is laying out: a whole statement, one item of a table or argument list, or an
--- expression that starts its own line.
type Role = 'statement' | 'item' | 'expression'

--- Where a line's structure is, outside every bracket, string, and function body.
type Marks = {
  --- The first assignment's `=`.
  assign: number?,
  --- Each `and` and `or`.
  operators: { number },
  --- Each `then`, `elseif`, and `else`.
  branches: { number },
  --- Each `|`.
  bars: { number },
  --- Each `,`.
  commas: { number },
  --- Each `(...)` and `{...}` with something in it: where it opens and closes.
  groups: { { open: number, close: number } },
}

local Openers = { [40] = true, [91] = true, [123] = true }
local Closers = { [41] = true, [93] = true, [125] = true }
local Quotes = { [34] = true, [39] = true, [96] = true }

local function isWord(byte: number?): boolean
  if not byte then return false end

  return byte == 95
    or (byte >= 48 and byte <= 57)
    or (byte >= 65 and byte <= 90)
    or (byte >= 97 and byte <= 122)
end

local function scan(text: string): Marks
  local marks: Marks = { operators = {}, branches = {}, bars = {}, commas = {}, groups = {} }
  local depth, functions, opened = 0, 0, 0
  local at, length = 1, #text

  while at <= length do
    local byte = string.byte(text, at)

    if Quotes[byte] then
      -- To the closing quote, past anything escaped.
      local stop = at + 1

      while stop <= length and string.byte(text, stop) ~= byte do
        stop += if string.byte(text, stop) == 92 then 2 else 1
      end

      at = stop + 1
    elseif Openers[byte] then
      if depth == 0 then opened = at end

      depth += 1
      at += 1
    elseif Closers[byte] then
      depth -= 1

      if depth == 0 and byte ~= 93 and string.find(text, '%S', opened + 1) ~= at then
        table.insert(marks.groups, { open = opened, close = at })
      end

      at += 1
    elseif isWord(byte) and not isWord(string.byte(text, at - 1)) then
      local stop = at

      while isWord(string.byte(text, stop + 1)) do
        stop += 1
      end

      local word = string.sub(text, at, stop)

      if word == 'function' then
        functions += 1
        depth += 1
      elseif word == 'end' and functions > 0 then
        functions -= 1
        depth -= 1
      elseif depth == 0 and at > 1 and (word == 'and' or word == 'or') then
        -- Not the operator a line that continues a chain starts with.
        table.insert(marks.operators, at)
      elseif depth == 0 and (word == 'then' or word == 'elseif' or word == 'else') then
        table.insert(marks.branches, at)
      end

      at = stop + 1
    else
      if depth == 0 then
        if byte == 44 then
          table.insert(marks.commas, at)
        elseif byte == 124 then
          table.insert(marks.bars, at)
        elseif byte == 61 and not marks.assign then
          local before, after = string.byte(text, at - 1), string.byte(text, at + 1)
          -- Not `==`, `~=`, `<=`, or `>=`.
          local compares = before == 61 or before == 126 or before == 60 or before == 62

          if not compares and after ~= 61 then marks.assign = at end
        end
      end

      at += 1
    end
  end

  return marks
end

--- `text` cut before each of `starts`, without the spaces the cuts leave.
local function cut(text: string, starts: { number }): { string }
  local parts, from = {}, 1

  for _, start in starts do
    table.insert(parts, (string.gsub(string.sub(text, from, start - 1), '%s+$', '')))
    from = start
  end

  table.insert(parts, string.sub(text, from))
  return parts
end

local place: (lines: { string }, text: string, depth: number, role: Role) -> ()

--- A block's first line: `opening`, the condition, and `closing`, the condition on lines of its
--- own when the three don't fit on one.
local function header(
  lines: { string },
  opening: string,
  condition: string,
  closing: string,
  depth: number
)
  local indent = string.rep('  ', depth)
  local whole = `{opening} {condition} {closing}`

  if #indent + #whole <= Width then
    table.insert(lines, indent .. whole)
    return
  end

  table.insert(lines, indent .. opening)
  place(lines, condition, depth + 1, 'expression')
  table.insert(lines, indent .. closing)
end

--- The items between a group's brackets, each on a line of its own.
local function expand(
  lines: { string },
  text: string,
  group: { open: number, close: number },
  depth: number
)
  local indent = string.rep('  ', depth)
  local open, close = group.open, group.close
  local inner = string.sub(text, open + 1, close - 1)
  local braces = string.byte(text, open) == 123

  -- A call whose one argument is a table is laid out as that table: `freeze({` and `})`.
  if not braces and string.find(inner, '^{.*}$') then
    local marks = scan(inner)

    if #marks.commas == 0 and #marks.groups == 1 and marks.groups[1].close == #inner then
      open, close, braces = open + 1, close - 1, true
      inner = string.sub(text, open + 1, close - 1)
    end
  end

  inner = string.gsub(string.gsub(inner, '^%s+', ''), '%s+$', '')
  local starts = {}

  for _, comma in scan(inner).commas do
    table.insert(starts, comma + 1)
  end

  local items: { string } = {}

  for _, item in cut(inner, starts) do
    local bare = string.gsub(string.gsub(item, '^%s+', ''), ',$', '')
    if bare ~= '' then table.insert(items, bare) end
  end

  table.insert(lines, indent .. string.sub(text, 1, open))

  for index, item in items do
    if braces then
      place(lines, item .. ',', depth + 1, 'item')
    elseif #items == 1 then
      -- Parentheses around one expression: its operands line up under each other.
      place(lines, item, depth + 1, 'expression')
    else
      place(lines, if index < #items then item .. ',' else item, depth + 1, 'item')
    end
  end

  table.insert(lines, indent .. string.sub(text, close))
end

place = function(lines: { string }, text: string, depth: number, role: Role)
  local indent = string.rep('  ', depth)

  if #indent + #text <= Width or string.sub(text, 1, 2) == '--' then
    table.insert(lines, indent .. text)
    return
  end

  -- A function's first line: its parameters, one a line. `scan` takes a function for its body.
  local keyword = string.match(text, '^local function ') or string.match(text, '^function ')

  if keyword then
    local parameters = scan(string.sub(text, #keyword + 1)).groups[1]
    local last = if parameters then parameters.close + #keyword else #keyword
    local body = string.find(text, ' return ', last, true)

    -- A function that is one `return`, as a block.
    if string.sub(text, -4) == ' end' and body then
      place(lines, string.sub(text, 1, body - 1), depth, 'statement')
      place(lines, string.sub(text, body + 1, -5), depth + 1, 'statement')
      table.insert(lines, indent .. 'end')
      return
    end

    if parameters and string.sub(text, -4) ~= ' end' then
      local group = { open = parameters.open + #keyword, close = parameters.close + #keyword }
      expand(lines, text, group, depth)
      return
    end
  end

  local marks = scan(text)
  local first = marks.branches[1]

  if string.sub(text, 1, 3) == 'if ' and first and role == 'statement' then
    local condition = string.sub(text, 4, first - 2)

    -- `if condition then statement end`, as a block.
    if string.sub(text, -4) == ' end' then
      header(lines, 'if', condition, 'then', depth)
      place(lines, string.sub(text, first + 5, -5), depth + 1, 'statement')
      table.insert(lines, indent .. 'end')
      return
    end

    if first + 3 == #text then
      header(lines, 'if', condition, 'then', depth)
      return
    end
  end

  local assign = marks.assign
  local alias = string.find(text, '^type ') or string.find(text, '^export type ')

  if alias and assign and #marks.bars > 0 then
    table.insert(lines, indent .. string.sub(text, 1, assign))

    for index, member in cut(text, marks.bars) do
      local first = index == 1
      table.insert(lines, `{indent}  {if first then string.sub(member, assign + 2) else member}`)
    end

    return
  end

  local value = if assign
    then assign + 2
    elseif string.sub(text, 1, 7) == 'return ' then 8
    else 1

  if string.sub(text, value, value + 2) == 'if ' and first then
    local parts = cut(text, marks.branches)
    place(lines, parts[1], depth, role)

    for index = 2, #parts do
      place(lines, parts[index], depth + 1, 'item')
    end

    return
  end

  if assign and role == 'statement' then
    local right = string.sub(text, value)
    local hangs = not string.find(right, '^{') and not string.find(right, '^function')

    if hangs and #indent + 2 + #right <= Width then
      table.insert(lines, indent .. string.sub(text, 1, assign))
      table.insert(lines, `{indent}  {right}`)
      return
    end
  end

  -- Several values returned: one a line. A table and what follows it stay `}, rest`.
  local starts = {}

  for _, comma in marks.commas do
    if comma < #text then table.insert(starts, comma + 1) end
  end

  if value == 8 and #starts > 0 and string.sub(text, 8, 8) ~= '{' then
    for index, part in cut(text, starts) do
      local bare = string.gsub(part, '^%s+', '')
      place(lines, bare, if index == 1 then depth else depth + 1, 'item')
    end

    return
  end

  if #marks.operators > 0 then
    local parts = cut(text, marks.operators)
    local inner = if role == 'expression' then depth else depth + 1
    place(lines, parts[1], depth, role)

    for index = 2, #parts do
      place(lines, parts[index], inner, 'item')
    end

    return
  end

  local group = marks.groups[1]

  if group then
    expand(lines, text, group, depth)
    return
  end

  table.insert(lines, indent .. text)
end

--- `text`, one statement on one line, as the lines it takes at `depth` levels of indentation.
local function wrap(text: string, depth: number): { string }
  local lines: { string } = {}
  place(lines, text, depth, 'statement')
  return lines
end

return table.freeze { Width = Width, wrap = wrap }
