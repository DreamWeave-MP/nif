--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's `components/nif/controller.hpp` values and checks the schema can't state as steps. The
links read here are checked by the record's post functions, in the order OpenMW resolves them.
]]

local Stream = require '../stream'
local Links = require '../links'

type Stream = Stream.Stream

local custom = {}

--- `RecordPtrT::read`: one link, -1 or a record index.
function custom.ptr(stream: Stream, cursor: number): (number, number)
  local index = buffer.readi32(stream.bytes, cursor)
  if index < -1 then Stream.invalidLink(index) end

  return index, cursor + 4
end

--- `count` links.
function custom.ptrs(stream: Stream, cursor: number, count: number): ({ number }, number)
  return Stream.links(stream, cursor, count), cursor + count * 4
end

--- `RecordListT`: a `u32` count of links.
function custom.ptrList(stream: Stream, cursor: number): ({ number }, number)
  return custom.ptrs(stream, cursor + 4, buffer.readu32(stream.bytes, cursor))
end

--- `count` link lists.
function custom.ptrLists(stream: Stream, cursor: number, count: number): ({ { number } }, number)
  local lists = table.create(count) :: { { number } }
  for index = 1, count do
    lists[index], cursor = custom.ptrList(stream, cursor)
  end

  return lists, cursor
end

--- `NiBoneLODController`'s skinned shape groups: a `u32` count of groups, each a `u32` count of
--- `SkinInfo`s.
function custom.skinInfoGroups(stream: Stream, cursor: number): ({ { any } }, number)
  local bytes = stream.bytes
  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  local groups = table.create(count) :: { { any } }
  for index = 1, count do
    local length = buffer.readu32(bytes, cursor)
    cursor += 4
    local group = table.create(length) :: { any }
    for member = 1, length do
      local shape, skin
      shape, cursor = custom.ptr(stream, cursor)
      skin, cursor = custom.ptr(stream, cursor)
      group[member] = { shape = shape, skin = skin }
    end

    groups[index] = group
  end

  return groups, cursor
end

--- `NiGeomMorpherController`'s interpolators: a link list up to Oblivion (followed, in
--- Bethesda's 10.2 files, by values OpenMW skips), then interpolator and weight pairs.
function custom.morphInterpolators(stream: Stream, cursor: number): (any, number)
  local bytes, version = stream.bytes, stream.version
  if version <= 0x14000005 then
    local interpolators
    interpolators, cursor = custom.ptrList(stream, cursor)
    if version >= 0x0A020000 and stream.bethVersion >= 10 then
      local unknown = buffer.readu32(bytes, cursor)
      cursor = Stream.skip(stream, cursor + 4, unknown * 4)
    end

    return { interpolators = interpolators, weights = {} :: { number } }, cursor
  end

  local count = buffer.readu32(bytes, cursor)
  cursor += 4
  local interpolators, weights = {} :: { number }, {} :: { number }
  for index = 1, count do
    interpolators[index], cursor = custom.ptr(stream, cursor)
    weights[index] = buffer.readf32(bytes, cursor)
    cursor += 4
  end

  return { interpolators = interpolators, weights = weights }, cursor
end

function custom.sequenceLinks(record: any, records: { any }, classes: { string }, index: number)
  Links.link(record.textKeys, 'Extra', records, classes, index)
  for _, block in record.controlledBlocks do
    Links.link(block.interpolator, 'NiInterpolator', records, classes, index)
    Links.link(block.controller, 'NiTimeController', records, classes, index)
    Links.link(block.blendInterpolator, 'NiBlendInterpolator', records, classes, index)
    Links.link(block.stringPalette, 'NiStringPalette', records, classes, index)
  end
end

function custom.controllerSequenceLinks(
  record: any,
  records: { any },
  classes: { string },
  index: number
)
  Links.link(record.manager, 'NiControllerManager', records, classes, index)
  Links.link(record.stringPalette, 'NiStringPalette', records, classes, index)
end

function custom.morphLinks(record: any, records: { any }, classes: { string }, index: number)
  Links.links(record.interpolators, 'NiInterpolator', records, classes, index)
end

function custom.boneLodLinks(record: any, records: { any }, classes: { string }, index: number)
  for _, group in record.nodeGroups do
    Links.links(group, 'NiAVObject', records, classes, index)
  end

  for _, group in record.skinnedShapeGroups do
    for _, info in group do
      Links.link(info.shape, 'NiTriBasedGeom', records, classes, index)
      Links.link(info.skin, 'NiSkinInstance', records, classes, index)
    end
  end

  Links.links(record.shapeGroups, 'NiTriBasedGeom', records, classes, index)
end

function custom.blendLinks(record: any, records: { any }, classes: { string }, index: number)
  for _, item in record.items do
    Links.link(item.interpolator, 'NiInterpolator', records, classes, index)
  end

  Links.link(record.singleInterpolator, 'NiInterpolator', records, classes, index)
end

return custom
