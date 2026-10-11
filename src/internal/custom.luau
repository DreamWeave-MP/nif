--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The fields whose layout the schema can't say: keyframe unions, bounding volumes, texture maps
and sources, sequence targets, shared normals, and UV sets. Each codec comes as `read`
(`(bytes, cursor, ...) -> (value, cursor)`), `write` (`(writer, value, map, ...)`), and, when it
holds links, `links` (`(value, links, linkCount) -> linkCount`), the shapes the record modules
have for the rest; their scanners are `custom_scan.luau`.
]]

local Array = require './array'
local Enums = require './enums'
local Text = require './text'
local Types = require './types'
local Writer = require './writer'

type Writer = Writer.Writer
type Map = { [number]: number }
type Links = { number }
type Array = Array.Array

local Names, Values = Enums.names, Enums.values
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

--- The identity rotation, shared by every record that stores exactly it (the record modules test
--- the bits): most do. Frozen, so edit a record's rotation by giving it a new table.
local Identity =
  table.freeze { vector.create(1, 0, 0), vector.create(0, 1, 0), vector.create(0, 0, 1) }

--- An array, as far as these codecs need: its bytes and where they are.
type View = Array.ArrayFields

--- A key union: one array under the name of its interpolation. `types.luau` names each union's
--- array kinds (`FloatKeys`, `PosKeys`, ...); the codecs only need that it is an array.
type KeyUnion = { LinKey: View?, BezKey: View?, TCBKey: View? }

--- Euler rotation keys: three float curves and the order they apply in (a name, or the number
--- when the file holds one no name has).
type Euler = { axisOrder: string | number, axes: { { keys: KeyUnion } } }

type RotUnion = { LinKey: View?, BezKey: View?, TCBKey: View?, EulerKey: Euler? }

--- The keys of a union, as its key type and array.
local function keysOf(value: KeyUnion | RotUnion): (number, View)
  if value.LinKey then return 1, value.LinKey end

  if value.BezKey then return 2, value.BezKey end

  if value.TCBKey then return 3, value.TCBKey end

  return 1, Array.empty.floatLin
end

--- The union holding `keys` under key type `kind`'s name.
local function unionOf(kind: number, keys: View): KeyUnion
  if kind == 2 then return { BezKey = keys } end

  if kind == 3 then return { TCBKey = keys } end

  return { LinKey = keys }
end

local function invalidKeyType(kind: number): never
  local name = Names.KeyType[kind] or 'NoInterp'
  error(`Invalid KeyType: {name}`, 0)
end

--- Writes a key array: its count, its kind unless it is empty (or `always`), and its bytes.
local function writeKeys(writer: Writer, kind: number, keys: View, always: boolean?)
  local count = keys.count
  Writer.reserve(writer, 8)
  buffer.writeu32(writer.bytes, writer.cursor, count)
  if count == 0 and not always then
    writer.cursor += 4
    return
  end

  buffer.writeu32(writer.bytes, writer.cursor + 4, kind)
  writer.cursor += 8
  Array.write(writer, keys)
end

type KeyCodec = {
  read: (bytes: buffer, cursor: number) -> (KeyUnion, number),
  write: (writer: Writer, value: KeyUnion, map: Map) -> (),
}

--- One key union's codec: `kinds` maps a key type to its array kind.
local function keyUnion(kinds: { Array.Kind }, always: boolean?): KeyCodec
  local function read(bytes: buffer, cursor: number): (KeyUnion, number)
    local count = buffer.readu32(bytes, cursor)
    local kind = if count == 0 and not always then 1 else buffer.readu32(bytes, cursor + 4)
    local start = if always or count > 0 then cursor + 8 else cursor + 4
    local arrayKind = kinds[kind]
    if not arrayKind then
      if count == 0 then return { LinKey = Array.empty[kinds[1]] }, start end

      invalidKeyType(kind)
    end

    return unionOf(kind, Array.view(bytes, start, count, arrayKind)),
      start + count * Array.strides[arrayKind]
  end

  local function write(writer: Writer, value: KeyUnion, _map: Map)
    local kind, keys = keysOf(value)
    writeKeys(writer, kind, keys, always)
  end

  return { read = read, write = write }
end

