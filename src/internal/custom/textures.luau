--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

local Enums = require '../enums'
local Text = require '../text'
local Types = require '../types'
local Writer = require '../writer'

type Writer = Writer.Writer
type Map = { [number]: number }
type Links = { number }

local Names, Values = Enums.names, Enums.values

--- A u32 length and the bytes, cut at the first NUL the way OpenMW reads names and decoded, once
--- per spelling.
local function readString(bytes: buffer, cursor: number): (string, number)
  local length = buffer.readu32(bytes, cursor)
  if length == 0 then return '', cursor + 4 end

  return Text.field(bytes, cursor + 4, length), cursor + 4 + length
end

local function enumName(names: { [number]: string }, value: number): string | number
  return names[value] or value
end

local function enumValue(values: { [string]: number }, value: string | number): number
  if type(value) == 'number' then return value end

  local number = values[value]
  if not number then error(`unknown enum value '{value}'`, 0) end

  return number
end

local function readLink(bytes: buffer, cursor: number): number?
  local value = buffer.readi32(bytes, cursor)
  if value < 0 then return nil end

  return value
end

--- Writes a float, flagging the writer when it is NaN (see `restoreNans` in `init.luau`).
local function writeF32(writer: Writer, cursor: number, value: number)
  buffer.writef32(writer.bytes, cursor, value)
  if value ~= value then writer.nan = true end
end

-- Texture maps: a count of slots, each a flag and a map. Slot 5 is the bump map; the rest are
-- named base, dark, detail, gloss, glow, and decals from 6 on.
--- A slot's map; enums are their names, or numbers no name has. `types.luau` has the names.
type TextureMap = {
  texture: number?,
  clampMode: string | number,
  filterMode: string | number,
  textureIndex: number,
  ps2L: number,
  ps2K: number,
  unknownFlag1: number,
  unknownFlag2: number,
  lumaScale: number?,
  lumaOffset: number?,
  displacement: { number }?,
}

type TextureMaps = {
  slots: number,
  base: TextureMap?,
  dark: TextureMap?,
  detail: TextureMap?,
  gloss: TextureMap?,
  glow: TextureMap?,
  bump: TextureMap?,
  decals: { TextureMap | false }?,
}
local BumpSlot = 5

local function readMap(bytes: buffer, cursor: number, bump: boolean): (TextureMap, number)
  local map: TextureMap = {
    texture = readLink(bytes, cursor),
    clampMode = enumName(Names.ClampMode, buffer.readi32(bytes, cursor + 4)),
    filterMode = enumName(Names.FilterMode, buffer.readi32(bytes, cursor + 8)),
    textureIndex = buffer.readu32(bytes, cursor + 12),
    ps2L = buffer.readi16(bytes, cursor + 16),
    ps2K = buffer.readi16(bytes, cursor + 18),
    unknownFlag1 = buffer.readu8(bytes, cursor + 20),
    unknownFlag2 = buffer.readu8(bytes, cursor + 21),
  }

  if not bump then return map, cursor + 22 end

  map.lumaScale = buffer.readf32(bytes, cursor + 22)
  map.lumaOffset = buffer.readf32(bytes, cursor + 26)
  map.displacement = {
    buffer.readf32(bytes, cursor + 30),
    buffer.readf32(bytes, cursor + 34),
    buffer.readf32(bytes, cursor + 38),
    buffer.readf32(bytes, cursor + 42),
  }
  return map, cursor + 46
end

local function writeMap(writer: Writer, map: TextureMap, links: Map, bump: boolean)
  Writer.reserve(writer, 50)
  local {bytes, cursor} = writer
  buffer.writeu32(bytes, cursor, 1)
  buffer.writei32(bytes, cursor + 4, Writer.link(map.texture, links))
  buffer.writei32(bytes, cursor + 8, enumValue(Values.ClampMode, map.clampMode or 'WrapSWrapT'))
  buffer.writei32(bytes, cursor + 12, enumValue(Values.FilterMode, map.filterMode or 'Trilerp'))
  buffer.writeu32(bytes, cursor + 16, map.textureIndex or 0)
  buffer.writei16(bytes, cursor + 20, map.ps2L or 0)
  buffer.writei16(bytes, cursor + 22, map.ps2K or -75)
  buffer.writeu8(bytes, cursor + 24, map.unknownFlag1 or 0)
  buffer.writeu8(bytes, cursor + 25, map.unknownFlag2 or 0)
  if not bump then
    writer.cursor = cursor + 26
    return
  end

  local displacement = map.displacement or { 1, 0, 0, 1 }
  writeF32(writer, cursor + 26, map.lumaScale or 0)
  writeF32(writer, cursor + 30, map.lumaOffset or 0)
  writeF32(writer, cursor + 34, displacement[1])
  writeF32(writer, cursor + 38, displacement[2])
  writeF32(writer, cursor + 42, displacement[3])
  writeF32(writer, cursor + 46, displacement[4])
  writer.cursor = cursor + 50
