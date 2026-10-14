--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
What the multi-version readers share: OpenMW's `NIFStream` rules that aren't one buffer read.
A stream is the file's bytes and versions; readers take it with a position and return the
position after what they read, so the position lives in a local, not a table.

Text in records is Windows-1252, decoded to UTF-8 as OpenMW and jess-nif decode it; strings in
the header's string table are UTF-8, read lossily, as jess-nif reads them.
]]

local Array = require '../array'
local Rows = require './rows'
local Text = require '../text'

local Empties, Metas = Array.empty, Array.metas

export type Stream = {
  bytes: buffer,
  --- The file's length: counts past it can't be right (`checkStreamSize`).
  length: number,
  version: number,
  userVersion: number,
  --- The Bethesda stream version, or 0 without one.
  bethVersion: number,
  --- The header's string table (20.1.0.1 and later), 0-based by index.
  strings: { string },
  --- The name of the record being read, which a few readers depend on.
  recordName: string,
}

--- An error as OpenMW words it, with the record it was found in once known.
export type NifError = { message: string, record: number? }

local ErrorMeta = {
  __tostring = function(self: NifError): string return self.message end,
}

--- The record being read or checked, which an error names unless it names its own.
local current: number? = nil

local function fail(message: string, record: number?): never
  error(setmetatable({ message = message, record = record or current }, ErrorMeta), 0)
end

--- Sets the record errors are found in (0-based), or none.
local function at(record: number?) current = record end

local Spellings: dream_intern_Pool = Text.pool
local Decoded = Text.decoded

--- `checkStreamSize`: `size` bytes can't be read from a smaller file.
local function checkSize(stream: Stream, size: number)
  if size > stream.length then
    fail(`Trying to read more than stream size: {size} max={stream.length}`)
  end
end

--- `getSizedString`: `length` bytes at `cursor`, cut at the first NUL.
local function sized(stream: Stream, cursor: number, length: number): (string, number)
  checkSize(stream, length)
  local bytes = stream.bytes
  if cursor + length > stream.length then
    fail(`Failed to read sized string: {length} bytes at offset {cursor} of {stream.length}`)
  end

  -- The whole field is interned (in native code), and cut and decoded once per spelling.
  local token = Spellings:intern(bytes, cursor, length)
  local text = Decoded[token]
  if not text then
    text = Text.cut(bytes, cursor, length)
    Decoded[token] = text
  end

  return text, cursor + length
end

--- A string with a `u32` length before it.
local function sizedU32(stream: Stream, cursor: number): (string, number)
  return sized(stream, cursor + 4, buffer.readu32(stream.bytes, cursor))
end

--- `getExportString`: a string with a `u8` length before it.
local function export(stream: Stream, cursor: number): (string, number)
  return sized(stream, cursor + 1, buffer.readu8(stream.bytes, cursor))
end

--- `getString`: sized before 20.1.0.1, a string table index after (`u32` max is empty).
local function string(stream: Stream, cursor: number): (string, number)
  if stream.version < 0x14010001 then return sizedU32(stream, cursor) end

  local index = buffer.readu32(stream.bytes, cursor)
  if index == 0xFFFFFFFF then return '', cursor + 4 end

  local text = stream.strings[index + 1]
  if not text then fail(`String table index {index} is past the {#stream.strings} strings`) end

  return text, cursor + 4
end

--- A string table index with no string: `u32` max is the empty string, any other is an error.
local function stringIndex(stream: Stream, index: number): string
  if index == 0xFFFFFFFF then return '' end

  return fail(`String table index {index} is past the {#stream.strings} strings`)
end

--- `getStringPalette`: a `u32` length, then NUL-separated strings, kept as they are.
local function palette(stream: Stream, cursor: number): (string, number)
  local length = buffer.readu32(stream.bytes, cursor)
  checkSize(stream, length)
  if cursor + 4 + length > stream.length then
    fail(`Failed to read string palette: {length} bytes at offset {cursor + 4} of {stream.length}`)
  end

  return Text.decode(stream.bytes, cursor + 4, length), cursor + 4 + length
end

--- `RecordPtrT::read`: indices below -1 throw.
local function invalidLink(index: number): never return fail(`Invalid index: {index}`) end

--- `half` bits as a number.
local function half(bits: number): number
  local exponent = bit32.extract(bits, 10, 5)
  local mantissa = bit32.band(bits, 0x3FF)
  local sign = if bit32.btest(bits, 0x8000) then -1 else 1
  if exponent == 0 then return sign * mantissa * 2 ^ -24 end

  if exponent == 0x1F then return if mantissa == 0 then sign * math.huge else 0 / 0 end

  return sign * (1 + mantissa / 1024) * 2 ^ (exponent - 15)
end

--- One frozen list for every link list with no links, most of them.
local NoLinks: { number } = table.freeze({} :: { number })

--- `count` links at `cursor`, each -1 or a record index; the count checked first (`checkSize`).
local function links(stream: Stream, cursor: number, count: number): { number }
  if count == 0 then return NoLinks end

  local bytes = stream.bytes
  if count * 4 > stream.length then checkSize(stream, count * 4) end

  if cursor + count * 4 > stream.length then
    fail(`Failed to read i32: 4 bytes at offset {stream.length} of {stream.length}`)
  end

  local list = table.create(count) :: { number }
  for entry = 1, count do
    local index = buffer.readi32(bytes, cursor + (entry - 1) * 4)
    if index < -1 then invalidLink(index) end

    list[entry] = index
  end

  return list
end