-- Float keys: time and value, then tangents (bez) or tension, continuity, bias (tcb).
local floatKeys = keyUnion { 'floatLin', 'floatBez', 'floatTcb' }

-- Morph target keys always carry their kind, even with no keys.
local morphKeys = keyUnion({ 'floatLin', 'floatBez', 'floatTcb' }, true)

-- Position keys: a vector value, with vector tangents (bez) or tension, continuity, bias (tcb).
local posKeys = keyUnion { 'posLin', 'posBez', 'posTcb' }

-- Color keys: linear only, time and r, g, b, a.
local colorKeys = keyUnion { 'colorLin' }

-- Rotation keys: a quaternion (stored w first; read x, y, z, w), or Euler angles as three float
-- curves. Bezier rotation keys carry no tangents.
local quaternionKeys = keyUnion { 'rotLin', 'rotLin', 'rotTcb' }
local rotKeys = {}

function rotKeys.read(bytes: buffer, cursor: number): (RotUnion, number)
  if buffer.readu32(bytes, cursor) == 0 or buffer.readu32(bytes, cursor + 4) ~= 4 then
    local keys, after = quaternionKeys.read(bytes, cursor)
    return { LinKey = keys.LinKey, BezKey = keys.BezKey, TCBKey = keys.TCBKey }, after
  end

  local axisOrder = enumName(Names.AxisOrder, buffer.readi32(bytes, cursor + 8))
  local xKeys, yKeys, zKeys
  xKeys, cursor = floatKeys.read(bytes, cursor + 12)
  yKeys, cursor = floatKeys.read(bytes, cursor)
  zKeys, cursor = floatKeys.read(bytes, cursor)
  return {
    EulerKey = {
      axisOrder = axisOrder,
      axes = { { keys = xKeys }, { keys = yKeys }, { keys = zKeys } },
    },
  },
    cursor
end

--- Euler keys save a count of one when any axis has keys, else none.
local function eulerCount(euler: Euler): number
  for _, axis in euler.axes do
    local _, keys = keysOf(axis.keys)
    if keys.count > 0 then return 1 end
  end

  return 0
end

function rotKeys.write(writer: Writer, value: RotUnion, map: Map)
  local euler = value.EulerKey
  if not euler then
    local kind, keys = keysOf(value)
    writeKeys(writer, kind, keys)
    return
  end

  local count = eulerCount(euler)
  Writer.reserve(writer, 12)
  buffer.writeu32(writer.bytes, writer.cursor, count)
  if count == 0 then
    writer.cursor += 4
    return
  end

  buffer.writeu32(writer.bytes, writer.cursor + 4, 4)
  buffer.writei32(writer.bytes, writer.cursor + 8, enumValue(Values.AxisOrder, euler.axisOrder))
  writer.cursor += 12
  for _, axis in euler.axes do
    floatKeys.write(writer, axis.keys, map)
  end
end

-- Bounding volumes: a sphere, an oriented box, or a union of volumes.
local boundingVolume = {}

function boundingVolume.read(bytes: buffer, cursor: number): (Types.BoundingVolume, number)
  local kind = buffer.readi32(bytes, cursor)
  cursor += 4
  if kind == 0 then
    local bound = { center = readVec3(bytes, cursor), radius = buffer.readf32(bytes, cursor + 12) }
    return { boundData = { NiSphereBV = { bound = bound } } }, cursor + 16
  elseif kind == 1 then
    local box = {
      center = readVec3(bytes, cursor),
      axis = {
        readVec3(bytes, cursor + 12),
        readVec3(bytes, cursor + 24),
        readVec3(bytes, cursor + 36),
      },
      extents = readVec3(bytes, cursor + 48),
    }
    return { boundData = { NiBoxBV = box } }, cursor + 60
  elseif kind == 4 then
    local count = buffer.readu32(bytes, cursor)
    cursor += 4
    local volumes = table.create(count) :: { Types.BoundingVolume }
    for index = 1, count do
      volumes[index], cursor = boundingVolume.read(bytes, cursor)
    end

    return { boundData = { NiUnionBV = { boundingVolumes = volumes } } }, cursor
  end

  error(`Invalid BoundType: {Names.BoundType[kind] or 'Sphere'}`, 0)
end

