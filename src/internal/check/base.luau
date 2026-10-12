--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Record-level checks for NIFs of every version OpenMW reads, over the multi-version reader's
records, following OpenMW's `nifosg` loader (`components/nifosg/nifloader.cpp`) and its collision
loader (`components/nifbullet/bulletnifloader.cpp`): a port of jess-nif's `check::gamebryo`.

Most rules apply to every version; the rest follow the loaders' branches by version or record
type: `BSXFlags` collision and editor markers, render geometry collision with Havok ignored,
`BSTriShape` geometry, Bethesda shader properties, interpolators, and the controllers, particles,
and animations OpenMW doesn't handle. Records are 0-based by index, as in the file.
]]

local Links = require '../gamebryo/links'
local Load = require '../gamebryo/load'
local Reader = require '../gamebryo/reader'
local Types = require './types'

type File = Reader.File
type Report = Types.Report
export type Severity = Types.Severity
export type CollisionSource = Types.CollisionSource
type Finding = Types.Finding
type Stats = Types.Stats
type Collision = Types.Collision

local Is = Links.is

--- Past this many controllers or modifiers a chain is treated as a loop.
local MaxChain = 4096
--- Rendered shapes past which a single model is a lot of draw calls.
local ManyShapes = 100
--- Rendered triangles past which a single model is heavy.
local ManyTriangles = 50000
--- Collision triangles, built from render geometry, past which collision is heavy.
local ManyCollisionTriangles = 5000
--- `NiTexturingProperty` slots OpenMW binds: base, dark, detail, gloss, glow, bump, decal.
local TextureStages = 7
--- `BSShaderTextureSet` slots OpenMW binds: diffuse, normal, glow.
local TextureSetStages = 3
--- `NiMaterialColorController::TargetColor::Specular`.
local TargetSpecular = 2
--- `BSXFlags` bit that gives a model collision.
local BsxCollision = 2
--- `BSXFlags` bit that hides editor markers.
local BsxEditorMarkers = 32
--- `NIFFile::VER_MW` and `VER_BGS`.
local VerMw, VerBgs = 0x04000002, 0x14020007

local NiGeometryTypes: { [string]: boolean } = table.freeze({
  NiTriShape = true,
  NiTriStrips = true,
  NiLines = true,
  BSLODTriShape = true,
  BSSegmentedTriShape = true,
} :: { [string]: boolean })

local BsGeometryTypes: { [string]: boolean } = table.freeze({
  BSTriShape = true,
  BSDynamicTriShape = true,
  BSMeshLODTriShape = true,
  BSSubIndexTriShape = true,
} :: { [string]: boolean })

--- Shapes `getCollisionShape` builds a mesh from: `NiTriShape` and `NiTriStrips`, and the
--- `NiTriShape` subclasses.
local CollidingTypes: { [string]: boolean } = table.freeze({
  NiTriShape = true,
  NiTriStrips = true,
  BSLODTriShape = true,
  BSSegmentedTriShape = true,
} :: { [string]: boolean })

--- Whether a transform is identity up to the float noise exporters leave, which changes nothing.
local function isIdentityTransform(
  translation: vector,
  rotation: { vector },
  scale: number
): boolean
  local function near(value: number, expected: number): boolean
    return math.abs(value - expected) <= 1e-5
  end

  if not (near(translation.x, 0) and near(translation.y, 0) and near(translation.z, 0)) then
    return false
  end

  for row = 1, 3 do
    local values = rotation[row]
    if
      not (
        near(values.x, if row == 1 then 1 else 0)
        and near(values.y, if row == 2 then 1 else 0)
        and near(values.z, if row == 3 then 1 else 0)
      )
    then
      return false
    end
  end

  return near(scale, 1)
end

local function startsWithIgnoreCase(text: string, prefix: string): boolean
  return #text >= #prefix and string.lower(string.sub(text, 1, #prefix)) == string.lower(prefix)
end

