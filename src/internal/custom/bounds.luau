--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

local Fields = require './fields'
local Types = require '../types'
local Writer = require '../writer'

type Writer = Writer.Writer
type Map = { [number]: number }

local {names: Names, readVec3, writeF32, writeVec3} = Fields

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
  local {bytes, cursor} = writer
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

return table.freeze { boundingVolume = boundingVolume }
