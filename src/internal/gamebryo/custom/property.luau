--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's `components/nif/property.hpp` values and checks the schema can't state as steps.
]]

local Stream = require '../stream'
local Links = require '../links'

type Stream = Stream.Stream
type ReadTexture = (stream: Stream, cursor: number) -> (any, number)

local custom = {}

--- Every disabled texture reads the same: `enabled` false, every other field its default. One
--- frozen texture stands for them all, made from the first one read.
local disabled: any = nil

--- A texture, or the shared disabled one without reading a table for it.
local function texture(stream: Stream, cursor: number, readTexture: ReadTexture): (any, number)
  local enabled
  if stream.version < 0x04010000 then
    enabled = buffer.readi32(stream.bytes, cursor) ~= 0
  else
    enabled = buffer.readi8(stream.bytes, cursor) ~= 0
  end

  if enabled or not disabled then
    local read, after = readTexture(stream, cursor)
    if not enabled then disabled = table.freeze(read) end

    return read, after
  end

  return disabled, cursor + if stream.version < 0x04010000 then 4 else 1
end

--- What `texturingMaps` returns, filled again by every call: its reader copies the fields out
--- before the next record is read.
local Maps = {
  textures = Stream.empty :: { any },
  shaderTextures = Stream.empty :: { any },
  shaderIds = Stream.empty :: { number },
  envMapLumaBias = vector.zero,
  bumpMapMatrix = Stream.zero4,
  parallaxOffset = 0,
}

--- `NiTexturingProperty`'s textures and shader textures with what follows some of them: the
--- environment map's luma bias and bump map matrix after the sixth texture, if enabled, and the
--- parallax offset after the eighth.
function custom.texturingMaps(
  stream: Stream,
  cursor: number,
  readTexture: ReadTexture
): (any, number)
  local bytes, version = stream.bytes, stream.version
  local maps = Maps
  maps.envMapLumaBias, maps.bumpMapMatrix, maps.parallaxOffset = vector.zero, Stream.zero4, 0

  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  local textures = if count == 0 then Stream.empty else table.create(count)
  for slot = 1, count do
    local read
    read, cursor = texture(stream, cursor, readTexture)
    textures[slot] = read
    if slot == 6 and read.enabled then
      maps.envMapLumaBias =
        vector.create(buffer.readf32(bytes, cursor), buffer.readf32(bytes, cursor + 4), 0)
      maps.bumpMapMatrix = {
        buffer.readf32(bytes, cursor + 8),
        buffer.readf32(bytes, cursor + 12),
        buffer.readf32(bytes, cursor + 16),
        buffer.readf32(bytes, cursor + 20),
      }
      cursor += 24
    elseif slot == 8 and read.enabled and version >= 0x14020005 then
      maps.parallaxOffset = buffer.readf32(bytes, cursor)
      cursor += 4
    end
  end

  maps.textures, maps.shaderTextures, maps.shaderIds = textures, Stream.empty, Stream.empty
  if version < 0x0A000100 then return maps, cursor end

  count = buffer.readu32(bytes, cursor)
  cursor += 4
  if count == 0 then return maps, cursor end

  local shaderTextures, shaderIds =
    table.create(count) :: { any }, table.create(count) :: { number }
  for index = 1, count do
    local read
    read, cursor = texture(stream, cursor, readTexture)
    local id = 0
    if read.enabled then
      id = buffer.readu32(bytes, cursor)
      cursor += 4
    end

    shaderTextures[index], shaderIds[index] = read, id
  end

  maps.shaderTextures, maps.shaderIds = shaderTextures, shaderIds
  return maps, cursor
end

function custom.texturingLinks(record: any, records: { any }, classes: { string }, index: number)
  for _, texture in record.textures do
    Links.link(texture.sourceTexture, 'NiSourceTexture', records, classes, index)
  end

  for _, texture in record.shaderTextures do
    Links.link(texture.sourceTexture, 'NiSourceTexture', records, classes, index)
  end
end

return custom
