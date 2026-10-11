--!strict
--!native
-- The NIF package's suite, on the two NetImmerse 4.0.0.2 files jess-nif tested with
-- (`assets/`) and on bytes built here. What the files hold was read off them once and is pinned
-- below; `golden/nif.txt` holds the digests the port campaign froze after jess-nif agreed.
local check = require '@nif/check'
local fix = require '@nif/fix'
local gamebryo = require '@nif/gamebryo'
local header = require '@nif/header'
local info = require '@nif/info'
local nif = require '@nif'
local scene = require '@nif/scene'
local support = require './support'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

local u8, u16, u32, i32, f32 = support.u8, support.u16, support.u32, support.i32, support.f32
local sized, short = support.sized, support.short

local AllTypes = support.asset 'all_types.nif'
local RandomObjects = support.asset 'random_objects.nif'

local Assets = {
  { name = 'all_types.nif', bytes = AllTypes },
  { name = 'random_objects.nif', bytes = RandomObjects },
}

--- Every record of `all_types.nif`, in file order.
local AllTypesRecords = 'NiNode NiBltSource NiTexturingProperty NiZBufferProperty NiStencilProperty'
  .. ' NiVertexColorProperty NiFogProperty NiAlphaProperty NiDitherProperty NiBSPArrayController'
  .. ' NiDirectionalLight NiSpotLight NiAmbientLight NiPointLight NiTextureEffect NiSourceTexture'
  .. ' NiSequenceStreamHelper NiDX8Renderer NiNode NiExtraData NiStringExtraData'
  .. ' NiTextKeyExtraData NiVertWeightsExtraData BrickNiExtraData TES3ObjectExtraData'
  .. ' NiFlipController NiKeyframeController NiAlphaController NiRollController'
  .. ' NiLightColorController NiLookAtController NiMaterialColorController NiKeyframeData NiCamera'
  .. ' NiScreenPolygon NiScreenPolygon NiFltAnimationNode NiLODNode NiSwitchNode NiSortAdjustNode'
  .. ' NiBillboardNode NiBSPNode NiBSParticleNode NiCollisionSwitch NiBSAnimationNode'
  .. ' RootCollisionNode AvoidNode NiAutoNormalParticles NiParticleSystemController'
  .. ' NiParticleColorModifier NiParticleGrowFade NiParticleRotation NiColorData'
  .. ' NiAutoNormalParticlesData NiTriShape NiPathController NiUVController NiVisController'
  .. ' NiVisData NiUVData NiTriShapeDynamicData NiLines NiLinesData NiParticles'
  .. ' NiParticleSystemController NiGravity NiSphericalCollider NiParticlesData'
  .. ' NiRotatingParticles NiParticleSystemController NiParticleBomb NiPlanarCollider'
  .. ' NiRotatingParticlesData NiTriShape NiGeomMorpherController NiMorphData NiTriShapeData'
  .. ' NiTriStrips NiTriStripsData NiSourceTexture NiPixelData NiPalette NiSkinPartition'
  .. ' NiKeyframeManager NiNode'

--- Each record of `all_types.nif` that links to others, as `index:links`, in file order.
local AllTypesLinks = {
  '18:19,25,33,36,37,38,39,40,41,42,43,44,45,46,47,54,61,63,68,73,77',
  '19:20',
  '20:21',
  '21:22',
  '22:23',
  '23:24',
  '25:26,18',
  '26:27,18,32',
  '27:28,18',
  '28:29,18',
  '29:30,18',
  '30:31,18',
  '31:18',
  '33:34,35',
  '47:48,53',
  '48:47,49',
  '49:50,52',
  '50:51',
  '54:55,60',
  '55:56,54',
  '56:57,54,59',
  '57:54,58',
  '61:62',
  '63:64,67',
  '64:63,65,66',
  '68:69,72',
  '69:68,70,71',
  '73:74,76',
  '74:73,75',
  '77:78',
  '79:80',
  '80:81',
}

local AllTypesRoots =
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 79, 82, 83, 84 }

local RandomObjectsRecords = 'NiNode NiTriShape NiTriShapeData NiNode NiTriShape NiTriShapeData'
  .. ' NiNode NiTriShape NiTriShapeData NiTriShape NiTriShapeData NiTriShape NiTriShape'
  .. ' NiTriShapeData NiTriShape NiWireframeProperty NiMaterialProperty NiTriShapeData NiTriShape'
  .. ' NiTriShapeData'

local RandomObjectsLinks = {
  '0:1,3,9,11,12,14,18',
  '1:2',
  '3:4,6',
  '4:5',
  '6:7',
  '7:8',
  '9:10',
  '11:10',
  '12:13',
  '14:15,16,17',
  '18:15,16,19',
}

--- Where things are in `random_objects.nif`: the `f32` scale of the shape `Cone` (record 1),
--- the `u32` length before the name of the node `Empty 1` (record 3), and the first vertex of
--- the `unitCube` data (record 17).
local ConeScaleAt, EmptyNameAt, CubeVertexAt = 278, 4850, 228786

--- The digests the NIF port campaign froze, each blessed only after jess-nif gave the same
--- answer: `fixture/<file>/<suite>` and `edit/<scenario>`.
local Golden = support.goldens 'nif.txt'

local Vertices = { { 0, 0, 0 }, { 10, 0, 0 }, { 10, 10, 0 }, { 0, 10, 3 }, { 5, 5, 8 } }
local Triangles = { { 0, 1, 2 }, { 0, 2, 3 }, { 2, 3, 4 } }
local Uvs = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { 0.5, 0.5 } }
local Colors = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 }, { 1, 1, 1, 0.5 }, { 0, 0, 0, 1 } }

--- A shape's options, under `root`.
local function shapeSpec(root: number): nif.ShapeSpec
  return {
    name = 'Tri Shape',
    vertices = Vertices,
    triangles = Triangles,
    uvSets = { Uvs, Uvs },
    vertexColors = Colors,
    texture = 'textures\\tx_a.dds',
    material = { alpha = 0.5, emissiveColor = { 0.2, 0.3, 0.4 } },
    parent = root,
    translation = { 1, 2, 3 },
    rotation = { 0, -1, 0, 1, 0, 0, 0, 0, 1 },
    scale = 2,
  } :: any
end

--- The campaign's building and editing scenarios (the model's half of its
--- `edit_differential.luau`), each returning its save; `golden/nif.txt` has every one's digest.
local Scenarios: { [string]: () -> buffer } = {}

Scenarios['bare records'] = function(): buffer
  local file = nif.new()
  local roots = {}
  for _, name in nif.recordTypes do
    table.insert(roots, file:insert { type = name })
  end

  file.roots = roots
  return file:save()
end

Scenarios['shape'] = function(): buffer
  local file = nif.new()
  local root = file:insert { type = 'NiNode', name = 'Root' }
  file:shape(shapeSpec(root))
  file.roots = { root }
  return file:save()
end

Scenarios['strips'] = function(): buffer
  local file = nif.new()
  local data = file:insert {
    type = 'NiTriStripsData',
    vertices = Vertices,
    stripLengths = { 4, 3 },
    strips = { 0, 1, 3, 2, 2, 3, 4 },
  }

  file.roots = { file:insert { type = 'NiTriStrips', geometryData = data } }
  return file:save()
end

Scenarios['remove'] = function(): buffer
  local file = nif.open(RandomObjects)
  file:remove(file:find({ type = 'NiTriShape', name = 'cube' })[1])
  return file:save()
end

Scenarios['attach and detach'] = function(): buffer
  local file = nif.open(RandomObjects)
  local sphere = file:find({ name = '^sphere$' })[1]
  file:detach(file:find({ name = '^empty 2$' })[1], sphere)
  file:attach(file.roots[1], sphere)
  return file:save()
end

Scenarios['textures'] = function(): buffer
  local file = nif.open(AllTypes)
  local path = file:textures()[1].path
  file:setTexture(string.upper((string.gsub(path, '\\', '/'))), 'textures/replaced.dds')
  return file:save()
end

Scenarios['bounds'] = function(): buffer
  local file = nif.open(RandomObjects)
  local index = file:find({ type = 'NiTriShapeData' })[1]
  local data = file:record(index) :: any
  for position = 1, data.vertices.count do
    local vertex = data.vertices:get(position)
    data.vertices:set(position, vector.create(vertex.x * 3, vertex.y + 7, vertex.z))
  end

  file:computeNormals(index)
  file:updateBounds()
  return file:save()
end

local ScenarioNames =
  { 'attach and detach', 'bare records', 'bounds', 'remove', 'shape', 'strips', 'textures' }

local IdentityRows = f32(1)
  .. f32(0)
  .. f32(0)
  .. f32(0)
  .. f32(1)
  .. f32(0)
  .. f32(0)
  .. f32(0)
  .. f32(1)

--- A Skyrim file (20.2.0.7, user version 12, stream 83) holding one `NiNode`: flags 14, at
--- (1, 2, 3), its name the first entry of the header's string table, no links.
local SkyrimNode = i32(0)
  .. u32(0)
  .. i32(-1)
  .. u32(14)
  .. f32(1)
  .. f32(2)
  .. f32(3)
  .. IdentityRows
  .. f32(1)
  .. i32(-1)
  .. u32(0)
  .. u32(0)

local SkyrimHeader = 'Gamebryo File Format, Version 20.2.0.7\n'
  .. u32(0x14020007)
  .. u8(1)
  .. u32(12)
  .. u32(1)
  .. u32(83)
  .. short 'author\0'
  .. short 'process\0'
  .. short 'export\0'
  .. u16(1)
  .. sized 'NiNode'
  .. u16(0)
  .. u32(#SkyrimNode)
  .. u32(1)
  .. u32(10)
  .. sized 'Scene Root'
  .. u32(0)

local SkyrimFile = SkyrimHeader .. SkyrimNode .. u32(1) .. i32(0)

--- The same node as Oblivion's 20.0.0.5 writes it, in a file without a Bethesda stream header:
--- its name inline, 16-bit flags, and a property list.
local OblivionNode = sized 'Scene Root'
  .. u32(0)
  .. i32(-1)
  .. u16(14)
  .. f32(1)
  .. f32(2)
  .. f32(3)
  .. IdentityRows
  .. f32(1)
  .. u32(0)
  .. i32(-1)
  .. u32(0)
  .. u32(0)

local OblivionHeader = 'Gamebryo File Format, Version 20.0.0.5\n'
  .. u32(0x14000005)
  .. u8(1)
  .. u32(0)
  .. u32(1)
  .. u16(1)
  .. sized 'NiNode'
  .. u16(0)
  .. u32(0)

local OblivionFile = OblivionHeader .. OblivionNode .. u32(1) .. i32(0)

--- What the multi-version reader makes of either hand-built node.
local SceneRoot = {
  type = 'NiNode',
  name = 'Scene Root',
  flags = 14,
  extra = -1,
  extraList = {},
  controller = -1,
  collision = -1,
  bounds = { type = 4294967295 },
  transform = {
    translation = vector.create(1, 2, 3),
    rotation = { vector.create(1, 0, 0), vector.create(0, 1, 0), vector.create(0, 0, 1) },
    scale = 1,
  },
  velocity = vector.zero,
  properties = {},
  children = {},
  effects = {},
}

local function typesOf(file: nif.Nif): string
  local names = {}
  for index = 0, file.count - 1 do
    table.insert(names, file:typeOf(index) or '-')
  end

  return table.concat(names, ' ')
end

--- Each record's links as the scan found them, `index:links`, records without any left out.
local function linksOf(file: nif.Nif): { string }
  local found, first = {}, 1
  for index = 1, file.count do
    local last = file.linkEnds[index]
    if last >= first then
      found[#found + 1] = `{index - 1}:{table.concat(file.links, ',', first, last)}`
    end

    first = last + 1
  end

  return found
end

local function decodeAll(file: nif.Nif)
  for index = 0, file.count - 1 do
    file:record(index)
  end
end

--- The first and last offsets where two byte strings differ, or nil when they are the same.
local function difference(left: string, right: string): (number?, number?)
  if left == right then return nil, nil end

  local first, last
  for position = 1, math.max(#left, #right) do
    if string.byte(left, position) == string.byte(right, position) then continue end

    first = first or position - 1
    last = position - 1
  end

  return first, last
end

local function saved(file: nif.Nif): string return buffer.tostring(file:save()) end

--- Every record's digest, by 0-based index, for telling which records an edit changed.
local function recordDigests(file: nif.Nif): { [number]: string }
  local digests = {}
  for index = 0, file.count - 1 do
    digests[index] = support.digest(file:record(index))
  end

  return digests
end

--- A file whose root has a `RootCollisionNode` under a child node, an editor marker shape,
--- and `NCc` string data: one finding each for `check`, and one repair each for `fix`.
local function defects(): nif.Nif
  local file = nif.new()
  local root = file:insert { type = 'NiNode', name = 'Root' }
  local lowercase = file:insert { type = 'NiStringExtraData', value = 'NCc', bytesRemaining = 7 }
  local rootNode = file:record(root) :: any
  rootNode.extraData = lowercase

  local inner = file:insert { type = 'NiNode', name = 'Inner' }
  file:attach(root, inner)
  file:attach(inner, file:insert { type = 'RootCollisionNode', name = 'RootCollisionNode' })
  file:shape {
    name = 'Tri EditorMarker 0',
    vertices = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } },
    triangles = { { 0, 1, 2 } },
    parent = root,
  }
  file.roots = { root }
  return file
end

--- A skinned triangle whose one bone weights vertices 0, 2, and 7, of the shape's three. The
--- model builds everything but the weights, whose array kind only a file can supply: the bone
--- is spliced into the saved `NiSkinData` (record 2), after its bone count and partition link.
local function skinned(): string
  local file = nif.new()
  local root = file:insert { type = 'NiNode', name = 'Root' }
  local bone = file:insert { type = 'NiNode', name = 'Bone' }
  file:attach(root, bone)

  local data = file:insert { type = 'NiSkinData' }
  local skin = file:insert { type = 'NiSkinInstance', data = data, root = root, bones = { bone } }
  local shape = file:shape {
    name = 'Skinned',
    vertices = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } },
    triangles = { { 0, 1, 2 } },
    parent = root,
  }
  local shapeRecord = file:record(shape) :: any
  shapeRecord.skinInstance = skin
  file.roots = { root }

  local bytes = buffer.tostring(file:save())
  local body = nif.open(bytes).bodies[data + 1]
  local weights = u16(3) .. u16(0) .. f32(1) .. u16(2) .. f32(0.5) .. u16(7) .. f32(0.25)
  local boneData = IdentityRows
    .. f32(0)
    .. f32(0)
    .. f32(0)
    .. f32(1)
    .. string.rep('\0', 16)
    .. weights
  return string.sub(bytes, 1, body + 52)
    .. u32(1)
    .. i32(-1)
    .. boneData
    .. string.sub(bytes, body + 61)
