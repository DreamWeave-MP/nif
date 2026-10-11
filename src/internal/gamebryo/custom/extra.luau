--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's `components/nif/extra.hpp` values the schema can't state as steps.
]]

local Stream = require '../stream'

type Stream = Stream.Stream

local custom = {}

--- `getSizedStrings` after a `u32` count, which, unlike a list, isn't checked against the file.
function custom.sizedStrings(stream: Stream, cursor: number): ({ string }, number)
  local count = buffer.readu32(stream.bytes, cursor)
  cursor += 4
  local list: { string } = {}
  for index = 1, count do
    list[index], cursor = Stream.sizedU32(stream, cursor)
  end

  return list, cursor
end

local scratch = buffer.create(4)

--- `x` rounded to a 32-bit float.
local function f32(value: number): number
  buffer.writef32(scratch, 0, value)
  return buffer.readf32(scratch, 0)
end

--- `BSInvMarker`'s rotation: three `u16` angles in thousandths of a radian, made into
--- `osg::Quat(x, X_AXIS, y, Y_AXIS, z, Z_AXIS)` (X applied first) in 32-bit floats, as
--- jess-nif's `Quat::from_rotation_z(z) * Quat::from_rotation_y(y) * Quat::from_rotation_x(x)`
--- rounds it.
function custom.invMarkerRotation(stream: Stream, cursor: number): ({ number }, number)
  local bytes = stream.bytes
  local xAngle, yAngle, zAngle =
    f32(buffer.readu16(bytes, cursor) / 1000),
    f32(buffer.readu16(bytes, cursor + 2) / 1000),
    f32(buffer.readu16(bytes, cursor + 4) / 1000)
  local sx, cx = f32(math.sin(xAngle * 0.5)), f32(math.cos(xAngle * 0.5))
  local sy, cy = f32(math.sin(yAngle * 0.5)), f32(math.cos(yAngle * 0.5))
  local sz, cz = f32(math.sin(zAngle * 0.5)), f32(math.cos(zAngle * 0.5))
  local zyX, zyY, zyZ, zyW = f32(-sz * sy), f32(cz * sy), f32(sz * cy), f32(cz * cy)
  local rotation = {
    f32(f32(zyW * sx) + f32(zyX * cx)),
    f32(f32(zyY * cx) + f32(zyZ * sx)),
    f32(f32(zyZ * cx) - f32(zyY * sx)),
    f32(f32(zyW * cx) - f32(zyX * sx)),
  }

  return rotation, cursor + 6
end

return custom
