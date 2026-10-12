--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Keyframe unions: float, morph, position, color, and rotation keys, each an array under the name
of its interpolation.
]]

local Array = require '../array'
local Enums = require '../enums'
local Writer = require '../writer'

type Writer = Writer.Writer
type Map = { [number]: number }

local Names, Values = Enums.names, Enums.values

local function enumName(names: { [number]: string }, value: number): string | number
  return names[value] or value
end

local function enumValue(values: { [string]: number }, value: string | number): number
  if type(value) == 'number' then return value end

  local number = values[value]
  if not number then error(`unknown enum value '{value}'`, 0) end

  return number
end

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

return table.freeze {
  floatKeys = floatKeys,
  morphKeys = morphKeys,
  posKeys = posKeys,
  rotKeys = rotKeys,
  colorKeys = colorKeys,
}
