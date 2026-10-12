--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

local Array = require '../array'
local Writer = require '../writer'

type Writer = Writer.Writer
type Map = { [number]: number }

--- An array, as far as these codecs need: its bytes and where they are.
type View = Array.ArrayFields

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
  return sum[for coordinates in record.uvSets => coordinates.count]
end

--- How many sets the saved record says it has: the coordinates over the vertices.
local function uvSetCount(record: Geometry): number
  local vertices = record.vertices.count
  if vertices == 0 then return 0 end

  return uvSetTotal(record) // vertices
end

return table.freeze {
  sharedNormals = sharedNormals,
  uvSets = uvSets,
  uvSetTotal = uvSetTotal,
  uvSetCount = uvSetCount,
}
