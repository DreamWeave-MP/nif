--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The render traversal's checks: what OpenMW's `NIFObjectLoader::handleNode` does to each node,
effect, shape, particle system, and their controllers.
]]

local Base = require './base'

local dataPlane = require '@dream/data'

type Checker = Base.Checker
type RenderState = Base.RenderState

local {get, is, recordType, typeName, nameOf, push, startsWithIgnoreCase} = Base
local Constants = Base.constants
local {NiGeometryTypes, BsGeometryTypes} = Constants

--- `u16`s side by side, the corners of triangles and the points of strips, and the `u16` that
--- starts each six-byte skin weight: read by the data plane, a whole run in one call.
local Corners: dream_data_Kind_u16 = dataPlane.u16()
local WeightVertices: dream_data_Kind_u16 = dataPlane.u16(6)

--- How many triangles a `u16` view of triples holds and, given a shape's `vertices`, the first
--- of their indices at or past them.
local function countList(list: any, vertices: number?): (number, number?)
  local bytes, offset, corners = list.buffer, list.offset, list.count // 3 * 3
  if not vertices or corners == 0 then return corners // 3, nil end

  local past = Corners:anyGe(bytes, offset, corners, vertices)
  if not past then return corners // 3, nil end

  for corner = 0, corners - 1 do
    local index = buffer.readu16(bytes, offset + corner * 2)
    if index >= vertices then return corners // 3, index end
  end

  return corners // 3, nil
end

--- How many triangles strips unroll to, strips shorter than 3 and degenerate triangles dropped,
--- and, given a shape's `vertices`, the first index at or past them of the triangles kept, each
--- triangle's indices in the order it is wound.
local function countStrips(strips: any, vertices: number?): (number, number?)
  local count, bad = 0, nil
  local limit = vertices or math.huge
  for _, strip in strips do
    local bytes, offset, length = strip.buffer, strip.offset, strip.count
    -- Only a strip with an index past the vertices is looked at index by index.
    local suspect = false
    if vertices and not bad and length >= 3 then
      suspect = Corners:anyGe(bytes, offset, length, limit)
    end

    for step = 0, length - 3 do
      local at = offset + step * 2
      local first, second, third =
        buffer.readu16(bytes, at), buffer.readu16(bytes, at + 2), buffer.readu16(bytes, at + 4)
      if first == second or second == third or first == third then continue end

      count += 1
      if not suspect then continue end

      -- Every other triangle is wound the other way.
      if step % 2 == 1 then
        second, third = third, second
      end

      if first >= limit then
        bad = first
      elseif second >= limit then
        bad = second
      elseif third >= limit then
        bad = third
      end

      suspect = bad == nil
    end
  end

  return count, bad
end

--- `getPartitions`: a skin instance's own partitions, or its skin data's.
local function partitionsOf(checker: Checker, skin: any): any
  local partitions = get(checker, skin.partitions, 'NiSkinPartition')
  if partitions then return partitions end

  local data = get(checker, skin.data, 'NiSkinData')
  return if data then get(checker, data.partitions, 'NiSkinPartition') else nil
end

--- How many triangles OpenMW draws and collides with: the skin partitions' when there are any,
--- otherwise the data's. Given the shape's `vertices`, also the first vertex index at or past
--- them, in the order the triangles are drawn.
local function countTriangles(checker: Checker, geometry: any, vertices: number?): (number, number?)
  local skin = get(checker, geometry.skin, 'NiSkinInstance')
  local partitions = if skin then partitionsOf(checker, skin) else nil
  if partitions then
    local count, bad = 0, nil
    for _, partition in partitions.partitions do
      local listed, pastList = countList(partition.trueTriangles, if bad then nil else vertices)
      bad = bad or pastList
      local unrolled, pastStrips = countStrips(partition.trueStrips, if bad then nil else vertices)
      bad = bad or pastStrips
      count += listed + unrolled
    end

    return count, bad
  end

  if geometry.data < 0 then return 0, nil end

  local shape = get(checker, geometry.data, 'NiTriShapeData')
  if shape then return countList(shape.triangles, vertices) end

  local strips = get(checker, geometry.data, 'NiTriStripsData')
  if strips then return countStrips(strips.strips, vertices) end

  return 0, nil
