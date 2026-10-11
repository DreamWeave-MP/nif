--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's `components/nif/node.hpp` values and checks the schema can't state as steps.
]]

local Stream = require '../stream'
local Links = require '../links'

type Stream = Stream.Stream

local custom = {}

local function vec3(bytes: buffer, cursor: number): vector
  return vector.create(
    buffer.readf32(bytes, cursor),
    buffer.readf32(bytes, cursor + 4),
    buffer.readf32(bytes, cursor + 8)
  )
end

--- `BoundingVolume::BASE_BV`: no volume.
--- `BoundingVolume::BASE_BV`: no volume, one frozen table for every record without one.
local NoBounds = table.freeze { type = 0xFFFFFFFF }

function custom.noBounds(): any return NoBounds end

--- `BoundingVolume`: a volume of the shape its type names, only that shape kept.
function custom.boundingVolume(stream: Stream, cursor: number): (any, number)
  local bytes = stream.bytes
  local kind = buffer.readu32(bytes, cursor)
  cursor += 4
  if kind == 0xFFFFFFFF then return { type = kind }, cursor end

  if kind == 0 then
    return {
      type = kind,
      sphere = { center = vec3(bytes, cursor), radius = buffer.readf32(bytes, cursor + 12) },
    },
      cursor + 16
  end

  if kind == 1 then
    local volume = {
      center = vec3(bytes, cursor),
      axes = Stream.mat3(bytes, cursor + 12),
      extents = vec3(bytes, cursor + 48),
    }
    return { type = kind, box = volume }, cursor + 60
  end

  if kind == 2 then
    local volume = {
      center = vec3(bytes, cursor),
      axis = vec3(bytes, cursor + 12),
      extent = buffer.readf32(bytes, cursor + 24),
      radius = buffer.readf32(bytes, cursor + 28),
    }

    return { type = kind, capsule = volume }, cursor + 32
  end

  if kind == 3 then
    local radius = buffer.readf32(bytes, cursor)
    cursor += 4
    local extent0, extent1 = 0, 0
    if stream.version >= 0x04020100 then
      extent0, extent1 = buffer.readf32(bytes, cursor), buffer.readf32(bytes, cursor + 4)
      cursor += 8
    end

    local volume = {
      radius = radius,
      extent0 = extent0,
      extent1 = extent1,
      center = vec3(bytes, cursor),
      axis0 = vec3(bytes, cursor + 12),
      axis1 = vec3(bytes, cursor + 24),
    }

    return { type = kind, lozenge = volume }, cursor + 36
  end

  if kind == 4 then
    local count = buffer.readu32(bytes, cursor)
    cursor += 4
    local children = table.create(count) :: { any }
    for index = 1, count do
      children[index], cursor = custom.boundingVolume(stream, cursor)
    end

    return { type = kind, children = children }, cursor
  end

  if kind == 5 then
    local plane = {
      buffer.readf32(bytes, cursor),
      buffer.readf32(bytes, cursor + 4),
      buffer.readf32(bytes, cursor + 8),
      buffer.readf32(bytes, cursor + 12),
    }
    cursor += 16
    local origin = vector.zero
    if stream.version >= 0x04020100 then
      origin = vec3(bytes, cursor)
      cursor += 12
    end

    return { type = kind, halfSpace = { plane = plane, origin = origin } }, cursor
  end

  return Stream.fail(`Unhandled BoundingVolume type: {kind}`)
end

--- `NiDefaultAVObjectPalette`'s objects: name and link pairs, a repeated name replacing the
--- earlier pair's link.
function custom.avObjectPalette(stream: Stream, cursor: number): ({ { any } }, number)
  local bytes = stream.bytes
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  local objects: { { any } }, at: { [string]: number } = {}, {}
  for _ = 1, count do
    local name
    name, cursor = Stream.sizedU32(stream, cursor)
    local index = buffer.readi32(bytes, cursor)
    cursor += 4
    if index < -1 then Stream.invalidLink(index) end

    local existing = at[name]
    if existing then
      objects[existing][2] = index
    else
      table.insert(objects, { name, index })
      at[name] = #objects
    end
  end

  return objects, cursor
end

function custom.paletteLinks(record: any, records: { any }, classes: { string }, index: number)
  for _, object in record.objects do
    Links.link(object[2], 'NiAVObject', records, classes, index)
  end
end

--- `BSVertexDesc`: a `u64` of nibbles; Skyrim SE always stores full-precision vertices.
function custom.vertexDesc(stream: Stream, cursor: number): (any, number)
  local bytes = stream.bytes
  local low, high = buffer.readu32(bytes, cursor), buffer.readu32(bytes, cursor + 4)
  local flags = bit32.extract(high, 12, 12)
  if stream.bethVersion == 100 then flags = bit32.bor(flags, 0x400) end

  local desc = {
    vertexDataSize = bit32.extract(low, 0, 4),
    dynamicVertexSize = bit32.extract(low, 4, 4),
    uv1Offset = bit32.extract(low, 8, 4),
    uv2Offset = bit32.extract(low, 12, 4),
    normalOffset = bit32.extract(low, 16, 4),
    tangentOffset = bit32.extract(low, 20, 4),
    colorOffset = bit32.extract(low, 24, 4),
    skinningDataOffset = bit32.extract(low, 28, 4),
    landscapeDataOffset = bit32.extract(high, 0, 4),
    eyeDataOffset = bit32.extract(high, 4, 4),
    flags = flags,
  }

  return desc, cursor + 8
