--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

local Text = require '../text'
local Types = require '../types'
local Writer = require '../writer'

type Writer = Writer.Writer
type Map = { [number]: number }

local Spellings: dream_intern_Pool = Text.pool
local Strings = Text.decoded

--- A u32 length and the bytes, cut at the first NUL the way OpenMW reads names. The whole field
--- is interned (in native code), and cut and decoded once per spelling.
local function readString(bytes: buffer, cursor: number): (string, number)
  local length = buffer.readu32(bytes, cursor)
  if length == 0 then return '', cursor + 4 end

  local token = Spellings:intern(bytes, cursor + 4, length)
  local text = Strings[token]
  if not text then
    text = Text.cut(bytes, cursor + 4, length)
    Strings[token] = text
  end

  return text, cursor + 4 + length
end

-- A sequence's target: an external file name, or two numbers.
local sequenceTarget = {}

function sequenceTarget.read(bytes: buffer, cursor: number): (Types.SequenceTarget, number)
  if buffer.readu8(bytes, cursor) ~= 0 then
    local name
    name, cursor = readString(bytes, cursor + 1)
    return { External = name }, cursor
  end

  return {
    Internal = { buffer.readi32(bytes, cursor + 1), buffer.readi32(bytes, cursor + 5) },
  }, cursor + 9
end

function sequenceTarget.write(writer: Writer, value: Types.SequenceTarget, _map: Map)
  Writer.reserve(writer, 9)
  local external = value.External
  if external then
    buffer.writeu8(writer.bytes, writer.cursor, 1)
    writer.cursor += 1
    Writer.string(writer, external)
    return
  end

  local internal = value.Internal :: { number }
  buffer.writeu8(writer.bytes, writer.cursor, 0)
  buffer.writei32(writer.bytes, writer.cursor + 1, internal[1])
  buffer.writei32(writer.bytes, writer.cursor + 5, internal[2])
  writer.cursor += 9
end

-- A sequence's controllers: { name, controller index } pairs.
local nameControllerPairs = {}

--- A name and a controller index.
type Pair = { string | number }

function nameControllerPairs.read(bytes: buffer, cursor: number): ({ Pair }, number)
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  local pairs = table.create(count) :: { Pair }
  for index = 1, count do
    local name
    name, cursor = readString(bytes, cursor)
    pairs[index] = { name, buffer.readi32(bytes, cursor) }
    cursor += 4
  end

  return pairs, cursor
end

function nameControllerPairs.write(writer: Writer, value: { Pair }, _map: Map)
  Writer.reserve(writer, 4)
  buffer.writeu32(writer.bytes, writer.cursor, #value)
  writer.cursor += 4
  for _, pair in value do
    Writer.string(writer, pair[1] :: string)
    Writer.reserve(writer, 4)
    buffer.writei32(writer.bytes, writer.cursor, pair[2] :: number)
    writer.cursor += 4
  end
end

return table.freeze { sequenceTarget = sequenceTarget, nameControllerPairs = nameControllerPairs }
