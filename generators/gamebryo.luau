--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Turns `gamebryo_schema.luau` into the multi-version reader's codec modules under
`nif/gamebryo/`: one module per struct in `structs/`, one per record class in `records/`, and
`load.luau`, which requires those on first use:

  jess run --capability filesystem.read --capability filesystem.write \
    generators/gamebryo.luau src/internal/gamebryo

A record class's `read` is one straight-line function over its bases' fields and its own, every
field a local until one table constructor at the end; its `check` is OpenMW's post-load pass:
every link must point to a record of the class it names, then the class's own checks.

What is written is the committed source as it stands, in the repository's Luau style: nothing
formats it afterwards. A reader takes the `stream` and a `cursor`, the position it reads the
stream's `bytes` at, and returns what it read and the cursor after it.

The schema's steps, in reading order:

- `{ name, kind, when?, count?, list?, fixed?, default? }` reads a field. `when` is a Luau
  condition; `count` an element count expression, `list` the type of a count read first
  (`'u32'` or `'u16'`), `fixed` a constant count. A name starting with `_` stays a local; a
  repeated name assigns the same local; a dotted name assigns into a table local.
- `{ name, expr = '...', when? }` computes a field from earlier ones.
- `{ skip = n | 'expr', when? }` skips bytes.
- `{ stop = 'condition' }` stops reading when the condition holds.
- `{ check = 'condition', message = 'template' }` fails unless the condition holds.

A class's `first` steps are read before its base's fields, the most derived class's first; a
`bare` class reads none of its bases' fields, which keep their defaults; `bases` names bases
whose fields are read only when a condition holds, as `{ NiGeometry = 'BV < SSE' }`. `stop`
ends the whole read, so only a class nothing derives from, or a struct, may use it.

Conditions and expressions see `V` (version), `UV` (user version), `BV` (Bethesda version),
`RN` (the record's name), and every earlier field by name; the readers spell those four out, as
`version`, `userVersion`, `bethVersion`, and `recordName`. `@a.b.c.d` is a version;
`FO3`, `SKY`, `SSE`, `FO4`, `F76`, `STF` are Bethesda versions; `VER_MW`, `VER_OB_OLD`,
`VER_OB`, `VER_BGS` are file versions. An expression may also call the reader's modules by the
names it has for them: `Stream`, `Custom`, `ReadStruct`, and `DefaultStruct`.

Kinds: `u8 i8 u16 i16 u32 i32 u64 f32 f16 bool string sstring estring palette vec2 vec3 vec4
quat mat3 sphere`, `link:<Class>` (`link:any` is checked only for its range), `links:<Class>`,
a struct's name, and `custom:<name>(args)`, a function of `nif/gamebryo/custom.luau` taking the
stream, the cursor, and the args, returning the value and the cursor after it. A `link:`
field with a `count`, `list`, or `fixed` is a list of links, checked like `links:`.
]]

local Classes = require '../src/internal/gamebryo/classes'
local Layout = require './layout'
local Schema = require './gamebryo_schema'

-- Each part registers its header's classes and structs.
require './gamebryo/base'
require './gamebryo/node'
require './gamebryo/property'
require './gamebryo/texture'
require './gamebryo/effect'
require './gamebryo/extra'
require './gamebryo/data'
require './gamebryo/controller'
require './gamebryo/physics'
require './gamebryo/particle'

type Step = Schema.Step
type Definition = Schema.Definition

local outDir = ...
if not outDir then error('usage: gamebryo.luau <output folder>', 0) end

--- The names a generated reader gives its own values. A field is read into a local of its own
--- name, so no field may have one of these.
local Reserved: { [string]: boolean } = {
  stream = true,
  bytes = true,
  cursor = true,
  version = true,
  userVersion = true,
  bethVersion = true,
  recordName = true,
  count = true,
  elements = true,
  index = true,
}

local Sizes: { [string]: number } = {
  u8 = 1,
  i8 = 1,
  u16 = 2,
  i16 = 2,
  f16 = 2,
  u32 = 4,
  i32 = 4,
  f32 = 4,
  u64 = 8,
  vec2 = 8,
  vec3 = 12,
  vec4 = 16,
  quat = 16,
  mat3 = 36,
  sphere = 16,
}

--- `Read::MIN_SIZE`, which counts are checked against before reading.
local MinSizes: { [string]: number } = {
  bool = 1,
  string = 4,
  sstring = 4,
  estring = 1,
  palette = 4,
}

