--!strict
--!native
-- The NIF package's suite, on the two NetImmerse 4.0.0.2 files jess-nif tested with
-- (`assets/`) and on bytes built here. What the files hold was read off them once and is pinned
-- below; `golden/nif.txt` holds the digests the port campaign froze after jess-nif agreed.
local nif = require '@nif'
local support = require './support'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

local u32, i32, f32, sized = support.u32, support.i32, support.f32, support.sized

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

return suite
