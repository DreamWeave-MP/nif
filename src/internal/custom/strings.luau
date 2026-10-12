--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The one string reader the custom codecs share. It is a module of its own, and not a copy in each
codec's, because its interning is lowered to native code where it is called, about a millisecond
of compiling for each place: here that is paid once, by the first codec that reads a string.
]]

local Text = require '../text'

local Spellings: dream_intern_Pool = Text.pool
local Strings = Text.decoded

--- A u32 length and the bytes, cut at the first NUL the way OpenMW reads names. The whole field
--- is interned (in native code), and cut and decoded once per spelling.
local function read(bytes: buffer, cursor: number): (string, number)
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

return table.freeze { read = read }