--- Scene-graph state inherited from ancestors: the texturing property in effect (a child's
--- replaces its parent's), and whether this is the root.
export type RenderState = { texturing: number?, root: boolean }

export type CollisionState = { hidden: boolean, shadowNamed: boolean, boundingBox: boolean }

export type Checker = {
  file: File,
  records: { any },
  version: number,
  --- A `.kf` animation rather than a model.
  kf: boolean,
  findings: { Finding },
  textures: { string },
  stats: Stats,
  reachable: { [number]: boolean },
  --- Properties on rendered objects, checked once each.
  properties: { number },
  --- Editor markers aren't drawn: root `MRK` string data, or root `BSXFlags` bit 32.
  hasMarkers: boolean,
  --- The collision loader skips editor markers: `Tri EditorMarker` shapes with root `MRK` in
  --- Morrowind-era files, `EditorMarker` shapes with `BSXFlags` bit 32 in later ones.
  collisionMarkers: boolean,
  --- The `RootCollisionNode` OpenMW hides from rendering.
  collisionNode: number?,
  --- Shapes that collide without drawing, and why they don't draw.
  invisibleColliders: { { any } },
  --- Shapes of a type the collision loader skips, in files whose render geometry collides.
  uncollidableShapes: { number },
  --- The first root's collision setup.
  collision: Collision?,
  --- Every effect in some node's effect list; effects are usually children as well.
  listedEffects: { [number]: boolean },
}

--- Record `index` when it is or derives from `class`.
local function get(checker: Checker, index: number?, class: string): any
  if not index or index < 0 then return nil end

  local record = checker.records[index + 1]
  if not record or not Is[checker.file.classes[index + 1]][class] then return nil end

  return record
end

local function recordType(checker: Checker, index: number): string?
  return checker.file.recordTypes[index + 1]
end

local function is(checker: Checker, index: number, kind: string): boolean
  return checker.file.recordTypes[index + 1] == kind
end

local function typeName(checker: Checker, index: number): string
  return checker.file.names[index + 1] or ''
end

local function nameOf(checker: Checker, index: number): string
  local net = get(checker, index, 'NiObjectNET')
  return if net then net.name else ''
end

local function push(
  checker: Checker,
  severity: Severity,
  code: string,
  record: number?,
  message: string
)
  table.insert(
    checker.findings,
    { severity = severity, code = code, message = message, record = record }
  )
end

--- The controllers chained from `first`, stopping at a missing link or a loop, as
--- `{ index, controller }` pairs.
local function controllers(checker: Checker, first: number): { { any } }
  local chain, seen = {}, {}
  local link = first
  while #chain < MaxChain do
    if link < 0 or seen[link] then break end

    seen[link] = true
    local controller = get(checker, link, 'NiTimeController')
    if not controller then break end

    table.insert(chain, { link, controller })
    link = controller.next
  end

  return chain
end

--- `NiObjectNET::getExtraList`: the extra data list, then the chain older files use.
local function extraList(checker: Checker, net: any): { number }
  local list = [for index in net.extraList if index >= 0 => index]
  local seen = {}
  local link = net.extra
  while #list < MaxChain do
    if link < 0 or seen[link] then break end

    seen[link] = true
    local extra = get(checker, link, 'Extra')
    if not extra then break end

    table.insert(list, link)
    link = extra.next
  end

  return list
end

local function rootExtra(checker: Checker, root: number): { number }
  local net = get(checker, root, 'NiObjectNET')
  return if net then extraList(checker, net) else {}
end

local function rootStrings(checker: Checker, root: number): { string }
  local strings = {}
  for _, index in rootExtra(checker, root) do
    if not is(checker, index, 'NiStringExtraData') then continue end

    local extra = get(checker, index, 'NiStringExtraData')
    if extra then table.insert(strings, extra.data) end
  end

  return strings
end

--- The root's first `BSXFlags` (bulletnifloader.cpp `handleRoot`).
local function bsxFlags(checker: Checker, root: number): number?
  for _, index in rootExtra(checker, root) do
    if not is(checker, index, 'BSXFlags') then continue end

    local flags = get(checker, index, 'NiIntegerExtraData')
    return if flags then flags.data else nil
  end

  return nil
end

local function contains(list: { string }, value: string): boolean
  return table.find(list, value) ~= nil
end

--- Morrowind-era files (up to 4.0.0.2), which get Morrowind's shadow, marker, and specular rules.
local function morrowindRules(checker: Checker): boolean return checker.version <= VerMw end

--- Files before 10.0.1.0 collide by `RootCollisionNode` and string data; later ones by `BSXFlags`.
local function gamebryoCollision(checker: Checker): boolean return checker.version >= 0x0A000100 end

local function findReachable(checker: Checker, rootsChecked: boolean)
  local file = checker.file
  local stack = [for root in file.roots if root >= 0 and root < #checker.records => root]
  local count = 0
  while #stack > 0 do
    local index = table.remove(stack) :: number
    local record = checker.records[index + 1]
    if not record or checker.reachable[index] then continue end

    checker.reachable[index] = true
    count += 1
    local codec: any = (Load :: any)[file.classes[index + 1]]
    for _, link in Links.of(record, codec.check, checker.records, file.classes, index) do
      if link >= 0 then table.insert(stack, link) end
    end
  end

  checker.stats.records = #checker.records
  checker.stats.reachableRecords = count
  if rootsChecked then return end

  for position, root in file.roots do
    if root < -1 or root >= #checker.records then
      push(
        checker,
        'broken',
        'root_out_of_range',
        nil,
        `Root {position - 1} does not point to a record, so it's skipped`
      )
    end
  end
end

--- node.cpp `NiNode::read`: record 0's transform is discarded when it's a node other than
--- `Bip01`, in Morrowind-era and Fallout 3 and later files (not Oblivion's).
local function checkRootTransform(checker: Checker)
  if checker.version > VerMw and checker.version < VerBgs then return end

  local node = get(checker, 0, 'NiNode')
  if not node then return end

  local {translation, rotation, scale} = node.transform
  local identity = isIdentityTransform(translation, rotation, scale)
  if identity or string.lower(node.name) == 'bip01' then return end

  push(
    checker,
    'info',
    'root_transform_ignored',
    0,
    `the root node "{node.name}" has a transform, which OpenMW ignores like Morrowind does`
  )
end

--- node.cpp `findRootCollisionNode`: children in reverse, searching each one's subtree before the
--- next child only with `RCN`. Depth first without recursion.
local function findCollisionNode(checker: Checker, root: number, recursive: boolean): number?
  local node = get(checker, root, 'NiNode')
  if not node then return nil end

  local seen = { [root] = true }
  -- The stack pops the last child first.
  local stack = [for child in node.children if child >= 0 => child]
  while #stack > 0 do
    local child = table.remove(stack) :: number
    if is(checker, child, 'RootCollisionNode') then return child end

    if not recursive then continue end

    local inner = get(checker, child, 'NiNode')
    if inner and not seen[child] then
      seen[child] = true
      for _, grandchild in inner.children do
        if grandchild >= 0 then table.insert(stack, grandchild) end
      end
    end
  end

  return nil
end

--- nifloader.cpp `handleNode` at the root: `MRK` string data or `BSXFlags` bit 32 hides editor
--- markers, and `RCN` searches for the collision node recursively.
local function checkRootStrings(checker: Checker, root: number)
  local strings = rootStrings(checker, root)
  local stringRecords = {}
  for _, index in rootExtra(checker, root) do
    if not is(checker, index, 'NiStringExtraData') then continue end

    local extra = get(checker, index, 'NiStringExtraData')
    if extra then table.insert(stringRecords, { index, extra.data }) end
  end

  local bsx = bsxFlags(checker, root)
  checker.hasMarkers =
    contains(strings, 'MRK') or (bsx ~= nil and bit32.btest(bsx, BsxEditorMarkers))
  checker.collisionNode = findCollisionNode(checker, root, contains(strings, 'RCN'))
  if gamebryoCollision(checker) then return end

  for _, entry in stringRecords do
    local index, value = entry[1], entry[2]
    -- bulletnifloader.cpp: only an uppercase third letter makes "NCC" camera-only.
    if startsWithIgnoreCase(value, 'NC') and string.sub(value, 3, 3) == 'c' then
      -- The string data record, which `nif fix` changes, not the root.
      push(
        checker,
        'collision',
        'lowercase_ncc',
        index,
        `"{value}" turns collision off entirely; only an uppercase "NCC" keeps camera collision`
      )
    end
  end
end

local function isActive(controller: any): boolean return bit32.btest(controller.flags, 0x8) end

--- An interpolator of a type the controller can't use makes OpenMW skip the controller.
local function checkInterpolator(checker: Checker, controller: number, expected: string): boolean
  local single = get(checker, controller, 'NiSingleInterpController')
  if not single or single.interpolator < 0 then return true end

  local interpolator = single.interpolator
  if is(checker, interpolator, expected) then return true end

  push(
    checker,
    'broken',
    'unsupported_interpolator',
    controller,
    `Unsupported interpolator type for {typeName(checker, controller)}: {typeName(checker, interpolator)}, so the controller is skipped`
  )
  return false
end

local function hasInterpolator(checker: Checker, controller: number): boolean
  local single = get(checker, controller, 'NiSingleInterpController')
  return single ~= nil and single.interpolator >= 0
end

local function checkNodeController(checker: Checker, index: number)
  local kind = recordType(checker, index)
  if kind == 'NiPathController' then
    local path = get(checker, index, 'NiPathController')
    if not path then return end

    if path.pathData < 0 or path.percentData < 0 then
      push(
        checker,
        'broken',
        'controller_without_data',
        index,
        'NiPathController without path or percent data is skipped'
      )
    elseif path.pathFlags ~= 0 then
      -- controller.cpp `PathController`: only the position along the path is applied.
      push(
        checker,
        'broken',
        'path_flags_ignored',
        index,
        'NiPathController\'s follow, bank, and flip flags are ignored; only the position is animated'
      )
    end
  elseif kind == 'NiLookAtController' then
    local lookAt = get(checker, index, 'NiLookAtController')
    if lookAt and lookAt.lookAt < 0 then
      push(
        checker,
        'broken',
        'controller_without_data',
        index,
        'NiLookAtController without a target is skipped'
      )
    end
  elseif kind == 'NiKeyframeController' then
    local keyframe = get(checker, index, 'NiKeyframeController')
    local data = keyframe ~= nil and keyframe.data >= 0
    if not data and not hasInterpolator(checker, index) then
      push(
        checker,
        'info',
        'controller_without_data',
        index,
        `{typeName(checker, index)} without data is skipped`
      )
    else
      checkInterpolator(checker, index, 'NiTransformInterpolator')
    end
  elseif kind == 'NiVisController' then
    checkInterpolator(checker, index, 'NiBoolInterpolator')
  elseif kind == 'NiRollController' then
    checkInterpolator(checker, index, 'NiFloatInterpolator')
  end
end

local function shapeData(checker: Checker, index: number): any
  local geometry = get(checker, index, 'NiGeometry')
  return if geometry then get(checker, geometry.data, 'NiGeometryData') else nil
end

local function checkMorpher(checker: Checker, owner: number, index: number, skinned: boolean)
  if skinned then
    push(
      checker,
      'broken',
      'morpher_on_skinned_shape',
      index,
      'NiGeomMorpherController is ignored on skinned shapes'
    )
    return
  end

  local data = shapeData(checker, owner)
  local vertices = if data then #data.vertices else 0
  local controller = get(checker, index, 'NiGeomMorpherController')
  local morphData = if controller then get(checker, controller.data, 'NiMorphData') else nil
  local base = if morphData then morphData.morphs[1] else nil
  if not base then
    push(
      checker,
      'broken',
      'controller_without_data',
      index,
      'NiGeomMorpherController without morphs is skipped'
    )
    return
  end

  if #base.vertices == vertices then return end

  push(
    checker,
    'broken',
    'morph_vertex_mismatch',
    index,
    `the base morph has {#base.vertices} vertices but the shape has {vertices}, so the morph is ignored`
  )
end

--- nifloader.cpp `handleNodeControllers`, `handleMeshControllers`, and the morpher in
--- `handleNiGeometry`.
local function checkNodeControllers(checker: Checker, owner: number, chain: { { any } })
  local ownerType = typeName(checker, owner)
  local ownerKind = recordType(checker, owner)
  local isNiGeometry = ownerKind ~= nil and NiGeometryTypes[ownerKind] == true
  local isMesh = isNiGeometry or (ownerKind ~= nil and BsGeometryTypes[ownerKind] == true)
  local isParticles = ownerKind == 'NiParticles'
  local geometry = get(checker, owner, 'NiGeometry')
  local skinned = geometry ~= nil and geometry.skin >= 0
  -- Particle systems OpenMW doesn't draw are reported once, as unsupported_particles.
  local unsupportedParticles = ownerKind == 'NiParticleSystem'
    or ownerKind == 'BSStripParticleSystem'
  for _, entry in chain do
    local index, controller = entry[1], entry[2]
    -- Inactive controllers are skipped everywhere except in KF files.
    if not isActive(controller) then continue end

    checker.stats.controllers += 1
    if unsupportedParticles then continue end

    local name = typeName(checker, index)
    local kind = recordType(checker, index)
    if
      kind == 'NiKeyframeController'
      or kind == 'NiPathController'
      or kind == 'NiVisController'
      or kind == 'NiRollController'
      or kind == 'NiLookAtController'
    then
      checkNodeController(checker, index)
    elseif kind == 'NiUVController' and isMesh then
      continue
    elseif kind == 'NiGeomMorpherController' and isNiGeometry then
      checkMorpher(checker, owner, index, skinned)
    elseif
      (kind == 'NiParticleSystemController' or kind == 'NiBSPArrayController') and isParticles
    then
      continue
    elseif
      kind == 'NiUVController'
      or kind == 'NiGeomMorpherController'
      or kind == 'NiParticleSystemController'
      or kind == 'NiBSPArrayController'
    then
      push(
        checker,
        'broken',
        'controller_does_nothing',
        index,
        `{name} on {ownerType} does nothing; it only works on geometry`
      )
    else
      push(
        checker,
        'broken',
        'unhandled_controller',
        index,
        `Unhandled controller {name} on {ownerType}`
      )
    end
  end
end

return {
  get = get,
  is = is,
  recordType = recordType,
  typeName = typeName,
  nameOf = nameOf,
  push = push,
  controllers = controllers,
  extraList = extraList,
  rootExtra = rootExtra,
  rootStrings = rootStrings,
  bsxFlags = bsxFlags,
  morrowindRules = morrowindRules,
  gamebryoCollision = gamebryoCollision,
  findReachable = findReachable,
  checkRootTransform = checkRootTransform,
  checkRootStrings = checkRootStrings,
  checkNodeControllers = checkNodeControllers,
  shapeData = shapeData,
  isActive = isActive,
  checkInterpolator = checkInterpolator,
  hasInterpolator = hasInterpolator,
  startsWithIgnoreCase = startsWithIgnoreCase,
  isIdentityTransform = isIdentityTransform,
  constants = {
    ManyShapes = ManyShapes,
    ManyTriangles = ManyTriangles,
    ManyCollisionTriangles = ManyCollisionTriangles,
    TextureStages = TextureStages,
    TextureSetStages = TextureSetStages,
    TargetSpecular = TargetSpecular,
    BsxCollision = BsxCollision,
    NiGeometryTypes = NiGeometryTypes,
    BsGeometryTypes = BsGeometryTypes,
    CollidingTypes = CollidingTypes,
  },
}
