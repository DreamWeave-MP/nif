--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Strings files repeat: node names, texture paths, controller targets. A read interns the bytes
(`@dream/intern`, lowered in native code: a hash and a compare, no string made) and makes the
Luau string only the first time it sees a spelling; after that the string is a read by token.
One pool for the process, so a name shared by a thousand files is made once. It only grows,
by one entry per distinct spelling read, about 50 bytes native plus the string.

The readers call `field` rather than intern where they read: the lowering is compiled at every
place an intern is written, about three quarters of a millisecond a place, which fifty readers
with a name each would pay the first time each was used.
]]

local bytes = require '@dream/bytes'
local intern = require '@dream/intern'

local spellings: dream_intern_Pool = intern.new 'exact'


--- Each token's text as a record holds it: cut at the first NUL and decoded from Windows-1252.
--- A spelling with a NUL in it has the text before the NUL, so a reader can intern a field's
--- whole span and cut it once per spelling, or intern the cut span; both find the same text.
local Decoded: { string } = {}


--- Text in records is Windows-1252, as OpenMW and jess-nif read it: the `length` bytes from
--- `offset` in `source` as UTF-8. ASCII, nearly all of it, is as it is.
local function decode(source: buffer, offset: number, length: number): string
  local raw = buffer.readstring(source, offset, length)
  if not string.find(raw, '[\128-\255]') then return raw end

  return bytes.decode(raw, 'windows-1252')
end

--- The `length` bytes from `offset` in `source` cut at the first NUL, the way OpenMW reads names,
--- and decoded.
local function cut(source: buffer, offset: number, length: number): string
  local raw = buffer.readstring(source, offset, length)
  local nul = string.find(raw, '\0', 1, true)
  if nul then raw = string.sub(raw, 1, nul - 1) end

  if not string.find(raw, '[\128-\255]') then return raw end

  return bytes.decode(raw, 'windows-1252')
end

--- The text a record's string field holds, `length` bytes from `offset` in `source`: cut at the
--- first NUL and decoded, made once per spelling.
local function field(source: buffer, offset: number, length: number): string
  local token = spellings:intern(source, offset, length)
  local text = Decoded[token]
  if text then return text end

  text = cut(source, offset, length)
  Decoded[token] = text
  return text
end

--- Each string's Windows-1252 bytes, by the string: a save writes the same names over and over.
local encoded: { [string]: string } = {}

--- Text as the Windows-1252 bytes a record stores; a character Windows-1252 lacks is an error.
local function encode(text: string): string
  local made = encoded[text]
  if made then return made end

  made = if string.find(text, '[\128-\255]')
    then buffer.tostring(bytes.encode(text, 'windows-1252'))
    else text
  encoded[text] = made
  return made
end

return table.freeze {
  pool = spellings,
  decoded = Decoded,
  field = field,
  decode = decode,
  cut = cut,
  encode = encode,
}