end

local function bytes4(bytes: buffer, cursor: number): { number }
  return {
    buffer.readu8(bytes, cursor),
    buffer.readu8(bytes, cursor + 1),
    buffer.readu8(bytes, cursor + 2),
    buffer.readu8(bytes, cursor + 3),
  }
end

local function halves(bytes: buffer, cursor: number, count: number): { number }
  local list = table.create(count) :: { number }
  for index = 1, count do
    list[index] = buffer.readu16(bytes, cursor + (index - 1) * 2)
  end

  return list
end

--- The bytes one `BSVertexData` takes, laid out as `flags` says.
local function vertexSize(flags: number): number
  local size = 0
  if bit32.btest(flags, 0x1) then
    size += if bit32.btest(flags, 0x400) then 16 else 8
  end

  if bit32.btest(flags, 0x2) then
    size += 4
  end

  if bit32.btest(flags, 0x8) then
    size += if bit32.btest(flags, 0x10) then 8 else 4
  end

  if bit32.btest(flags, 0x20) then
    size += 4
  end

  if bit32.btest(flags, 0x40) then
    size += 12
  end

  if bit32.btest(flags, 0x100) then
    size += 4
  end

  return size
end

local Zero2: { number } = table.freeze { 0, 0 }

--- `BSVertexData` for each of `count` vertices, laid out as `flags` says, each read when asked
--- for.
function custom.vertexData(
  stream: Stream,
  cursor: number,
  count: number,
  flags: number
): (any, number)
  local function read(bytes: buffer, cursor: number): any
    local zero4 = Stream.zero4
    local vertex = {
      vertex = zero4,
      halfVertex = zero4,
      uv = Zero2,
      normal = zero4,
      tangent = zero4,
      vertColor = zero4,
      boneWeights = zero4,
      boneIndices = zero4,
      eyeData = 0,
    }

    if bit32.btest(flags, 0x1) then
      if bit32.btest(flags, 0x400) then
        vertex.vertex = {
          buffer.readf32(bytes, cursor),
          buffer.readf32(bytes, cursor + 4),
          buffer.readf32(bytes, cursor + 8),
          buffer.readf32(bytes, cursor + 12),
        }
        cursor += 16
      else
        vertex.halfVertex = halves(bytes, cursor, 4)
        cursor += 8
      end
    end

    if bit32.btest(flags, 0x2) then
      vertex.uv = halves(bytes, cursor, 2)
      cursor += 4
    end

    if bit32.btest(flags, 0x8) then
      vertex.normal = bytes4(bytes, cursor)
      cursor += 4
      if bit32.btest(flags, 0x10) then
        vertex.tangent = bytes4(bytes, cursor)
        cursor += 4
      end
    end

    if bit32.btest(flags, 0x20) then
      vertex.vertColor = bytes4(bytes, cursor)
      cursor += 4
    end

    if bit32.btest(flags, 0x40) then
      vertex.boneWeights = halves(bytes, cursor, 4)
      vertex.boneIndices = bytes4(bytes, cursor + 8)
      cursor += 12
    end

    if bit32.btest(flags, 0x100) then
      vertex.eyeData = buffer.readf32(bytes, cursor)
      cursor += 4
    end

    return vertex
  end

  return Stream.rows(stream, cursor, count, vertexSize(flags), read)
end

--- A string with a `u16` length before it.
function custom.sizedU16(stream: Stream, cursor: number): (string, number)
  return Stream.sized(stream, cursor + 2, buffer.readu16(stream.bytes, cursor))
end

--- A `u32` count of rows of `width` floats.
function custom.f32Rows(stream: Stream, cursor: number, width: number): ({ { number } }, number)
  local bytes = stream.bytes
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  Stream.checkSize(stream, count * width * 4)
  local rows = table.create(count) :: { { number } }
  for index = 1, count do
    local row = table.create(width) :: { number }
    for column = 1, width do
      row[column] = buffer.readf32(bytes, cursor)
      cursor += 4
    end

    rows[index] = row
  end

  return rows, cursor
end

--- A `u32` count of lists, each a `u32` count of sized strings.
function custom.stringLists(stream: Stream, cursor: number): ({ { string } }, number)
  local bytes = stream.bytes
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  local lists = table.create(count) :: { { string } }
  for index = 1, count do
    local length = buffer.readu32(bytes, cursor)
    cursor += 4
    local list = table.create(length) :: { string }
    for entry = 1, length do
      list[entry], cursor = Stream.sizedU32(stream, cursor)
    end

    lists[index] = list
  end

  return lists, cursor
end

return custom