end

--- nifloader.cpp `handleNiGeometry`: `influences.at(vertex)` throws past the end.
local function checkSkinWeights(checker: Checker, shape: number, skin: number, vertices: number)
  local instance = get(checker, skin, 'NiSkinInstance')
  local data = if instance then get(checker, instance.data, 'NiSkinData') else nil
  if not data then return end

  local worst = -1
  for _, bone in data.bones do
    local {buffer: bytes, offset, count} = bone.weights
    if count == 0 then continue end

    local past = WeightVertices:maxGe(bytes, offset, count, vertices)
    if past and past > worst then worst = past end
  end

  if worst < 0 then return end

  push(
    checker,
    'wont_load',
    'skin_weight_out_of_range',
    shape,
    `the skin weights vertex {worst}, but the shape has {vertices} {if vertices == 1
      then 'vertex'
      else 'vertices'}`
  )
end

local function checkGeometry(checker: Checker, index: number, kind: string, state: RenderState)
  local geometry = get(checker, index, 'NiGeometry')
  if not geometry then return end

  local shapeType = typeName(checker, index)
  local name = geometry.name

  -- node.cpp `NiGeometry::post`: data of the wrong kind is silently dropped.
  local dataIndex = geometry.data
  if dataIndex < 0 then return end

  local expected = if kind == 'NiTriStrips'
    then 'NiTriStripsData'
    elseif kind == 'NiLines' then 'NiLinesData'
    else 'NiTriShapeData'
  if not is(checker, dataIndex, expected) then
    push(
      checker,
      'broken',
      'wrong_geometry_data',
      index,
      `{shapeType} "{name}" has {typeName(checker, dataIndex)} rather than {expected}, so it doesn't draw`
    )
    return
  end

  local data = get(checker, dataIndex, 'NiGeometryData')
  if not data then return end

  local vertices = #data.vertices
  local triangles, bad = countTriangles(checker, geometry, vertices)
  local linesData = get(checker, dataIndex, 'NiLinesData')
  local lines = if linesData then #linesData.lines else 0
  local empty = if kind == 'NiLines' then lines == 0 else triangles == 0
  if vertices == 0 or empty then
    push(
      checker,
      'info',
      'empty_geometry',
      index,
      `{shapeType} "{name}" has no triangles and isn't drawn`
    )
    return
  end

  checker.stats.shapes += 1
  checker.stats.vertices += vertices
  checker.stats.triangles += triangles
  if bad then
    push(
      checker,
      'broken',
      'vertex_index_out_of_range',
      dataIndex,
      `"{name}" uses vertex {bad} of {vertices}; this may crash OpenMW`
    )
  end

  -- nifloader.cpp `handleNiGeometryData`: a missing UV set falls back to set 0.
  local uvSets = #data.uvList
  local texturing = get(checker, state.texturing, 'NiTexturingProperty')
  if texturing then
    for slot, texture in texturing.textures do
      if not texture.enabled then continue end

      local set = texture.uvSet
      if slot - 1 < Constants.TextureStages and set >= uvSets and uvSets > 0 then
        push(
          checker,
          'broken',
          'uv_set_out_of_range',
          index,
          `"{name}" texture slot {slot - 1} uses UV set {set} but has {uvSets}; UV set 0 is used instead`
        )
      end
    end
  end

  if geometry.skin >= 0 then
    checker.stats.skinned = true
    checkSkinWeights(checker, index, geometry.skin, vertices)
  end
end

