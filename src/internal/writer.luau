--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

local Text = require './text'

--- A growing output buffer: `bytes` holds what is written so far, `cursor` is the next free byte,
--- `capacity` is the buffer's length (`buffer.len` is a call, and the writers check room before
--- every run), and `nan` says a float written since it was last cleared was NaN.
export type Writer = { bytes: buffer, cursor: number, capacity: number, nan: boolean }

--- Makes room for `size` more bytes at the cursor, doubling the buffer as needed.
local function reserve(writer: Writer, size: number)
  local need = writer.cursor + size
  local length = writer.capacity
  if need <= length then return end

  while length < need do
    length *= 2
  end

  local grown = buffer.create(length)
  buffer.copy(grown, 0, writer.bytes, 0, writer.cursor)
  writer.bytes, writer.capacity = grown, length
end

local function new(size: number): Writer
  local length = math.max(size, 64)
  return { bytes = buffer.create(length), cursor = 0, capacity = length, nan = false }
end

--- The bytes written, trimmed to their length.
local function finish(writer: Writer): buffer
  if writer.cursor == writer.capacity then return writer.bytes end

  local out = buffer.create(writer.cursor)
  buffer.copy(out, 0, writer.bytes, 0, writer.cursor)
  return out
end

--- A string as a u32 length and its Windows-1252 bytes, with no terminator.
local function writeString(writer: Writer, text: string)
  local value = Text.encode(text)
  local length = #value
  reserve(writer, 4 + length)
  buffer.writeu32(writer.bytes, writer.cursor, length)
  buffer.writestring(writer.bytes, writer.cursor + 4, value)
  writer.cursor += 4 + length
end

--- A link as its index in the saved file: -1 when null or when its record is not saved.
local function link(value: number?, map: { [number]: number }): number
  if not value or value < 0 then return -1 end

  return map[value] or -1
end

return table.freeze {
  new = new,
  reserve = reserve,
  finish = finish,
  string = writeString,
  link = link,
}
