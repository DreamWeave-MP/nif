--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Turns `schema.luau` into the codec modules under `nif/`: each type's scanner in `scans/` and
`scan.luau` to require it on first use, the structs' readers in `structs.luau` and their writers
in `struct_writes.luau`, each record type's reader in `records/`, its `fill` in `fills/`, and its
writer and link collector in `writes/`, `load.luau` and `codec.luau` to require those on first
use, `enums.luau`, and `types.luau`:

  jess run --capability filesystem.read --capability filesystem.write \
    generators/generate.luau src/internal

For every record and struct there are four straight-line functions: `scan` walks past its fields
collecting the links, `read` decodes them into one table, `write` encodes a table, and `links`
collects the links of a decoded one. A record's read, write, and links cover its bases' fields
too, so runs of fixed-size fields are read and written at constant offsets from one position and
native code checks their bounds once. None of them loads with the package. A type's scanner
compiles the first time a file that holds the type is opened, its reader the first time one is
decoded, and its `fill`, and its `write` and `links`, the first time each is used: compiling is
most of what the first use of a type costs.

What is written is the committed source as it stands, in the repository's Luau style: nothing
formats it afterwards. The generated code reads `bytes` at `cursor`, writes through `writer`
(whose buffer, position, and length it keeps in `bytes`, `cursor`, and `capacity`), and collects
links into `links`, `linkCount` of them so far.
]]

local Layout = require './layout'
local Schema = require './schema'

type Field = Schema.Field
type Definition = Schema.Definition

local outDir = ...
if not outDir then error('usage: generate.luau <output folder>', 0) end

--- The names the generated functions give their own values. A field is read into a local of its
--- own name, so no field of a record or of a struct read by a function may have one of these.
local Reserved: { [string]: boolean } = {
  bytes = true,
  cursor = true,
  capacity = true,
  writer = true,
  record = true,
  struct = true,
  links = true,
  linkCount = true,
  map = true,
  into = true,
  typeName = true,
  index = true,
}

local Sizes: { [string]: number } = {
  u8 = 1,
  bool8 = 1,
  u16 = 2,
  i16 = 2,
  u32 = 4,
  i32 = 4,
  f32 = 4,
  link = 4,
  vec2 = 8,
  vec3 = 12,
  vec4 = 16,
  quat = 16,
  mat2 = 16,
  mat3 = 36,
  tri = 6,
  u16f32 = 6,
  f32x2 = 8,
  u32x3 = 12,
  u8x4 = 4,
}

local Scalars: { [string]: string } = {
  u8 = 'u8',
  bool8 = 'u8',
  u16 = 'u16',
  i16 = 'i16',
  u32 = 'u32',
  i32 = 'i32',
  f32 = 'f32',
}

--- Structs of fixed-size fields and no links, by size: read and written in place, not by a call.
local Inline: { [string]: number } = {}

local function sizeOf(kind: string): number?
  if string.sub(kind, 1, 5) == 'enum:' then return 4 end

  return Sizes[kind] or Inline[kind]
end

do
  local changed = true
  while changed do
    changed = false
    for name, definition in Schema.Structs do
      if Inline[name] then continue end

      local size = 0
      for _, field in definition.fields do
        local kind = field[2]
        local each = kind and kind ~= 'link' and sizeOf(kind)
        if
          not each
          or string.sub(field[1], 1, 1) == '_'
          or field.when
          or field.list
          or field.count
        then
          size = -1
          break
        end

        size += each * (field.fixed or 1)
      end

      if size > 0 then
        Inline[name] = size
        changed = true
      end
    end
  end
end

local function at(offset: number): string
  if offset == 0 then return 'cursor' end

  return `cursor + {offset}`
end

local function f32(offset: number): string return `buffer.readf32(bytes, {at(offset)})` end

local function vec3(offset: number): string
  return `vector.create({f32(offset)}, {f32(offset + 4)}, {f32(offset + 8)})`
end

--- The expression reading one `kind` element at `offset` past `cursor`. `inList` keeps a null link
--- as -1, so lists stay dense.
local function readElement(kind: string, offset: number, inList: boolean?): string
  if Inline[kind] then
    local parts, position = {}, offset
    for _, field in Schema.Structs[kind].fields do
      local fieldKind = field[2] :: string
      local each = sizeOf(fieldKind) :: number
      local value = readElement(fieldKind, position)
      if field.fixed then
        local elements = {}
        for index = 0, field.fixed - 1 do
          table.insert(elements, readElement(fieldKind, position + index * each))
        end

        value = `\{ {table.concat(elements, ', ')} }`
      end

      table.insert(parts, `{field[1]} = {value}`)
      position += each * (field.fixed or 1)
    end

    return `\{ {table.concat(parts, ', ')} }`
  end

  local scalar = Scalars[kind]
  if kind == 'bool8' then return `buffer.readu8(bytes, {at(offset)}) ~= 0` end

  if scalar then return `buffer.read{scalar}(bytes, {at(offset)})` end

  if string.sub(kind, 1, 5) == 'enum:' then
    -- Read twice rather than call: the second load shares the first's bounds check.
    local read = `buffer.readi32(bytes, {at(offset)})`
    return `Names.{string.sub(kind, 6)}[{read}] or {read}`
  end

  if kind == 'link' then
    if inList then return `buffer.readi32(bytes, {at(offset)})` end

    -- Raw: the record's constructor turns a negative index into nil.
    return `buffer.readi32(bytes, {at(offset)})`
  end

  if kind == 'vec2' then return `vector.create({f32(offset)}, {f32(offset + 4)}, 0)` end

  if kind == 'vec3' then return vec3(offset) end

  if kind == 'vec4' or kind == 'mat2' then
    return `\{ {f32(offset)}, {f32(offset + 4)}, {f32(offset + 8)}, {f32(offset + 12)} }`
  end

  if kind == 'quat' then
    return `\{ {f32(offset + 4)}, {f32(offset + 8)}, {f32(offset + 12)}, {f32(offset)} }`
  end

  if kind == 'mat3' then return `Custom.readMat3(bytes, {at(offset)})` end

  if kind == 'tri' then
    local function u16(extra: number): string
      return `buffer.readu16(bytes, {at(offset + extra)})`
    end

    return `vector.create({u16(0)}, {u16(2)}, {u16(4)})`
  end

  if kind == 'u16f32' then
    local index, weight = `buffer.readu16(bytes, {at(offset)})`, f32(offset + 2)
    return `vector.create({index}, {weight}, 0)`
  end

  if kind == 'f32x2' then return `\{ {f32(offset)}, {f32(offset + 4)} }` end

  if kind == 'u32x3' then
    local function u32(extra: number): string
      return `buffer.readu32(bytes, {at(offset + extra)})`
    end

    return `\{ {u32(0)}, {u32(4)}, {u32(8)} }`
  end

  if kind == 'u8x4' then
    local function u8(extra: number): string
      return `buffer.readu8(bytes, {at(offset + extra)})`
    end

    return `\{ {u8(0)}, {u8(1)}, {u8(2)}, {u8(3)} }`
  end

  error(`no element reader for {kind}`)
end

--- The check that flags the writer when a float in `value` is NaN, so the save puts back the
--- source's NaN bits (`restoreNans` in `init.luau`); nil for kinds without floats.
local function nanCheck(kind: string, value: string): string?
  local parts: { string } = {}
  if kind == 'f32' then
    parts = { value }
  elseif kind == 'vec2' or kind == 'vec3' then
    parts = { value }
  elseif kind == 'vec4' or kind == 'quat' or kind == 'mat2' then
    parts = { `{value}[1]`, `{value}[2]`, `{value}[3]`, `{value}[4]` }
  elseif kind == 'mat3' then
    parts = { `{value}1`, `{value}2`, `{value}3` }
  elseif kind == 'u16f32' then
    parts = { `{value}.y` }
  elseif kind == 'f32x2' then
    parts = { `{value}[1]`, `{value}[2]` }
  else
    return nil
  end

  local tests = [for part in parts => `{part} ~= {part}`]
  return `if {table.concat(tests, ' or ')} then writer.nan = true end`
end