--- nifloader.cpp `handleBSGeometry`.
local function checkBsGeometry(checker: Checker, index: number)
  local shape = get(checker, index, 'BSTriShape')
  if not shape then return end

  local shapeType = typeName(checker, index)
  local name = shape.name
  local vertices = if bit32.btest(shape.vertDesc.flags, 0x1) then #shape.vertData else 0
  local triangles, bad = countList(shape.triangles, vertices)
  if vertices == 0 or triangles == 0 then
    push(
      checker,
      'info',
      'empty_geometry',
      index,
      `{shapeType} "{name}" has no triangles and isn't drawn`
    )
    return
  end

  checker.stats.shapes += 1
  checker.stats.vertices += vertices
  checker.stats.triangles += triangles
  if bad then
    push(
      checker,
      'broken',
      'vertex_index_out_of_range',
      index,
      `"{name}" uses vertex {bad} of {vertices}; this may crash OpenMW`
    )
  end

  local skin = shape.skin
  if skin < 0 then return end

  checker.stats.skinned = true
  -- Only Fallout 4's skinning is handled; Skyrim SE's isn't yet.
  local problem: string? = nil
  if not is(checker, skin, 'BSSkinInstance') then
    problem = `"{name}" is skinned with {typeName(checker, skin)}, which OpenMW doesn't support yet, so it's drawn unskinned`
  elseif not bit32.btest(shape.vertDesc.flags, 0x40) then
    problem = `"{name}" has a skin but its vertices have no skin weights, so it's drawn unskinned`
  end

  if problem then push(checker, 'broken', 'unsupported_skinning', index, problem) end
end

local function checkParticleModifier(checker: Checker, modifier: number, collider: boolean)
  local kind = recordType(checker, modifier)
  if collider then
    if kind ~= 'NiPlanarCollider' and kind ~= 'NiSphericalCollider' then
      push(
        checker,
        'broken',
        'unhandled_particle_modifier',
        modifier,
        `Unhandled particle collider {typeName(checker, modifier)}`
      )
    end

    return
  end

  if kind == 'NiParticleGrowFade' or kind == 'NiGravity' or kind == 'NiParticleBomb' then return end

  if kind == 'NiParticleRotation' then
    push(checker, 'info', 'particle_rotation_ignored', modifier, 'NiParticleRotation is ignored')
    return
  end

  if kind == 'NiParticleColorModifier' then
    local color = get(checker, modifier, 'NiParticleColorModifier')
    if color and color.data < 0 then
      push(
        checker,
        'broken',
        'controller_without_data',
        modifier,
        'NiParticleColorModifier without color data is skipped'
      )
    end

    return
  end

  push(
    checker,
    'broken',
    'unhandled_particle_modifier',
    modifier,
    `Unhandled particle modifier {typeName(checker, modifier)}`
  )
end

--- nifloader.cpp `handleParticleSystem`, `handleParticlePrograms`.
local function checkParticles(checker: Checker, index: number)
  local particles = get(checker, index, 'NiGeometry')
  if not particles then return end

  local name = particles.name
  local chain = Base.controllers(checker, particles.controller)
  local function isSystemController(controller: number): boolean
    local kind = recordType(checker, controller)
    return kind == 'NiParticleSystemController' or kind == 'NiBSPArrayController'
  end

  local controllerIndex, controller = nil, nil
  for position = #chain, 1, -1 do
    local entry = chain[position]
    if not Base.isActive(entry[2]) or not isSystemController(entry[1]) then continue end

    local system = get(checker, entry[1], 'NiParticleSystemController')
    if system then
      controllerIndex, controller = entry[1], system
      break
    end
  end

  if not controller then
    if any[for entry in chain => isSystemController(entry[1])] then
      push(
        checker,
        'info',
        'inactive_particles',
        index,
        `"{name}" has only inactive particle controllers, so it has no particles`
      )
      return
    end

    push(
      checker,
      'broken',
      'particles_without_controller',
      index,
      `No particle controller found for "{name}", so it has no particles`
    )
    return
  end

  checker.stats.shapes += 1
  if controller.emitter < 0 then
    push(
      checker,
      'broken',
      'particles_without_emitter',
      controllerIndex,
      'the particle controller has no emitter, so nothing is emitted'
    )
  end

  local function chain(first: number, colliders: boolean)
    local seen, count = {}, 0
    local link = first
    while count < 4096 do
      if link < 0 or seen[link] then break end

      seen[link] = true
      count += 1
      local object = get(checker, link, 'NiParticleModifier')
      if not object then break end

      checkParticleModifier(checker, link, colliders)
      link = object.next
    end
  end

  chain(controller.modifier, false)
  chain(controller.collider, true)
end