--- Element kinds read as array views of the file's bytes (`nif/array.luau`).
local Views: { [string]: string } = {
  u8 = 'u8',
  u16 = 'u16',
  i32 = 'i32',
  f32 = 'f32',
  vec2 = 'vec2',
  vec3 = 'vec3',
  vec4 = 'vec4',
  quat = 'quat',
}

local Constants: { [string]: string } = {
  FO3 = '34',
  SKY = '83',
  SSE = '100',
  FO4 = '130',
  F76 = '155',
  STF = '172',
  VER_MW = '0x04000002',
  VER_OB_OLD = '0x0A000102',
  VER_OB = '0x14000005',
  VER_BGS = '0x14020007',
}

--- What the schema's conditions call the file's versions and the record's name, and the locals a
--- reader keeps them in.
local Words: { [string]: string } = {
  ['V'] = 'version',
  ['UV'] = 'userVersion',
  ['BV'] = 'bethVersion',
  ['RN'] = 'recordName',
}

--- An expression with its versions and constants written out, in the reader's own names.
local function expand(text: string): string
  text = string.gsub(
    text,
    '@(%d+)%.(%d+)%.(%d+)%.(%d+)',
    function(major: string, minor: string, patch: string, revision: string)
      local value = (
        (tonumber(major) :: number * 256 + tonumber(minor) :: number) * 256
        + tonumber(patch) :: number
      )
          * 256
        + tonumber(revision) :: number
      return string.format('0x%08X', value)
    end
  )
  text = string.gsub(
    text,
    '%f[%w_]([%u_%d]+)%f[^%w_]',
    function(word: string) return Constants[word] or Words[word] or word end
  )
  return text
end

--- Lines written so far, the indentation depth, whether a block just closed, so the next
--- statement at its depth needs a blank line before it, and whether one just opened, so the next
--- follows its first line with none.
type Out = { lines: { string }, depth: number, pending: boolean?, opened: boolean? }

