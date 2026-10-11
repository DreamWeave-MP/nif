--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Record-level checks for NIFs of every version OpenMW reads, over the multi-version reader's
records, following OpenMW's `nifosg` loader (`components/nifosg/nifloader.cpp`) and its collision
loader (`components/nifbullet/bulletnifloader.cpp`): a port of jess-nif's `check::gamebryo`.

Most rules apply to every version; the rest follow the loaders' branches by version or record
type: `BSXFlags` collision and editor markers, render geometry collision with Havok ignored,
`BSTriShape` geometry, Bethesda shader properties, interpolators, and the controllers, particles,
and animations OpenMW doesn't handle. The rules live in `base`, `scene`, `collision`, and
`properties`; this runs them in OpenMW's order.
]]

local Base = require './base'
local Collision = require './collision'
local Properties = require './properties'
local Reader = require '../gamebryo/reader'
local Scene = require './scene'
local Types = require './types'

type Checker = Base.Checker

local get, is, typeName, push = Base.get, Base.is, Base.typeName, Base.push
local Constants = Base.constants

--- nifloader.cpp `loadKf`: only `NiSequenceStreamHelper` animations load.
local function checkKf(checker: Checker)
  local helper: number? = nil
  local sequences = false
  for _, root in checker.file.roots do
    if root < 0 or root >= #checker.records then continue end

    if not helper and is(checker, root, 'NiSequenceStreamHelper') then helper = root end

    if is(checker, root, 'NiControllerSequence') then sequences = true end
  end

  if not helper then
    push(
      checker,
      'broken',
      'kf_without_sequence',
      nil,
      if sequences
        then 'Found no NiSequenceStreamHelper root record, so no animation loads; OpenMW doesn\'t read NiControllerSequence animations'
        else 'Found no NiSequenceStreamHelper root record, so no animation loads'
    )
    return
  end

  local net = get(checker, helper, 'NiObjectNET')
  if not net then return end

  local extras = Base.extraList(checker, net)
  local first = extras[1]
  if not first then
    push(
      checker,
      'broken',
      'kf_without_text_keys',
      helper,
      'NiSequenceStreamHelper has no text keys, so the animation is discarded'
    )
    return
  end

  if not is(checker, first, 'NiTextKeyExtraData') then
    push(
      checker,
      'broken',
      'kf_without_text_keys',
      first,
      `First extra data was not a NiTextKeyExtraData, but a {typeName(checker, first)}`
    )
    return
  end

  local chain = Base.controllers(checker, net.controller)
  local keyframes = 0
  for position = 2, math.min(#extras, #chain + 1) do
    local extra, controller = extras[position], chain[position - 1][1]
    if
      not is(checker, extra, 'NiStringExtraData')
      or not is(checker, controller, 'NiKeyframeController')
    then
      push(
        checker,
        'broken',
        'kf_unexpected_pair',
        extra,
        `Unexpected extra data {typeName(checker, extra)} with controller {typeName(checker, controller)}; the pair is skipped`
      )
      continue
    end

    local keyframe = get(checker, controller, 'NiKeyframeController')
    local data = keyframe ~= nil and keyframe.data >= 0
    if
      (data or Base.hasInterpolator(checker, controller))
      and Base.checkInterpolator(checker, controller, 'NiTransformInterpolator')
    then
      keyframes += 1
    end
  end

  if keyframes == 0 then
    push(
      checker,
      'broken',
      'kf_without_controllers',
      helper,
      'the KF has no keyframe controllers, so OpenMW discards it'
    )
  end
end

local function checkPerformance(checker: Checker)
  local stats = checker.stats
  -- Later files link records OpenMW reads but never resolves (Havok constraints and actions,
  -- additional geometry data, animation notes), which the reader doesn't follow.
  local unreachable = stats.records - stats.reachableRecords
  if unreachable > 0 and Base.morrowindRules(checker) then
    push(
      checker,
      'performance',
      'unreachable_records',
      nil,
      if unreachable == 1
        then '1 record isn\'t reachable from any root and is loaded for nothing'
        else `{unreachable} records aren't reachable from any root and are loaded for nothing`
    )
  end

  if stats.embeddedTextures > 0 then
    push(
      checker,
      'performance',
      'embedded_textures',
      nil,
      `{stats.embeddedTextures} embedded textures ({stats.embeddedTextureBytes} bytes) can't be shared, compressed, or replaced like texture files`
    )
  end

  if stats.shapes > Constants.ManyShapes then
    push(
      checker,
      'performance',
      'many_shapes',
      nil,
      `{stats.shapes} shapes: each one is at least one draw call`
    )
  end

  if stats.triangles > Constants.ManyTriangles then
    push(checker, 'performance', 'many_triangles', nil, `{stats.triangles} triangles in one model`)
  end
end

local function run(checker: Checker, rootsChecked: boolean)
  Base.findReachable(checker, rootsChecked)
  local roots = {}
  for _, root in checker.file.roots do
    if root >= 0 and root < #checker.records and get(checker, root, 'NiAVObject') then
      table.insert(roots, root)
    end
  end

  if checker.kf then
    checkKf(checker)
  elseif #roots == 0 then
    -- nifloader.cpp `load`: throws when no root is an NiAVObject.
    push(checker, 'wont_load', 'no_root_nodes', nil, 'Found no root nodes')
  end

  Base.checkRootTransform(checker)
  for _, root in roots do
    Base.checkRootStrings(checker, root)
    Scene.walk(checker, root, { texturing = nil, root = true })
    if Base.gamebryoCollision(checker) then
      Collision.checkBsx(checker, root)
    else
      Collision.check(checker, root)
    end
  end

  Collision.checkBoundingBox(checker, roots)
  Properties.check(checker)
  Properties.collectTextures(checker)
  checkPerformance(checker)
end

--- Checks every record of `file`, read from `name` (`.kf` files are checked as animations), into
--- `report`.
local function check(name: string, file: Reader.File, report: Types.Report)
  report.deep = true
  local fileName = string.lower(string.match(name, '[^/\\]*$') or name)
  local rootsChecked = false
  for _, finding in report.findings do
    if finding.code == 'root_out_of_range' then rootsChecked = true end
  end

  local checker: Checker = {
    file = file,
    records = file.records,
    version = file.header.version,
    kf = string.sub(fileName, -3) == '.kf',
    findings = {},
    textures = {},
    stats = {
      records = 0,
      reachableRecords = 0,
      nodes = 0,
      shapes = 0,
      vertices = 0,
      triangles = 0,
      collisionTriangles = 0,
      controllers = 0,
      embeddedTextures = 0,
      embeddedTextureBytes = 0,
      skinned = false,
    },
    reachable = {},
    properties = {},
    hasMarkers = false,
    collisionMarkers = false,
    collisionNode = nil,
    invisibleColliders = {},
    uncollidableShapes = {},
    collision = nil,
    listedEffects = {},
  }

  for index = 0, #file.records - 1 do
    local node = get(checker, index, 'NiNode')
    if not node then continue end

    for _, effect in node.effects do
      if effect >= 0 then checker.listedEffects[effect] = true end
    end
  end

  run(checker, rootsChecked)
  table.move(checker.findings, 1, #checker.findings, #report.findings + 1, report.findings)
  report.textures = checker.textures
  report.stats = checker.stats
  report.collision = checker.collision
end

return table.freeze { check = check }