end

--- A root node followed by a copy of itself that nothing links to: a save never writes one, so
--- the copy is spliced in before the roots and the record count raised.
local function unreachable(): (string, string)
  local file = nif.new()
  file.roots = { file:insert { type = 'NiNode', name = 'Root' } }

  local bytes = buffer.tostring(file:save())
  local opened = nif.open(bytes)
  local node = string.sub(bytes, opened.starts[1] + 1, opened.rootsAt)
  return string.sub(bytes, 1, 44) .. u32(2) .. node .. node .. string.sub(bytes, opened.rootsAt + 1),
    bytes
end

--- A report without its header, which the header cases pin.
local function findings(name: string, data: buffer | string): check.Report
  local report = check.check(name, data)
  report.header = nil
  return report
end

local NoStats: check.Stats = {
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
}

local function stats(counts: { [string]: number | boolean }): check.Stats
  local made = table.clone(NoStats) :: any
  for key, value in counts do
    made[key] = value
  end

  return made
end

suite.describe('the module', function()
  suite.it('is frozen and lists the 112 record types it knows', function()
    expect(table.isfrozen(nif)).toBe(true)
    expect(#nif.recordTypes).toBe(112)
    expect(nif.recordTypes[1]).toBe 'NiObject'
    expect(nif.recordTypes[4]).toBe 'NiNode'
    expect(nif.recordTypes[112]).toBe 'NiDX8Renderer'
  end)

  suite.it('makes an empty file that saves as a header with no records or roots', function()
    local empty = nif.new()
    expect(empty.count).toBe(0)
    expect(empty.roots).toEqual {}
    expect(empty:reachableCount()).toBe(0)

    local bytes = saved(empty)
    expect(bytes).toBe(
      'NetImmerse File Format, Version 4.0.0.2\n' .. u32(0x04000002) .. u32(0) .. u32(0)
    )

    local reopened = nif.open(bytes)
    expect(reopened.count).toBe(0)
    expect(reopened.roots).toEqual {}
  end)
end)

suite.describe('open', function()
  suite.it('reads all_types.nif: 85 records of 78 types under 23 roots', function()
    local file = nif.open(AllTypes)
    expect(file.count).toBe(85)
    expect(file.roots).toEqual(AllTypesRoots)
    expect(typesOf(file)).toBe(AllTypesRecords)
    expect(linksOf(file)).toEqual(AllTypesLinks)
    expect(file:reachableCount()).toBe(85)

    local distinct, count = {}, 0
    for index = 0, file.count - 1 do
      local name = file:typeOf(index) :: string
      if not distinct[name] then
        count += 1
      end

      distinct[name] = true
    end

    expect(count).toBe(78)
  end)

  suite.it('reads random_objects.nif: 20 records under one root', function()
    local file = nif.open(RandomObjects)
    expect(file.count).toBe(20)
    expect(file.roots).toEqual { 0 }
    expect(typesOf(file)).toBe(RandomObjectsRecords)
    expect(linksOf(file)).toEqual(RandomObjectsLinks)
    expect(file:reachableCount()).toBe(20)
  end)

  suite.it('takes a buffer as it takes a string, and keeps it as the source', function()
    local bytes = buffer.fromstring(RandomObjects)
    local file = nif.open(bytes)
    expect(file.source).toBe(bytes)
    expect(file.count).toBe(20)
    expect(typesOf(file)).toBe(RandomObjectsRecords)
  end)

  suite.it('decodes nothing until a record is asked for', function()
    local file = nif.open(RandomObjects)
    for index = 0, file.count - 1 do
      expect(file:isDecoded(index)).toBe(false)
    end

    local cone = file:record(1)
    expect(file:isDecoded(1)).toBe(true)
    expect(file:isDecoded(2)).toBe(false)
    expect(file:record(1)).toBe(cone)
    expect(file:indexOf(cone :: nif.Record)).toBe(1)
  end)

  suite.it('answers nil past either end', function()
    local file = nif.open(RandomObjects)
    expect(file:record(-1)).toBeNil()
    expect(file:record(20)).toBeNil()
    expect(file:typeOf(20)).toBeNil()
    expect(file:read(20, {})).toBeNil()
    expect(file:indexOf({} :: any)).toBeNil()
  end)
end)

suite.describe('records', function()
  suite.it('decode a node, a shape, and its properties as the file holds them', function()
    local file = nif.open(RandomObjects)
    local root = file:record(0) :: any
    expect(root.type).toBe 'NiNode'
    expect(root.name).toBe 'random_objects.nif'
    expect(root.flags).toBe(0)
    expect(root.scale).toBe(1)
    expect(root.translation).toBe(vector.zero)
    expect(root.rotation).toEqual {
      vector.create(1, 0, 0),
      vector.create(0, 1, 0),
      vector.create(0, 0, 1),
    }
    expect(root.children:toTable()).toEqual { 1, 3, 9, 11, 12, 14, 18 }
    expect(root.properties.count).toBe(0)
    expect(root.extraData).toBeNil()
    expect(root.controller).toBeNil()

    local cone = file:record(1) :: any
    expect(cone.type).toBe 'NiTriShape'
    expect(cone.name).toBe 'Cone'
    expect(cone.flags).toBe(2)
    expect(cone.geometryData).toBe(2)
    expect(cone.scale).toBe(1.1419281959533691)
    expect(cone.translation).toBe(
      vector.create(-276.1847839355469, -88.8243179321289, 127.00479125976562)
    )

    local cube = file:record(14) :: any
    expect(cube.name).toBe 'unitCube'
    expect(cube.properties:toTable()).toEqual { 15, 16 }
    expect(file:record(15)).toEqual { type = 'NiWireframeProperty', name = '', flags = 1 }
    expect(file:record(16)).toEqual {
      type = 'NiMaterialProperty',
      name = '',
      flags = 1,
      ambientColor = vector.create(1, 0, 0),
      diffuseColor = vector.create(1, 0, 0),
      specularColor = vector.create(1, 0, 0),
      emissiveColor = vector.create(1, 0, 0),
      shine = 0,
      alpha = 1,
    }
  end)

  suite.it('view geometry as arrays over the file\'s bytes', function()
    local file = nif.open(RandomObjects)
    local data = file:record(17) :: any
    expect(data.type).toBe 'NiTriShapeData'
    expect(data.vertices.buffer).toBe(file.source)
    expect(data.vertices.offset).toBe(CubeVertexAt)
    expect(data.vertices.kind).toBe 'vec3'
    expect(#data.vertices).toBe(8)
    expect(data.vertices:toTable()).toEqual {
      vector.create(-0.5, -0.5, -0.5),
      vector.create(0.5, -0.5, -0.5),
      vector.create(-0.5, 0.5, -0.5),
      vector.create(0.5, 0.5, -0.5),
      vector.create(-0.5, -0.5, 0.5),
      vector.create(0.5, -0.5, 0.5),
      vector.create(-0.5, 0.5, 0.5),
      vector.create(0.5, 0.5, 0.5),
    }
    expect(data.triangles.count).toBe(12)
    expect(data.triangles:get(1)).toBe(vector.create(0, 2, 1))
    expect(data.triangles:get(12)).toBe(vector.create(3, 7, 5))
    expect(data.normals.count).toBe(0)
    expect(data.uvSets).toEqual {}
    expect(data.bound).toEqual { center = vector.zero, radius = 0.8660253882408142 }

    local cone = file:record(2) :: any
    expect(cone.vertices.count).toBe(128)
    expect(cone.normals.count).toBe(128)
    expect(cone.triangles.count).toBe(62)
    expect(#cone.uvSets).toBe(1)
    expect(cone.uvSets[1].count).toBe(128)
    expect(cone.bound.radius).toBe(141.42135620117188)
  end)

  suite.it('decode all_types.nif\'s extra data chain, textures, and pixels', function()
    local file = nif.open(AllTypes)
    local scene = file:record(18) :: any
    expect(scene.name).toBe 'Scene Root'
    expect(scene.extraData).toBe(19)
    expect(scene.controller).toBe(25)
    expect(scene.children.count).toBe(19)
    expect(file:record(19)).toEqual { type = 'NiExtraData', next = 20, bytesRemaining = 0 }
    expect(file:record(20)).toEqual {
      type = 'NiStringExtraData',
      next = 21,
      bytesRemaining = 0,
      value = 'Hello World',
    }

    expect(file:record(21)).toEqual {
      type = 'NiTextKeyExtraData',
      next = 22,
      bytesRemaining = 0,
      keys = { { time = 1, value = 'Hello' }, { time = 2, value = 'World' } },
    }
    expect(file:record(24)).toEqual { type = 'TES3ObjectExtraData', bytesRemaining = 0 }
    expect(file:record(15)).toEqual {
      type = 'NiSourceTexture',
      name = '',
      source = { external = 'g7\\textests\\light07_0.bmp' },
      pixelLayout = 'Palettized8',
      useMipmaps = 'No',
      alphaFormat = 'Binary',
      isStatic = true,
    }

    local embedded = file:record(79) :: any
    expect(embedded.source).toEqual { internal = 80 }
    expect(embedded.isStatic).toBe(false)

    local pixels = file:record(80) :: any
    expect(pixels.palette).toBe(81)
    expect(pixels.pixelStride).toBe(1)
    expect(pixels.pixelData.count).toBe(2)
    expect(pixels.mipmaps.count).toBe(2)

    local palette = file:record(81) :: any
    expect(palette.hasAlpha).toBe(false)
    expect(palette.palettes.count).toBe(3)
  end)

  suite.it('read into a caller\'s table without keeping anything', function()
    local file = nif.open(RandomObjects)
    local into = {}
    local cone = file:read(1, into) :: any
    expect(cone).toBe(into)
    expect(cone.name).toBe 'Cone'
    expect(cone.scale).toBe(1.1419281959533691)
    expect(file:isDecoded(1)).toBe(false)
    expect(file:indexOf(cone)).toBeNil()

    local cube = file:read(4, into) :: any
    expect(cube).toBe(into)
    expect(cube.name).toBe 'Cube'
    expect(cube.geometryData).toBe(5)
    expect(support.digest(file:read(16, {}))).toBe(support.digest(file:record(16)))
  end)

  suite.it('iterate in file order with 0-based indices', function()
    local file = nif.open(RandomObjects)
    local indices, names = {}, {}
    for index, record in file:records() do
      table.insert(indices, index)
      table.insert(names, (record :: nif.Record).type)
    end

    expect(#indices).toBe(20)
    expect(indices[1]).toBe(0)
    expect(indices[20]).toBe(19)
    expect(table.concat(names, ' ')).toBe(RandomObjectsRecords)
    expect(file:isDecoded(19)).toBe(true)
  end)

  suite.it('are found by type and by a case-insensitive name pattern', function()
    local file = nif.open(RandomObjects)
    expect(#file:find()).toBe(20)
    expect(file:find { type = 'NiNode' }).toEqual { 0, 3, 6 }
    expect(file:find { type = 'ninode' }).toEqual { 0, 3, 6 }
    expect(file:find { name = 'suzanne' }).toEqual { 9, 11 }
    expect(file:find { type = { 'NiTriShape', 'NiNode' }, name = '^(cone|empty 1)$' }).toEqual {
      1,
      3,
    }
    expect(file:find { type = 'NiCamera' }).toEqual {}
    expect(file:find { name = 'nothing is called this' }).toEqual {}
  end)

  suite.it('dump whole, as a list, and narrowed by type, index, and name', function()
    local file = nif.open(RandomObjects)
    local listed = file:dump { list = true, type = 'NiNode' }
    expect(listed).toEqual {
      roots = { 0 },
      records = {
        { index = 0, type = 'NiNode', name = 'random_objects.nif' },
        { index = 3, type = 'NiNode', name = 'Empty 1' },
        { index = 6, type = 'NiNode', name = 'Empty 2' },
      },
    }

    expect(file:dump({ list = true, index = { 15, 16 } }).records).toEqual {
      { index = 15, type = 'NiWireframeProperty' },
      { index = 16, type = 'NiMaterialProperty' },
    }

    expect(file:dump({ list = true, name = 'torus' }).records).toEqual {
      { index = 12, type = 'NiTriShape', name = 'Torus' },
    }

    local whole = file:dump { index = 16 }
    expect(#whole.records).toBe(1)
    expect(whole.records[1].index).toBe(16)
    expect(whole.records[1].alpha).toBe(1)
    expect(whole.records[1]).toEqual(file:dump({ type = 'NiMaterialProperty' }).records[1])
    expect(#file:dump().records).toBe(20)
    expect(#nif.open(AllTypes):dump({ list = true }).records).toBe(85)
  end)

  suite.it('list external textures with the record naming each', function()
    expect(nif.open(RandomObjects):textures()).toEqual {}
    expect(nif.open(AllTypes):textures()).toEqual {
      { record = 15, path = 'g7\\textests\\light07_0.bmp' },
    }
  end)
end)

suite.describe('preservation', function()
  for _, asset in Assets do
    local name, bytes = asset.name, asset.bytes
    suite.it(`saves {name} untouched as its own bytes`, function()
      expect(difference(saved(nif.open(bytes)), bytes)).toBeNil()
      expect(difference(saved(nif.open(buffer.fromstring(bytes))), bytes)).toBeNil()
    end)

    suite.it(`saves {name} with every record decoded as its own bytes`, function()
      local file = nif.open(bytes)
      decodeAll(file)
      expect(difference(saved(file), bytes)).toBeNil()
      expect(difference(saved(file), bytes)).toBeNil()
    end)

    suite.it(`saves {name} with any one record decoded as its own bytes`, function()
      local count = nif.open(bytes).count
      for index = 0, count - 1 do
        local file = nif.open(bytes)
        file:record(index)
        if saved(file) ~= bytes then error(`decoding record {index} alone changed the save`, 0) end
      end
    end)

    suite.it(`saves {name} as its own bytes after reads, finds, and dumps`, function()
      local file = nif.open(bytes)
      local into = {}
      for index = 0, file.count - 1 do
        file:read(index, into)
      end

      file:find { name = 'e' }
      file:dump()
      file:textures()
      file:reachableCount()
      expect(difference(saved(file), bytes)).toBeNil()
    end)
  end

  suite.it('changes only the field an edit sets', function()
    local file = nif.open(RandomObjects)
    local before = recordDigests(nif.open(RandomObjects))
    local cone = file:record(1) :: any
    cone.scale = 2

    local bytes = saved(file)
    expect(#bytes).toBe(#RandomObjects)
    expect(string.sub(bytes, ConeScaleAt + 1, ConeScaleAt + 4)).toBe(f32(2))
    expect(string.sub(bytes, 1, ConeScaleAt)).toBe(string.sub(RandomObjects, 1, ConeScaleAt))
    expect(string.sub(bytes, ConeScaleAt + 5) == string.sub(RandomObjects, ConeScaleAt + 5)).toBe(
      true
    )

    local reopened = nif.open(bytes)
    expect((reopened:record(1) :: any).scale).toBe(2)
    expect(typesOf(reopened)).toBe(RandomObjectsRecords)
    expect(linksOf(reopened)).toEqual(RandomObjectsLinks)

    local after = recordDigests(reopened)
    for index = 0, 19 do
      if index ~= 1 then expect(after[index]).toBe(before[index]) end
    end

    expect(after[1] == before[1]).toBe(false)
  end)

  suite.it('moves what follows a longer name without changing it', function()
    local file = nif.open(RandomObjects)
    local before = recordDigests(nif.open(RandomObjects))
    local node = file:record(3) :: any
    expect(node.name).toBe 'Empty 1'
    node.name = 'Renamed node'

    local bytes = saved(file)
    expect(#bytes).toBe(#RandomObjects + 5)
    expect(string.sub(bytes, 1, EmptyNameAt)).toBe(string.sub(RandomObjects, 1, EmptyNameAt))
    expect(string.sub(bytes, EmptyNameAt + 1, EmptyNameAt + 16)).toBe(sized 'Renamed node')
    expect(string.sub(bytes, EmptyNameAt + 17) == string.sub(RandomObjects, EmptyNameAt + 12)).toBe(
      true
    )

    local reopened = nif.open(bytes)
    expect((reopened:record(3) :: any).name).toBe 'Renamed node'
    expect(reopened.roots).toEqual { 0 }
    expect(linksOf(reopened)).toEqual(RandomObjectsLinks)

    local after = recordDigests(reopened)
    for index = 0, 19 do
      if index ~= 3 then expect(after[index]).toBe(before[index]) end
    end
  end)

  suite.it('copies an array out on its first set, never writing to the source', function()
    local source = buffer.fromstring(RandomObjects)
    local file = nif.open(source)
    local data = file:record(17) :: any
    data.vertices:set(1, vector.create(-1, -1, -1))
    expect(data.vertices.owned).toBe(true)
    expect(buffer.tostring(source)).toBe(RandomObjects)

    local bytes = saved(file)
    expect(#bytes).toBe(#RandomObjects)

    local first, last = difference(bytes, RandomObjects)
    expect((first :: number) >= CubeVertexAt).toBe(true)
    expect((last :: number) < CubeVertexAt + 12).toBe(true)
    expect(string.sub(bytes, CubeVertexAt + 1, CubeVertexAt + 12)).toBe(
      f32(-1) .. f32(-1) .. f32(-1)
    )

    local reopened = nif.open(bytes):record(17) :: any
    expect(reopened.vertices:get(1)).toBe(vector.create(-1, -1, -1))
    expect(reopened.vertices:get(2)).toBe(vector.create(0.5, -0.5, -0.5))
    expect(reopened.bound.radius).toBe(0.8660253882408142)
  end)

  suite.it('keeps a signaling NaN a decode would have turned quiet', function()
    -- 0x7fa00001: a NaN with the quiet bit clear, where the shape `Cone` has its scale.
    local signaling = '\1\0\160\127'
    local bytes = string.sub(RandomObjects, 1, ConeScaleAt)
      .. signaling
      .. string.sub(RandomObjects, ConeScaleAt + 5)
    local file = nif.open(bytes)
    decodeAll(file)

    local scale = (file:record(1) :: any).scale
    expect(scale ~= scale).toBe(true)
    expect(difference(saved(file), bytes)).toBeNil()
    expect(string.sub(saved(file), ConeScaleAt + 1, ConeScaleAt + 4)).toBe(signaling)
  end)

  suite.it('drops what the roots no longer reach and renumbers the links', function()
    local file = nif.open(RandomObjects)
    expect(file:remove(4)).toBe(true)
    expect(file:remove(4)).toBe(false)
    expect(file:remove(99)).toBe(false)
    expect(file:typeOf(4)).toBeNil()
    expect(file:record(4)).toBeNil()
    expect(file.count).toBe(20)
    expect(file:reachableCount()).toBe(18)

    local indices = {}
    for index in file:records() do
      table.insert(indices, index)
    end

    expect(indices).toEqual { 0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }

    local reopened = nif.open(file:save())
    expect(reopened.count).toBe(18)
    expect(reopened.roots).toEqual { 0 }
    expect(typesOf(reopened)).toBe(
      'NiNode NiTriShape NiTriShapeData NiNode NiNode NiTriShape NiTriShapeData NiTriShape'
        .. ' NiTriShapeData NiTriShape NiTriShape NiTriShapeData NiTriShape NiWireframeProperty'
        .. ' NiMaterialProperty NiTriShapeData NiTriShape NiTriShapeData'
    )
    expect(linksOf(reopened)).toEqual {
      '0:1,3,7,9,10,12,16',
      '1:2',
      '3:4',
      '4:5',
      '5:6',
      '7:8',
      '9:8',
      '10:11',
      '12:13,14,15',
      '16:13,14,17',
    }
    expect((reopened:record(4) :: any).name).toBe 'Empty 2'
    expect(difference(saved(reopened), saved(file))).toBeNil()
  end)

  suite.it('removing a root takes it out of the roots', function()
    local file = nif.open(AllTypes)
    expect(file:remove(84)).toBe(true)
    expect(#file.roots).toBe(22)
    expect(file.roots[22]).toBe(83)

    local reopened = nif.open(file:save())
    expect(reopened.count).toBe(84)
    expect(#reopened.roots).toBe(22)
  end)

  suite.it('writes a link to a record that isn\'t there as -1', function()
    local file = nif.new()
    local root = file:insert { type = 'NiNode', name = 'Root' }
    file:attach(root, 7)
    file.roots = { root }

    local reopened = nif.open(file:save())
    expect(reopened.count).toBe(1)
    expect((reopened:record(0) :: any).children:toTable()).toEqual { -1 }
  end)
end)

suite.describe('building', function()
  suite.it(
    'inserts every record type bare, and each saves and decodes back to the same bytes',
    function()
      local built = buffer.tostring(Scenarios['bare records']())
      local file = nif.open(built)
      expect(file.count).toBe(112)
      expect(#file.roots).toBe(112)
      expect(typesOf(file)).toBe(table.concat(nif.recordTypes, ' '))
      expect(linksOf(file)).toEqual {}
      decodeAll(file)
      expect(difference(saved(file), built)).toBeNil()
    end
  )

  suite.it('adds a shape with its data, texture, and material under a node', function()
    local file = nif.new()
    local root = file:insert { type = 'NiNode', name = 'Root' }
    expect(root).toBe(0)
    expect(file:shape(shapeSpec(root))).toBe(5)
    expect(file.count).toBe(6)
    expect(file:reachableCount()).toBe(0)
    file.roots = { root }
    expect(file:reachableCount()).toBe(6)

    local reopened = nif.open(file:save())
    expect(typesOf(reopened)).toBe 'NiNode NiTriShapeData NiSourceTexture NiTexturingProperty NiMaterialProperty NiTriShape'
    expect(linksOf(reopened)).toEqual { '0:5', '3:2', '5:3,4,1' }

    local shape = reopened:record(5) :: any
    expect(shape.name).toBe 'Tri Shape'
    expect(shape.geometryData).toBe(1)
    expect(shape.properties:toTable()).toEqual { 3, 4 }
    expect(shape.translation).toBe(vector.create(1, 2, 3))
    expect(shape.scale).toBe(2)
    expect(shape.rotation).toEqual {
      vector.create(0, -1, 0),
      vector.create(1, 0, 0),
      vector.create(0, 0, 1),
    }

    local data = reopened:record(1) :: any
    expect(data.vertices:toTable()).toEqual {
      vector.create(0, 0, 0),
      vector.create(10, 0, 0),
      vector.create(10, 10, 0),
      vector.create(0, 10, 3),
      vector.create(5, 5, 8),
    }

    expect(data.triangles:toTable()).toEqual {
      vector.create(0, 1, 2),
      vector.create(0, 2, 3),
      vector.create(2, 3, 4),
    }
    expect(#data.uvSets).toBe(2)
    expect(data.uvSets[2]:get(5)).toBe(vector.create(0.5, 0.5, 0))
    expect(data.vertexColors.count).toBe(5)

    -- Derived, not given: the sphere around the extremes' midpoint, sqrt(66) out, and each
    -- vertex's area-weighted normal; the second vertex is only in the flat first triangle.
    expect(data.bound).toEqual { center = vector.create(5, 5, 4), radius = 8.124038696289062 }
    expect(data.normals.count).toBe(5)
    expect(data.normals:get(2)).toBe(vector.create(0, 0, 1))
    expect((reopened:record(2) :: any).source).toEqual { external = 'textures\\tx_a.dds' }
    expect((reopened:record(3) :: any).textureMaps.base.texture).toBe(2)

    local material = reopened:record(4) :: any
    expect(material.alpha).toBe(0.5)
    expect(material.emissiveColor).toBe(
      vector.create(0.20000000298023224, 0.30000001192092896, 0.4000000059604645)
    )
    expect(reopened:textures()).toEqual { { record = 2, path = 'textures\\tx_a.dds' } }
  end)

  suite.it('counts a strip\'s triangles and derives its bound and normals', function()
    local reopened = nif.open(Scenarios['strips']())
    expect(typesOf(reopened)).toBe 'NiTriStripsData NiTriStrips'
    expect(reopened.roots).toEqual { 1 }

    local data = reopened:record(0) :: any
    expect(data.numTriangles).toBe(3)
    expect(data.stripLengths:toTable()).toEqual { 4, 3 }
    expect(data.strips:toTable()).toEqual { 0, 1, 3, 2, 2, 3, 4 }
    expect(data.bound).toEqual { center = vector.create(5, 5, 4), radius = 8.124038696289062 }
    expect(data.normals.count).toBe(5)
  end)

  suite.it('refuses records and options it doesn\'t know', function()
    local file = nif.open(RandomObjects)
    expect(function() file:insert { type = 'NiBogus' } end).toThrow 'unknown NIF record type \'NiBogus\''
    expect(function() file:insert { name = 'untyped' } end).toThrow 'a record table needs a type, such as "NiNode"'
    expect(function() file:shape({ vertices = {}, triangles = {}, colour = 1 } :: any) end).toThrow 'Nif:shape has no option \'colour\''
    expect(function() file:shape { vertices = {}, triangles = {}, uvs = {}, uvSets = {} } end).toThrow 'pass uvs or uvSets, not both'
    expect(file.count).toBe(20)
  end)
end)

suite.describe('editing', function()
  suite.it('moves a shape from one node to another', function()
    local file = nif.open(RandomObjects)
    local sphere = file:find({ name = '^sphere$' })[1]
    local parent = file:find({ name = '^empty 2$' })[1]
    expect(sphere).toBe(7)
    expect(parent).toBe(6)
    expect(file:detach(parent, sphere)).toBe(true)
    expect(file:detach(parent, sphere)).toBe(false)
    file:attach(file.roots[1], sphere)

    local reopened = nif.open(file:save())
    expect(reopened.count).toBe(20)
    expect((reopened:record(0) :: any).children:toTable()).toEqual { 1, 3, 9, 11, 12, 14, 18, 7 }
    expect((reopened:record(6) :: any).children:toTable()).toEqual {}
  end)

  suite.it('attaches to and detaches from nodes only', function()
    local file = nif.open(RandomObjects)
    expect(function() file:attach(1, 2) end).toThrow 'record 1 isn\'t a node'
    expect(function() file:detach(2, 1) end).toThrow 'record 2 isn\'t a node'
    expect(function() file:attach(99, 1) end).toThrow 'record 99 isn\'t a node'
  end)

  suite.it('repoints a texture spelled another way, in that record alone', function()
    local file = nif.open(AllTypes)
    local before = recordDigests(nif.open(AllTypes))
    expect(file:setTexture('no/such/texture.dds', 'textures/other.dds')).toBe(0)
    expect(file:setTexture('G7/TEXTESTS/LIGHT07_0.BMP', 'textures/replaced.dds')).toBe(1)

    local bytes = saved(file)
    expect(#bytes).toBe(#AllTypes - 4)

    local reopened = nif.open(bytes)
    expect(reopened:textures()).toEqual { { record = 15, path = 'textures/replaced.dds' } }
    expect(typesOf(reopened)).toBe(AllTypesRecords)
    expect(linksOf(reopened)).toEqual(AllTypesLinks)

    local after = recordDigests(reopened)
    for index = 0, 84 do
      if index ~= 15 then expect(after[index]).toBe(before[index]) end
    end
  end)

  suite.it('recomputes normals and bounds from moved vertices', function()
    local file = nif.open(RandomObjects)
    local index = file:find({ type = 'NiTriShapeData' })[1]
    expect(index).toBe(2)

    local data = file:record(index) :: any
    expect(data.bound).toEqual { center = vector.zero, radius = 141.42135620117188 }
    for position = 1, data.vertices.count do
      local vertex = data.vertices:get(position)
      data.vertices:set(position, vector.create(vertex.x * 3, vertex.y + 7, vertex.z))
    end

    expect(data.bound.radius).toBe(141.42135620117188)
    file:computeNormals(index)
    expect(file:updateBounds()).toBe(7)

    -- Three times as wide and 7 further along y: sqrt(300^2 + 100^2) out from (0, 7, 0).
    local bound = (nif.open(file:save()):record(index) :: any).bound
    expect(bound).toEqual { center = vector.create(0, 7, 0), radius = 316.2277526855469 }
    expect(function() file:computeNormals(0) end).toThrow 'record 0 isn\'t geometry data'
    expect(function() file:computeNormals(99) end).toThrow 'record 99 isn\'t geometry data'
  end)
end)

suite.describe('jess-nif\'s answers', function()
  for _, asset in Assets do
    suite.it(`hold for {asset.name}'s records and saves`, function()
      local observed = support.digest(support.attempt(function(): unknown
        local file = nif.open(buffer.fromstring(asset.bytes))
        local untouched = support.xxh3(file:save())
        local records = {}
        for index = 0, file.count - 1 do
          records[index + 1] = file:record(index)
        end

        return { roots = file.roots, records = records, untouched = untouched, saved = file:save() }
      end))
      expect(observed).toBe(Golden[`fixture/{asset.name}/morrowind`])
    end)
  end

  for _, name in ScenarioNames do
    suite.it(
      `hold for the save of '{name}'`,
      function() expect(support.digest(Scenarios[name]())).toBe(Golden[`edit/{name}`]) end
    )
  end
end)

suite.describe('errors', function()
  suite.it('refuse bytes that don\'t start with the NetImmerse 4.0.0.2 header', function()
    expect(function() nif.open '' end).toThrow 'Invalid NIF Header'
    expect(function() nif.open(buffer.create(0)) end).toThrow 'Invalid NIF Header'
    expect(function() nif.open(string.sub(AllTypes, 1, 47)) end).toThrow 'Invalid NIF Header'
    expect(function() nif.open('Gamebryo' .. string.sub(AllTypes, 9)) end).toThrow 'Invalid NIF Header'
    expect(function() nif.open(string.rep('\0', 4096)) end).toThrow 'Invalid NIF Header'
  end)

  suite.it('refuse another version under the right header', function()
    local wrong = string.sub(AllTypes, 1, 40) .. u32(0x04000001) .. string.sub(AllTypes, 45)
    expect(function() nif.open(wrong) end).toThrow 'Invalid NIF Version'
  end)

  suite.it('refuse a record type the model doesn\'t know', function()
    -- The first record's name, `NiNode`, is the six bytes after its length at offset 48.
    expect(string.sub(AllTypes, 49, 58)).toBe(sized 'NiNode')

    local unknown = string.sub(AllTypes, 1, 52) .. 'XiNode' .. string.sub(AllTypes, 59)
    expect(function() nif.open(unknown) end).toThrow 'Invalid Type'

    local lowercase = string.sub(AllTypes, 1, 52) .. 'ninode' .. string.sub(AllTypes, 59)
    expect(function() nif.open(lowercase) end).toThrow 'Invalid Type'
  end)

  suite.it('refuse a file cut short, wherever it is cut', function()
    expect(function() nif.open(string.sub(AllTypes, 1, 48)) end).toThrow 'buffer access out of bounds'
    expect(function() nif.open(string.sub(AllTypes, 1, #AllTypes - 1)) end).toThrow 'buffer access out of bounds'

    for length = 0, #AllTypes - 1 do
      -- Every proper prefix must be refused; what's checked is that none opens.
      local opened = pcall(nif.open, string.sub(AllTypes, 1, length))
      if opened then error(`the first {length} bytes of all_types.nif opened`, 0) end
    end

    for length = 0, #RandomObjects - 1, 251 do
      -- As above, on the larger file's prefixes.
      local opened = pcall(nif.open, string.sub(RandomObjects, 1, length))
      if opened then error(`the first {length} bytes of random_objects.nif opened`, 0) end
    end
  end)

  suite.it('refuse a root list that runs past the end', function()
    local file = nif.new()
    file.roots = { file:insert { type = 'NiNode' } }

    local bytes = saved(file)
    local rootCount = #bytes - 8
    expect(string.sub(bytes, rootCount + 1)).toBe(u32(1) .. i32(0))

    local overlong = string.sub(bytes, 1, rootCount) .. u32(2) .. i32(0)
    expect(function() nif.open(overlong) end).toThrow 'buffer access out of bounds'
  end)
end)

suite.describe('@nif/header', function()
  suite.it(
    'parses both fixtures\' headers: a version line, a version, and a record count',
    function()
      for _, asset in Assets do
        local parsed = header.parse(buffer.fromstring(asset.bytes))
        expect(parsed).toEqual {
          versionLine = 'NetImmerse File Format, Version 4.0.0.2',
          version = 0x04000002,
          userVersion = 0,
          recordCount = if asset.name == 'all_types.nif' then 85 else 20,
          recordTypes = {},
          recordTypeIndices = {},
          recordSizes = {},
          strings = {},
          size = 48,
        }
        expect(header.game(parsed)).toBe 'Morrowind'
        expect(header.versionString(parsed.version)).toBe '4.0.0.2'
        expect(header.recordType(parsed, 0)).toBeNil()

        -- Without record sizes there is no telling where the roots are.
        expect(header.roots(parsed, buffer.fromstring(asset.bytes))).toBeNil()
        expect(header.parse(buffer.fromstring(string.sub(asset.bytes, 1, 48)))).toEqual(parsed)
      end
    end
  )

  suite.it('packs versions big end first and names the ones that matter', function()
    expect(header.version(4, 0, 0, 2)).toBe(0x04000002)
    expect(header.version(20, 2, 0, 7)).toBe(0x14020007)
    expect(header.versionString(0x14020007)).toBe '20.2.0.7'
    expect(header.versionString(0x0A000102)).toBe '10.0.1.2'
    expect(header.versions).toEqual {
      morrowind = 0x04000002,
      oblivionOld = 0x0A000102,
      oblivion = 0x14000005,
      bethesda = 0x14020007,
    }

    expect(header.bethVersions).toEqual {
      fo3 = 34,
      skyrim = 83,
      sse = 100,
      fo4 = 130,
      f76 = 155,
      starfield = 172,
    }
  end)

  suite.it('reads a Skyrim header: stream version, author, types, sizes, and strings', function()
    local bytes = buffer.fromstring(SkyrimFile)
    local parsed = header.parse(bytes)
    expect(parsed).toEqual {
      versionLine = 'Gamebryo File Format, Version 20.2.0.7',
      version = 0x14020007,
      userVersion = 12,
      bethVersion = 83,
      author = 'author',
      recordCount = 1,
      recordTypes = { 'NiNode' },
      recordTypeIndices = { 0 },
      recordSizes = { 80 },
      strings = { 'Scene Root' },
      size = 125,
    }
    expect(parsed.size).toBe(#SkyrimHeader)
    expect(header.game(parsed)).toBe 'Skyrim'
    expect(header.recordType(parsed, 0)).toBe 'NiNode'
    expect(header.recordType(parsed, 1)).toBeNil()
    expect(header.roots(parsed, bytes)).toEqual { 0 }
    expect(header.roots(parsed, buffer.fromstring(string.sub(SkyrimFile, 1, #SkyrimFile - 1)))).toBeNil()
    expect(header.roots(parsed, buffer.fromstring(SkyrimHeader .. SkyrimNode))).toBeNil()
  end)

  suite.it('reads an Oblivion header without a Bethesda stream', function()
    local parsed = header.parse(buffer.fromstring(OblivionFile))
    expect(parsed).toEqual {
      versionLine = 'Gamebryo File Format, Version 20.0.0.5',
      version = 0x14000005,
      userVersion = 0,
      recordCount = 1,
      recordTypes = { 'NiNode' },
      recordTypeIndices = { 0 },
      recordSizes = {},
      strings = {},
      size = 70,
    }
    expect(header.game(parsed)).toBe 'Oblivion'
    expect(header.roots(parsed, buffer.fromstring(OblivionFile))).toBeNil()
  end)

  suite.it(
    'reads a Fallout 76 stream header, which has a number where the process script was',
    function()
      local bytes = 'Gamebryo File Format, Version 20.2.0.7\n'
        .. u32(0x14020007)
        .. u8(1)
        .. u32(12)
        .. u32(0)
        .. u32(155)
        .. short 'me\0'
        .. u32(7)
        .. short 'export\0'
        .. short 'path\0'
        .. u16(0)
        .. u32(0)
        .. u32(0)
        .. u32(0)
      local parsed = header.parse(buffer.fromstring(bytes))
      expect(parsed.bethVersion).toBe(155)
      expect(parsed.author).toBe 'me'
      expect(parsed.size).toBe(#bytes)
      expect(header.game(parsed)).toBe 'Fallout 76'
      expect(header.roots(parsed, buffer.fromstring(bytes .. u32(0)))).toEqual {}
    end
  )

  suite.it('names the game by version and stream version', function()
    local function game(version: number, bethVersion: number?): string
      return header.game({ version = version, bethVersion = bethVersion } :: any)
    end

    local bethesda = header.versions.bethesda
    expect(game(header.versions.morrowind)).toBe 'Morrowind'
    expect(game(header.versions.oblivionOld)).toBe 'Oblivion'
    expect(game(header.version(10, 2, 0, 0))).toBe 'Oblivion'
    expect(game(header.versions.oblivion, 11)).toBe 'Oblivion'
    expect(game(bethesda, 34)).toBe 'Fallout 3/New Vegas'
    expect(game(bethesda, 82)).toBe 'Fallout 3/New Vegas'
    expect(game(bethesda, 83)).toBe 'Skyrim'
    expect(game(bethesda, 99)).toBe 'Skyrim'
    expect(game(bethesda, 100)).toBe 'Skyrim Special Edition'
    expect(game(bethesda, 129)).toBe 'Skyrim Special Edition'
    expect(game(bethesda, 130)).toBe 'Fallout 4'
    expect(game(bethesda, 154)).toBe 'Fallout 4'
    expect(game(bethesda, 155)).toBe 'Fallout 76'
    expect(game(bethesda, 171)).toBe 'Fallout 76'
    expect(game(bethesda, 172)).toBe 'Starfield'
    expect(game(bethesda)).toBe 'other'
    expect(game(header.version(3, 3, 0, 13))).toBe 'other'
    expect(game(header.version(20, 3, 0, 9), 34)).toBe 'other'
  end)

  suite.it('replaces bytes that aren\'t UTF-8, one mark per bad sequence', function()
    expect(header.lossy 'plain').toBe 'plain'
    expect(header.lossy 'caf\u{E9}').toBe 'caf\u{E9}'
    expect(header.lossy 'a\xFFb').toBe 'a\u{FFFD}b'
    expect(header.lossy 'a\xE2\x82').toBe 'a\u{FFFD}'
    expect(header.lossy '\xFF\xFE').toBe '\u{FFFD}\u{FFFD}'

    local line = 'NetImmerse File Format, \xFF\n' .. u32(0x04000002) .. u32(0)
    expect(header.parse(buffer.fromstring(line)).versionLine).toBe 'NetImmerse File Format, \u{FFFD}'
  end)

  suite.it('refuses what OpenMW refuses, by name', function()
    local function parse(bytes: string): () -> ()
      return function() header.parse(buffer.fromstring(bytes)) end
    end

    local oblivion = 'Gamebryo File Format, Version 20.0.0.5\n' .. u32(0x14000005)
    expect(parse 'junk\n').toThrow 'Invalid NIF header: junk'
    expect(parse 'TES3 and then some\nmore').toThrow 'Invalid NIF header: TES3 and then some'
    expect(parse(oblivion .. u8(0))).toThrow 'Big endian NIF files are unsupported'
    expect(
      parse(
        'Gamebryo File Format, Version 20.3.1.2\n' .. u32(0x14030102) .. u8(1) .. u32(0) .. u32(0)
      )
    ).toThrow 'Hashed record types are unsupported'
    expect(parse(oblivion .. u8(1) .. u32(0) .. u32(1) .. u16(1) .. sized '' .. u16(0) .. u32(0))).toThrow 'Record type is blank (index 0)'
    expect(
      parse(oblivion .. u8(1) .. u32(0) .. u32(1) .. u16(1) .. sized 'NiNode' .. u16(5) .. u32(0))
    ).toThrow 'Record type is blank (index 0)'
  end)

  suite.it('says where a header is cut short', function()
    local function parse(length: number): () -> ()
      return function() header.parse(buffer.fromstring(string.sub(SkyrimHeader, 1, length))) end
    end

    expect(parse(0)).toThrow 'truncated version line at offset 0'
    expect(parse(38)).toThrow 'truncated version line at offset 0'
    expect(parse(39)).toThrow 'truncated version at offset 39'
    expect(parse(44)).toThrow 'truncated user version at offset 44'
    expect(parse(60)).toThrow 'truncated author at offset 57'
    expect(parse(80)).toThrow 'truncated export script at offset 74'
    expect(parse(100)).toThrow 'truncated string count at offset 99'
    expect(parse(124)).toThrow 'truncated group count at offset 121'

    for length = 0, #SkyrimHeader - 1 do
      expect(parse(length)).toThrow 'truncated '
    end

    for length = 0, 47 do
      expect(function() header.parse(buffer.fromstring(string.sub(AllTypes, 1, length))) end).toThrow 'truncated '
    end
  end)
end)

suite.describe('@nif/gamebryo', function()
  suite.it('reads random_objects.nif as OpenMW does: every record through its class', function()
    local file = gamebryo.open(RandomObjects)
    expect(#file.records).toBe(20)
    expect(table.concat(file.names, ' ')).toBe(RandomObjectsRecords)
    expect(table.concat(file.classes, ' ')).toBe(RandomObjectsRecords)
    expect(table.concat(file.recordTypes, ' ')).toBe(RandomObjectsRecords)
    expect(file.roots).toEqual { 0 }
    expect(file.header).toEqual(header.parse(buffer.fromstring(RandomObjects)))
    expect(file.records[1]).toEqual {
      type = 'NiNode',
      name = 'random_objects.nif',
      flags = 0,
      extra = -1,
      extraList = {},
      controller = -1,
      collision = -1,
      bounds = { type = 4294967295 },
      transform = {
        translation = vector.zero,
        rotation = { vector.create(1, 0, 0), vector.create(0, 1, 0), vector.create(0, 0, 1) },
        scale = 1,
      },
      velocity = vector.zero,
      properties = {},
      children = { 1, 3, 9, 11, 12, 14, 18 },
      effects = {},
    }

    local cone = file.records[2]
    expect(cone.type).toBe 'NiTriShape'
    expect(cone.name).toBe 'Cone'
    expect(cone.flags).toBe(2)
    expect(cone.data).toBe(2)
    expect(cone.skin).toBe(-1)
    expect(cone.transform.scale).toBe(1.1419281959533691)
    expect(file.records[15].properties).toEqual { 15, 16 }
    expect(file.records[16]).toEqual {
      type = 'NiWireframeProperty',
      name = '',
      extra = -1,
      extraList = {},
      controller = -1,
      enable = true,
    }

    expect(file.records[17]).toEqual {
      type = 'NiMaterialProperty',
      name = '',
      extra = -1,
      extraList = {},
      controller = -1,
      flags = 1,
      ambient = vector.create(1, 0, 0),
      diffuse = vector.create(1, 0, 0),
      specular = vector.create(1, 0, 0),
      emissive = vector.create(1, 0, 0),
      emissiveMult = 1,
      glossiness = 0,
      alpha = 1,
    }

    local data = file.records[18]
    expect(data.type).toBe 'NiTriShapeData'
    expect(data.numVertices).toBe(8)
    expect(data.numTriangles).toBe(12)
    expect(data.vertices.count).toBe(8)
    expect(data.vertices:get(8)).toBe(vector.create(0.5, 0.5, 0.5))
    expect(data.triangles.count).toBe(36)
    expect(data.triangles:toTable()[3]).toBe(1)
    expect(data.normals.count).toBe(0)
    expect(data.uvList).toEqual {}
    expect(data.boundingSphere).toEqual { center = vector.zero, radius = 0.8660253882408142 }
  end)

  suite.it('takes a buffer as it takes a string', function()
    local file = gamebryo.open(buffer.fromstring(RandomObjects))
    expect(#file.records).toBe(20)
    expect(file.records[5].name).toBe 'Cube'
  end)

  suite.it('refuses all_types.nif at the record type OpenMW has no reader for', function()
    local message, record = support.thrown(function() gamebryo.open(AllTypes) end)
    expect(message).toBe 'Unknown record type NiBltSource'
    expect(record).toBe(1)
  end)

  suite.it('reads each record type the model builds bare, or refuses it by name', function()
    local unknown, refused, read = {}, {}, 0
    for _, name in nif.recordTypes do
      local file = nif.new()
      file.roots = { file:insert { type = name } }

      local message = support.thrown(function()
        local opened = gamebryo.open(file:save())
        expect(#opened.records).toBe(1)
        expect(opened.names).toEqual { name }

        -- A record's `type` is its name, unless its class has a field called that: a gravity's
        -- is its force type.
        expect(opened.records[1].type).toBe(if name == 'NiGravity' then 0 else name)
        expect(opened.roots).toEqual { 0 }
      end)

      if not message then
        read += 1
      elseif message == `Unknown record type {name}` then
        table.insert(unknown, name)
      else
        table.insert(refused, `{name}: {message}`)
      end
    end

    -- The model's abstract bases, and the types OpenMW's factory has no reader for.
    expect(read).toBe(79)
    expect(table.concat(unknown, ' ')).toBe(
      'NiObject NiObjectNET NiAVObject BSMirroredNode NiBSAnimationManager NiBSPNode'
        .. ' NiDynamicEffect NiLight NiGeometry NiTriBasedGeom NiGeometryData NiTriBasedGeomData'
        .. ' NiTriShapeDynamicData NiTexture NiRenderedTexture NiRenderedCubeMap NiBltSource'
        .. ' NiProperty BrickNiExtraData TES3ObjectExtraData NiTimeController NiFloatController'
        .. ' NiMorpherController NiKeyframeManager NiParticleModifier NiParticleCollider'
        .. ' NiEmitterModifier NiRotData NiScreenPolygon NiAccumulator NiRenderer NiDX8Renderer'
    )
    expect(refused).toEqual { 'NiSkinInstance: NiSkinInstance missing root or data' }
  end)

  suite.it('reads what the model builds', function()
    local file = gamebryo.open(Scenarios['shape']())
    expect(table.concat(file.names, ' ')).toBe 'NiNode NiTriShapeData NiSourceTexture NiTexturingProperty NiMaterialProperty NiTriShape'
    expect(file.roots).toEqual { 0 }
    expect(file.records[1].children).toEqual { 5 }
    expect(file.records[6].name).toBe 'Tri Shape'
    expect(file.records[6].data).toBe(1)
    expect(file.records[6].properties).toEqual { 3, 4 }
    expect(file.records[2].numVertices).toBe(5)
    expect(file.records[5].alpha).toBe(0.5)
  end)

  suite.it('reads an Oblivion node and a Skyrim node to the same record', function()
    local oblivion = gamebryo.open(OblivionFile)
    expect(oblivion.records).toEqual { SceneRoot }
    expect(oblivion.names).toEqual { 'NiNode' }
    expect(oblivion.classes).toEqual { 'NiNode' }
    expect(oblivion.recordTypes).toEqual { 'NiNode' }
    expect(oblivion.roots).toEqual { 0 }
    expect(oblivion.header.version).toBe(header.versions.oblivion)

    local skyrim = gamebryo.open(SkyrimFile)
    expect(skyrim.records).toEqual { SceneRoot }
    expect(skyrim.names).toEqual { 'NiNode' }
    expect(skyrim.roots).toEqual { 0 }
    expect(skyrim.header.bethVersion).toBe(83)

    -- The Morrowind model is for 4.0.0.2 alone.
    expect(function() nif.open(SkyrimFile) end).toThrow 'Invalid NIF Header'
    expect(function() nif.open(OblivionFile) end).toThrow 'Invalid NIF Header'
  end)

  suite.it('refuses a record type it doesn\'t know, and a blank one', function()
    local unknown = string.sub(RandomObjects, 1, 52) .. 'XiNode' .. string.sub(RandomObjects, 59)
    local message, record = support.thrown(function() gamebryo.open(unknown) end)
    expect(message).toBe 'Unknown record type XiNode'
    expect(record).toBe(0)

    local blank = string.sub(RandomObjects, 1, 48) .. u32(0) .. string.sub(RandomObjects, 59)
    message, record = support.thrown(function() gamebryo.open(blank) end)
    expect(message).toBe 'Record type is blank (index 0)'
    expect(record).toBe(0)
  end)

  suite.it('refuses a link to a record of the wrong class', function()
    local file = nif.new()
    local root = file:insert { type = 'NiNode', name = 'Root' }
    file:attach(root, file:insert { type = 'NiTriShapeData' })
    file.roots = { root }

    local message, record = support.thrown(function() gamebryo.open(file:save()) end)
    expect(message).toBe 'Failed to cast record pointer to NiAVObject: record 1 is a NiTriShapeData'
    expect(record).toBe(0)
  end)

  suite.it('refuses a link past the last record, which the model saves as no link', function()
    local file = nif.new()
    local root = file:insert { type = 'NiNode', name = 'Root' }
    file:attach(root, file:insert { type = 'NiNode', name = 'Child' })
    file.roots = { root }

    -- The root's one child link is the four bytes before its empty effect list.
    local bytes = saved(file)
    local linkAt = nif.open(bytes).starts[2] - 8
    expect(string.sub(bytes, linkAt + 1, linkAt + 4)).toBe(i32(1))
    expect(gamebryo.open(bytes).records[1].children).toEqual { 1 }

    local patched = string.sub(bytes, 1, linkAt) .. i32(99) .. string.sub(bytes, linkAt + 5)
    local message, record = support.thrown(function() gamebryo.open(patched) end)
    expect(message).toBe 'NiNode links to record 99, past the 2 records'
    expect(record).toBe(0)

    local model = nif.open(patched)
    expect(model:reachableCount()).toBe(1)

    local resaved = nif.open(model:save())
    expect(resaved.count).toBe(1)
    expect((resaved:record(0) :: any).children:toTable()).toEqual { -1 }
    expect(gamebryo.open(model:save()).records[1].children).toEqual { -1 }
  end)

  suite.it('refuses a file cut short', function()
    local message, record = support.thrown(
      function() gamebryo.open(string.sub(RandomObjects, 1, 1000)) end
    )
    expect(message).toBe 'Trying to read more than stream size: 1536 max=1000'
    expect(record).toBe(2)
    expect(support.thrown(function() gamebryo.open '' end)).toBe 'truncated version line at offset 0'

    for length = 0, #RandomObjects - 1, 1009 do
      if not support.thrown(function() gamebryo.open(string.sub(RandomObjects, 1, length)) end) then
        error(`the first {length} bytes of random_objects.nif were read`, 0)
      end
    end
  end)

  for _, asset in Assets do
    suite.it(`gives jess-nif's answer for {asset.name}`, function()
      local observed = support.digest(support.attempt(function(): unknown
        local file = gamebryo.open(buffer.fromstring(asset.bytes))
        return {
          records = file.records,
          names = file.names,
          classes = file.classes,
          recordTypes = file.recordTypes,
          roots = file.roots,
        }
      end))
      expect(observed).toBe(Golden[`fixture/{asset.name}/gamebryo`])
    end)
  end
end)

suite.describe('@nif/scene', function()
  suite.it(
    'builds random_objects.nif: 11 nodes, 8 drawables over 7 geometries, 2 materials',
    function()
      local file = nif.open(RandomObjects)
      local built = scene.build(file)
      expect(scene.dump(built)).toBe(support.goldenText 'random_objects.scene.txt')
      expect(#built.nodes).toBe(11)
      expect(#built.drawables).toBe(8)
      expect(#built.geometries).toBe(7)
      expect(#built.materials).toBe(2)
      expect(built.textures).toEqual {}
      expect(built.skins).toEqual {}
      expect(built.skinBones).toEqual {}
      expect(built.issues).toEqual {}

      local root = built.nodes[1]
      expect(root.source).toBe(0)
      expect(root.name).toBe 'random_objects.nif'
      expect(root.parent).toBeNil()
      expect(root.subtreeEnd).toBe(11)

      local cone = built.nodes[2]
      expect(cone.source).toBe(1)
      expect(cone.recordType).toBe 'NiTriShape'
      expect(cone.name).toBe 'Cone'
      expect(cone.parent).toBe(0)
      expect(cone.subtreeEnd).toBe(2)
      expect(cone.billboard).toBe(false)
      expect(cone.visibility).toBe 'Visible'
      expect(cone['local'][4]).toBe(
        vector.create(-276.1847839355469, -88.8243179321289, 127.00479125976562)
      )
      expect(cone.world).toEqual(cone['local'])

      -- `Empty 1` holds `Cube` and `Empty 2`, which holds `Sphere`.
      expect(built.nodes[3].subtreeEnd).toBe(6)
      expect(built.nodes[5].parent).toBe(2)
      expect(built.nodes[6].parent).toBe(4)
      expect(built.nodes[6].name).toBe 'Sphere'

      -- `Suzanne1` and `Suzanne2` share one data record, so one geometry.
      expect(built.drawables[4]).toEqual { node = 6, geometry = 3, material = 0, layer = 'Opaque' }
      expect(built.drawables[5]).toEqual { node = 7, geometry = 3, material = 0, layer = 'Opaque' }
      expect(built.drawables[8]).toEqual { node = 10, geometry = 6, material = 1, layer = 'Opaque' }
      expect(built.geometries[1]).toEqual {
        source = 2,
        recordType = 'NiTriShapeData',
        vertices = { 0, 128 },
        indices = { 0, 186 },
        firstUv = 0,
        uvSets = 1,
        hasNormals = true,
        hasColors = false,
        bound = { center = vector.zero, radius = 141.42135620117188 },
      }
      expect(built.geometries[6].vertices).toEqual { 6505, 6513 }
      expect(built.geometries[6].uvSets).toBe(0)
      expect(built.geometries[6].hasNormals).toBe(false)

      local wire = built.materials[2]
      expect(wire.sources).toEqual { material = 16, wireframe = 15 }
      expect(wire.wireframe).toBe(true)
      expect(wire.ambient).toBe(vector.create(1, 0, 0))
      expect(wire.emissive).toBe(vector.create(1, 0, 0))
      expect(wire.specular).toBe(vector.zero)
      expect(wire.storedSpecular).toEqual {
        color = vector.create(1, 0, 0),
        glossiness = 0,
        enabled = true,
      }
      expect(wire.depth).toEqual { test = true, write = true }
      expect(wire.cull).toBe 'Back'
      expect(built.materials[1].sources).toEqual {}
      expect(built.materials[1].wireframe).toBe(false)
    end
  )

  suite.it('packs geometry into buffers sized by what the shapes hold', function()
    local buffers = scene.build(nif.open(RandomObjects)).buffers

    -- 128 + 24 + 1984 + 2065 + 2304 + 8 + 240 vertices, three indices for each of 3246
    -- triangles, and a UV for every vertex but the last two geometries'.
    expect(buffers.vertexCount).toBe(6753)
    expect(buffers.indexCount).toBe(9738)
    expect(buffers.uvCount).toBe(6505)
    expect(buffers.weightCount).toBe(0)
    expect(buffer.len(buffers.positions)).toBe(6753 * 12)
    expect(buffer.len(buffers.normals)).toBe(6753 * 12)
    expect(buffer.len(buffers.colors)).toBe(6753 * 16)
    expect(buffer.len(buffers.uvs)).toBe(6505 * 8)
    expect(buffer.len(buffers.indices)).toBe(9738 * 2)
    expect(buffer.len(buffers.skinVertices)).toBe(0)
    expect(buffer.len(buffers.skinWeights)).toBe(0)

    -- The cone's first vertex, and the unit cube's first triangle.
    expect(buffer.readf32(buffers.positions, 0)).toBe(0)
    expect(buffer.readf32(buffers.positions, 4)).toBe(100)
    expect(buffer.readf32(buffers.positions, 8)).toBe(-100)
    expect(buffer.readf32(buffers.positions, 6505 * 12)).toBe(-0.5)

    local cubeIndices = (9738 - 240 - 36) * 2
    expect(buffer.readu16(buffers.indices, cubeIndices)).toBe(0)
    expect(buffer.readu16(buffers.indices, cubeIndices + 2)).toBe(2)
    expect(buffer.readu16(buffers.indices, cubeIndices + 4)).toBe(1)
  end)

  suite.it('builds all_types.nif, listing what it doesn\'t translate', function()
    local built = scene.build(nif.open(AllTypes))
    expect(scene.dump(built)).toBe(support.goldenText 'all_types.scene.txt')
    expect(#built.nodes).toBe(27)
    expect(#built.drawables).toBe(2)
    expect(#built.geometries).toBe(2)
    expect(#built.materials).toBe(1)
    expect(built.nodes[13].recordType).toBe 'NiBillboardNode'
    expect(built.nodes[13].billboard).toBe(true)
    expect(built.nodes[18].recordType).toBe 'RootCollisionNode'
    expect(built.nodes[18].visibility).toBe 'Collision'
    expect(built.nodes[7].name).toBe 'Scene Root'
    expect(built.nodes[7].subtreeEnd).toBe(26)
    expect(built.geometries[1].recordType).toBe 'NiTriShapeDynamicData'
    expect(built.buffers.vertexCount).toBe(8)
    expect(built.buffers.indexCount).toBe(12)

    local kinds: { [string]: number } = {}
    for _, issue in built.issues do
      kinds[issue.kind] = (kinds[issue.kind] or 0) + 1
    end

    expect(kinds).toEqual {
      NotSceneObject = 15,
      Effect = 5,
      Controller = 14,
      UnsupportedNode = 3,
      UnsupportedGeometry = 4,
      EmptyGeometry = 1,
    }

    expect(built.issues[1]).toEqual {
      source = 1,
      recordType = 'NiBltSource',
      kind = 'NotSceneObject',
    }
    expect(scene.issueText(built.issues[1])).toBe 'root isn\'t a scene object'
    expect(scene.issueText(built.issues[10])).toBe 'dynamic effect not translated'
  end)

  suite.it('gives a built shape its texture and material, and marks what OpenMW hides', function()
    local built = scene.build(nif.open(Scenarios['shape']()))
    expect(#built.nodes).toBe(2)
    expect(built.textures).toEqual {
      { source = 2, kind = 'external', path = 'textures\\tx_a.dds' },
    }

    expect(built.drawables).toEqual {
      { node = 1, geometry = 0, material = 0, layer = 'Opaque' },
    }

    local material = built.materials[1]
    expect(material.sources).toEqual { texturing = 3, material = 4 }
    expect(material.baseTexture).toEqual {
      texture = 0,
      uvSet = 0,
      clamp = 'WrapSWrapT',
      filter = 'Trilerp',
    }
    expect(material.alpha).toBe(0.5)
    expect(built.geometries[1].uvSets).toBe(2)
    expect(built.geometries[1].hasColors).toBe(true)
    expect(built.buffers.uvCount).toBe(10)

    -- The shape's transform: twice a quarter turn about z, at (1, 2, 3).
    expect(built.nodes[2].world).toEqual {
      vector.create(0, 2, 0),
      vector.create(-2, 0, 0),
      vector.create(0, 0, 2),
      vector.create(1, 2, 3),
    }

    -- Until `fix` adds the root's "RCN" and "MRK" string data, OpenMW draws both.
    local file = defects()
    local drawn = scene.build(file)
    expect(drawn.nodes[3].recordType).toBe 'RootCollisionNode'
    expect(drawn.nodes[3].visibility).toBe 'Visible'
    expect(drawn.nodes[4].name).toBe 'Tri EditorMarker 0'
    expect(drawn.nodes[4].visibility).toBe 'Visible'

    fix.fix(file)

    local hidden = scene.build(file)
    expect(hidden.nodes[3].visibility).toBe 'Collision'
    expect(hidden.nodes[4].visibility).toBe 'EditorMarker'
  end)

  suite.it('reads a skin: its bones, bind transforms, and weights', function()
    -- As built, the bone weights a vertex the shape doesn't have, so the skin is left off.
    local file = nif.open(skinned())
    local unfit = scene.build(file)
    expect(unfit.drawables).toEqual { { node = 2, geometry = 0, material = 0, layer = 'Opaque' } }
    expect(unfit.skins).toEqual {}
    expect(unfit.issues).toEqual {
      { source = 3, recordType = 'NiSkinInstance', kind = 'SkinMismatch' },
    }

    fix.fix(file)

    local built = scene.build(file)
    expect(built.issues).toEqual {}
    expect(built.drawables).toEqual {
      { node = 2, geometry = 0, material = 0, skin = 0, layer = 'Opaque' },
    }

    local identity = {
      vector.create(1, 0, 0),
      vector.create(0, 1, 0),
      vector.create(0, 0, 1),
      vector.zero,
    }

    expect(built.skins).toEqual {
      { source = 3, data = 2, root = 0, transform = identity, bones = { 0, 1 } },
    }

    expect(built.skinBones).toEqual {
      {
        source = 1,
        node = 1,
        bind = identity,
        bound = { center = vector.zero, radius = 0 },
        weights = { 0, 2 },
      },
    }

    expect(built.buffers.weightCount).toBe(2)
    expect(buffer.len(built.buffers.skinVertices)).toBe(4)
    expect(buffer.len(built.buffers.skinWeights)).toBe(8)
    expect(buffer.readu16(built.buffers.skinVertices, 2)).toBe(2)
    expect(buffer.readf32(built.buffers.skinWeights, 4)).toBe(0.5)
  end)

  suite.it('words issues as jess-nif\'s dump does, and dumps an empty scene', function()
    local function text(issue: { [string]: unknown }): string return scene.issueText(issue :: any) end

    expect(text { kind = 'MissingLink', field = 'geometry_data', target = 9 }).toBe 'geometry_data links missing record 9'
    expect(text { kind = 'WrongLinkType', field = 'skin', found = 'NiNode' }).toBe 'skin links a NiNode'
    expect(text { kind = 'TextureSlot', slot = 'gloss' }).toBe 'gloss texture not translated'
    expect(text { kind = 'Cycle' }).toBe 'cycle: the node is its own ancestor'
    expect(text { kind = 'Mystery' }).toBe 'Mystery'
    expect(scene.maxSceneNodes).toBe(1048576)

    local empty = scene.build(nif.new())
    expect(empty.nodes).toEqual {}
    expect(empty.buffers.vertexCount).toBe(0)
    expect(scene.dump(empty)).toBe 'nodes:\ndrawables:\ngeometries:\nmaterials:\ntextures:\nskins:\nissues:\n'
  end)

  suite.it('reports a link to a record that isn\'t there and one of the wrong type', function()
    local file = nif.new()
    local root = file:insert { type = 'NiNode', name = 'Root' }
    file:attach(root, file:insert { type = 'NiTriShape', name = 'No data', geometryData = 40 })
    file:attach(root, file:insert { type = 'NiTriShape', name = 'Wrong data', geometryData = root })
    file.roots = { root }

    local built = scene.build(file)
    expect(#built.nodes).toBe(3)
    expect(built.drawables).toEqual {}
    expect(built.issues).toEqual {
      {
        source = 1,
        recordType = 'NiTriShape',
        kind = 'MissingLink',
        field = 'geometry_data',
        target = 40,
      },
      {
        source = 2,
        recordType = 'NiTriShape',
        kind = 'WrongLinkType',
        field = 'geometry_data',
        found = 'NiNode',
      },
    }
  end)

  for _, asset in Assets do
    suite.it(`gives jess-nif's answer for {asset.name}, and leaves its save alone`, function()
      local file = nif.open(buffer.fromstring(asset.bytes))
      local observed =
        support.digest(support.attempt(function(): unknown return scene.build(file) end))
      expect(observed).toBe(Golden[`fixture/{asset.name}/scene`])
      expect(difference(saved(file), asset.bytes)).toBeNil()
    end)
  end
end)

suite.describe('@nif/info', function()
  suite.it('counts record types', function()
    expect(info.recordTypeCounts(nif.open(RandomObjects))).toEqual {
      NiNode = 3,
      NiTriShape = 8,
      NiTriShapeData = 7,
      NiWireframeProperty = 1,
      NiMaterialProperty = 1,
    }

    local counts = info.recordTypeCounts(nif.open(AllTypes))
    local types, total = 0, 0
    for _, count in counts do
      types += 1
      total += count
    end

    expect(types).toBe(78)
    expect(total).toBe(85)
    expect(counts.NiNode).toBe(3)
    expect(counts.NiParticleSystemController).toBe(3)
    expect(counts.NiScreenPolygon).toBe(2)
    expect(counts.NiSourceTexture).toBe(2)
    expect(counts.NiTriShape).toBe(2)
    expect(counts.NiBltSource).toBe(1)
    expect(info.recordTypeCounts(nif.new())).toEqual {}
  end)

  suite.it('lays out random_objects.nif as a tree of nodes and shapes', function()
    local function shape(
      index: number,
      name: string,
      data: number,
      vertices: number,
      triangles: number
    )
      return {
        index = index,
        type = 'NiTriShape',
        name = name,
        shape = {
          data = { index = data, type = 'NiTriShapeData' },
          vertices = vertices,
          triangles = triangles,
        },
      }
    end

    local properties = {
      { index = 15, type = 'NiWireframeProperty' },
      { index = 16, type = 'NiMaterialProperty' },
    }

    local unitCube = shape(14, 'unitCube', 17, 8, 12) :: any
    unitCube.properties = properties

    local unitSphere = shape(18, 'unitSphere', 19, 240, 80) :: any
    unitSphere.properties = properties

    expect(info.sceneTree(nif.open(RandomObjects))).toEqual {
      {
        index = 0,
        type = 'NiNode',
        name = 'random_objects.nif',
        children = {
          shape(1, 'Cone', 2, 128, 62),
          {
            index = 3,
            type = 'NiNode',
            name = 'Empty 1',
            children = {
              shape(4, 'Cube', 5, 24, 12),
              {
                index = 6,
                type = 'NiNode',
                name = 'Empty 2',
                children = { shape(7, 'Sphere', 8, 1984, 960) },
              },
            },
          },
          shape(9, 'Suzanne1', 10, 2065, 968),
          shape(11, 'Suzanne2', 10, 2065, 968),
          shape(12, 'Torus', 13, 2304, 1152),
          unitCube,
          unitSphere,
        },
      },
    }
  end)

  suite.it('lists all_types.nif\'s 23 roots with controllers, extra data, and geometry', function()
    local tree = info.sceneTree(nif.open(AllTypes))
    expect(#tree).toBe(23)
    expect(tree[1]).toEqual { index = 0, type = 'NiNode', name = '' }
    expect(tree[2]).toEqual { index = 1, type = 'NiBltSource', name = '' }
    expect(tree[17]).toEqual { index = 16, type = 'NiSequenceStreamHelper', name = '' }
    expect(tree[23]).toEqual { index = 84, type = 'NiNode', name = '' }

    local root = tree[19]
    expect(root.index).toBe(18)
    expect(root.name).toBe 'Scene Root'
    expect(root.hidden).toBeNil()
    expect(root.controllers).toEqual {
      { index = 25, type = 'NiFlipController', active = false },
      { index = 26, type = 'NiKeyframeController', active = false },
      { index = 27, type = 'NiAlphaController', active = false },
      { index = 28, type = 'NiRollController', active = false },
      { index = 29, type = 'NiLightColorController', active = false },
      { index = 30, type = 'NiLookAtController', active = false },
      { index = 31, type = 'NiMaterialColorController', active = false },
    }

    expect(root.extraData).toEqual {
      { index = 19, type = 'NiExtraData' },
      { index = 20, type = 'NiStringExtraData', value = 'Hello World' },
      { index = 21, type = 'NiTextKeyExtraData' },
      { index = 22, type = 'NiVertWeightsExtraData' },
      { index = 23, type = 'BrickNiExtraData' },
      { index = 24, type = 'TES3ObjectExtraData' },
    }

    local children = root.children :: { info.TreeNode }
    expect(#children).toBe(19)
    expect(children[1]).toEqual { index = 33, type = 'NiCamera', name = '' }
    expect(children[14]).toEqual {
      index = 54,
      type = 'NiTriShape',
      name = 'dynamic',
      controllers = {
        { index = 55, type = 'NiPathController', active = false },
        { index = 56, type = 'NiUVController', active = false },
        { index = 57, type = 'NiVisController', active = false },
      },
      shape = { data = { index = 60, type = 'NiTriShapeDynamicData' }, vertices = 4, triangles = 2 },
    }

    expect(children[15].shape).toEqual {
      data = { index = 62, type = 'NiLinesData' },
      vertices = 4,
      triangles = 0,
    }

    expect(children[19]).toEqual {
      index = 77,
      type = 'NiTriStrips',
      name = 'strips',
      shape = { data = { index = 78, type = 'NiTriStripsData' }, vertices = 4, triangles = 6 },
    }
  end)

  suite.it('shows a shape\'s skin, hidden nodes, and string data', function()
    local tree = info.sceneTree(nif.open(skinned()))
    expect((tree[1].children :: { info.TreeNode })[2]).toEqual {
      index = 5,
      type = 'NiTriShape',
      name = 'Skinned',
      shape = {
        data = { index = 4, type = 'NiTriShapeData' },
        vertices = 3,
        triangles = 1,
        skin = 3,
      },
    }

    local file = defects()
    local inner = file:record(2) :: any
    inner.flags = 1
    tree = info.sceneTree(file)
    expect(tree[1].extraData).toEqual { { index = 1, type = 'NiStringExtraData', value = 'NCc' } }
    expect((tree[1].children :: { info.TreeNode })[1].hidden).toBe(true)
  end)

  suite.it('reads the same counts and tree from the multi-version reader\'s records', function()
    local file = gamebryo.open(RandomObjects)
    local model = nif.open(RandomObjects)
    expect(info.fileTypeCounts(file)).toEqual(info.recordTypeCounts(model))
    expect(info.fileSceneTree(file)).toEqual(info.sceneTree(model))

    local skyrim = gamebryo.open(SkyrimFile)
    expect(info.fileTypeCounts(skyrim)).toEqual { NiNode = 1 }
    expect(info.fileSceneTree(skyrim)).toEqual { { index = 0, type = 'NiNode', name = 'Scene Root' } }
  end)

  suite.it('stops a tree at its depth limit', function()
    expect(info.maxTreeDepth).toBe(256)

    local file = nif.new()
    local parent = file:insert { type = 'NiNode', name = 'level 1' }
    file.roots = { parent }
    for level = 2, 300 do
      local child = file:insert { type = 'NiNode', name = `level {level}` }
      file:attach(parent, child)
      parent = child
    end

    local node, depth = info.sceneTree(file)[1], 1
    while node.children do
      node, depth = node.children[1], depth + 1
    end

    expect(depth).toBe(257)
    expect(node).toEqual { index = 256, type = 'NiNode', name = '' }
  end)

  for _, asset in Assets do
    suite.it(`gives jess-nif's answer for {asset.name}, and leaves its save alone`, function()
      local file = nif.open(buffer.fromstring(asset.bytes))
      local observed = support.digest(
        support.attempt(
          function(): unknown
            return { counts = info.recordTypeCounts(file), tree = info.sceneTree(file) }
          end
        )
      )
      expect(observed).toBe(Golden[`fixture/{asset.name}/info`])
      expect(difference(saved(file), asset.bytes)).toBeNil()
    end)
  end
end)

suite.describe('@nif/check', function()
  suite.it('finds nothing wrong with random_objects.nif and counts what it draws', function()
    local report = check.check('meshes/random_objects.nif', RandomObjects)
    expect(report.header).toEqual(header.parse(buffer.fromstring(RandomObjects)))
    expect(report.deep).toBe(true)
    expect(report.findings).toEqual {}
    expect(report.textures).toEqual {}

    -- Eight shapes over seven data records: the vertices and triangles count what is drawn.
    expect(report.stats).toEqual(stats {
      records = 20,
      reachableRecords = 20,
      nodes = 3,
      shapes = 8,
      vertices = 8818,
      triangles = 4214,
      collisionTriangles = 4214,
    })
    expect(report.collision).toEqual { source = 'render_geometry', hidesMarkers = false }
    expect(check.check('meshes/random_objects.nif', buffer.fromstring(RandomObjects))).toEqual(
      report
    )
  end)

  suite.it('says OpenMW won\'t load all_types.nif, and why', function()
    local report = check.check('all_types.nif', AllTypes)
    expect((report.header :: header.Header).recordCount).toBe(85)
    expect(report.deep).toBe(false)
    expect(report.stats).toBeNil()
    expect(report.collision).toBeNil()
    expect(report.textures).toEqual {}
    expect(report.findings).toEqual {
      {
        severity = 'wont_load',
        code = 'unknown_record_type',
        message = 'Unknown record type NiBltSource',
        record = 1,
      },
    }
  end)

  suite.it(
    'checks a .kf as an animation',
    function()
      expect(check.check('random_objects.kf', RandomObjects).findings).toEqual {
        {
          severity = 'broken',
          code = 'kf_without_sequence',
          message = 'Found no NiSequenceStreamHelper root record, so no animation loads',
        },
      }
    end
  )

  suite.it('reports a header it can\'t read, and nothing else', function()
    expect(check.check('empty.nif', '')).toEqual {
      deep = false,
      textures = {},
      findings = {
        {
          severity = 'wont_load',
          code = 'invalid_header',
          message = 'truncated version line at offset 0',
        },
      },
    }

    expect(check.check('junk.nif', 'junk\nmore').findings).toEqual {
      { severity = 'wont_load', code = 'invalid_header', message = 'Invalid NIF header: junk' },
    }
  end)

  suite.it('reports why the reader refuses a file', function()
    expect(findings('cut.nif', string.sub(RandomObjects, 1, 1000))).toEqual {
      deep = false,
      textures = {},
      findings = {
        {
          severity = 'wont_load',
          code = 'unreadable_record',
          message = 'Trying to read more than stream size: 1536 max=1000',
          record = 2,
        },
      },
    }

    local wrong = nif.new()
    local root = wrong:insert { type = 'NiNode', name = 'Root' }
    wrong:attach(root, wrong:insert { type = 'NiTriShapeData' })
    wrong.roots = { root }
    expect(findings('wrong.nif', wrong:save()).findings).toEqual {
      {
        severity = 'wont_load',
        code = 'wrong_link_type',
        message = 'Failed to cast record pointer to NiAVObject: record 1 is a NiTriShapeData',
        record = 0,
      },
    }

    expect(findings('empty.nif', nif.new():save()).findings).toEqual {
      { severity = 'wont_load', code = 'no_root_nodes', message = 'Found no root nodes' },
    }
  end)

  suite.it('finds a nested collision node, a visible editor marker, and a lowercase NCC', function()
    local report = findings('defects.nif', defects():save())
    expect(report.deep).toBe(true)
    expect(report.findings).toEqual {
      {
        severity = 'broken',
        code = 'visible_editor_marker',
        message = '"Tri EditorMarker 0" draws in game because the root has no "MRK" string data',
        record = 5,
      },
      {
        severity = 'collision',
        code = 'lowercase_ncc',
        message = '"NCc" turns collision off entirely; only an uppercase "NCC" keeps camera collision',
        record = 1,
      },
    }

    local nested = nif.new()
    local root = nested:insert { type = 'NiNode', name = 'Root' }
    local inner = nested:insert { type = 'NiNode', name = 'Inner' }
    nested:attach(root, inner)
    nested:attach(inner, nested:insert { type = 'RootCollisionNode', name = 'RootCollisionNode' })
    nested.roots = { root }
    report = findings('nested.nif', nested:save())
    expect(report.collision).toEqual { source = 'render_geometry', hidesMarkers = false }
    expect(report.findings).toEqual {
      {
        severity = 'broken',
        code = 'stray_root_collision_node',
        message = 'OpenMW doesn\'t find this RootCollisionNode, since it isn\'t a child of the root and the root has no "RCN" string data, so it draws and the render geometry collides too',
        record = 2,
      },
    }
  end)

  suite.it('finds skin weights past the shape\'s vertices and records no root reaches', function()
    local report = findings('skinned.nif', skinned())
    expect(report.findings).toEqual {
      {
        severity = 'wont_load',
        code = 'skin_weight_out_of_range',
        message = 'the skin weights vertex 7, but the shape has 3 vertices',
        record = 5,
      },
    }

    expect(report.stats).toEqual(stats {
      records = 6,
      reachableRecords = 6,
      nodes = 2,
      shapes = 1,
      vertices = 3,
      triangles = 1,
      collisionTriangles = 1,
      skinned = true,
    })

    report = findings('stray.nif', (unreachable()))
    expect(report.findings).toEqual {
      {
        severity = 'performance',
        code = 'unreachable_records',
        message = '1 record isn\'t reachable from any root and is loaded for nothing',
      },
    }
    expect(report.stats).toEqual(stats { records = 2, reachableRecords = 1, nodes = 1 })
  end)

  suite.it('lists the textures a file names, as it spells them', function()
    local report = findings('shape.nif', Scenarios['shape']())
    expect(report.textures).toEqual { 'textures\\tx_a.dds' }
    expect((report.stats :: check.Stats).shapes).toBe(1)
    expect((report.stats :: check.Stats).vertices).toBe(5)
    expect((report.stats :: check.Stats).triangles).toBe(3)
  end)

  suite.it('checks later versions through their headers and the multi-version reader', function()
    local report = findings('skyrim.nif', SkyrimFile)
    expect(report).toEqual {
      deep = true,
      textures = {},
      collision = { source = 'none', hidesMarkers = false },
      stats = stats { records = 1, reachableRecords = 1, nodes = 1 },
      findings = {
        {
          severity = 'info',
          code = 'root_transform_ignored',
          message = 'the root node "Scene Root" has a transform, which OpenMW ignores like Morrowind does',
          record = 0,
        },
      },
    }

    local unknown = string.gsub(SkyrimFile, 'NiNode', 'XiNode', 1)
    expect(findings('unknown.nif', unknown)).toEqual {
      deep = false,
      textures = {},
      findings = {
        {
          severity = 'wont_load',
          code = 'unknown_record_type',
          message = 'Unknown record type XiNode',
          record = 0,
        },
      },
    }

    local badRoot = SkyrimHeader .. SkyrimNode .. u32(1) .. i32(5)
    expect(findings('root.nif', badRoot).findings).toEqual {
      { severity = 'wont_load', code = 'no_root_nodes', message = 'Found no root nodes' },
      {
        severity = 'broken',
        code = 'root_out_of_range',
        message = 'Root 0 does not point to a record: index 5',
      },
      -- Record 0's transform is discarded whether or not a root reaches it.
      {
        severity = 'info',
        code = 'root_transform_ignored',
        message = 'the root node "Scene Root" has a transform, which OpenMW ignores like Morrowind does',
        record = 0,
      },
    }

    -- A Morrowind file has no record sizes to find its roots by, so they're checked once read.
    local plain = nif.new()
    plain.roots = { plain:insert { type = 'NiNode', name = 'Root' } }

    local bytes = saved(plain)
    expect(findings('root.nif', string.sub(bytes, 1, #bytes - 4) .. i32(5)).findings).toEqual {
      { severity = 'wont_load', code = 'no_root_nodes', message = 'Found no root nodes' },
      {
        severity = 'broken',
        code = 'root_out_of_range',
        message = 'Root 0 does not point to a record, so it\'s skipped',
      },
      {
        severity = 'performance',
        code = 'unreachable_records',
        message = '1 record isn\'t reachable from any root and is loaded for nothing',
      },
    }

    -- The node's size is the `u32` at offset 95; eight bytes more puts the roots past the end.
    expect(string.sub(SkyrimFile, 96, 99)).toBe(u32(#SkyrimNode))

    local missized = string.sub(SkyrimFile, 1, 95)
      .. u32(#SkyrimNode + 8)
      .. string.sub(SkyrimFile, 100)
    expect(findings('sizes.nif', missized).findings).toEqual {
      {
        severity = 'info',
        code = 'record_sizes_mismatch',
        message = 'the header\'s record sizes don\'t add up to the file; OpenMW doesn\'t use them, but the roots can\'t be checked',
      },
      {
        severity = 'info',
        code = 'root_transform_ignored',
        message = 'the root node "Scene Root" has a transform, which OpenMW ignores like Morrowind does',
        record = 0,
      },
    }

    -- A root list cut short is the reader's to refuse; its wording isn't pinned.
    local cut = findings('cut.nif', string.sub(SkyrimFile, 1, #SkyrimFile - 1))
    expect(cut.deep).toBe(false)
    expect(cut.findings[1].severity).toBe 'wont_load'
    expect(cut.findings[1].code).toBe 'unreadable_record'
  end)

  for _, asset in Assets do
    suite.it(`gives jess-nif's answer for {asset.name}`, function()
      local observed = support.digest(
        support.attempt(
          function(): unknown return check.check(asset.name, buffer.fromstring(asset.bytes)) end
        )
      )
      expect(observed).toBe(Golden[`fixture/{asset.name}/check`])
    end)
  end
end)

suite.describe('@nif/fix', function()
  suite.it('lists its kinds in the order they apply', function()
    expect(fix.kinds).toEqual { 'rcn', 'ncc', 'markers', 'skinWeights', 'unreachable' }
    expect(table.isfrozen(fix.kinds)).toBe(true)
  end)

  for _, asset in Assets do
    suite.it(`finds nothing to fix in {asset.name}, and gives jess-nif's answer`, function()
      local file = nif.open(buffer.fromstring(asset.bytes))
      local fixed = fix.fix(file)
      expect(fixed).toEqual {}
      expect(difference(saved(file), asset.bytes)).toBeNil()
      expect(support.digest { fixed = fixed, saved = file:save() }).toBe(
        Golden[`fixture/{asset.name}/fix`]
      )
    end)
  end

  suite.it('repairs a nested collision node, an editor marker, and a lowercase NCC', function()
    local file = defects()
    file:insert { type = 'NiNode', name = 'Stray' }
    expect(fix.fix(file)).toEqual {
      {
        fix = 'ncc',
        message = '"NCc" is now "NCC", so the camera still collides',
        record = 1,
      },
      {
        fix = 'rcn',
        message = 'added "RCN" string data, so OpenMW finds the RootCollisionNode (record 3) under a child node',
        record = 0,
      },
      {
        fix = 'markers',
        message = 'added "MRK" string data, so 1 editor marker shape doesn\'t draw in game',
        record = 0,
      },
      { fix = 'unreachable', message = 'dropped 1 record nothing links to' },
    }

    local repaired = nif.open(file:save())
    expect(typesOf(repaired)).toBe(
      'NiNode NiStringExtraData NiNode RootCollisionNode NiTriShapeData NiTriShape'
        .. ' NiStringExtraData NiStringExtraData'
    )

    -- The new string data goes first in the root's chain: MRK, then RCN, then what was there.
    expect((repaired:record(0) :: any).extraData).toBe(7)
    expect(repaired:record(7)).toEqual {
      type = 'NiStringExtraData',
      next = 6,
      bytesRemaining = 7,
      value = 'MRK',
    }

    expect(repaired:record(6)).toEqual {
      type = 'NiStringExtraData',
      next = 1,
      bytesRemaining = 7,
      value = 'RCN',
    }
    expect((repaired:record(1) :: any).value).toBe 'NCC'
    expect(fix.fix(repaired)).toEqual {}

    local report = findings('repaired.nif', repaired:save())
    for _, finding in report.findings do
      expect(finding.code == 'lowercase_ncc').toBe(false)
      expect(finding.code == 'visible_editor_marker').toBe(false)
      expect(finding.code == 'stray_root_collision_node').toBe(false)
    end

    expect((report.collision :: check.Collision).hidesMarkers).toBe(true)
  end)

  suite.it('applies only the kinds asked for', function()
    local file = defects()
    expect(fix.fix(file, { 'ncc' })).toEqual {
      {
        fix = 'ncc',
        message = '"NCc" is now "NCC", so the camera still collides',
        record = 1,
      },
    }
    expect(file.count).toBe(6)
    expect(fix.fix(file, { 'markers' })).toEqual {
      {
        fix = 'markers',
        message = 'added "MRK" string data, so 1 editor marker shape doesn\'t draw in game',
        record = 0,
      },
    }
    expect(file.count).toBe(7)
    expect(fix.fix(file, {})).toEqual {}
  end)

  suite.it('drops skin weights for vertices the shape doesn\'t have', function()
    local bytes = skinned()
    local file = nif.open(bytes)
    local weights = (file:record(2) :: any).boneData[1].vertexWeights
    expect(weights:toTable()).toEqual {
      vector.create(0, 1, 0),
      vector.create(2, 0.5, 0),
      vector.create(7, 0.25, 0),
    }

    expect(fix.fix(file)).toEqual {
      {
        fix = 'skinWeights',
        message = 'dropped 1 skin weight for vertices past the shape\'s 3',
        record = 5,
      },
    }

    local repaired = saved(file)
    expect(#repaired).toBe(#bytes - 6)
    expect((nif.open(repaired):record(2) :: any).boneData[1].vertexWeights:toTable()).toEqual {
      vector.create(0, 1, 0),
      vector.create(2, 0.5, 0),
    }
    expect(findings('repaired.nif', repaired).findings).toEqual {}
    expect(fix.fix(nif.open(repaired))).toEqual {}
  end)

  suite.it('reports the records a save drops for being unreachable', function()
    local stray, plain = unreachable()
    local file = nif.open(stray)
    expect(file.count).toBe(2)
    expect(fix.fix(file, { 'rcn', 'ncc', 'markers', 'skinWeights' })).toEqual {}
    expect(fix.fix(file)).toEqual {
      { fix = 'unreachable', message = 'dropped 1 record nothing links to' },
    }
    expect(saved(file)).toBe(plain)
    expect(findings('plain.nif', plain).findings).toEqual {}
  end)
end)

return suite