local function blank(out: Out)
  local last = out.lines[#out.lines]
  if last and last ~= '' and not out.opened then table.insert(out.lines, '') end
end

--- One statement, broken over several lines when it doesn't fit on one (`layout.luau`); a
--- statement that takes several is set apart like a block.
local function emit(out: Out, line: string)
  if line == '' then
    out.pending = false
    blank(out)
    return
  end

  local wrapped = Layout.wrap(line, out.depth)
  if out.pending or #wrapped > 1 then blank(out) end

  table.move(wrapped, 1, #wrapped, #out.lines + 1, out.lines)
  out.pending, out.opened = #wrapped > 1, false
end

--- Opens a block, after a blank line unless it starts its own block: compound statements are
--- paragraphs, as the Luau style has them.
local function open(out: Out, line: string)
  blank(out)
  local wrapped = Layout.wrap(line, out.depth)
  table.move(wrapped, 1, #wrapped, #out.lines + 1, out.lines)
  out.depth += 1
  out.pending, out.opened = false, true
end

--- Closes a block, or with `else` turns the open `if` block to its other branch.
local function close(out: Out, line: string?)
  out.depth -= 1
  table.insert(out.lines, string.rep('  ', out.depth) .. (line or 'end'))

  if line == 'else' then
    out.depth += 1
    out.pending, out.opened = false, true
  else
    out.pending, out.opened = line == nil or line == 'end', false
  end
end

--- A function that is one statement: on its header's line when it fits there.
local function oneLine(out: Out, header: string, statement: string)
  local whole = `{header} {statement} end`

  if out.depth * 2 + #whole <= Layout.Width then
    emit(out, whole)
    return
  end

  open(out, header)
  emit(out, statement)
  close(out)
end

local function isLink(kind: string): boolean return string.sub(kind, 1, 5) == 'link:' end

local function isLinks(kind: string): boolean return string.sub(kind, 1, 6) == 'links:' end

local function isCustom(kind: string): boolean return string.sub(kind, 1, 7) == 'custom:' end

local function isStruct(kind: string): boolean return Schema.structs[kind] ~= nil end

--- The custom function's name and its argument list, from `custom:name(args)`.
local function customCall(kind: string): (string, string)
  local name, args = string.match(kind, '^custom:([%w_]+)%((.*)%)$')
  if name then return name, if args == '' then '' else ', ' .. expand(args :: string) end

  return string.sub(kind, 8), ''
end

local function minSize(kind: string): number
  if isLink(kind) or isLinks(kind) then return 4 end

  return Sizes[kind]
    or MinSizes[kind]
    or (if isStruct(kind) then Schema.structs[kind].min or 0 else 0)
end

--- The value a field holds when its step doesn't run.
local function default(step: Step): string
  if step.default then return expand(step.default) end

  local kind = step[2] :: string
  if step.count or step.list then
    if Views[kind] then return `Empties.{Views[kind]}` end

    return 'Stream.empty'
  end

  if step.fixed then return 'Stream.empty' end

  if
    Sizes[kind]
    and kind ~= 'vec2'
    and kind ~= 'vec3'
    and kind ~= 'vec4'
    and kind ~= 'quat'
    and kind ~= 'mat3'
    and kind ~= 'sphere'
  then
    return '0'
  end

  if kind == 'bool' then return 'false' end

  if kind == 'string' or kind == 'sstring' or kind == 'estring' or kind == 'palette' then
    return '\'\''
  end

  if kind == 'vec2' or kind == 'vec3' then return 'vector.zero' end

  if kind == 'vec4' then return 'Stream.zero4' end

  if kind == 'quat' then return 'Stream.unitQuat' end

  if kind == 'mat3' then return 'Stream.identity()' end

  if kind == 'sphere' then return 'Stream.noSphere' end

  if isLink(kind) then return '-1' end

  if isLinks(kind) then return 'Stream.empty' end

  if isStruct(kind) then return `DefaultStruct.{kind}()` end

  return 'nil'
end

local function at(offset: number): string
  return if offset == 0 then 'cursor' else `cursor + {offset}`
end

--- A struct of unconditional fixed-size fields as one constructor reading at constant offsets,
--- and its size; nil for any other struct, which is read by a call.
local function inlineStruct(kind: string): (string?, number)
  local definition = Schema.structs[kind]
  if not definition or definition.base then return nil, 0 end

  local parts, offset = {}, 0
  for _, step in definition.fields do
    local name, fieldKind = step[1], step[2]
    if
      not name
      or not fieldKind
      or step.when
      or step.count
      or step.list
      or step.fixed
      or step.expr
      or step.skip
      or step.stop
      or step.check
    then
      return nil, 0
    end

    local function float(extra: number): string
      return `buffer.readf32(bytes, {at(offset + extra)})`
    end

    local value, size
    if
      fieldKind == 'u8'
      or fieldKind == 'i8'
      or fieldKind == 'u16'
      or fieldKind == 'i16'
      or fieldKind == 'u32'
      or fieldKind == 'i32'
      or fieldKind == 'f32'
    then
      value, size = `buffer.read{fieldKind}(bytes, {at(offset)})`, Sizes[fieldKind]
    elseif fieldKind == 'f16' then
      value, size = `buffer.readu16(bytes, {at(offset)})`, 2
    elseif fieldKind == 'vec2' then
      value, size = `vector.create({float(0)}, {float(4)}, 0)`, 8
    elseif fieldKind == 'vec3' then
      value, size = `vector.create({float(0)}, {float(4)}, {float(8)})`, 12
    elseif fieldKind == 'vec4' then
      -- A call, not a constructor: four reads would take a line each.
      value, size = `Stream.vec4(bytes, {at(offset)})`, 16
    elseif fieldKind == 'quat' then
      value, size = `Stream.quat(bytes, {at(offset)})`, 16
    elseif fieldKind == 'mat3' then
      value, size = `Stream.mat3(bytes, {at(offset)})`, 36
    else
      return nil, 0
    end

    if string.sub(name, 1, 1) ~= '_' then table.insert(parts, `{name} = {value}`) end

    offset += size
  end

  return `\{ {table.concat(parts, ', ')} }`, offset
end

--- Whether `expression` reads only the file's versions, which a whole file shares.
local function versionOnly(expression: string): boolean
  local text = string.gsub(expand(expression), '0x%x+', '')
  for word in string.gmatch(text, '[%a_][%w_]*') do
    if
      word ~= 'version'
      and word ~= 'userVersion'
      and word ~= 'bethVersion'
      and word ~= 'and'
      and word ~= 'or'
      and word ~= 'not'
    then
      return false
    end
  end

  return true
end

--- Whether every `kind` struct in a file takes the same bytes: fixed-size fields, read or not by
--- the versions alone. A list of them is read as rows (`Stream.structRows`), each element when it
--- is asked for.
local function versionFixed(kind: string): boolean
  local definition = Schema.structs[kind]
  if not definition or definition.base then return false end

  for _, step in definition.fields do
    if step.count or step.list or step.fixed or step.expr or step.stop or step.check then
      return false
    end

    if step.when and not versionOnly(step.when) then return false end

    if step.skip then
      if type(step.skip) ~= 'number' then return false end

      continue
    end

    local fieldKind = step[2]
    if not fieldKind then return false end

    local fixed = Sizes[fieldKind] ~= nil
      or fieldKind == 'bool'
      or isLink(fieldKind)
      or (isStruct(fieldKind) and (inlineStruct(fieldKind) ~= nil or versionFixed(fieldKind)))
    if not fixed then return false end
  end

  return true
end

local function f32(offset: number): string
  return `buffer.readf32(bytes, {at(offset)})`
end

--- Reads one `kind` value into `target` and moves `cursor` past it.
local function readInto(out: Out, target: string, kind: string)
  local size = Sizes[kind]
  if
    kind == 'u8'
    or kind == 'i8'
    or kind == 'u16'
    or kind == 'i16'
    or kind == 'u32'
    or kind == 'i32'
    or kind == 'f32'
  then
    emit(out, `{target} = buffer.read{kind}(bytes, cursor)`)
    emit(out, `cursor += {size}`)
  elseif kind == 'f16' then
    emit(out, `{target} = buffer.readu16(bytes, cursor)`)
    emit(out, 'cursor += 2')
  elseif kind == 'u64' then
    emit(
      out,
      `{target} = buffer.readu32(bytes, cursor) + buffer.readu32(bytes, cursor + 4) * 4294967296`
    )
    emit(out, 'cursor += 8')
  elseif kind == 'bool' then
    open(out, 'if version < 0x04010000 then')
    emit(out, `{target} = buffer.readi32(bytes, cursor) ~= 0`)
    emit(out, 'cursor += 4')
    close(out, 'else')
    emit(out, `{target} = buffer.readi8(bytes, cursor) ~= 0`)
    emit(out, 'cursor += 1')
    close(out)
  elseif kind == 'string' then
    -- The string table, from 20.1.0.1, inline: most strings in later files.
    open(out, 'if version >= 0x14010001 then')
    local index = 'buffer.readu32(bytes, cursor)'
    emit(out, `{target} = stream.strings[{index} + 1] or Stream.stringIndex(stream, {index})`)
    emit(out, 'cursor += 4')
    close(out, 'else')
    emit(out, `{target}, cursor = Stream.sizedU32(stream, cursor)`)
    close(out)
  elseif kind == 'sstring' then
    emit(out, `{target}, cursor = Stream.sizedU32(stream, cursor)`)
  elseif kind == 'estring' then
    emit(out, `{target}, cursor = Stream.export(stream, cursor)`)
  elseif kind == 'palette' then
    emit(out, `{target}, cursor = Stream.palette(stream, cursor)`)
  elseif kind == 'vec2' then
    emit(out, `{target} = vector.create({f32(0)}, {f32(4)}, 0)`)
    emit(out, 'cursor += 8')
  elseif kind == 'vec3' then
    emit(out, `{target} = vector.create({f32(0)}, {f32(4)}, {f32(8)})`)
    emit(out, 'cursor += 12')
  elseif kind == 'vec4' then
    emit(out, `{target} = \{ {f32(0)}, {f32(4)}, {f32(8)}, {f32(12)} }`)
    emit(out, 'cursor += 16')
  elseif kind == 'quat' then
    emit(out, `{target} = \{ {f32(4)}, {f32(8)}, {f32(12)}, {f32(0)} }`)
    emit(out, 'cursor += 16')
  elseif kind == 'mat3' then
    emit(out, `{target} = Stream.mat3(bytes, cursor)`)
    emit(out, 'cursor += 36')
  elseif kind == 'sphere' then
    emit(
      out,
      `{target} = \{ center = vector.create({f32(0)}, {f32(4)}, {f32(8)}), radius = {f32(12)} }`
    )
    emit(out, 'cursor += 16')
  elseif isLink(kind) then
    emit(out, `{target} = buffer.readi32(bytes, cursor)`)
    emit(out, 'cursor += 4')
    emit(out, `if {target} < -1 then Stream.invalidLink({target}) end`)
  elseif isLinks(kind) then
    open(out, 'do')
    emit(out, 'local count = buffer.readu32(bytes, cursor)')
    emit(out, 'cursor += 4')
    emit(out, `{target} = Stream.links(stream, cursor, count)`)
    emit(out, 'cursor += count * 4')
    close(out)
  elseif isStruct(kind) then
    local inline, size = inlineStruct(kind)
    if inline then
      emit(out, `{target} = {inline}`)
      emit(out, `cursor += {size}`)
    else
      emit(out, `{target}, cursor = ReadStruct.{kind}(stream, cursor)`)
    end
  elseif isCustom(kind) then
    local name, args = customCall(kind)
    emit(out, `{target}, cursor = Custom.{name}(stream, cursor{args})`)
  else
    error(`no reader for kind {kind}`)
  end
end

--- Reads `count` elements of `kind` into `target`.
local function readArray(out: Out, target: string, kind: string, count: string, checked: boolean)
  -- Views are most of a mesh, so they're made here, without `checkSize` and `Stream.view` as
  -- calls: the bounds check covers both, and `Stream.viewFail` tells them apart for the message.
  local view = Views[kind]
  if view then
    local size = Sizes[kind]
    local fail = `Stream.viewFail(stream, cursor, {count}, '{view}', {size}, {checked})`
    local made = `\{ buffer = bytes, offset = cursor, count = {count}, stride = {size} }`
    emit(out, `if cursor + {count} * {size} > stream.length then {fail} end`)
    emit(
      out,
      `{target} = if {count} == 0 then Empties.{view} else setmetatable({made}, Metas.{view})`
    )
    emit(out, `cursor += {count} * {size}`)
    return
  end

  if checked and minSize(kind) > 0 then
    emit(out, `Stream.checkSize(stream, {count} * {minSize(kind)})`)
  end

  -- Fixed-size structs are read when an element is asked for, not here (`nif/gamebryo/rows.luau`).
  if isStruct(kind) then
    local inline, size = inlineStruct(kind)
    if inline then
      emit(
        out,
        `{target}, cursor = Stream.rows(stream, cursor, {count}, {size}, StructRow.{kind})`
      )
      return
    end

    if versionFixed(kind) then
      emit(
        out,
        `{target}, cursor = Stream.structRows(stream, cursor, {count}, ReadStruct.{kind})`
      )
      return
    end
  end

  -- `elements`, not `list`, which a field may be called.
  open(out, 'do')
  emit(out, `local elements = table.create({count})`)
  open(out, `for index = 1, {count} do`)
  readInto(out, 'elements[index]', kind)
  close(out)
  emit(out, `{target} = elements`)
  close(out)
end

local function readStep(out: Out, step: Step)
  local name = step[1] :: string
  local kind = step[2]
  if step.expr then
    emit(out, `{name} = {expand(step.expr)}`)
    return
  end

  assert(kind, `step {name} has no kind`)
  if step.list then
    open(out, 'do')
    local reader = if step.list == 'u16' then 'readu16' else 'readu32'
    emit(out, `local count = buffer.{reader}(bytes, cursor)`)
    emit(out, `cursor += {if step.list == 'u16' then 2 else 4}`)
    readArray(out, name, kind, 'count', true)
    close(out)
  elseif step.count then
    open(out, 'do')
    emit(out, `local count = {expand(step.count)}`)
    readArray(out, name, kind, 'count', true)
    close(out)
  elseif step.fixed then
    readArray(out, name, kind, tostring(step.fixed), false)
  else
    readInto(out, name, kind)
  end
end

--- The fields a definition stores and the locals it reads into, bases first.
local function flatten(definition: Definition, classes: boolean): { Step }
  local chain, names = { definition }, { '' }
  local base = definition.base
  while base do
    local parent = (if classes then Schema.classes[base] else Schema.structs[base]) :: Definition
    assert(parent, `unknown base {base}`)
    table.insert(chain, 1, parent)
    table.insert(names, 1, base)
    base = parent.base
  end

  local conditions: { [string]: string } = {}
  for _, link in chain do
    for name, condition in link.bases or {} do
      conditions[name] = condition
    end
  end

  local steps, bare = {}, 0
  for level = #chain, 1, -1 do
    for _, step in chain[level].first or {} do
      table.insert(steps, step)
    end

    if chain[level].bare and bare == 0 then bare = level end
  end

  for level, link in chain do
    local condition = conditions[names[level]]
    for _, step in link.fields do
      if condition then
        assert(not step.stop and not step.check, `{names[level]}'s fields can't be conditional`)
        step = table.clone(step)
        step.when = if step.when then `({condition}) and ({step.when})` else condition
      end

      if level < bare then
        local unread = table.clone(step)
        unread.unread = true
        table.insert(steps, unread)
      else
        table.insert(steps, step)
      end
    end
  end

  return steps
end

--- Declares each local once, with its default, in first-seen order; returns the stored names.
--- Conditional steps whose field gets its default in an `else` branch, when the step doesn't run.
local ElseDefault: { [Step]: boolean } = {}

local function declare(out: Out, steps: { Step }): { string }
  local seen, stored, uses = {}, {}, {}
  for _, step in steps do
    local name = step[1]
    if name then uses[name] = (uses[name] or 0) + 1 end
  end

  local empties: { string } = {}
  local function flush()
    if #empties == 0 then return end

    emit(out, `local {table.concat(empties, ', ')} = {string.rep('{}, ', #empties - 1)}\{}`)
    table.clear(empties)
  end

  local stopped = false
  for _, step in steps do
    if step.stop then stopped = true end

    local name = step[1]
    if not name or seen[name] or string.find(name, '.', 1, true) then continue end

    if Reserved[name] then
      error(`the field {name} has a name the readers keep for themselves`, 0)
    end

    seen[name] = true
    -- A default is built only when the field isn't read: a field every read assigns needs none,
    -- and a field one conditional step assigns gets it in that step's `else`.
    local always = not stopped and not step.when and not step.unread
    local otherwise = not stopped and step.when ~= nil and not step.unread and uses[name] == 1
    if otherwise then ElseDefault[step] = true end

    local value = if always or otherwise then nil else default(step)

    -- Empty tables declared next to each other share a statement, as the style has them.
    if value ~= '{}' then flush() end

    if value == '{}' then
      table.insert(empties, name)
    else
      emit(out, if value then `local {name} = {value}` else `local {name}`)
    end

    if string.sub(name, 1, 1) ~= '_' then table.insert(stored, name) end
  end

  flush()
  return stored
end

local function emitSteps(out: Out, steps: { Step })
  local depth = 0
  for _, step in steps do
    if step.unread then continue end

    if step.stop then
      open(out, `if not ({expand(step.stop)}) then`)
      depth += 1
      continue
    end

    if step.check then
      -- A message that names nothing is a plain string.
      local message = step.message :: string
      local quoted = if string.find(message, '{', 1, true) then `\`{message}\`` else `'{message}'`
      emit(out, `if not ({expand(step.check)}) then Stream.fail({quoted}) end`)
      continue
    end

    local when = step.when and expand(step.when)
    if when then open(out, `if {when} then`) end

    if step.skip then
      local length = if type(step.skip) == 'number'
        then tostring(step.skip)
        else expand(step.skip :: string)
      emit(out, `cursor = Stream.skip(stream, cursor, {length})`)
    else
      readStep(out, step)
    end

    if when and ElseDefault[step] then
      close(out, 'else')
      emit(out, `{step[1]} = {default(step)}`)
    end

    if when then close(out) end
  end

  for _ = 1, depth do
    close(out)
  end
end

--- What every reader starts with: the stream's bytes and versions, in locals.
local Versions = 'local bytes, version, userVersion, bethVersion = '
  .. 'stream.bytes, stream.version, stream.userVersion, stream.bethVersion'

local function emitReader(
  out: Out,
  header: string,
  definition: Definition,
  classes: boolean,
  typeName: boolean
)
  local steps = flatten(definition, classes)
  open(out, header)
  emit(out, Versions)
  if typeName then emit(out, 'local recordName = stream.recordName') end

  local stored = declare(out, steps)
  emitSteps(out, steps)
  local parts = if typeName then { 'type = recordName' } else {}
  for _, name in stored do
    table.insert(parts, `{name} = {name}`)
  end

  emit(out, '')
  emit(out, `return \{ {table.concat(parts, ', ')} }, cursor`)
  close(out)
end

--- The links a class holds and the checks OpenMW runs after loading, bases first.
local function emitCheck(out: Out, definition: Definition)
  local steps = flatten(definition, true)
  local chain = { definition }
  local base = definition.base
  while base do
    table.insert(chain, 1, Schema.classes[base])
    base = Schema.classes[base].base
  end

  local header =
    'local function check(record: any, records: { any }, classes: { string }, index: number)'
  local body: Out = { lines = {}, depth = out.depth + 1 }
  local seen, anyLinks = {}, {}
  for _, step in steps do
    local name, kind = step[1], step[2]
    if not name or not kind or seen[name] or string.sub(name, 1, 1) == '_' then continue end

    seen[name] = true
    if kind == 'link:any' then
      -- Checked in `post`, after the links of a class.
      table.insert(anyLinks, name)
    elseif isLink(kind) and (step.count or step.list or step.fixed) then
      -- Most lists and links are empty or -1: those cost a test, not a call.
      open(body, `if #record.{name} > 0 then`)
      emit(body, `Links.links(record.{name}, '{string.sub(kind, 6)}', records, classes, index)`)
      close(body)
    elseif isLink(kind) then
      open(body, `if record.{name} >= 0 then`)
      emit(body, `Links.link(record.{name}, '{string.sub(kind, 6)}', records, classes, index)`)
      close(body)
    elseif isLinks(kind) then
      open(body, `if #record.{name} > 0 then`)
      emit(body, `Links.links(record.{name}, '{string.sub(kind, 7)}', records, classes, index)`)
      close(body)
    end
  end

  for _, name in anyLinks do
    emit(body, `Links.any(record.{name}, records)`)
  end

  for _, link in chain do
    for _, post in link.post or {} do
      emit(body, `Custom.{post}(record, records, classes, index)`)
    end
  end

  -- A class with nothing to check has a function with nothing in it, on one line.
  if #body.lines == 0 then
    emit(out, `{header} end`)
    return
  end

  open(out, header)
  table.move(body.lines, 1, #body.lines, #out.lines + 1, out.lines)
  out.opened = false
  close(out)
end

local Header = {
  '--!strict',
  '--!native',
  '-- SPDX-License-Identifier: MIT OR Apache-2.0',
  '-- @generated by generators/gamebryo.luau from generators/gamebryo_schema.luau. Do not edit.',
  '',
}

local function sorted(map: { [string]: any }): { string }
  local list = {}
  for key in map do
    table.insert(list, key)
  end

  table.sort(list)
  return list
end

--- The three tables a module reaches structs through, and what each holds of a struct's module.
local StructTables = {
  { 'ReadStruct', 'read' },
  { 'DefaultStruct', 'default' },
  { 'StructRow', 'rows' },
}

--- A module one folder below the reader's: the header, the requires and locals `body` uses, in
--- one order everywhere, and the body. A struct is a module of its own, required by each module
--- that reads it, so a file compiles the structs its records hold and no others; `structs` is
--- where those modules are, from this one.
local function moduleText(body: { string }, structs: string): string
  local text = table.concat(body, '\n')
  local out = table.clone(Header)
  local function uses(name: string): boolean
    return string.find(text, `%f[%w_]{name}%f[^%w_]`) ~= nil
  end

  local views = uses 'Empties' and uses 'Metas'
  if views then table.insert(out, 'local Array = require \'../../array\'') end

  if uses 'Custom' then table.insert(out, 'local Custom = require \'../custom\'') end

  if uses 'Stream' or uses 'Empties' then
    table.insert(out, 'local Stream = require \'../stream\'')
  end

  if uses 'Links' then table.insert(out, 'local Links = require \'../links\'') end

  -- Each struct the body names through one of the tables, and each table's entries.
  local required: { [string]: boolean } = {}
  local tables: { string } = {}
  for _, entry in StructTables do
    local items, seen = {}, {}
    for name in string.gmatch(text, `%f[%w_]{entry[1]}%.([%w_]+)`) do
      if seen[name] then continue end

      if string.find(text, `%f[%w_]local {name}%f[^%w_]`) then
        error(`a reader of struct {name} has a local of that name`, 0)
      end

      seen[name], required[name] = true, true
      table.insert(items, name)
    end

    table.sort(items)
    for index, name in items do
      items[index] = `{name} = {name}.{entry[2]}`
    end

    if #items > 0 then
      table.insert(tables, `local {entry[1]} = \{ {table.concat(items, ', ')} }`)
    end
  end

  for _, name in sorted(required) do
    table.insert(out, `local {name} = require '{structs}{name}'`)
  end

  if views then
    table.insert(out, 'local Empties, Metas = Array.empty, Array.metas')
  elseif uses 'Empties' then
    table.insert(out, 'local Empties = require(\'../../array\').empty')
  end

  for _, line in tables do
    local wrapped = Layout.wrap(line, 0)
    -- A table that takes several lines is a paragraph of its own.
    if #wrapped > 1 and out[#out] ~= '' then table.insert(out, '') end

    table.move(wrapped, 1, #wrapped, #out + 1, out)
    if #wrapped > 1 then table.insert(out, '') end
  end

  if out[#out] ~= '' then table.insert(out, '') end

  table.move(body, 1, #body, #out + 1, out)
  return table.concat(out, '\n') .. '\n'
end

--- One struct's module: its reader, its default, and, for a struct of fixed-size fields, the
--- constructor that reads one row of a list of them.
local function structModule(name: string): string
  local definition = Schema.structs[name]
  local out: Out = { lines = {}, depth = 0 }
  emitReader(
    out,
    'local function read(stream: Stream.Stream, cursor: number): (any, number)',
    definition,
    false,
    false
  )
  emit(out, '')
  local parts, seen = {}, {}
  for _, step in flatten(definition, false) do
    local field = step[1]
    if
      not field
      or seen[field]
      or string.sub(field, 1, 1) == '_'
      or string.find(field, '.', 1, true)
    then
      continue
    end

    seen[field] = true
    table.insert(parts, `{field} = {default(step)}`)
  end

  -- The reader is read-only, so a struct's default is one frozen table, made when first used.
  emit(out, 'local shared')
  emit(out, '')
  open(out, 'local function default(): any')
  emit(out, 'if shared then return shared end')
  emit(out, '')
  emit(out, `shared = table.freeze(\{ {table.concat(parts, ', ')} })`)
  emit(out, 'return shared')
  close(out)
  local exports = 'read = read, default = default'
  local inline = inlineStruct(name)
  if inline then
    emit(out, '')
    oneLine(out, 'local function rows(bytes: buffer, cursor: number): any', `return {inline}`)
    exports ..= ', rows = rows'
  end

  emit(out, '')
  emit(out, `return table.freeze \{ {exports} }`)
  return moduleText(out.lines, './')
end

local function recordModule(class: string): string
  local definition = Schema.classes[class]
  local out: Out = { lines = {}, depth = 0 }
  emitReader(
    out,
    'local function read(stream: Stream.Stream, cursor: number): (any, number)',
    definition,
    true,
    true
  )
  emit(out, '')
  emitCheck(out, definition)
  emit(out, '')
  emit(out, 'return table.freeze { read = read, check = check }')
  return moduleText(out.lines, '../structs/')
end

local concrete = {}
for _, entry in Classes.factory do
  concrete[entry[1]] = true
end

--- Writes `texts`, by module name, as the modules of `folder`, and removes any other file there.
local function writeModules(folder: string, texts: { [string]: string })
  if not jess.fs.isDir(folder) then jess.fs.createDir(folder) end

  for name, text in texts do
    jess.fs.write(jess.fs.join(folder, `{name}.luau`), text)
  end

  for _, file in jess.fs.list(folder) do
    if not texts[string.sub(file, 1, -6)] then jess.fs.remove(jess.fs.join(folder, file)) end
  end
end

local structs: { [string]: string } = {}
for _, name in sorted(Schema.structs) do
  structs[name] = structModule(name)
end

writeModules(jess.fs.join(outDir, 'structs'), structs)
local written, missing = 0, {}
for _, class in sorted(concrete) do
  if not Schema.classes[class] then
    table.insert(missing, class)
    continue
  end

  jess.fs.write(jess.fs.join(outDir, 'records', `{class}.luau`), recordModule(class))
  written += 1
end

local load = table.clone(Header)
table.insert(load, 'local Requires = {')
for _, class in sorted(concrete) do
  if not Schema.classes[class] then continue end

  local line = `  {class} = function() return require './records/{class}' end,`
  if #line <= Layout.Width then
    table.insert(load, line)
    continue
  end

  -- Too long for one line, so it is a paragraph of its own.
  if load[#load] ~= '' then table.insert(load, '') end

  table.insert(load, `  {class} = function()`)
  table.insert(load, `    return require './records/{class}'`)
  table.insert(load, '  end,')
  table.insert(load, '')
end

for _, line in
  {
    '}',
    '',
    '--- Each record class\'s codec, required the first time a record of it is read.',
    'local Codecs = setmetatable({}, {',
    '  __index = function(codecs, class)',
    '    local codec = Requires[class]',
    '    if not codec then return nil end',
    '',
    '    local loaded = codec()',
    '    rawset(codecs, class, loaded)',
    '    return loaded',
    '  end,',
    '})',
    '',
    'return Codecs',
  }
do
  table.insert(load, line)
end

jess.fs.write(jess.fs.join(outDir, 'load.luau'), table.concat(load, '\n') .. '\n')
print(`wrote structs/, load, and {written} record classes; {#missing} classes have no schema yet`)