end

local textureMaps = {}

function textureMaps.read(bytes: buffer, cursor: number): (TextureMaps, number)
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  local maps: TextureMaps = { slots = count }
  local decals: { TextureMap | false } = {}
  for slot = 0, count - 1 do
    local present = buffer.readu32(bytes, cursor) ~= 0
    cursor += 4
    local map
    if present then
      map, cursor = readMap(bytes, cursor, slot == BumpSlot)
    end

    if slot == 0 then
      maps.base = map
    elseif slot == 1 then
      maps.dark = map
    elseif slot == 2 then
      maps.detail = map
    elseif slot == 3 then
      maps.gloss = map
    elseif slot == 4 then
      maps.glow = map
    elseif slot == BumpSlot then
      maps.bump = map
    else
      decals[slot - BumpSlot] = map or false
    end
  end

  while #decals > 0 and not decals[#decals] do
    decals[#decals] = nil
  end

  if #decals > 0 then maps.decals = decals end

  return maps, cursor
end

--- The map in a slot: 0 to 4 by name, 5 the bump map, the decals after.
local function slotMap(maps: TextureMaps, slot: number): TextureMap?
  if slot == 0 then return maps.base end

  if slot == 1 then return maps.dark end

  if slot == 2 then return maps.detail end

  if slot == 3 then return maps.gloss end

  if slot == 4 then return maps.glow end

  if slot == BumpSlot then return maps.bump end

  local decals = maps.decals
  return decals and decals[slot - BumpSlot] or nil
end

--- How many slots to write: at least the file's count, and enough for every map.
local function slotCount(maps: TextureMaps): number
  local used = 0
  local decals = maps.decals
  if decals then
    for index = #decals, 1, -1 do
      if decals[index] then
        used = BumpSlot + index + 1
        break
      end
    end
  end

  if used == 0 then
    for slot = BumpSlot, 0, -1 do
      if slotMap(maps, slot) then
        used = slot + 1
        break
      end
    end
  end

  return math.max(maps.slots or 0, used)
end

function textureMaps.write(writer: Writer, value: TextureMaps, map: Map)
  local count = slotCount(value)
  Writer.reserve(writer, 4)
  buffer.writeu32(writer.bytes, writer.cursor, count)
  writer.cursor += 4
  for slot = 0, count - 1 do
    local entry = slotMap(value, slot)
    if entry then
      writeMap(writer, entry, map, slot == BumpSlot)
    else
      Writer.reserve(writer, 4)
      buffer.writeu32(writer.bytes, writer.cursor, 0)
      writer.cursor += 4
    end
  end
end

function textureMaps.links(value: TextureMaps, links: Links, linkCount: number): number
  for slot = 0, slotCount(value) - 1 do
    local entry = slotMap(value, slot)
    local texture = entry and entry.texture
    if texture then
      linkCount += 1
      links[linkCount] = texture
    end
  end

  return linkCount
end

-- A texture's source: an external file name, or an internal NiPixelData link.
local textureSource = {}

function textureSource.read(bytes: buffer, cursor: number): (Types.TextureSource, number)
  if buffer.readu8(bytes, cursor) ~= 0 then
    local name
    name, cursor = readString(bytes, cursor + 1)
    return { external = name }, cursor
  end

  if buffer.readu8(bytes, cursor + 1) ~= 0 then
    return { internal = readLink(bytes, cursor + 2) }, cursor + 6
  end

  return {}, cursor + 2
end

function textureSource.write(writer: Writer, value: Types.TextureSource, map: Map)
  Writer.reserve(writer, 6)
  local external = value.external
  if external then
    buffer.writeu8(writer.bytes, writer.cursor, 1)
    writer.cursor += 1
    Writer.string(writer, external)
    return
  end

  buffer.writeu8(writer.bytes, writer.cursor, 0)
  local internal = value.internal
  if internal == nil then
    buffer.writeu8(writer.bytes, writer.cursor + 1, 0)
    writer.cursor += 2
    return
  end

  buffer.writeu8(writer.bytes, writer.cursor + 1, 1)
  buffer.writei32(writer.bytes, writer.cursor + 2, Writer.link(internal, map))
  writer.cursor += 6
end

function textureSource.links(value: Types.TextureSource, links: Links, linkCount: number): number
  local internal = value.internal
  if internal == nil then return linkCount end

  linkCount += 1
  links[linkCount] = internal
  return linkCount
end

return table.freeze { textureMaps = textureMaps, textureSource = textureSource }
