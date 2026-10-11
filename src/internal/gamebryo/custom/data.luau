--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's `components/nif/data.hpp` values and checks the schema can't state as steps, and the
key groups (`nifkey.hpp`) records read their animations from.
]]

local Array = require '../../array'
local Stream = require '../stream'
local Lists = require '../lists'

type Stream = Stream.Stream
type ReadValue = (stream: Stream, cursor: number) -> (any, number)

--- One key: its time and value, tangents for quadratic keys, and tension, continuity, and bias
--- for TCB keys.
export type Key = { time: number, value: any, inTan: any?, outTan: any?, tcb: { number }? }

--- `KeyMapT`: a key group, its keys in file order.
export type KeyMap = {
  frameName: string,
  legacyWeight: number,
  interpolationType: number,
  keys: { Key },
}

local custom = {}

local function vec3(bytes: buffer, cursor: number): vector
  return vector.create(
    buffer.readf32(bytes, cursor),
    buffer.readf32(bytes, cursor + 4),
    buffer.readf32(bytes, cursor + 8)
  )
end

local function readFloat(stream: Stream, cursor: number): (number, number)
  return buffer.readf32(stream.bytes, cursor), cursor + 4
end

local function readVec3(stream: Stream, cursor: number): (vector, number)
  return vec3(stream.bytes, cursor), cursor + 12
end

local function readVec4(stream: Stream, cursor: number): ({ number }, number)
  local bytes = stream.bytes
  return {
    buffer.readf32(bytes, cursor),
    buffer.readf32(bytes, cursor + 4),
    buffer.readf32(bytes, cursor + 8),
    buffer.readf32(bytes, cursor + 12),
  },
    cursor + 16
end

--- Stored `w, x, y, z`; kept `x, y, z, w`.
local function readQuat(stream: Stream, cursor: number): ({ number }, number)
  local bytes = stream.bytes
  return {
    buffer.readf32(bytes, cursor + 4),
    buffer.readf32(bytes, cursor + 8),
    buffer.readf32(bytes, cursor + 12),
    buffer.readf32(bytes, cursor),
  },
    cursor + 16
end

--- Booleans are 4 bytes before 4.1.0.0 and 1 byte after.
local function readBool(stream: Stream, cursor: number): (boolean, number)
  if stream.version < 0x04010000 then
    return buffer.readi32(stream.bytes, cursor) ~= 0, cursor + 4
  end

  return buffer.readi8(stream.bytes, cursor) ~= 0, cursor + 1
end

--- `KeyMapT::read`. Morph key groups start with a frame name, and after 10.1.0.0 have no keys
--- at all. Quaternion keys never carry tangents; XYZ rotations are read by their owner.
local function keyMap(
  stream: Stream,
  cursor: number,
  value: ReadValue,
  tangents: boolean,
  morph: boolean?
): (KeyMap, number)
  local bytes, version = stream.bytes, stream.version
  local map: KeyMap =
    { frameName = '', legacyWeight = 0, interpolationType = 0, keys = Stream.empty :: any }
  if morph then
    if version >= 0x0A01006A then
      map.frameName, cursor = Stream.string(stream, cursor)
    end

    if version > 0x0A010000 then
      if version >= 0x0A010068 and version <= 0x14010002 and stream.bethVersion < 10 then
        map.legacyWeight = buffer.readf32(bytes, cursor)
        cursor += 4
      end

      return map, cursor
    end
  end

  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  if count == 0 and not morph then return map, cursor end

  local interpolation = buffer.readu32(bytes, cursor)
  cursor += 4
  map.interpolationType = interpolation
  local withTangents, tcb = false, false
  if interpolation == 2 then
    withTangents = tangents
  elseif interpolation == 3 then
    tcb = true
  elseif interpolation ~= 1 and interpolation ~= 5 then
    -- XYZ rotations are read by their owner as three float key groups.
    if interpolation ~= 4 and count ~= 0 then
      Stream.fail(`Unhandled interpolation type: {interpolation}`)
    end

    return map, cursor
  end

  Stream.checkSize(stream, count)
  if count == 0 then return map, cursor end

  -- One key, read when asked for: every key of a map is the same size, so the keys are rows.
  local function key(_: buffer, at: number): Key
    local read: Key = { time = buffer.readf32(bytes, at), value = nil }
    read.value, at = value(stream, at + 4)
    if withTangents then
      read.inTan, at = value(stream, at)
      read.outTan, at = value(stream, at)
    end

    if tcb then
      read.tcb = {
        buffer.readf32(bytes, at),
        buffer.readf32(bytes, at + 4),
        buffer.readf32(bytes, at + 8),
      }
    end

    return read
  end

  local stride = 4 + if tcb then 12 else 0
  local _, afterValue = value(stream, cursor + 4)
  stride += (afterValue - cursor - 4) * if withTangents then 3 else 1
  map.keys, cursor = Stream.rows(stream, cursor, count, stride, key)
  return map, cursor
end

function custom.floatKeys(stream: Stream, cursor: number, morph: boolean?): (KeyMap, number)
  return keyMap(stream, cursor, readFloat, true, morph)
end