--- nifloader.cpp `handleEffect`: only enabled, sphere-mapped environment maps work.
local function checkEffect(checker: Checker, index: number)
  if not is(checker, index, 'NiTextureEffect') then
    if checker.records[index + 1] then
      push(
        checker,
        'info',
        'light_ignored',
        index,
        `Unhandled effect {typeName(checker, index)}; NIF lights don't light anything`
      )
    end

    return
  end

  local effect = get(checker, index, 'NiTextureEffect')
  if not effect or not effect.switchState then return end

  -- `NiTextureEffect::TextureType::Environment_Map` and `CoordGenType::Sphere_Map`.
  if effect.textureType ~= 2 then
    push(
      checker,
      'broken',
      'unhandled_texture_effect',
      index,
      `Unhandled NiTextureEffect type {effect.textureType}`
    )
  elseif effect.texture < 0 then
    push(
      checker,
      'broken',
      'texture_effect_without_texture',
      index,
      'NiTextureEffect missing source texture'
    )
  elseif effect.coordGenType ~= 2 then
    push(
      checker,
      'broken',
      'unhandled_texture_effect',
      index,
      `Unhandled NiTextureEffect CoordGenType {effect.coordGenType}`
    )
  end
end

local function checkNode(checker: Checker, index: number, node: any)
  local kind = recordType(checker, index)
  if kind == 'NiBillboardNode' then
    -- nifloader.cpp `createNode`: other modes fall back to rigid face camera.
    local billboard = get(checker, index, 'NiBillboardNode')
    local mode = if billboard then billboard.mode else 0
    local unhandled: string? = nil
    if mode == 3 then
      unhandled = 'always face center'
    elseif mode == 4 then
      unhandled = 'rigid face center'
    elseif mode ~= 0 and mode ~= 1 and mode ~= 2 and mode ~= 5 then
      unhandled = 'unknown'
    end

    if unhandled then
      push(
        checker,
        'broken',
        'unhandled_billboard_mode',
        index,
        `Unhandled billboard mode {mode} ({unhandled}); it falls back to rigid face camera`
      )
    end
  elseif kind == 'NiSortAdjustNode' then
    local sort = get(checker, index, 'NiSortAdjustNode')
    if sort then
      if sort.subSorter < 0 then
        push(
          checker,
          'broken',
          'empty_accumulator',
          index,
          'Empty accumulator found in NiSortAdjustNode; it has no effect'
        )
      else
        push(
          checker,
          'info',
          'sort_adjust_leaks',
          index,
          'OpenMW applies an NiSortAdjustNode\'s sorting to every shape after it in the file, not just its children'
        )
      end
    end
  end

  for _, effect in node.effects do
    if effect >= 0 then checkEffect(checker, effect) end
  end

  for _, child in node.children do
    if child < 0 then continue end

    if get(checker, child, 'NiDynamicEffect') and not checker.listedEffects[child] then
      push(
        checker,
        'info',
        'effect_in_children',
        child,
        `{typeName(checker, child)} is a child but in no node's effect list, so it does nothing`
      )
    end
  end
end

--- What `handleNode` draws of a visible leaf: particles, geometry, and `BSTriShape`s, minus
--- shadows and hidden editor markers.
local function checkShape(checker: Checker, index: number, state: RenderState)
  local kind = recordType(checker, index)
  if not kind then return end

  local name = nameOf(checker, index)
  -- nifloader.cpp `handleNode`: particles are handled before and apart from geometry.
  if kind == 'NiParticles' then
    checkParticles(checker, index)
    return
  end

  -- Neither NiParticles nor geometry, so nothing handles them.
  if kind == 'NiParticleSystem' or kind == 'BSStripParticleSystem' then
    push(
      checker,
      'broken',
      'unsupported_particles',
      index,
      `{typeName(checker, index)} "{name}" isn't drawn; OpenMW only handles Morrowind-style NiParticles`
    )
    return
  end

  if not NiGeometryTypes[kind] and not BsGeometryTypes[kind] then return end

  if Base.morrowindRules(checker) then
    if startsWithIgnoreCase(name, 'shadow') or startsWithIgnoreCase(name, 'tri shadow') then
      return
    end

    if startsWithIgnoreCase(name, 'tri editormarker') then
      if checker.hasMarkers then return end

      push(
        checker,
        'broken',
        'visible_editor_marker',
        index,
        `"{name}" draws in game because the root has no "MRK" string data`
      )
    end
  elseif
    startsWithIgnoreCase(name, 'EditorMarker')
    or startsWithIgnoreCase(name, 'VisibilityEditorMarker')
  then
    if checker.hasMarkers then return end

    push(
      checker,
      'broken',
      'visible_editor_marker',
      index,
      `"{name}" draws in game because the root has neither "MRK" string data nor the BSXFlags editor marker bit (32)`
    )
  end

  if BsGeometryTypes[kind] then
    checkBsGeometry(checker, index)
  else
    checkGeometry(checker, index, kind, state)
  end