--- `count` elements of `kind` (`stride` bytes each) at `cursor`, as a view of the file's bytes.
local function view(
  stream: Stream,
  cursor: number,
  count: number,
  kind: Array.Kind,
  stride: number
): (Array.Array, number)
  local length = count * stride
  if cursor + length > stream.length then
    fail(`Failed to read {kind}: {stride} bytes at offset {stream.length} of {stream.length}`)
  end

  if count == 0 then return Empties[kind], cursor end

  -- The array module's own view, made here without its two calls: views are most of a mesh.
  local array = setmetatable(
    { buffer = stream.bytes, offset = cursor, count = count, stride = stride },
    Metas[kind]
  )
  return array :: any, cursor + length
end

--- Fails a view of `count` elements of `kind` at `cursor` that runs past the file, as `checkSize`
--- (when the readers check the count) and then the read would.
local function viewFail(
  stream: Stream,
  cursor: number,
  count: number,
  kind: Array.Kind,
  stride: number,
  checked: boolean
): never
  if checked then checkSize(stream, count * stride) end

  local _ = view(stream, cursor, count, kind, stride)
  return fail(`Failed to read {kind}: {stride} bytes at offset {stream.length} of {stream.length}`)
end

--- `count` fixed-size structs (`stride` bytes each) at `cursor`, each read by `read` when asked
--- for.
local function rows(
  stream: Stream,
  cursor: number,
  count: number,
  stride: number,
  read: Rows.Read
): (any, number)
  if count == 0 then return NoLinks, cursor end

  local length = count * stride
  if cursor + length > stream.length then
    fail(`Failed to read struct: {stride} bytes at offset {stream.length} of {stream.length}`)
  end

  return Rows.new(stream.bytes, cursor, count, stride, read), cursor + length
end

--- `count` structs at `cursor` that are all the size of the first, each read by `read` when asked
--- for.
local function structRows(
  stream: Stream,
  cursor: number,
  count: number,
  read: (stream: Stream, cursor: number) -> (any, number)
): (any, number)
  if count == 0 then return NoLinks, cursor end

  local _, after = read(stream, cursor)
  local stride = after - cursor
  return rows(
    stream,
    cursor,
    count,
    stride,
    function(_: buffer, at: number): any return (read(stream, at)) end
  )
end

--- Skips `length` bytes.
local function skip(stream: Stream, cursor: number, length: number): number
  if cursor + length > stream.length then
    fail(`Failed to read skipped bytes: {length} bytes at offset {cursor} of {stream.length}`)
  end

  return cursor + length
end

--- The identity matrix, shared and frozen: most rotations in a file are it.
local Identity: { vector } =
  table.freeze { vector.create(1, 0, 0), vector.create(0, 1, 0), vector.create(0, 0, 1) }

--- A 3x3 matrix, row by row, as three row vectors; the identity is the shared one.
local function mat3(bytes: buffer, cursor: number): { vector }
  -- By bits: 1.0 is 0x3F800000, and -0.0 isn't the identity's 0.
  if
    buffer.readu32(bytes, cursor) == 0x3F800000
    and buffer.readu32(bytes, cursor + 4) == 0
    and buffer.readu32(bytes, cursor + 8) == 0
    and buffer.readu32(bytes, cursor + 12) == 0
    and buffer.readu32(bytes, cursor + 16) == 0x3F800000
    and buffer.readu32(bytes, cursor + 20) == 0
    and buffer.readu32(bytes, cursor + 24) == 0
    and buffer.readu32(bytes, cursor + 28) == 0
    and buffer.readu32(bytes, cursor + 32) == 0x3F800000
  then
    return Identity
  end

  return {
    vector.create(
      buffer.readf32(bytes, cursor),
      buffer.readf32(bytes, cursor + 4),
      buffer.readf32(bytes, cursor + 8)
    ),
    vector.create(
      buffer.readf32(bytes, cursor + 12),
      buffer.readf32(bytes, cursor + 16),
      buffer.readf32(bytes, cursor + 20)
    ),
    vector.create(
      buffer.readf32(bytes, cursor + 24),
      buffer.readf32(bytes, cursor + 28),
      buffer.readf32(bytes, cursor + 32)
    ),
  }
end

local function identity(): { vector } return Identity end

--- Defaults shared by every field that holds them; frozen, since the reader is read-only.
local Zero4: { number } = table.freeze { 0, 0, 0, 0 }
local UnitQuat: { number } = table.freeze { 0, 0, 0, 1 }
local NoSphere = table.freeze { center = vector.zero, radius = 0 }

--- Four floats.
local function vec4(bytes: buffer, cursor: number): { number }
  return {
    buffer.readf32(bytes, cursor),
    buffer.readf32(bytes, cursor + 4),
    buffer.readf32(bytes, cursor + 8),
    buffer.readf32(bytes, cursor + 12),
  }
end

--- A quaternion stored `w, x, y, z`, as `{ x, y, z, w }`.
local function quat(bytes: buffer, cursor: number): { number }
  return {
    buffer.readf32(bytes, cursor + 4),
    buffer.readf32(bytes, cursor + 8),
    buffer.readf32(bytes, cursor + 12),
    buffer.readf32(bytes, cursor),
  }
end

return table.freeze {
  --- The shared, frozen empty list: an unread or empty list.
  empty = NoLinks,
  at = at,
  links = links,
  rows = rows,
  structRows = structRows,
  view = view,
  viewFail = viewFail,
  skip = skip,
  mat3 = mat3,
  identity = identity,
  zero4 = Zero4,
  unitQuat = UnitQuat,
  noSphere = NoSphere,
  stringIndex = stringIndex,
  vec4 = vec4,
  quat = quat,
  fail = fail,
  checkSize = checkSize,
  sized = sized,
  sizedU32 = sizedU32,
  export = export,
  string = string,
  palette = palette,
  invalidLink = invalidLink,
  half = half,
}
