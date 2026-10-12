--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The small reads and writes the custom codecs share: enum names and values, a string, a link, a
vector, and a float that says when it was NaN.
]]

local Enums = require '../enums'
local Text = require '../text'
local Writer = require '../writer'

type Writer = Writer.Writer

local Spellings: dream_intern_Pool = Text.pool
local Strings = Text.decoded

local function enumName(names: { [number]: string }, value: number): string | number
  return names[value] or value
end

local function enumValue(values: { [string]: number }, value: string | number): number
  if type(value) == 'number' then return value end

  local number = values[value]
  if not number then error(`unknown enum value '{value}'`, 0) end

  return number
end

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

local function readLink(bytes: buffer, cursor: number): number?
  local value = buffer.readi32(bytes, cursor)
  if value < 0 then return nil end

  return value
end

local function readVec3(bytes: buffer, cursor: number): vector
  return vector.create(
    buffer.readf32(bytes, cursor),
    buffer.readf32(bytes, cursor + 4),
    buffer.readf32(bytes, cursor + 8)
  )
end

--- Writes a float, flagging the writer when it is NaN (see `restoreNans` in `init.luau`).
local function writeF32(writer: Writer, cursor: number, value: number)
  buffer.writef32(writer.bytes, cursor, value)
  if value ~= value then writer.nan = true end
end

local function writeVec3(writer: Writer, cursor: number, value: vector)
  writeF32(writer, cursor, value.x)
  writeF32(writer, cursor + 4, value.y)
  writeF32(writer, cursor + 8, value.z)
end

return table.freeze {
  names = Enums.names,
  values = Enums.values,
  enumName = enumName,
  enumValue = enumValue,
  readString = readString,
  readLink = readLink,
  readVec3 = readVec3,
  writeF32 = writeF32,
  writeVec3 = writeVec3,
}
