--!strict
--!native
-- The NIF package's suite, on the two NetImmerse 4.0.0.2 files jess-nif tested with
-- (`assets/`) and on bytes built here. What the files hold was read off them once and is pinned
-- below; `golden/nif.txt` holds the digests the port campaign froze after jess-nif agreed.
local gamebryo = require '@nif/gamebryo'
local header = require '@nif/header'
local nif = require '@nif'
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

return suite