--- The statements writing `value` as one `kind` element at `offset` past `cursor`.
local function writeElement(kind: string, value: string, offset: number): { string }
  if Inline[kind] then
    local lines, position = {}, offset
    for _, field in Schema.Structs[kind].fields do
      local fieldKind = field[2] :: string
      local each = sizeOf(fieldKind) :: number
      local part = value .. string.upper(string.sub(field[1], 1, 1)) .. string.sub(field[1], 2)
      local annotation = if fieldKind == 'vec3' then ': vector' else ''
      table.insert(lines, `local {part}{annotation} = {value}.{field[1]}`)
      for index = 0, (field.fixed or 1) - 1 do
        local element = if field.fixed then `{part}[{index + 1}]` else part
        for _, line in writeElement(fieldKind, element, position + index * each) do
          table.insert(lines, line)
        end

        local check = nanCheck(fieldKind, element)
        if check then table.insert(lines, check) end
      end

      position += each * (field.fixed or 1)
    end

    return lines
  end

  local scalar = Scalars[kind]
  if kind == 'bool8' then
    return { `buffer.writeu8(bytes, {at(offset)}, if {value} then 1 else 0)` }
  end

  if scalar then return { `buffer.write{scalar}(bytes, {at(offset)}, {value})` } end

  if string.sub(kind, 1, 5) == 'enum:' then
    -- A known name is one lookup; a number, or an unknown name to report, takes the call.
    local values = `Values.{string.sub(kind, 6)}`
    local number = `{values}[{value}] or Custom.enumValue({values}, {value})`
    return { `buffer.writei32(bytes, {at(offset)}, {number})` }
  end

  if kind == 'link' then
    local saved = `if {value} and {value} >= 0 then map[{value}] or -1 else -1`
    return { `buffer.writei32(bytes, {at(offset)}, {saved})` }
  end

  local lines = {}
  local function put(write: string, extra: number, part: string)
    table.insert(lines, `buffer.write{write}(bytes, {at(offset + extra)}, {part})`)
  end

  if kind == 'vec2' then
    put('f32', 0, `{value}.x`)
    put('f32', 4, `{value}.y`)
  elseif kind == 'vec3' then
    -- `value` is a local annotated `vector`, so native code lowers this to three stores.
    table.insert(lines, `{value}:writef32x3(bytes, {at(offset)})`)
  elseif kind == 'vec4' or kind == 'mat2' then
    for index = 1, 4 do
      put('f32', (index - 1) * 4, `{value}[{index}]`)
    end
  elseif kind == 'quat' then
    put('f32', 0, `{value}[4]`)
    for index = 1, 3 do
      put('f32', index * 4, `{value}[{index}]`)
    end
  elseif kind == 'mat3' then
    for row = 1, 3 do
      table.insert(lines, `local {value}{row}: vector = {value}[{row}]`)
      table.insert(lines, `{value}{row}:writef32x3(bytes, {at(offset + (row - 1) * 12)})`)
    end
  elseif kind == 'tri' then
    put('u16', 0, `{value}.x`)
    put('u16', 2, `{value}.y`)
    put('u16', 4, `{value}.z`)
  elseif kind == 'u16f32' then
    put('u16', 0, `{value}.x`)
    put('f32', 2, `{value}.y`)
  elseif kind == 'f32x2' then
    put('f32', 0, `{value}[1]`)
    put('f32', 4, `{value}[2]`)
  elseif kind == 'u32x3' then
    for index = 1, 3 do
      put('u32', (index - 1) * 4, `{value}[{index}]`)
    end
  elseif kind == 'u8x4' then
    for index = 1, 4 do
      put('u8', index - 1, `{value}[{index}]`)
    end
  else
    error(`no element writer for {kind}`)
  end

  return lines
end

--- Source text with indentation. A block, and a statement too long for one line, gets a blank line
--- before and after it: the room the style gives compound statements.
type Out = {
  lines: { string },
  depth: number,
  --- A block just closed: the next line gets a blank line before it.
  pending: boolean,
  --- A block just opened: its first line follows the opening with no blank line.
  opened: boolean?,
}