end

type Pending = { index: number, state: RenderState? }

--- One node of the render traversal; its children go on `stack`, the first on top.
local function walkNode(
  checker: Checker,
  index: number,
  from: RenderState,
  seen: { [number]: boolean },
  stack: { Pending }
)
  local av = get(checker, index, 'NiAVObject')
  if not av or seen[index] then return end

  seen[index] = true
  local state: RenderState = { texturing = from.texturing, root = false }
  -- Non-root "Bounding Box" objects are dropped.
  if not from.root and string.lower(av.name) == 'bounding box' then return end

  local node = get(checker, index, 'NiNode')
  if node then
    checker.stats.nodes += 1
  end

  for _, property in av.properties do
    if property >= 0 then table.insert(checker.properties, property) end
  end

  -- applyNodeProperties: geometry's shader and alpha properties.
  local geometry = get(checker, index, 'NiGeometry') or get(checker, index, 'BSTriShape')
  if geometry then
    if geometry.shaderProperty >= 0 then
      table.insert(checker.properties, geometry.shaderProperty)
    end

    if geometry.alphaProperty >= 0 then table.insert(checker.properties, geometry.alphaProperty) end
  end

  for _, property in av.properties do
    if property >= 0 and is(checker, property, 'NiTexturingProperty') then
      state.texturing = property
    end
  end

  local chain = Base.controllers(checker, av.controller)
  local hasVisController = any[for entry in chain => is(checker, entry[1], 'NiVisController')]
  Base.checkNodeControllers(checker, index, chain)

  -- Hidden subtrees (flag 0x1) stay in the graph for their controllers, but only draw with an
  -- NiVisController on the hidden node itself. The collision node is hidden too.
  local hidden =
    (bit32.btest(av.flags, 1) and not hasVisController) or index == checker.collisionNode
  if node then
    checkNode(checker, index, node)
    local childState = if hidden then nil else state
    local children = node.children
    for position = #children, 1, -1 do
      local child = children[position]
      if child >= 0 then table.insert(stack, { index = child, state = childState }) end
    end
  elseif not hidden then
    checkShape(checker, index, state)
  end
end

--- Hidden subtrees: controllers still load, nothing draws.
local function walkHiddenNode(
  checker: Checker,
  index: number,
  seen: { [number]: boolean },
  stack: { Pending }
)
  local av = get(checker, index, 'NiAVObject')
  if not av or seen[index] then return end

  seen[index] = true
  Base.checkNodeControllers(checker, index, Base.controllers(checker, av.controller))
  local node = get(checker, index, 'NiNode')
  if not node then return end

  local children = node.children
  for position = #children, 1, -1 do
    local child = children[position]
    if child >= 0 then table.insert(stack, { index = child, state = nil }) end
  end
end

--- The render traversal, `NIFObjectLoader::handleNode`: depth first, children in order, without
--- recursion. A child without a render state is in a hidden subtree.
local function walk(checker: Checker, root: number, state: RenderState)
  local seen = {}
  local stack: { Pending } = { { index = root, state = state } }
  while #stack > 0 do
    local pending = table.remove(stack) :: Pending
    if pending.state then
      walkNode(checker, pending.index, pending.state, seen, stack)
    else
      walkHiddenNode(checker, pending.index, seen, stack)
    end
  end
end

return table.freeze {
  walk = walk,
  countTriangles = countTriangles,
}
