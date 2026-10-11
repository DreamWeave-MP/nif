--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's `components/nif/physics.hpp` values and checks the schema can't state as steps.
]]

local Stream = require '../stream'
local Links = require '../links'

type Stream = Stream.Stream

local custom = {}

--- One `TriangleData`: three `u16` vertices, the welding info, and, up to Oblivion, a normal.
local function packedTriangle(bytes: buffer, cursor: number): any
  return {
    triangle = {
      buffer.readu16(bytes, cursor),
      buffer.readu16(bytes, cursor + 2),
      buffer.readu16(bytes, cursor + 4),
    },
    weldingInfo = buffer.readu16(bytes, cursor + 6),
    normal = vector.zero,
  }
end

local function packedTriangleWithNormal(bytes: buffer, cursor: number): any
  local triangle = packedTriangle(bytes, cursor)
  triangle.normal =
    vector.create(
      buffer.readf32(bytes, cursor + 8),
      buffer.readf32(bytes, cursor + 12),
      buffer.readf32(bytes, cursor + 16)
    )
  return triangle
end

--- `hkPackedNiTriStripsData`'s triangles after a `u32` count, each read when asked for; up to
--- Oblivion they carry normals. Like jess-nif, the count isn't checked against the file size.
function custom.packedTriangles(stream: Stream, cursor: number): (any, number)
  local count = buffer.readu32(stream.bytes, cursor)
  local normals = stream.version <= 0x14000005
  local stride = if normals then 20 else 8
  if cursor + 4 + count * stride > stream.length then
    Stream.fail(
      `Failed to read TriangleData: {stride} bytes at offset {cursor + 4} of {stream.length}`
    )
  end

  return Stream.rows(
    stream,
    cursor + 4,
    count,
    stride,
    if normals then packedTriangleWithNormal else packedTriangle
  )
end

--- `bhkPoseArray`'s poses: a `u32` count of poses, each a `u32` count of bone transforms.
function custom.poses(stream: Stream, cursor: number): ({ { any } }, number)
  local bytes = stream.bytes
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  local poses: { { any } } = {}
  for index = 1, count do
    local length = buffer.readu32(bytes, cursor)
    cursor += 4
    if cursor + length * 40 > stream.length then
      Stream.fail(`Failed to read bhkPoseArray: 40 bytes at offset {cursor} of {stream.length}`)
    end

    local pose = table.create(length) :: { any }
    for bone = 1, length do
      pose[bone] = {
        translation = vector.create(
          buffer.readf32(bytes, cursor),
          buffer.readf32(bytes, cursor + 4),
          buffer.readf32(bytes, cursor + 8)
        ),
        rotation = {
          buffer.readf32(bytes, cursor + 16),
          buffer.readf32(bytes, cursor + 20),
          buffer.readf32(bytes, cursor + 24),
          buffer.readf32(bytes, cursor + 12),
        },
        scale = vector.create(
          buffer.readf32(bytes, cursor + 28),
          buffer.readf32(bytes, cursor + 32),
          buffer.readf32(bytes, cursor + 36)
        ),
      }
      cursor += 40
    end

    poses[index] = pose
  end

  return poses, cursor
end

--- `bhkConstraint`'s entities, which its info holds.
function custom.constraintLinks(record: any, records: { any }, classes: { string }, index: number)
  Links.link(record.info.entityA, 'bhkEntity', records, classes, index)
  Links.link(record.info.entityB, 'bhkEntity', records, classes, index)
end

--- `bhkBallSocketConstraintChain`'s entities; OpenMW leaves its info's links unresolved.
function custom.constraintChainLinks(
  record: any,
  records: { any },
  classes: { string },
  index: number
)
  Links.links(record.constraintChainInfo.entities, 'bhkRigidBody', records, classes, index)
end

return custom