local function blank(out: Out)
  local last = out.lines[#out.lines]
  if last and last ~= '' then table.insert(out.lines, '') end
end

--- One statement, broken over several lines when it doesn't fit on one (`layout.luau`).
local function emit(out: Out, line: string)
  if line == '' then
    out.pending = false
    blank(out)
    return
  end

  local wrapped = Layout.wrap(line, out.depth)

  if #wrapped > 1 then
    if not out.opened then blank(out) end

    table.move(wrapped, 1, #wrapped, #out.lines + 1, out.lines)
    out.pending, out.opened = true, false
    return
  end

  if out.pending then
    out.pending = false
    blank(out)
  end

  table.insert(out.lines, wrapped[1])
  out.opened = false
end

--- A statement set apart like a block, whatever its length.
local function spaced(out: Out, line: string)
  out.pending = false
  if not out.opened then blank(out) end

  emit(out, line)
  out.pending = true
end

local function open(out: Out, line: string)
  out.pending = false
  if not out.opened then blank(out) end

  local wrapped = Layout.wrap(line, out.depth)
  table.move(wrapped, 1, #wrapped, #out.lines + 1, out.lines)
  out.depth += 1
  out.opened = true
end

--- Switches the open `if` block to its `else` branch.
local function otherwise(out: Out)
  out.pending = false
  table.insert(out.lines, string.rep('  ', out.depth - 1) .. 'else')
  out.opened = true
end

local function close(out: Out, line: string?)
  out.depth -= 1
  table.insert(out.lines, string.rep('  ', out.depth) .. (line or 'end'))
  out.pending, out.opened = true, false
end

--- A function that is one statement: on its header's line when it fits there.
local function oneLine(out: Out, header: string, statement: string)
  local whole = `{header} {statement} end`

  if out.depth * 2 + #whole <= Layout.Width then
    spaced(out, whole)
    return
  end

  open(out, header)
  emit(out, statement)
  close(out)
end

local function isStruct(kind: string): boolean return Schema.Structs[kind] ~= nil end

local function isCustom(kind: string): boolean return string.sub(kind, 1, 7) == 'custom:' end

local function customName(kind: string): string return string.sub(kind, 8) end

local function isHidden(field: Field): boolean return string.sub(field[1], 1, 1) == '_' end

--- Lists of these are array views of the file's bytes (`array.luau`), not tables.
local ArrayKinds: { [string]: boolean } = {
  u8 = true,
  u16 = true,
  i32 = true,
  f32 = true,
  vec2 = true,
  vec3 = true,
  vec4 = true,
  quat = true,
  tri = true,
  u16f32 = true,
  f32x2 = true,
  u32x3 = true,
  u8x4 = true,
  link = true,
}

--- The array kind a list of `kind` reads as: links are their raw i32 indices, -1 for null.
local function arrayKind(kind: string): string return if kind == 'link' then 'i32' else kind end

local function isArray(field: Field): boolean
  return (field.list ~= nil or field.count ~= nil) and ArrayKinds[field[2] :: string] == true
end

--- A field is fixed-size when it sits in a run of constant offsets: one element, or `fixed` of
--- them, with no condition.
local function fixedSize(field: Field): number?
  local kind = field[2]
  if not kind or field.when or field.list or field.count then return nil end

  local size = sizeOf(kind)
  if not size then return nil end

  return size * (field.fixed or 1)
end

--- Whether a field from `from` on names `name` in an expression: its count, its scanner's count,
--- its condition, value, or arguments.
local function referenced(name: string, fields: { Field }, from: number): boolean
  local pattern = `%f[%w_]{name}%f[^%w_]`
  for index = from, #fields do
    local field = fields[index]
    local sources = { field.count, field.scanCount, field.when, field.expr, field.args }
    for _, source in sources do
      if string.find(source, pattern) then return true end
    end
  end

  return false
end

local function hasLinks(definition: Definition, seen: { [string]: boolean }?): boolean
  local visited: { [string]: boolean } = seen or {}
  for _, field in definition.fields do
    local kind = field[2]
    if kind == 'link' or kind == 'custom:textureMaps' or kind == 'custom:textureSource' then
      return true
    end

    if kind and isStruct(kind) and not visited[kind] then
      visited[kind] = true
      if hasLinks(Schema.Structs[kind], visited) then return true end
    end
  end

  return false
end

-- Reading.

--- Refuses a field the generated functions would mistake for one of their own values.
local function checkNames(owner: string, fields: { Field })
  for _, field in fields do
    if Reserved[field[1]] then
      error(`{owner}'s field {field[1]} has a name the generated code keeps for itself`, 0)
    end
  end
end

--- A record's fields and its bases', root first; a struct's own.
local function flatten(definition: Definition): { Field }
  local chain = { definition }
  while chain[1].base do
    local base = chain[1].base :: string
    local found
    for _, entry in Schema.Records do
      if entry.name == base then found = entry.definition end
    end

    table.insert(chain, 1, found or error(`unknown base {base}`))
  end

  local fields, seen = {}, {}
  for _, link in chain do
    for _, field in link.fields do
      if seen[field[1]] then error(`field {field[1]} appears twice in one record`) end

      seen[field[1]] = true
      table.insert(fields, field)
    end
  end

  return fields
end

--- Reads every field into a local, then builds the record in one constructor, so its table is
--- sized once. `typed` puts the type name, the reader's third argument, in it. `fill` writes the
--- fields into `into` instead, refilling the array views, matrices, and structs it already holds,
--- so reading many records allocates little.
local function emitRead(out: Out, fields: { Field }, typed: boolean, fill: boolean?)
  local offset = 0
  local function flush()
    if offset == 0 then return end

    emit(out, `cursor += {offset}`)
    offset = 0
  end

  for _, field in fields do
    local name, kind = field[1], field[2]
    local size = fixedSize(field)
    if field.expr then
      emit(out, `local {name} = {field.expr}`)
    elseif size then
      local value
      if field.fixed then
        local parts = {}
        local each = sizeOf(kind) :: number
        for index = 0, field.fixed - 1 do
          table.insert(parts, readElement(kind, offset + index * each))
        end

        value = `\{ {table.concat(parts, ', ')} }`
      else
        value = readElement(kind, offset)
      end

      if kind == 'mat3' and not field.fixed then
        -- Exactly identity's bits read as the shared, frozen identity: most rotations are.
        local tests = {}
        for index = 0, 8 do
          local bits = if index % 4 == 0 then '0x3f800000' else '0'
          table.insert(tests, `buffer.readu32(bytes, {at(offset + index * 4)}) == {bits}`)
        end

        emit(out, `local {name} = Identity`)
        open(out, `if not ({table.concat(tests, ' and ')}) then`)
        local rows = {}
        for row = 0, 2 do
          local start = offset + row * 12
          table.insert(rows, `vector.create({f32(start)}, {f32(start + 4)}, {f32(start + 8)})`)
        end

        if fill then
          emit(out, `local reused = into.{name}`)
          open(out, 'if reused and reused ~= Identity then')
          for row = 1, 3 do
            emit(out, `reused[{row}] = {rows[row]}`)
          end

          emit(out, `{name} = reused`)
          otherwise(out)
        end

        spaced(out, `{name} = \{ {table.concat(rows, ', ')} }`)
        if fill then close(out) end

        close(out)
        offset += size
        continue
      end

      if fill and Inline[kind] and not field.fixed then
        emit(out, `local {name} = into.{name}`)
        open(out, `if {name} then`)
        local position = offset
        for _, part in Schema.Structs[kind].fields do
          local partKind = part[2] :: string
          local each = sizeOf(partKind) :: number
          local partValue = readElement(partKind, position)
          if part.fixed then
            local elements = {}
            for index = 0, part.fixed - 1 do
              table.insert(elements, readElement(partKind, position + index * each))
            end

            partValue = `\{ {table.concat(elements, ', ')} }`
          end

          emit(out, `{name}.{part[1]} = {partValue}`)
          position += each * (part.fixed or 1)
        end

        otherwise(out)
        spaced(out, `{name} = {readElement(kind, offset)}`)
        close(out)
        offset += size
        continue
      end

      offset += size
      local put = if string.find(value, '{', 1, true) then spaced else emit
      put(out, `local {name} = {value}`)
    else
      flush()
      local target = name
      if field.when then
        emit(out, `local {target}`)
        open(out, `if {field.when} then`)
      else
        emit(out, `local {target}`)
      end

      if kind == 'string' then
        -- Interned whole (`nif/text.luau`): cut at the first NUL, as OpenMW reads names, and
        -- decoded, once per spelling.
        emit(out, `local {name}Length = buffer.readu32(bytes, cursor)`)
        emit(out, `local {name}Token = Spellings:intern(bytes, cursor + 4, {name}Length)`)
        emit(out, `{target} = Strings[{name}Token]`)
        open(out, `if not {target} then`)
        emit(out, `{target} = Text.cut(bytes, cursor + 4, {name}Length)`)
        emit(out, `Strings[{name}Token] = {target}`)
        close(out)
        emit(out, `cursor += 4 + {name}Length`)
      elseif isCustom(kind) then
        local args = if field.args then `, {field.args}` else ''
        emit(out, `{target}, cursor = Custom.{customName(kind)}.read(bytes, cursor{args})`)
      elseif isStruct(kind) and not (field.list or field.count) then
        emit(out, `{target}, cursor = ReadStruct.{kind}(bytes, cursor)`)
      else
        if field.list then
          emit(out, `local {name}Count = buffer.read{field.list}(bytes, cursor)`)
          emit(out, `cursor += {Sizes[field.list]}`)
        else
          emit(out, `local {name}Count = {field.count}`)
        end

        if isArray(field) then
          -- `open` walked these bytes, so they are in the buffer.
          local arrayType, stride = arrayKind(kind), sizeOf(kind)
          local view =
            `\{ buffer = bytes, offset = cursor, count = {name}Count, stride = {stride} }`
          emit(out, `{target} = Empties.{arrayType}`)
          open(out, `if {name}Count > 0 then`)
          if fill then
            -- A view this record type left here before, of this kind and never edited, is refilled.
            emit(out, `local reused = into.{name}`)
            open(
              out,
              `if reused and not reused.owned and getmetatable(reused) == Metas.{arrayType} then`
            )
            emit(out, `reused.buffer, reused.offset, reused.count = bytes, cursor, {name}Count`)
            emit(out, `{target} = reused`)
            otherwise(out)
          end

          spaced(out, `{target} = setmetatable({view}, Metas.{arrayType})`)
          if fill then close(out) end

          emit(out, `cursor += {name}Count * {sizeOf(kind)}`)
          close(out)
        else
          emit(out, `{target} = table.create({name}Count)`)
          open(out, `for index = 1, {name}Count do`)
          if isStruct(kind) and not Inline[kind] then
            emit(out, `{target}[index], cursor = ReadStruct.{kind}(bytes, cursor)`)
          else
            emit(out, `{target}[index] = {readElement(kind, 0, true)}`)
            emit(out, `cursor += {sizeOf(kind)}`)
          end

          close(out)
        end
      end

      if field.when then close(out) end
    end

    if field.stash then emit(out, `Stash.{field.stash} = {name}`) end
  end

  flush()
  if fill then
    emit(out, 'into.type = typeName')
    for _, field in fields do
      if isHidden(field) then continue end

      local name = field[1]
      local single = field[2] == 'link' and not (field.list or field.count or field.fixed)
      emit(
        out,
        if single
          then `into.{name} = if {name} >= 0 then {name} else nil`
          else `into.{name} = {name}`
      )
    end

    emit(out, 'return cursor')
    return
  end

  local parts = if typed then { 'type = typeName' } else {}
  for _, field in fields do
    if isHidden(field) then continue end

    local name = field[1]
    local single = field[2] == 'link' and not (field.list or field.count or field.fixed)
    table.insert(
      parts,
      if single then `{name} = if {name} >= 0 then {name} else nil` else `{name} = {name}`
    )
  end

  spaced(out, `return \{ {table.concat(parts, ', ')} }, cursor`)
end

-- Scanning: the reader's walk, keeping only what later counts need and the links.

local function emitScan(out: Out, definition: Definition)
  local fields = definition.fields
  local offset = 0
  local function flush()
    if offset == 0 then return end

    emit(out, `cursor += {offset}`)
    offset = 0
  end

  for index, field in fields do
    local name, kind = field[1], field[2]
    local needsLocal = isHidden(field) or referenced(name, fields, index + 1)
    local size = fixedSize(field)
    if field.expr then
      emit(out, `local {name} = {field.expr}`)
    elseif size then
      if needsLocal then emit(out, `local {name} = {readElement(kind, offset)}`) end

      if kind == 'link' then
        local count = field.fixed or 1
        for element = 0, count - 1 do
          -- `scanLink`, inline: a link is listed when it isn't -1.
          local position = at(offset + element * 4)
          if element > 0 then blank(out) end

          open(out, `if buffer.readi32(bytes, {position}) >= 0 then`)
          emit(out, 'linkCount += 1')
          emit(out, `links[linkCount] = buffer.readi32(bytes, {position})`)
          close(out)
        end
      end

      offset += size
    else
      flush()
      if field.when then open(out, `if {field.when} then`) end

      if kind == 'string' then
        emit(out, 'cursor += 4 + buffer.readu32(bytes, cursor)')
      elseif isCustom(kind) then
        local args = if field.args then `, {field.args}` else ''
        emit(
          out,
          `cursor, linkCount = Custom.{customName(kind)}(bytes, cursor, links, linkCount{args})`
        )
      elseif isStruct(kind) and not (field.list or field.count) then
        emit(out, `cursor, linkCount = Scanners.{kind}(bytes, cursor, links, linkCount)`)
      else
        local count
        if field.list then
          emit(out, `local {name}Count = buffer.read{field.list}(bytes, cursor)`)
          emit(out, `cursor += {Sizes[field.list]}`)
          count = `{name}Count`
        else
          count = field.scanCount or field.count :: string
        end

        if referenced(`{name}At`, fields, index + 1) then emit(out, `local {name}At = cursor`) end

        if kind == 'link' then
          open(out, `for _ = 1, {count} do`)
          emit(out, 'local link = buffer.readi32(bytes, cursor)')
          open(out, 'if link >= 0 then')
          emit(out, 'linkCount += 1')
          emit(out, 'links[linkCount] = link')
          close(out)
          emit(out, 'cursor += 4')
          close(out)
        elseif isStruct(kind) and not Inline[kind] then
          open(out, `for _ = 1, {count} do`)
          emit(out, `cursor, linkCount = Scanners.{kind}(bytes, cursor, links, linkCount)`)
          close(out)
        else
          emit(out, `cursor += ({count}) * {sizeOf(kind)}`)
        end
      end

      if field.when then close(out) end
    end

    if field.stash then emit(out, `Stash.{field.stash} = {name}`) end
  end

  flush()
end

-- Writing: fixed fields in runs, one reservation per run.

--- A writer keeps the output's buffer, position, and length in the locals `bytes`, `cursor`, and
--- `capacity`, and hands them back to `writer` only around calls that write through it.
local Retake = 'bytes, cursor, capacity = writer.bytes, writer.cursor, writer.capacity'

--- Makes room for `size` more bytes at `cursor`, calling out only when the buffer must grow.
local function emitReserve(out: Out, size: string)
  open(out, `if cursor + {size} > capacity then`)
  emit(out, 'writer.cursor = cursor')
  emit(out, `Writer.reserve(writer, {size})`)
  emit(out, 'bytes, capacity = writer.bytes, writer.capacity')
  close(out)
end

--- A call that writes through `writer`, with the locals handed over and taken back.
local function emitCall(out: Out, call: string)
  emit(out, 'writer.cursor = cursor')
  emit(out, call)
  emit(out, Retake)
end

--- `subject` is what the fields are written from: `record` in a record's writer, `struct` in a
--- struct's.
local function emitWriteRun(out: Out, run: { Field }, subject: string)
  local total = 0
  for _, field in run do
    total += fixedSize(field) :: number
  end

  emitReserve(out, tostring(total))
  local offset = 0
  for _, field in run do
    local name, kind = field[1], field[2]
    local value = if isHidden(field) then field.save :: string else `{subject}.{name}`
    if field.fixed then
      local each = sizeOf(kind) :: number
      emit(out, `local {name} = {value}`)
      for index = 0, field.fixed - 1 do
        for _, line in writeElement(kind, `{name}[{index + 1}]`, offset + index * each) do
          emit(out, line)
        end

        local check = nanCheck(kind, `{name}[{index + 1}]`)
        if check then emit(out, check) end
      end
    else
      local check = nanCheck(kind, name)
      local lines = writeElement(kind, value, offset)
      local reused = kind == 'vec3' or kind == 'link' or string.sub(kind, 1, 5) == 'enum:'
      if #lines > 1 or check or reused then
        emit(
          out,
          if kind == 'vec3' then `local {name}: vector = {value}` else `local {name} = {value}`
        )
        lines = writeElement(kind, name, offset)
      end

      for _, line in lines do
        emit(out, line)
      end

      if check then emit(out, check) end
    end

    offset += fixedSize(field) :: number
  end

  emit(out, `cursor += {total}`)
end

local function emitWriteField(out: Out, field: Field, subject: string)
  local name, kind = field[1], field[2]
  if field.when then open(out, `if {subject}.{name} ~= nil then`) end

  if kind == 'string' then
    open(out, 'do')
    emit(out, `local text = Text.encode({subject}.{name})`)
    emit(out, 'local length = #text')
    emitReserve(out, '4 + length')
    emit(out, 'buffer.writeu32(bytes, cursor, length)')
    emit(out, 'buffer.writestring(bytes, cursor + 4, text)')
    emit(out, 'cursor += 4 + length')
    close(out)
  elseif isCustom(kind) then
    emitCall(out, `Custom.{customName(kind)}.write(writer, {subject}.{name}, map)`)
  elseif isStruct(kind) and not (field.list or field.count) then
    emitCall(out, `WriteStruct.{kind}(writer, {subject}.{name}, map)`)
  else
    open(out, 'do')
    emit(out, `local values = {subject}.{name}`)
    local count = if isArray(field) then 'values.count' else '#values'
    local each = sizeOf(kind)
    local prefix = if field.list then Sizes[field.list] else 0
    if isArray(field) and kind == 'link' then
      emitReserve(out, `{prefix} + {count} * 4`)
    elseif isArray(field) then
      emit(out, `local length = {count} * values.stride`)
      emitReserve(out, `{prefix} + length`)
    elseif each then
      emitReserve(out, `{prefix} + {count} * {each}`)
    elseif prefix > 0 then
      emitReserve(out, tostring(prefix))
    end

    if field.list then
      emit(out, `buffer.write{field.list}(bytes, cursor, {count})`)
      emit(out, `cursor += {prefix}`)
    end

    if isArray(field) and kind == 'link' then
      emit(out, 'local source, offset = values.buffer, values.offset')
      open(out, `for index = 0, {count} - 1 do`)
      emit(out, 'local link = buffer.readi32(source, offset + index * 4)')
      emit(out, 'buffer.writei32(bytes, cursor, if link >= 0 then map[link] or -1 else -1)')
      emit(out, 'cursor += 4')
      close(out)
    elseif isArray(field) then
      emit(out, 'buffer.copy(bytes, cursor, values.buffer, values.offset, length)')
      emit(out, 'cursor += length')
    elseif each then
      open(out, 'for _, value in values do')
      for _, line in writeElement(kind, 'value', 0) do
        emit(out, line)
      end

      emit(out, `cursor += {each}`)
      close(out)
    else
      open(out, 'for _, value in values do')
      emitCall(out, `WriteStruct.{kind}(writer, value, map)`)
      close(out)
    end

    close(out)
  end

  if field.when then close(out) end
end

local function emitWrite(out: Out, definition: Definition, subject: string)
  -- The body comes first, under a line that stands for the locals it turns out to read.
  local body: Out = { lines = {}, depth = out.depth, pending = false }
  local run: { Field } = {}
  local function flush()
    if #run == 0 then return end

    emitWriteRun(body, run, subject)
    run = {}
  end

  emit(body, 'local')
  for _, field in definition.fields do
    if field.expr then continue end

    if fixedSize(field) then
      table.insert(run, field)
      continue
    end

    flush()
    if isHidden(field) then error(`hidden variable field {field[1]}`) end

    emitWriteField(body, field, subject)
  end

  flush()
  if #body.lines == 1 then return end

  -- Keep only the locals the body reads, so none is declared and never used.
  local text = table.concat(body.lines, '\n')
  local names = { 'bytes', 'cursor', 'capacity' }
  if not string.find(text, '%(%s*bytes,') then table.remove(names, 1) end

  if not string.find(text, '> capacity then') then table.remove(names) end

  local list = table.concat(names, ', ')
  local values = [for name in names => `writer.{name}`]

  -- The writer's fields are taken by name: one of them as a plain local, several as a pattern.
  local take = `{list} = {table.concat(values, ', ')}`
  local first = if #names > 1 then `\{{list}} = writer` else take
  body.lines[1] = `{string.rep('  ', out.depth)}local {first}`
  for _, line in body.lines do
    local indent, code = string.match(line, '^(%s*)(.*)$')
    table.insert(out.lines, if code == Retake then indent .. take else line)
  end

  out.pending, out.opened = body.pending, false
  emit(out, 'writer.cursor = cursor')
end

-- Collecting the links of a decoded table.

local function emitLinks(out: Out, definition: Definition, subject: string)
  for _, field in definition.fields do
    local name, kind = field[1], field[2]
    if isHidden(field) or not kind then continue end

    if kind == 'link' and not (field.list or field.count or field.fixed) then
      emit(out, `local {name} = {subject}.{name}`)
      open(out, `if {name} and {name} >= 0 then`)
      emit(out, 'linkCount += 1')
      emit(out, `links[linkCount] = {name}`)
      close(out)
    elseif kind == 'link' then
      emit(out, `local {name} = {subject}.{name}`)
      open(out, `for index = 0, {name}.count - 1 do`)
      emit(out, `local value = buffer.readi32({name}.buffer, {name}.offset + index * 4)`)
      open(out, 'if value >= 0 then')
      emit(out, 'linkCount += 1')
      emit(out, 'links[linkCount] = value')
      close(out)
      close(out)
    elseif kind == 'custom:textureMaps' or kind == 'custom:textureSource' then
      emit(out, `linkCount = Custom.{customName(kind)}.links({subject}.{name}, links, linkCount)`)
    elseif isStruct(kind) and hasLinks(Schema.Structs[kind]) then
      if field.list or field.count then
        open(out, `for _, value in {subject}.{name} do`)
        emit(out, `linkCount = StructLinks.{kind}(value, links, linkCount)`)
        close(out)
      else
        emit(out, `linkCount = StructLinks.{kind}({subject}.{name}, links, linkCount)`)
      end
    else
      continue
    end

    blank(out)
  end
end

-- The modules.

--- A function: its header, what `body` emits, and `footer`, its last statement. With nothing in
--- the body it is the footer alone, on the header's line when that fits.
local function emitFunction(out: Out, header: string, body: () -> (), footer: string)
  local start = #out.lines
  open(out, header)
  local before = #out.lines
  body()

  if #out.lines == before then
    for _ = start + 1, before do
      table.remove(out.lines)
    end

    out.depth -= 1
    out.opened = false
    oneLine(out, header, footer)
    blank(out)
    return
  end

  if out.lines[#out.lines] ~= '' then blank(out) end

  emit(out, footer)
  close(out)
  blank(out)
end

--- Lines as they are, but for a statement at the margin too long for one.
local function lines(out: Out, list: { string })
  for _, line in list do
    for _, part in Layout.wrap(line, 0) do
      table.insert(out.lines, part)
    end
  end
end

local function sortedKeys<T>(map: { [string]: T }): { string }
  local keys = {}
  for key in map do
    table.insert(keys, key)
  end

  table.sort(keys)
  return keys
end

local Generated =
  '-- Generated by generators/generate.luau from generators/schema.luau. Do not edit.'

--- One scanner's module: `body`, its function, under what that uses, the struct scanners among
--- them, required from beside it.
local function scannerModule(body: { string }): string
  local text = table.concat(body, '\n')
  local function uses(name: string): boolean
    return string.find(text, `%f[%w_]{name}%f[^%w_]`) ~= nil
  end

  local out = {
    '--!strict',
    '--!native',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '',
  }

  if uses 'Custom' then table.insert(out, 'local Custom = require \'../custom_scan\'') end

  if uses 'Stash' then table.insert(out, 'local Stash = require \'../scan_stash\'') end

  if #out > 5 then table.insert(out, '') end

  table.insert(out, 'type Links = { number }')
  table.insert(out, '')

  local structs = [
    for name in sortedKeys(Schema.Structs)
    if string.find(text, `Scanners.{name}(`, 1, true)
    => `  {name} = require './{name}',`
  ]

  if #structs > 0 then
    table.insert(out, 'local Scanners = table.freeze {')
    table.move(structs, 1, #structs, #out + 1, out)
    table.insert(out, '}')
    table.insert(out, '')
  end

  table.move(body, 1, #body, #out + 1, out)
  table.insert(out, 'return scan')
  return table.concat(out, '\n') .. '\n'
end

--- The scanners, what `open` runs over every record: `index` is `scan.luau`, which says what
--- requires each type's scanner, and `scanners` is each scanner's module by its type's name.
--- Only the index loads with the package; a scanner compiles the first time a file holds its
--- type.
local function scanModules(): { index: string, scanners: { [string]: string } }
  local index: Out = { lines = {}, depth = 0, pending = false }
  lines(index, {
    '--!strict',
    '--!native',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '',
    'type Links = { number }',
    'export type Scanner = (buffer, number, Links, number) -> (number, number)',
    '',
    '--- What requires each type\'s scanner, by type name. A scanner is a module of its own in',
    '--- `scans/`, required the first time `open` meets its type: a module\'s functions are all',
    '--- compiled when it loads, and a file holds few of the types there are.',
    'local Scanners: { [string]: () -> Scanner } = {}',
  })

  local bases: { [string]: Definition } = {}
  for _, entry in Schema.Records do
    bases[entry.name] = entry.definition
  end

  local scanners: { [string]: string } = {}
  local aliases: { string } = {}
  local parameters = 'bytes: buffer, cursor: number, links: Links, linkCount: number'

  local function define(name: string, definition: Definition)
    local base = definition.base
    if base and #definition.fields == 0 then
      table.insert(aliases, `Scanners.{name} = Scanners.{base}`)
      return
    end

    checkNames(name, definition.fields)
    local out: Out = { lines = {}, depth = 0, pending = false }
    emitFunction(
      out,
      `local function scan({parameters}): (number, number)`,
      function()
        -- The base records' fields, inline from the root down: a scan is one call per record.
        local chain = {}
        local ancestor = base
        while ancestor do
          local found = bases[ancestor]
          table.insert(chain, 1, found)
          ancestor = found.base
        end

        for _, inherited in chain do
          emitScan(out, inherited)
        end

        emitScan(out, definition)
      end,
      'return cursor, linkCount'
    )
    scanners[name] = scannerModule(out.lines)
    oneLine(index, `Scanners.{name} = function(): Scanner`, `return require './scans/{name}'`)
  end

  for _, name in sortedKeys(Schema.Structs) do
    if not Inline[name] then define(name, Schema.Structs[name]) end
  end

  local names = {}
  for _, entry in Schema.Records do
    define(entry.name, entry.definition)
    table.insert(names, `'{entry.name}'`)
  end

  -- A type with no fields of its own is scanned as its base is, by the base's module.
  blank(index)
  for _, alias in aliases do
    emit(index, alias)
  end

  blank(index)
  emit(index, '--- Every record type name, in the order the Rust `NiType` lists them.')
  emit(index, `local RecordNames = table.freeze \{ {table.concat(names, ', ')} }`)
  blank(index)
  emit(index, 'return table.freeze { scan = Scanners, names = RecordNames }')
  return { index = table.concat(index.lines, '\n') .. '\n', scanners = scanners }
end

--- What a scanner leaves for another to read: a record for the structs it holds.
local function scanStashModule(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, {
    '--!strict',
    '--!native',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '',
    '--- Values a scanner leaves for a later field, or for the scanner of a struct it holds.',
    'local Stash: { [string]: number } = {}',
    '',
    'return Stash',
  })
  return table.concat(out.lines, '\n') .. '\n'
end

--- A codec module's header: its requires and locals, only those `body` uses, so the analyzer
--- has nothing to call unused. `prefix` is where the sibling modules are, from the module.
local function codecModule(body: { string }, prefix: string, locals: { string }?): string
  local text = table.concat(body, '\n')
  local function uses(name: string): boolean
    return string.find(text, `%f[%w_]{name}%f[^%w_]`) ~= nil
  end

  local out = {
    '--!strict',
    '--!native',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '',
  }

  local modules = {
    { 'Array', 'array' },
    { 'Codec', 'codec' },
    { 'Custom', 'custom' },
    { 'Enums', 'enums' },
    { 'Stash', 'stash' },
    { 'Structs', 'structs' },
    { 'StructWrites', 'struct_writes' },
    { 'Text', 'text' },
    { 'Types', 'types' },
    { 'Writer', 'writer' },
  }

  local needs = {
    Array = uses 'Array' or uses 'Metas' or uses 'Empties',
    Codec = uses 'Codec',
    Custom = uses 'Custom' or uses 'Identity',
    Enums = uses 'Names' or uses 'Values',
    Stash = uses 'Stash',
    Structs = uses 'ReadStruct',
    StructWrites = uses 'WriteStruct' or uses 'StructLinks',
    Text = uses 'Spellings' or uses 'Text',
    Types = true,
    Writer = uses 'Writer',
  }

  for _, module in modules do
    if needs[module[1]] then
      table.insert(out, `local {module[1]} = require '{prefix}{module[2]}'`)
    end
  end

  local aliases = {
    { 'Record', 'Types.Record' },
    { 'Links', '{ number }' },
    { 'Map', '{ [number]: number }' },
    { 'Writer', 'Writer.Writer' },
  }

  table.insert(out, '')
  for _, alias in aliases do
    if uses(alias[1]) then table.insert(out, `type {alias[1]} = {alias[2]}`) end
  end

  if out[#out] ~= '' then table.insert(out, '') end

  if uses 'Names' and uses 'Values' then
    table.insert(out, 'local Names, Values = Enums.names, Enums.values')
  elseif uses 'Names' then
    table.insert(out, 'local Names = Enums.names')
  elseif uses 'Values' then
    table.insert(out, 'local Values = Enums.values')
  end

  if uses 'Metas' then table.insert(out, 'local Metas, Empties = Array.metas, Array.empty') end

  if uses 'Identity' then table.insert(out, 'local Identity = Custom.identity') end

  if uses 'Spellings' then
    table.insert(out, 'local Spellings: dream_intern_Pool = Text.pool')
    table.insert(out, 'local Strings = Text.decoded')
  end

  for _, line in locals or {} do
    table.insert(out, line)
  end

  if out[#out] ~= '' then table.insert(out, '') end

  for _, line in body do
    table.insert(out, line)
  end

  return table.concat(out, '\n') .. '\n'
end

--- The values records hold inside them, shared by the record modules: their readers in one
--- module, their writers and link collectors in another, which only a save loads.
local function structsModules(): { read: string, write: string }
  local read: Out = { lines = {}, depth = 0, pending = false }
  local write: Out = { lines = {}, depth = 0, pending = false }
  lines(read, { 'local ReadStruct = {}', '' })
  lines(write, { 'local WriteStruct = {}', 'local StructLinks = {}', '' })

  for _, name in sortedKeys(Schema.Structs) do
    if Inline[name] then continue end

    local definition = Schema.Structs[name]
    checkNames(name, definition.fields)
    open(read, `function ReadStruct.{name}(bytes: buffer, cursor: number): (Types.{name}, number)`)
    emitRead(read, definition.fields, false)
    close(read)
    blank(read)
    emitFunction(
      write,
      `function WriteStruct.{name}(writer: Writer, struct: Types.{name}, map: Map)`,
      function() emitWrite(write, definition, 'struct') end,
      'return'
    )
    emitFunction(
      write,
      `function StructLinks.{name}(struct: Types.{name}, links: Links, linkCount: number): number`,
      function() emitLinks(write, definition, 'struct') end,
      'return linkCount'
    )
  end

  emit(read, 'return table.freeze { read = ReadStruct }')
  emit(write, 'return table.freeze { write = WriteStruct, links = StructLinks }')

  -- The struct tables are each module's own, not a require of itself.
  local reads = string.gsub(codecModule(read.lines, './'), 'local Structs = require [^\n]*\n', '')
  local writes =
    string.gsub(codecModule(write.lines, './'), 'local StructWrites = require [^\n]*\n', '')
  return { read = reads, write = writes }
end

--- The values one field leaves for a later one that another function reads.
local function stashModule(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, {
    '--!strict',
    '--!native',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '',
    '--- Values one field leaves for a later one, read by an expression; shared, since a struct',
    '--- reads what its record left.',
    'local Stash: { [string]: number } = {}',
    '',
    'return Stash',
  })
  return table.concat(out.lines, '\n') .. '\n'
end

--- What a record type's codec is made of (`codec.luau`): the reader, and the two modules it
--- requires only when asked for them.
type RecordModules = { read: string, fill: string, write: string }

--- A record module: `body` under the requires and locals it uses, the struct tables among them.
local function recordModule(body: { string }): string
  local text = table.concat(body, '\n')
  local sources = {
    { 'ReadStruct', 'Structs.read' },
    { 'WriteStruct', 'StructWrites.write' },
    { 'StructLinks', 'StructWrites.links' },
  }

  local locals, values = {}, {}
  for _, source in sources do
    if string.find(text, `%f[%w_]{source[1]}%.`) then
      table.insert(locals, source[1])
      table.insert(values, source[2])
    end
  end

  local declare = {}
  if #locals > 0 then
    declare = { `local {table.concat(locals, ', ')} = {table.concat(values, ', ')}` }
  end

  return codecModule(body, '../', declare)
end

--- One record type's modules, each over its fields and its bases'. The reader loads the first
--- time a record of the type is decoded; `fill`, and `write` with `links`, each load the first
--- time the type's codec is asked for them. A module's functions are all compiled when it
--- loads, which is most of what a type's first use costs, so a file that is only decoded
--- compiles its readers and nothing else.
local function recordModules(name: string, definition: Definition): RecordModules
  local fields = flatten(definition)
  local flat: Definition = { fields = fields }
  checkNames(name, fields)
  local read: Out = { lines = {}, depth = 0, pending = false }
  open(
    read,
    'local function read(bytes: buffer, cursor: number, typeName: string): (Record, number)'
  )
  emitRead(read, fields, true)
  close(read)
  blank(read)
  local parts = {
    'read',
    `function() return require '../fills/{name}' end`,
    `function() return require '../writes/{name}' end`,
  }

  emit(read, `return Codec.lazy({table.concat(parts, ', ')})`)
  local fill: Out = { lines = {}, depth = 0, pending = false }
  open(
    fill,
    'local function fill(bytes: buffer, cursor: number, typeName: string, into: Record): number'
  )
  emitRead(fill, fields, true, true)
  close(fill)
  blank(fill)
  emit(fill, 'return fill')
  local write: Out = { lines = {}, depth = 0, pending = false }
  emitFunction(
    write,
    'local function write(writer: Writer, record: Record, map: Map)',
    function() emitWrite(write, flat, 'record') end,
    'return'
  )
  emitFunction(
    write,
    'local function collectLinks(record: Record, links: Links, linkCount: number): number',
    function() emitLinks(write, flat, 'record') end,
    'return linkCount'
  )
  emit(write, 'return table.freeze { write = write, links = collectLinks }')
  return {
    read = recordModule(read.lines),
    fill = recordModule(fill.lines),
    write = recordModule(write.lines),
  }
end

--- What makes a codec of a record type's reader: `fill`, and `write` and `links`, required
--- from their own modules the first time the codec is asked for one.
local function codecHelperModule(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, {
    '--!strict',
    '--!native',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '',
    'local Types = require \'./types\'',
    'local Writer = require \'./writer\'',
    '',
    'type Read = (bytes: buffer, cursor: number, typeName: string) -> (Types.Record, number)',
    'type Fill = (bytes: buffer, cursor: number, typeName: string, into: Types.Record) -> number',
    'type Write = (writer: Writer.Writer, record: Types.Record, map: { [number]: number }) -> ()',
    'type Links = (record: Types.Record, links: { number }, linkCount: number) -> number',
    '',
    '--- One record type\'s codec.',
    'export type Codec = { read read: Read, read fill: Fill, read write: Write, read links: Links }',
    '',
    '--- A codec\'s parts as they load: its reader from the start.',
    'type Parts = { read: Read, fill: Fill?, write: Write?, links: Links? }',
    '',
    '--- A record type\'s codec, given its reader from `records/`. Its `fill` (`fills/`), and its',
    '--- `write` and `links` (`writes/`), are each required the first time the codec is asked for',
    '--- one: a module\'s functions are all compiled when it loads, which is most of what a type\'s',
    '--- first use costs, and a file that is only decoded never asks.',
    'local function lazy(',
    '  read: Read,',
    '  fill: () -> Fill,',
    '  saving: () -> { write: Write, links: Links }',
    '): Codec',
    '  local parts: Parts = { read = read }',
    '  local meta = {}',
    '',
    '  function meta.__index(_: Parts, part: string): unknown',
    '    if part == \'fill\' then',
    '      local loaded = fill()',
    '      parts.fill = loaded',
    '      return loaded',
    '    end',
    '',
    '    if part ~= \'write\' and part ~= \'links\' then return nil end',
    '',
    '    local loaded = saving()',
    '    parts.write, parts.links = loaded.write, loaded.links',
    '    return if part == \'write\' then loaded.write else loaded.links',
    '  end',
    '',
    '  return (setmetatable(parts, meta) :: unknown) :: Codec',
    'end',
    '',
    'return table.freeze { lazy = lazy }',
  })
  return table.concat(out.lines, '\n') .. '\n'
end

--- The record types that have a module: those with fields of their own, or none to inherit.
local function moduleOf(name: string): string
  for _, entry in Schema.Records do
    if entry.name ~= name then continue end

    local definition = entry.definition
    if definition.base and #definition.fields == 0 then
      return moduleOf(definition.base :: string)
    end

    return name
  end

  error(`unknown record {name}`)
end

--- The loader: each record type's module, required the first time it is asked for.
local function loadModule(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, {
    '--!strict',
    '--!native',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '',
    'local Codec = require \'./codec\'',
    '',
    '--- One record type\'s codec: its reader from `records/`, and what that requires when asked.',
    'export type Codec = Codec.Codec',
    '',
    'local Load: { [string]: () -> Codec } = {}',
  })

  for _, entry in Schema.Records do
    local module = moduleOf(entry.name)
    if module == entry.name then
      oneLine(
        out,
        `Load.{entry.name} = function(): Codec`,
        `return require './records/{entry.name}'`
      )
    end
  end

  blank(out)
  for _, entry in Schema.Records do
    local module = moduleOf(entry.name)
    if module ~= entry.name then emit(out, `Load.{entry.name} = Load.{module}`) end
  end

  blank(out)
  lines(out, {
    '--- Codecs by record type name: a plain read once a type\'s module has loaded, which the first',
    '--- read of any name `scan.luau` knows does.',
    'local Codecs: { [string]: Codec } = setmetatable({}, {',
    '  __index = function(codecs: { [string]: Codec }, name: string): Codec',
    '    local codec = Load[name]()',
    '    rawset(codecs, name, codec)',
    '    return codec',
    '  end,',
    '})',
    '',
    'return Codecs',
  })
  return table.concat(out.lines, '\n') .. '\n'
end

local function enums(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  for _, line in
    {
      '--!strict',
      '--!native',
      '-- SPDX-License-Identifier: MIT OR Apache-2.0',
      Generated,
      '',
    }

  do
    table.insert(out.lines, line)
  end

  open(out, 'local Names: { [string]: { [number]: string } } = {')
  for _, name in sortedKeys(Schema.Enums) do
    local parts = [for entry in Schema.Enums[name] => `[{entry[2]}] = '{entry[1]}'`]
    spaced(out, `{name} = table.freeze \{ {table.concat(parts, ', ')} },`)
  end

  close(out, '}')
  blank(out)
  emit(out, 'local Values: { [string]: { [string]: number } } = {}')
  open(out, 'for name, names in Names do')
  emit(out, 'local values: { [string]: number } = {}')
  open(out, 'for value, label in names do')
  emit(out, 'values[label] = value')
  close(out)
  blank(out)
  emit(out, 'Values[name] = table.freeze(values)')
  close(out)
  blank(out)
  emit(out, 'return table.freeze { names = table.freeze(Names), values = table.freeze(Values) }')
  return table.concat(out.lines, '\n') .. '\n'
end

-- Types: what a decoded record holds, field by field.

local KindTypes: { [string]: string } = {
  u8 = 'number',
  u16 = 'number',
  i16 = 'number',
  u32 = 'number',
  i32 = 'number',
  f32 = 'number',
  bool8 = 'boolean',
  string = 'string',
  link = 'number',
  vec2 = 'vector',
  vec3 = 'vector',
  vec4 = '{ number }',
  quat = '{ number }',
  mat2 = '{ number }',
  mat3 = '{ vector }',
  tri = 'vector',
  u16f32 = 'vector',
  f32x2 = '{ number }',
  u32x3 = '{ number }',
  u8x4 = '{ number }',
}

local KindDocs: { [string]: string } = {
  link = 'A record index.',
  vec2 = 'The z component is 0.',
  vec4 = '`{ r, g, b, a }`, or `{ x, y, z, w }`.',
  quat = '`{ x, y, z, w }`; the file stores w first.',
  mat2 = 'Column by column, as stored.',
  mat3 = 'The rows, as stored; a shared frozen identity when the file stores exactly that.',
  tri = 'Three vertex indices.',
}

local CustomTypes: { [string]: string } = {
  floatKeys = 'FloatKeys',
  morphKeys = 'FloatKeys',
  posKeys = 'PosKeys',
  rotKeys = 'RotKeys',
  colorKeys = 'ColorKeys',
  boundingVolume = 'BoundingVolume',
  textureMaps = 'TextureMaps',
  textureSource = 'TextureSource',
  sequenceTarget = 'SequenceTarget',
  nameControllerPairs = '{ { string | number } }',
  sharedNormals = '{ U16Array }',
  uvSets = '{ Vec2Array }',
}

local Prelude = [[
--- A float curve's keys, under the one name their interpolation uses.
export type FloatKeys = {
  LinKey: FloatLinKeys?,
  BezKey: FloatBezKeys?,
  TCBKey: FloatTcbKeys?,
}

--- A position curve's keys.
export type PosKeys = {
  LinKey: PosLinKeys?,
  BezKey: PosBezKeys?,
  TCBKey: PosTcbKeys?,
}

--- A rotation curve's keys: quaternions `{ x, y, z, w }`, or three Euler angle curves.
export type RotKeys = {
  LinKey: RotLinKeys?,
  BezKey: RotLinKeys?,
  TCBKey: RotTcbKeys?,
  EulerKey: { axisOrder: AxisOrder, axes: { { keys: FloatKeys } } }?,
}

--- A color curve's keys, linear only.
export type ColorKeys = { LinKey: ColorLinKeys }

--- A bounding volume: one of a sphere, an oriented box, or a union of volumes.
export type BoundingVolume = {
  boundData: {
    NiSphereBV: { bound: NiBound }?,
    NiBoxBV: { center: vector, axis: { vector }, extents: vector }?,
    NiUnionBV: { boundingVolumes: { BoundingVolume } }?,
  },
}

--- One texture map in a texturing property's slot.
export type TextureMap = {
  texture: number?,
  clampMode: ClampMode,
  filterMode: FilterMode,
  textureIndex: number,
  ps2L: number,
  ps2K: number,
  unknownFlag1: number,
  unknownFlag2: number,
}

--- The bump map's slot adds luma and a 2x2 displacement, column by column.
export type BumpMap =
  TextureMap
  & { lumaScale: number, lumaOffset: number, displacement: { number } }

--- A texturing property's maps by slot. `slots` is how many the file lists; a save lists at
--- least that many, and enough for every map. A decal slot with no map is `false`.
export type TextureMaps = {
  slots: number,
  base: TextureMap?,
  dark: TextureMap?,
  detail: TextureMap?,
  gloss: TextureMap?,
  glow: TextureMap?,
  bump: BumpMap?,
  decals: { TextureMap | false }?,
}

--- Where a texture's pixels are: a file, or an NiPixelData record.
export type TextureSource = { external: string?, internal: number? }

--- What a keyframe sequence animates: a file, or two numbers.
export type SequenceTarget = { External: string?, Internal: { number }? }
]]

--- Each array kind's type name.
local ArrayTypeNames: { [string]: string } = {}
for _, kind in Schema.ArrayKinds do
  ArrayTypeNames[kind.kind] = kind.type
end

local function fieldType(field: Field): string
  local kind = field[2] :: string
  local base
  if string.sub(kind, 1, 5) == 'enum:' then
    base = string.sub(kind, 6)
  elseif isCustom(kind) then
    base = CustomTypes[customName(kind)]
  elseif isStruct(kind) then
    base = kind
  else
    base = KindTypes[kind]
  end

  if isArray(field) then
    local name = ArrayTypeNames[arrayKind(kind)]
    return if field.when then `{name}?` else name
  end

  if field.list or field.count or field.fixed then return `\{ {base} }` end

  if field.when or kind == 'link' then return `{base}?` end

  return base
end

local function emitFields(out: Out, definition: Definition)
  for _, field in definition.fields do
    if isHidden(field) then continue end

    local kind = field[2] :: string
    local doc = field.doc or KindDocs[kind]
    if isArray(field) and kind == 'link' then
      doc = 'Array view of `i32` record indices; -1 for a null link.'
    elseif isArray(field) then
      doc = `Array view of \`{kind}\` elements.{if field.doc then ' ' .. field.doc else ''}`
    elseif kind == 'link' then
      doc = 'A record index, nil when null.'
    end

    if doc then emit(out, `--- {doc}`) end

    emit(out, `{field[1]}: {fieldType(field)},`)
  end
end

local function types(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  for _, line in
    {
      '--!strict',
      '--!native',
      '-- SPDX-License-Identifier: MIT OR Apache-2.0',
      Generated,
      '',
      '--[[',
      'What a decoded Morrowind NIF record holds. A record type is its base type and its own fields;',
      '`type` names the record type. `Record` is any of them: test `record.type` to narrow one.',
      ']]',
      '',
      'local ArrayTypes = require \'./array_types\'',
      '',
    }

  do
    table.insert(out.lines, line)
  end

  emit(out, '--- Views of bulk data in the bytes it was read from; see `array.luau`.')
  emit(out, 'export type Array = ArrayTypes.Array')
  for _, kind in Schema.ArrayKinds do
    emit(out, `export type {kind.type} = ArrayTypes.{kind.type}`)
  end

  blank(out)
  for _, name in sortedKeys(Schema.Enums) do
    local labels = [for entry in Schema.Enums[name] => `'{entry[1]}'`]
    emit(out, '--- A value not in the list is kept as its number.')
    emit(out, `export type {name} = {table.concat(labels, ' | ')} | number`)
    blank(out)
  end

  for line in string.gmatch(Prelude, '[^\n]*\n') do
    table.insert(out.lines, string.sub(line, 1, -2))
  end

  for _, name in sortedKeys(Schema.Structs) do
    local definition = Schema.Structs[name]
    if definition.doc then emit(out, `--- {definition.doc}`) end

    open(out, `export type {name} = \{`)
    emitFields(out, definition)
    close(out, '}')
  end

  for _, entry in Schema.Records do
    local base = entry.definition.base
    emit(out, `--- {entry.name}{if base then `: an {base}, and its own fields` else ''}.`)
    open(out, `export type {entry.name} = \{`)
    emit(out, `type: '{entry.name}',`)
    emitFields(out, { fields = flatten(entry.definition) })
    close(out, '}')
  end

  local names = [for entry in Schema.Records => entry.name]
  emit(out, '--- Any record.')
  emit(out, `export type Record = {table.concat(names, ' | ')}`)
  blank(out)
  emit(out, 'return {}')
  return table.concat(out.lines, '\n') .. '\n'
end

-- Arrays: a type and a method table per element kind, from `Schema.ArrayKinds`.

type ArrayKind = Schema.ArrayKind
type ArrayValue = Schema.ArrayValue

--- The single letters a kind's values go by where they are a coordinate's or a color's parts, and
--- what `set` calls each: the type's signature keeps the letter, which is how the format's
--- documentation names it.
local Groups: { [string]: string } = table.freeze {
  ['x'] = 'xComponent',
  ['y'] = 'yComponent',
  ['z'] = 'zComponent',
  ['w'] = 'wComponent',
  ['r'] = 'red',
  ['g'] = 'green',
  ['b'] = 'blue',
  ['a'] = 'alpha',
}

--- The name `set` takes a value by.
local function parameter(value: ArrayValue): string return Groups[value.name] or value.name end

--- A `toTable` element's type.
local function elementType(kind: ArrayKind): string
  local values = kind.values
  if kind.shape == 'value' then return values[1].type end

  if kind.shape == 'list' then return '{ number }' end

  local parts = {}
  local grouped = false
  for _, value in values do
    if kind.shape == 'grouped' and Groups[value.name] then
      grouped = true
      continue
    end

    table.insert(parts, `{value.name}: {value.type}`)
  end

  if grouped then table.insert(parts, 2, 'value: { number }') end

  return `\{ {table.concat(parts, ', ')} }`
end

local function arrayTypes(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, {
    '--!strict',
    '--!native',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '-- The array types, one per element kind, and each kind\'s stride.',
    '',
  })
  local kinds, names = {}, {}
  for _, kind in Schema.ArrayKinds do
    table.insert(kinds, `'{kind.kind}'`)
    table.insert(names, kind.type)
  end

  emit(out, `export type Kind = {table.concat(kinds, ' | ')}`)
  blank(out)
  lines(out, {
    '--- What every array has: the bytes, where element 1 starts, how many elements, and each one\'s',
    '--- size. `owned` is set once `set` has copied the bytes out of the file\'s buffer.',
    'export type ArrayFields = { buffer: buffer, offset: number, count: number, stride: number, owned: boolean? }',
    '',
  })

  for _, kind in Schema.ArrayKinds do
    local returns, params = {}, {}
    for _, value in kind.values do
      table.insert(returns, value.type)
      table.insert(params, `{value.name}: {value.type}`)
    end

    local result = if #returns == 1 then returns[1] else `({table.concat(returns, ', ')})`
    emit(out, `--- An array of {kind.doc}.`)
    open(out, `export type {kind.type} = \{`)
    emit(out, 'buffer: buffer,')
    emit(out, 'offset: number,')
    emit(out, 'count: number,')
    emit(out, 'stride: number,')
    emit(out, 'owned: boolean?,')
    emit(out, `kind: '{kind.kind}',`)
    emit(out, `get: (self: {kind.type}, index: number) -> {result},`)
    emit(out, `set: (self: {kind.type}, index: number, {table.concat(params, ', ')}) -> (),`)
    emit(out, `toTable: (self: {kind.type}) -> \{ {elementType(kind)} },`)
    close(out, '}')
  end

  emit(out, `export type Array = {table.concat(names, ' | ')}`)
  blank(out)
  open(out, 'local Strides: { [Kind]: number } = {')
  for _, kind in Schema.ArrayKinds do
    emit(out, `{kind.kind} = {kind.stride},`)
  end

  close(out, '}')
  blank(out)
  emit(out, 'return table.freeze { strides = table.freeze(Strides) }')
  return table.concat(out.lines, '\n') .. '\n'
end

local function readValue(value: ArrayValue): string
  local parts = [
    for component in value.components
    => `buffer.read{component.encoding}(bytes, {at(component.offset)})`
  ]

  if value.type == 'number' then return parts[1] end

  if #parts == 2 then table.insert(parts, '0') end

  return `vector.create({table.concat(parts, ', ')})`
end

local function writeValue(value: ArrayValue): { string }
  local written = {}
  for index, component in value.components do
    local part = if value.type == 'number'
      then parameter(value)
      else `{parameter(value)}.{({ 'x', 'y', 'z' })[index]}`
    table.insert(written, `buffer.write{component.encoding}(bytes, {at(component.offset)}, {part})`)
  end

  return written
end

--- One array kind's `get`, `set`, and `toTable`, a module of its own.
local function arrayKindModule(kind: ArrayKind): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, {
    '--!strict',
    '--!native',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    `-- What an array of kind \`{kind.kind}\` does beyond being read in place, loaded the first time one`,
    '-- is asked for a method (`array_access.luau`).',
    '',
    'local Types = require \'../array_types\'',
    '',
    'type ArrayFields = Types.ArrayFields',
    '',
    '--- A kind\'s name and methods.',
    'type Methods = { [string]: unknown }',
    '',
    '--- Element `index`\'s byte position, checking it is one of the array\'s.',
    'local function at(array: ArrayFields, index: number): number',
    '  if index < 1 or index > array.count or index % 1 ~= 0 then',
    '    error(`index {index} is outside 1..{array.count}`, 3)',
    '  end',
    '',
    '  return array.offset + (index - 1) * array.stride',
    'end',
    '',
    '--- Copies the array\'s bytes out of the file\'s buffer before its first edit.',
    'local function own(array: ArrayFields)',
    '  if array.owned then return end',
    '',
    '  local length = array.count * array.stride',
    '  local bytes = buffer.create(length)',
    '  buffer.copy(bytes, 0, array.buffer, array.offset, length)',
    '  array.buffer, array.offset, array.owned = bytes, 0, true',
    'end',
    '',
  })
  local name, typeName = kind.type, `Types.{kind.type}`
  local returns, params, reads = {}, {}, {}
  for _, value in kind.values do
    table.insert(returns, value.type)
    table.insert(params, `{parameter(value)}: {value.type}`)
    table.insert(reads, readValue(value))
  end

  local result = if #returns == 1 then returns[1] else `({table.concat(returns, ', ')})`
  open(out, `local {name}: Methods = \{`)
  emit(out, `kind = '{kind.kind}',`)
  close(out, '}')
  open(out, `function {name}.get(array: {typeName}, index: number): {result}`)
  emit(out, 'local bytes, cursor = array.buffer, at(array, index)')
  spaced(out, `return {table.concat(reads, ', ')}`)
  close(out)
  open(out, `function {name}.set(array: {typeName}, index: number, {table.concat(params, ', ')})`)
  emit(out, 'own(array)')
  emit(out, 'local bytes, cursor = array.buffer, at(array, index)')
  for _, value in kind.values do
    for _, line in writeValue(value) do
      emit(out, line)
    end
  end

  close(out)
  open(out, `function {name}.toTable(array: {typeName}): \{ {elementType(kind)} }`)
  -- The array's fields are read once, into locals: read again for every element they cost a
  -- list of numbers more than the elements do.
  emit(out, 'local count = array.count')
  emit(out, `local list = table.create(count) :: \{ {elementType(kind)} }`)
  emit(out, 'local bytes, cursor, stride = array.buffer, array.offset, array.stride')
  open(out, 'for index = 1, count do')
  if kind.shape == 'value' then
    emit(out, `list[index] = {reads[1]}`)
  elseif kind.shape == 'list' then
    spaced(out, `list[index] = \{ {table.concat(reads, ', ')} }`)
  else
    local parts, group = {}, {}
    for position, value in kind.values do
      if kind.shape == 'grouped' and Groups[value.name] then
        table.insert(group, reads[position])
      else
        table.insert(parts, `{value.name} = {reads[position]}`)
      end
    end

    if #group > 0 then table.insert(parts, 2, `value = \{ {table.concat(group, ', ')} }`) end

      spaced(out, `list[index] = \{ {table.concat(parts, ', ')} }`)
  end

  emit(out, 'cursor += stride')
  close(out)
  blank(out)
  emit(out, 'return list')
  close(out)
  blank(out)
  emit(out, `return table.freeze({name})`)
  return table.concat(out.lines, '\n') .. '\n'
end

--- Each kind's methods for `array.luau`: its name, and the module of the rest (`arrays/`),
--- required the first time one of them is asked for.
local function arrayAccess(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, {
    '--!strict',
    '--!native',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '-- What an array does beyond being read in place: `get`, `set`, and `toTable` for each kind.',
    '-- `array.luau` loads this the first time an array is asked for anything it doesn\'t hold; a',
    '-- kind\'s methods are a module of their own in `arrays/`, loaded the first time an array of',
    '-- that kind is.',
    '',
    'local Types = require \'./array_types\'',
    '',
    '--- A kind\'s name and methods.',
    'type Methods = { [string]: unknown }',
    '',
    '--- A kind\'s methods before its module has loaded: its name, and a metatable that requires',
    '--- the rest the first time an array of the kind is asked for anything else it doesn\'t hold,',
    '--- and then goes. That is a method, or `owned` of a view (`fill` asks before it refills',
    '--- one): loading then too leaves a plain table behind, which answers the next such question',
    '--- without a call.',
    'local function lazy(kind: Types.Kind, load: () -> Methods): Methods',
    '  local methods: Methods = { kind = kind }',
    '  local meta = {}',
    '',
    '  function meta.__index(_: Methods, name: string): unknown',
    '    local loaded = load()',
    '    methods.get, methods.set, methods.toTable = loaded.get, loaded.set, loaded.toTable',
    '    setmetatable(methods, nil)',
    '    return methods[name]',
    '  end',
    '',
    '  return setmetatable(methods, meta)',
    'end',
    '',
  })
  open(out, 'local Kinds: { [Types.Kind]: Methods } = {')
  for _, kind in Schema.ArrayKinds do
    emit(out, `{kind.kind} = lazy('{kind.kind}', function() return require './arrays/{kind.kind}' end),`)
  end

  close(out, '}')
  blank(out)
  emit(out, 'return table.freeze(Kinds)')
  return table.concat(out.lines, '\n') .. '\n'
end

--- Where each of a record type's modules goes.
local RecordDirs: RecordModules = table.freeze {
  read = jess.fs.join(outDir, 'records'),
  fill = jess.fs.join(outDir, 'fills'),
  write = jess.fs.join(outDir, 'writes'),
}

local written: { [string]: boolean } = {}
for _, folder in RecordDirs :: { [string]: string } do
  if not jess.fs.isDir(folder) then jess.fs.createDir(folder) end
end

for _, entry in Schema.Records do
  if moduleOf(entry.name) ~= entry.name then continue end

  local file = `{entry.name}.luau`
  written[file] = true
  for part, text in recordModules(entry.name, entry.definition) :: { [string]: string } do
    jess.fs.write(jess.fs.join((RecordDirs :: { [string]: string })[part], file), text)
  end
end

for _, folder in RecordDirs :: { [string]: string } do
  for _, file in jess.fs.list(folder) do
    if not written[file] then jess.fs.remove(jess.fs.join(folder, file)) end
  end
end

--- Each record type's base, and whether a type is or derives from another.
local function classesModule(): string
  local out = {
    '--!strict',
    '--!native',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '',
    '--- Each record type and the type it derives from.',
    'local Parents: { [string]: string } = {',
  }

  local names = [for entry in Schema.Records if entry.definition.base => entry.name]
  table.sort(names)
  for _, name in names do
    for _, entry in Schema.Records do
      if entry.name == name then table.insert(out, `  {name} = '{entry.definition.base}',`) end
    end
  end

  for _, line in
    {
      '}',
      '',
      '--- Each type\'s ancestors, itself included, built the first time it is asked about.',
      'local Ancestors: { [string]: { [string]: boolean } } = {}',
      '',
      '--- Whether record type `name` is `class` or derives from it.',
      'local function is(name: string, class: string): boolean',
      '  local set = Ancestors[name]',
      '  if not set then',
      '    set = {}',
      '    local current: string? = name',
      '    while current do',
      '      set[current] = true',
      '      current = Parents[current]',
      '    end',
      '',
      '    Ancestors[name] = set',
      '  end',
      '',
      '  return set[class] == true',
      'end',
      '',
      'return table.freeze { parents = Parents, is = is }',
    }

  do
    table.insert(out, line)
  end

  return table.concat(out, '\n') .. '\n'
end

jess.fs.write(jess.fs.join(outDir, 'classes.luau'), classesModule())
local scans = scanModules()
jess.fs.write(jess.fs.join(outDir, 'scan.luau'), scans.index)
jess.fs.write(jess.fs.join(outDir, 'scan_stash.luau'), scanStashModule())

local scansDir = jess.fs.join(outDir, 'scans')
if not jess.fs.isDir(scansDir) then jess.fs.createDir(scansDir) end

for name, text in scans.scanners do
  jess.fs.write(jess.fs.join(scansDir, `{name}.luau`), text)
end

for _, file in jess.fs.list(scansDir) do
  if not scans.scanners[string.gsub(file, '%.luau$', '')] then
    jess.fs.remove(jess.fs.join(scansDir, file))
  end
end

local structs = structsModules()
jess.fs.write(jess.fs.join(outDir, 'structs.luau'), structs.read)
jess.fs.write(jess.fs.join(outDir, 'struct_writes.luau'), structs.write)
jess.fs.write(jess.fs.join(outDir, 'stash.luau'), stashModule())
jess.fs.write(jess.fs.join(outDir, 'load.luau'), loadModule())
jess.fs.write(jess.fs.join(outDir, 'codec.luau'), codecHelperModule())
jess.fs.write(jess.fs.join(outDir, 'enums.luau'), enums())
jess.fs.write(jess.fs.join(outDir, 'array_types.luau'), arrayTypes())
jess.fs.write(jess.fs.join(outDir, 'array_access.luau'), arrayAccess())

local arraysDir = jess.fs.join(outDir, 'arrays')
local arrays: { [string]: boolean } = {}
if not jess.fs.isDir(arraysDir) then jess.fs.createDir(arraysDir) end

for _, kind in Schema.ArrayKinds do
  local file = `{kind.kind}.luau`
  arrays[file] = true
  jess.fs.write(jess.fs.join(arraysDir, file), arrayKindModule(kind))
end

for _, file in jess.fs.list(arraysDir) do
  if not arrays[file] then jess.fs.remove(jess.fs.join(arraysDir, file)) end
end

jess.fs.write(jess.fs.join(outDir, 'types.luau'), types())
print(
  'wrote scan, scan_stash, scans/, structs, struct_writes, stash, load, codec, enums, types,'
    .. ` array_types, array_access, arrays/, records/, fills/, and writes/ in {outDir}`
)