function custom.vec3Keys(stream: Stream, cursor: number): (KeyMap, number)
  return keyMap(stream, cursor, readVec3, true)
end

function custom.vec4Keys(stream: Stream, cursor: number): (KeyMap, number)
  return keyMap(stream, cursor, readVec4, true)
end

function custom.quatKeys(stream: Stream, cursor: number): (KeyMap, number)
  return keyMap(stream, cursor, readQuat, false)
end

function custom.boolKeys(stream: Stream, cursor: number): (KeyMap, number)
  return keyMap(stream, cursor, readBool, true)
end

--- `count` UV sets of `vertices` coordinates each.
function custom.vec2Lists(
  stream: Stream,
  cursor: number,
  count: number,
  vertices: number
): ({ any }, number)
  local lists = table.create(count) :: { any }
  for index = 1, count do
    Stream.checkSize(stream, vertices * 8)
    lists[index], cursor = Stream.view(stream, cursor, vertices, 'vec2', 8)
  end

  return lists, cursor
end

--- A `u16` count of lists, each a `u16` count of `u16`s: walked to its end, its lists indexed
--- only when one is asked for.
function custom.u16Lists(stream: Stream, cursor: number): (any, number)
  local bytes, length = stream.bytes, stream.length
  local count = buffer.readu16(bytes, cursor)
  cursor += 2
  if count == 0 then return Stream.empty, cursor end

  local start = cursor
  for _ = 1, count do
    local size = buffer.readu16(bytes, cursor) * 2
    cursor += 2
    if size > length then
      Stream.fail(`Trying to read more than stream size: {size} max={length}`)
    end

    if cursor + size > length then
      Stream.fail(`Failed to read u16: 2 bytes at offset {length} of {length}`)
    end

    cursor += size
  end

  return Lists.prefixed(bytes, start, count), cursor
end

--- One list of `u16`s for each of `lengths`, back to back.
function custom.strips(stream: Stream, cursor: number, lengths: any): (any, number)
  local count = lengths.count
  if count == 0 then return Stream.empty, cursor end

  local length, start = stream.length, cursor
  local from, at = lengths.buffer, lengths.offset
  for index = 0, count - 1 do
    local size = buffer.readu16(from, at + index * 2) * 2
    if size > length then
      Stream.fail(`Trying to read more than stream size: {size} max={length}`)
    end

    if cursor + size > length then
      Stream.fail(`Failed to read u16: 2 bytes at offset {length} of {length}`)
    end

    cursor += size
  end

  return Lists.sized(stream.bytes, start, lengths), cursor
end

--- `readVector` of `length` bytes.
local function byteVector(stream: Stream, cursor: number, length: number): number
  Stream.checkSize(stream, length)
  if cursor + length > stream.length then
    Stream.fail(`Failed to read byte vector: {length} bytes at offset {cursor} of {stream.length}`)
  end

  return cursor + length
end

--- Bytes jess-nif keeps but doesn't report.
function custom.bytes(stream: Stream, cursor: number, length: number): (nil, number)
  return nil, byteVector(stream, cursor, length)
end

--- `NiLinesData`'s lines, as pairs of vertex indices, from a connectivity flag per vertex; the
--- last vertex connects back to the first.
function custom.lines(stream: Stream, cursor: number, count: number): ({ number }, number)
  local bytes = stream.bytes
  local stop = byteVector(stream, cursor, count)
  local lines = {} :: { number }
  -- Can't construct a line from a single vertex.
  if count >= 2 then
    for vertex = 0, count - 2 do
      if bit32.btest(buffer.readu8(bytes, cursor + vertex), 1) then
        table.insert(lines, vertex)
        table.insert(lines, vertex + 1)
      end
    end

    if bit32.btest(buffer.readu8(bytes, cursor + count - 1), 1) then
      table.insert(lines, count - 1)
      table.insert(lines, 0)
    end
  end

  return lines, stop
end

--- `NiVisData`'s keys, as time and whether visible.
function custom.visKeys(stream: Stream, cursor: number): ({ { any } }, number)
  local bytes = stream.bytes
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  local keys = table.create(count) :: { { any } }
  for index = 1, count do
    keys[index] = { buffer.readf32(bytes, cursor), buffer.readu8(bytes, cursor + 4) ~= 0 }
    cursor += 5
  end

  return keys, cursor
end

--- `NiSkinData::BoneInfo` for each of `count` bones: a transform, bounds, and the vertices it
--- weighs on as `(vertex, weight)`.
function custom.skinBones(
  stream: Stream,
  cursor: number,
  count: number,
  weighted: boolean
): ({ any }, number)
  local bytes = stream.bytes
  local bones = table.create(count) :: { any }
  for index = 1, count do
    local bone = {
      transform = {
        rotation = Stream.mat3(bytes, cursor),
        translation = vec3(bytes, cursor + 36),
        scale = buffer.readf32(bytes, cursor + 48),
      },
      boundSphere = {
        center = vec3(bytes, cursor + 52),
        radius = buffer.readf32(bytes, cursor + 64),
      },
      weights = Array.empty.u16f32,
    }

    local vertices = buffer.readu16(bytes, cursor + 68)
    cursor += 70
    if weighted then
      bone.weights, cursor = Stream.view(stream, cursor, vertices, 'u16f32', 6)
    end

    bones[index] = bone
  end

  return bones, cursor
