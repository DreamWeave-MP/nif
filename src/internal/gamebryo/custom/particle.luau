--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/particle.hpp` values the schema can't state as steps.

local Stream = require '../stream'

type Stream = Stream.Stream

local custom = {}

--- `NiPSysEmitterCtlrData`'s visibility keys, read by `readKeyMapPair<float, bool>`: a count,
--- then a time and a byte per key, with no interpolation type whatever the version.
function custom.emitterVisKeys(stream: Stream, cursor: number): (any, number)
  local bytes = stream.bytes
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  Stream.checkSize(stream, count * 5)
  local keys = table.create(count) :: { { time: number, value: boolean } }
  for index = 1, count do
    keys[index] = {
      time = buffer.readf32(bytes, cursor),
      value = buffer.readu8(bytes, cursor + 4) ~= 0,
    }
    cursor += 5
  end

  return { frameName = '', legacyWeight = 0, interpolationType = 0, keys = keys }, cursor
end

return custom