function boundingVolume.write(writer: Writer, value: Types.BoundingVolume, map: Map)
  local data = value.boundData
  Writer.reserve(writer, 64)
  local bytes, cursor = writer.bytes, writer.cursor
  local sphere, box, union = data.NiSphereBV, data.NiBoxBV, data.NiUnionBV
  if sphere then
    local bound = sphere.bound
    buffer.writei32(bytes, cursor, 0)
    writeVec3(writer, cursor + 4, bound.center)
    writeF32(writer, cursor + 16, bound.radius)
    writer.cursor = cursor + 20
  elseif box then
    buffer.writei32(bytes, cursor, 1)
    writeVec3(writer, cursor + 4, box.center)
    writeVec3(writer, cursor + 16, box.axis[1])
    writeVec3(writer, cursor + 28, box.axis[2])
    writeVec3(writer, cursor + 40, box.axis[3])
    writeVec3(writer, cursor + 52, box.extents)
    writer.cursor = cursor + 64
  elseif union then
    local volumes = union.boundingVolumes
    buffer.writei32(bytes, cursor, 4)
    buffer.writeu32(bytes, cursor + 4, #volumes)
    writer.cursor = cursor + 8
    for _, volume in volumes do
      boundingVolume.write(writer, volume, map)
    end
  end
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
  local bytes, cursor = writer.bytes, writer.cursor
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

--- The one empty list of arrays, frozen, for the many records with no UV sets or shared normals.
local NoViews: { View } = table.freeze({} :: { View })

-- Shared normals: a u16 count of lists, each a u16 count of u16 vertex indices.
local sharedNormals = {}

function sharedNormals.read(bytes: buffer, cursor: number): ({ View }, number)
  local count = buffer.readu16(bytes, cursor)
  cursor += 2
  if count == 0 then return NoViews, cursor end

  local lists = table.create(count) :: { View }
  for index = 1, count do
    local length = buffer.readu16(bytes, cursor)
    lists[index] = Array.view(bytes, cursor + 2, length, 'u16')
    cursor += 2 + length * 2
  end

  return lists, cursor
end

function sharedNormals.write(writer: Writer, value: { View }, _map: Map)
  Writer.reserve(writer, 2)
  buffer.writeu16(writer.bytes, writer.cursor, #value)
  writer.cursor += 2
  for _, indices in value do
    Writer.reserve(writer, 2)
    buffer.writeu16(writer.bytes, writer.cursor, indices.count)
    writer.cursor += 2
    Array.write(writer, indices)
  end
end

-- UV sets: `sets` arrays of `vertices` coordinates, stored one set after another.
local uvSets = {}

function uvSets.read(
  bytes: buffer,
  cursor: number,
  sets: number,
  vertices: number
): ({ View }, number)
  if sets * vertices == 0 then return NoViews, cursor end

  local lists = table.create(sets) :: { View }
  for set = 1, sets do
    lists[set] = Array.view(bytes, cursor, vertices, 'vec2')
    cursor += vertices * 8
  end

  return lists, cursor
end

function uvSets.write(writer: Writer, value: { View }, _map: Map)
  for _, coordinates in value do
    Array.write(writer, coordinates)
  end
end

--- The parts of a geometry record its UV set count is worked out from.
type Geometry = { vertices: View, uvSets: { View } }

local function uvSetTotal(record: Geometry): number
  local total = 0
  for _, coordinates in record.uvSets do
    total += coordinates.count
  end

  return total
end

--- How many sets the saved record says it has: the coordinates over the vertices.
local function uvSetCount(record: Geometry): number
  local vertices = record.vertices.count
  if vertices == 0 then return 0 end

  return uvSetTotal(record) // vertices
end

return table.freeze {
  identity = Identity,
  enumValue = enumValue,
  uvSetTotal = uvSetTotal,
  uvSetCount = uvSetCount,
  floatKeys = floatKeys,
  morphKeys = morphKeys,
  posKeys = posKeys,
  rotKeys = rotKeys,
  colorKeys = colorKeys,
  boundingVolume = boundingVolume,
  textureMaps = textureMaps,
  textureSource = textureSource,
  sequenceTarget = sequenceTarget,
  nameControllerPairs = nameControllerPairs,
  sharedNormals = sharedNormals,
  uvSets = uvSets,
}