end

--- `NiMorphData::MorphData` for each of `count` morph targets: keys and `vertices` vertices.
function custom.morphs(
  stream: Stream,
  cursor: number,
  count: number,
  vertices: number
): ({ any }, number)
  local morphs = table.create(count) :: { any }
  for index = 1, count do
    local keyFrames, list
    keyFrames, cursor = keyMap(stream, cursor, readFloat, true, true)
    Stream.checkSize(stream, vertices * 12)
    list, cursor = Stream.view(stream, cursor, vertices, 'vec3', 12)
    morphs[index] = { keyFrames = keyFrames, vertices = list }
  end

  return morphs, cursor
end

--- `NiPalette`'s 256 colors; indices past 255 are unused, and without alpha every color is
--- opaque.
function custom.paletteColors(stream: Stream, cursor: number, alpha: boolean): ({ number }, number)
  local bytes = stream.bytes
  local mask = if alpha then 0 else 0xFF000000
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  local colors = table.create(256, 0) :: { number }
  for index = 1, count do
    if index <= 256 then colors[index] = bit32.bor(buffer.readu32(bytes, cursor), mask) end

    cursor += 4
  end

  return colors, cursor
end

local function u32List(stream: Stream, cursor: number): ({ number }, number)
  local bytes = stream.bytes
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  Stream.checkSize(stream, count * 4)
  local list = table.create(count) :: { number }
  for index = 1, count do
    list[index] = buffer.readu32(bytes, cursor)
    cursor += 4
  end

  return list, cursor
end

--- `NiAdditionalGeometryData::DataBlock`s; only `BSPackedAdditionalGeometryData`'s (`packed`)
--- have a shader index and total size.
function custom.geometryBlocks(stream: Stream, cursor: number, packed: boolean): ({ any }, number)
  local bytes = stream.bytes
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  local blocks = table.create(count) :: { any }
  for index = 1, count do
    local valid
    valid, cursor = readBool(stream, cursor)
    local block = {
      valid = valid,
      blockSize = 0,
      blockOffsets = {} :: { number },
      dataSizes = {} :: { number },
      shaderIndex = 0,
      totalSize = 0,
    }

    blocks[index] = block
    if not valid then continue end

    block.blockSize = buffer.readu32(bytes, cursor)
    block.blockOffsets, cursor = u32List(stream, cursor + 4)
    block.dataSizes, cursor = u32List(stream, cursor)
    cursor = byteVector(stream, cursor, #block.dataSizes * block.blockSize)
    if packed then
      block.shaderIndex, block.totalSize =
        buffer.readu32(bytes, cursor), buffer.readu32(bytes, cursor + 4)
      cursor += 8
    end
  end

  return blocks, cursor
end

--- `BSVertexDesc` as a record holds it when the file has none.
function custom.noVertexDesc(): any
  return {
    vertexDataSize = 0,
    dynamicVertexSize = 0,
    uv1Offset = 0,
    uv2Offset = 0,
    normalOffset = 0,
    tangentOffset = 0,
    colorOffset = 0,
    skinningDataOffset = 0,
    landscapeDataOffset = 0,
    eyeDataOffset = 0,
    flags = 0,
  }
end

--- `list`'s indices through `map` (both `u16` views), an index past the map kept as it is, as a
--- new `u16` array, worked out the first time it is read.
function custom.remap(list: any, map: any): any
  local count = list.count
  return Array.lazy('u16', count, function(to: buffer)
    local size, from, at, mapBuffer, mapAt =
      map.count, list.buffer, list.offset, map.buffer, map.offset
    for element = 0, count - 1 do
      local index = buffer.readu16(from, at + element * 2)
      if index < size then index = buffer.readu16(mapBuffer, mapAt + index * 2) end

      buffer.writeu16(to, element * 2, index)
    end
  end)
end

function custom.remapStrips(strips: { any }, map: any): { any }
  local remapped = table.create(#strips) :: { any }
  for index, strip in strips do
    remapped[index] = custom.remap(strip, map)
  end

  return remapped
end

--- `NiSkinInstance::post` and `BSSkinInstance::post`.
local function checkSkin(record: any, records: { any }, kind: string, dataName: string)
  local data = if record.data >= 0 then records[record.data + 1] else nil
  if not data or record.root < 0 then Stream.fail(`{kind} missing root or data`) end

  if #data.bones ~= #record.bones then Stream.fail(`Mismatch in {dataName} bone count`) end

  for _, bone in record.bones do
    if bone < 0 then Stream.fail 'Oops: Missing bone! Don\'t know how to handle this.' end
  end
end

function custom.skinInstance(record: any, records: { any }, _classes: { string }, _index: number)
  checkSkin(record, records, 'NiSkinInstance', 'NiSkinData')
end

function custom.bsSkinInstance(record: any, records: { any }, _classes: { string }, _index: number)
  checkSkin(record, records, 'BSSkin::Instance', 'BSSkin::BoneData')
end

return custom
