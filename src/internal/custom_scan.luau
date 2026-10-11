--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The scanners for the fields `custom.luau` reads and writes: each walks past its field, collecting
the links it holds (`(bytes, cursor, links, linkCount, ...) -> (cursor, linkCount)`), and decodes
nothing. `open` needs only these, so it never loads the decoders.
]]

local Array = require './array'
local Enums = require './enums'

type Links = { number }

local function scanLink(bytes: buffer, cursor: number, links: Links, linkCount: number): number
  local value = buffer.readi32(bytes, cursor)
  if value < 0 then return linkCount end

  linkCount += 1
  links[linkCount] = value
  return linkCount
end

local function sumU16(bytes: buffer, cursor: number, count: number): number
  local total = 0
  for index = 0, count - 1 do
    total += buffer.readu16(bytes, cursor + index * 2)
  end

  return total
end

local function invalidKeyType(kind: number): never
  local name = Enums.names.KeyType[kind] or 'NoInterp'
  error(`Invalid KeyType: {name}`, 0)
end

--- A key union's scanner: `strides` holds each key type's size; `always` says the kind is stored
--- even with no keys.
local function keyUnion(kinds: { Array.Kind }, always: boolean?)
  local strides = {}
  for kind, arrayKind in kinds do
    strides[kind] = Array.strides[arrayKind]
  end

  return function(bytes: buffer, cursor: number, _links: Links, linkCount: number): (number, number)
    local count = buffer.readu32(bytes, cursor)
    if count == 0 then return if always then cursor + 8 else cursor + 4, linkCount end

    local kind = buffer.readu32(bytes, cursor + 4)
    local stride = strides[kind]
    if not stride then invalidKeyType(kind) end

    return cursor + 8 + count * stride, linkCount
  end
end

local FloatKinds: { Array.Kind } = { 'floatLin', 'floatBez', 'floatTcb' }
local floatKeys = keyUnion(FloatKinds)
local quaternionKeys = keyUnion { 'rotLin', 'rotLin', 'rotTcb' }

--- Rotation keys, or Euler angles as three float curves.
local function rotKeys(
  bytes: buffer,
  cursor: number,
  links: Links,
  linkCount: number
): (number, number)
  if buffer.readu32(bytes, cursor) == 0 or buffer.readu32(bytes, cursor + 4) ~= 4 then
    return quaternionKeys(bytes, cursor, links, linkCount)
  end

  cursor, linkCount = floatKeys(bytes, cursor + 12, links, linkCount)
  cursor, linkCount = floatKeys(bytes, cursor, links, linkCount)
  return floatKeys(bytes, cursor, links, linkCount)
end

--- A sphere, an oriented box, or a union of volumes.
local function boundingVolume(
  bytes: buffer,
  cursor: number,
  links: Links,
  linkCount: number
): (number, number)
  local kind = buffer.readi32(bytes, cursor)
  cursor += 4
  if kind == 0 then return cursor + 16, linkCount end

  if kind == 1 then return cursor + 60, linkCount end

  if kind ~= 4 then error(`Invalid BoundType: {Enums.names.BoundType[kind] or 'Sphere'}`, 0) end

  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  for _ = 1, count do
    cursor, linkCount = boundingVolume(bytes, cursor, links, linkCount)
  end

  return cursor, linkCount
end

--- Slot 5 is the bump map, which is longer than the rest.
local function textureMaps(
  bytes: buffer,
  cursor: number,
  links: Links,
  linkCount: number
): (number, number)
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  for slot = 0, count - 1 do
    local present = buffer.readu32(bytes, cursor) ~= 0
    cursor += 4
    if present then
      linkCount = scanLink(bytes, cursor, links, linkCount)
      cursor += if slot == 5 then 46 else 22
    end
  end

  return cursor, linkCount
end

local function textureSource(
  bytes: buffer,
  cursor: number,
  links: Links,
  linkCount: number
): (number, number)
  if buffer.readu8(bytes, cursor) ~= 0 then
    return cursor + 5 + buffer.readu32(bytes, cursor + 1), linkCount
  end

  if buffer.readu8(bytes, cursor + 1) ~= 0 then
    return cursor + 6, scanLink(bytes, cursor + 2, links, linkCount)
  end

  return cursor + 2, linkCount
end

local function sequenceTarget(
  bytes: buffer,
  cursor: number,
  _links: Links,
  linkCount: number
): (number, number)
  if buffer.readu8(bytes, cursor) ~= 0 then
    return cursor + 5 + buffer.readu32(bytes, cursor + 1), linkCount
  end

  return cursor + 9, linkCount
end

local function nameControllerPairs(
  bytes: buffer,
  cursor: number,
  _links: Links,
  linkCount: number
): (number, number)
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  for _ = 1, count do
    cursor += 8 + buffer.readu32(bytes, cursor)
  end

  return cursor, linkCount
end

local function sharedNormals(
  bytes: buffer,
  cursor: number,
  _links: Links,
  linkCount: number
): (number, number)
  local count = buffer.readu16(bytes, cursor)
  cursor += 2
  for _ = 1, count do
    cursor += 2 + 2 * buffer.readu16(bytes, cursor)
  end

  return cursor, linkCount
end

local function uvSets(
  _bytes: buffer,
  cursor: number,
  _links: Links,
  linkCount: number,
  sets: number,
  vertices: number
): (number, number)
  return cursor + sets * vertices * 8, linkCount
end

return table.freeze {
  scanLink = scanLink,
  sumU16 = sumU16,
  floatKeys = floatKeys,
  morphKeys = keyUnion(FloatKinds, true),
  posKeys = keyUnion { 'posLin', 'posBez', 'posTcb' },
  rotKeys = rotKeys,
  colorKeys = keyUnion { 'colorLin' },
  boundingVolume = boundingVolume,
  textureMaps = textureMaps,
  textureSource = textureSource,
  sequenceTarget = sequenceTarget,
  nameControllerPairs = nameControllerPairs,
  sharedNormals = sharedNormals,
  uvSets = uvSets,
}
