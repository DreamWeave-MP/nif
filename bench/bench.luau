--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The NIF package, timed through its public modules on the suite's two files: opening, decoding,
reading through one table, dumping, the array views' `get` and `toTable`, saving untouched and
re-encoded, the checker, the scene, the tree, the fixes, and the multi-version reader:

  jess run --capability filesystem.read --capability process.spawn --package . \
    bench/bench.luau [filter] [jess binary]

One line per workload, `name<TAB>seconds per call`: the median of seven batches of about a tenth
of a second each. Every call's answer is compared with the one pinned here, so a path that stops
doing its work fails instead of posting a time.

Given the jess binary to start (and `process.spawn`), the cold workloads too: what one process
pays for one file from its first `require` on, when compiling the modules it needs is most of
the work. Each is the median of seven processes running `cold.luau`.
]]

local check = require '@nif/check'
local fix = require '@nif/fix'
local gamebryo = require '@nif/gamebryo'
local header = require '@nif/header'
local info = require '@nif/info'
local nif = require '@nif'
local process = require '@dream/process'
local scene = require '@nif/scene'
local support = require '../tests/support'

-- A build without the verified toolchain runs Luau slower than a release does, so a number from
-- one says nothing about what ships.
if not jess.bench.verified then
  error('nif bench: this jess was built without the verified toolchain: measure on a release', 0)
end

local filter: string?, binary: string? = ...
local only = if filter and filter ~= '' then filter else nil

--- Where this file is, from its chunk name: `cold.luau` is beside it, the package above it.
local function here(): string
  local source = debug.info(1, 's')
  local first = string.sub(source, 1, 1)
  local path = if first == '@' or first == '=' then string.sub(source, 2) else source
  return string.match(path, '^(.*)/[^/]*$') or '.'
end

local Here = here()

local function median(samples: { number }): number
  table.sort(samples)
  return samples[(#samples + 1) // 2]
end

--- Times `body`, whose every call must answer `expected`.
local function workload(name: string, expected: number, body: () -> number)
  if only and not string.find(name, only, 1, true) then return end

  local function once()
    local answer = body()
    if answer ~= expected then error(`{name}: answered {answer}, not {expected}`, 0) end
  end

  jess.bench.collect()
  once()
  local start = os.clock()
  once()
  local single = math.max(os.clock() - start, 1e-7)
  local iterations = math.max(1, math.floor(0.1 / single))
  local samples = {}
  for batch = 1, 7 do
    jess.bench.collect()
    start = os.clock()
    for _ = 1, iterations do
      once()
    end

    samples[batch] = (os.clock() - start) / iterations
  end

  print(`{name}\t{string.format('%.9f', median(samples))}`)
end

--- Times `cold.luau`'s `kind` of work on the file at `path`, a process a sample.
local function cold(name: string, expected: number, kind: string, path: string)
  if not binary or (only and not string.find(name, only, 1, true)) then return end

  local arguments = {
    'run',
    '--capability',
    'filesystem.read',
    '--package',
    `{Here}/..`,
    `{Here}/cold.luau`,
    kind,
    path,
  }

  local samples = {}
  for run = 1, 7 do
    local result, message = process.run(binary, arguments, { stdout = 'capture' })
    if not result then error(`{name}: {message}`, 0) end

    local answer, seconds = string.match(result.stdout or '', '^(%d+)\t([%d.]+)\n$')
    if not result.success or tonumber(answer) ~= expected then
      error(`{name}: answered {answer or result.stdout}, not {expected}`, 0)
    end

    samples[run] = tonumber(seconds) :: number
  end

  print(`{name}\t{string.format('%.9f', median(samples))}`)
end

--- Whether `value` is one of the package's array views: its module is private, so a view is told
--- by its metatable, which has a length and, unlike the multi-version reader's lists, no iterator.
local function isView(value: unknown): boolean
  if type(value) ~= 'table' then return false end

  local meta = getmetatable(value :: any)
  return meta ~= nil and meta.__len ~= nil and not meta.__iter
end

--- Every array view under `value`, into `found`.
local function views(value: unknown, found: { any })
  if type(value) ~= 'table' then return end

  if isView(value) then
    if (value :: any).count > 0 then table.insert(found, value) end

    return
  end

  for _, entry in value :: { [unknown]: unknown } do
    views(entry, found)
  end
end

--- How many values are under `value`, reading every list the multi-version reader left unread.
local function walk(value: unknown): number
  if type(value) ~= 'table' then return 1 end

  if isView(value) then return (value :: any).count end

  local fields = value :: any
  local meta = getmetatable(fields)
  local total = 1
  if meta and meta.__len then
    for index = 1, #fields do
      total += walk(fields[index])
    end

    return total
  end

  for _, entry in fields do
    total += walk(entry)
  end

  return total
end

--- The nodes of a tree `@nif/info` made.
local function treeSize(nodes: { info.TreeNode }?): number
  if not nodes then return 0 end

  local total = #nodes
  for _, node in nodes do
    total += treeSize(node.children)
  end

  return total
end

type Expected = {
  open: number,
  decode: number,
  read: number,
  dump: number,
  views: number,
  get: number,
  toTable: number,
  save: number,
  check: number,
  scene: number,
  sceneDump: number,
  tree: number,
  fix: number,
  header: number,
  --- Nothing for a file the multi-version reader refuses.
  gamebryo: number?,
  gamebryoWalk: number?,
  gamebryoTree: number?,
}

local function file(name: string, expected: Expected)
  local text = support.asset(`{name}.nif`)
  local bytes = buffer.fromstring(text)
  local size = buffer.len(bytes)

  workload(`{name} open`, expected.open, function(): number return nif.open(bytes).count end)

  workload(`{name} open + decode`, expected.decode, function(): number
    local total = 0
    for _, record in nif.open(bytes):records() do
      total += #(record :: nif.Record).type
    end

    return total
  end)

  do
    local opened = nif.open(bytes)
    local scratch: { [string]: { [string]: unknown } } = {}
    for index = 0, opened.count - 1 do
      scratch[opened:typeOf(index) :: string] = {}
    end

    workload(`{name} read into one table a type`, expected.read, function(): number
      local total = 0
      for index = 0, opened.count - 1 do
        local record = opened:read(index, scratch[opened:typeOf(index) :: string])
        total += #(record :: nif.Record).type
      end

      return total
    end)
  end

  workload(`{name} open + dump`, expected.dump, function(): number
    local dumped = nif.open(bytes):dump()
    return #dumped.records + #dumped.roots
  end)

  do
    local opened = nif.open(bytes)
    local found = {}
    for _, record in opened:records() do
      views(record, found)
    end

    if #found ~= expected.views then error(`{name}: {#found} views, not {expected.views}`, 0) end

    workload(`{name} get every element of {#found} views`, expected.get, function(): number
      local total = 0
      for _, view in found do
        for index = 1, view.count do
          total += select('#', view:get(index))
        end
      end

      return total
    end)

    workload(`{name} toTable of {#found} views`, expected.toTable, function(): number
      local total = 0
      for _, view in found do
        total += #view:toTable()
      end

      return total
    end)
  end

  workload(`{name} open + save untouched`, size, function(): number
    return buffer.len(nif.open(bytes):save())
  end)

  local function reencoded(): buffer
    local opened = nif.open(bytes)
    for _ in opened:records() do
    end

    return opened:save()
  end

  if buffer.tostring(reencoded()) ~= text then error(`{name}: a re-encoded save differs`, 0) end

  workload(
    `{name} open + decode + save`,
    expected.save,
    function(): number return buffer.len(reencoded()) end
  )

  workload(`{name} check`, expected.check, function(): number
    local report = check.check(`{name}.nif`, bytes)
    return #report.findings + #report.textures
  end)

  workload(`{name} scene`, expected.scene, function(): number
    local built = scene.build(nif.open(bytes))
    return #built.nodes + #built.drawables + #built.issues
  end)

  do
    local built = scene.build(nif.open(bytes))

    workload(
      `{name} scene dump`,
      expected.sceneDump,
      function(): number return #scene.dump(built) end
    )
  end

  workload(`{name} tree and type counts`, expected.tree, function(): number
    local opened = nif.open(bytes)
    local total = treeSize(info.sceneTree(opened))
    for _, count in info.recordTypeCounts(opened) do
      total += count
    end

    return total
  end)

  workload(
    `{name} open + fix + save`,
    expected.fix,
    function(): number
      local opened = nif.open(bytes)
      return #fix.fix(opened) + buffer.len(opened:save())
    end
  )

  workload(
    `{name} header`,
    expected.header,
    function(): number return header.parse(bytes).recordCount end
  )

  local path = `{Here}/../tests/assets/{name}.nif`
  cold(`{name} cold: open + decode`, expected.decode, 'decode', path)
  cold(`{name} cold: read into one table a type`, expected.read, 'read', path)
  cold(`{name} cold: open + decode + save`, expected.save, 'save', path)
  cold(`{name} cold: check`, expected.check, 'check', path)
  cold(`{name} cold: scene`, expected.scene, 'scene', path)

  local records = expected.gamebryo
  if not records then return end

  cold(`{name} cold: multi-version open`, records, 'multi-version', path)

  workload(
    `{name} multi-version open`,
    records,
    function(): number return #gamebryo.open(bytes).records end
  )

  workload(`{name} multi-version open + read every list`, expected.gamebryoWalk :: number, function(): number
    return walk(gamebryo.open(bytes).records)
  end)

  workload(`{name} multi-version tree`, expected.gamebryoTree :: number, function(): number
    return treeSize(info.fileSceneTree(gamebryo.open(bytes)))
  end)
end

file('all_types', {
  open = 85,
  decode = 1313,
  read = 1313,
  dump = 108,
  views = 67,
  get = 1376,
  toTable = 1285,
  save = 15877,
  check = 1,
  scene = 71,
  sceneDump = 4143,
  tree = 127,
  fix = 15877,
  header = 85,
})

file('random_objects', {
  open = 20,
  decode = 233,
  read = 233,
  dump = 21,
  views = 29,
  get = 23023,
  toTable = 23023,
  save = 232548,
  check = 0,
  scene = 19,
  sceneDump = 1996,
  tree = 31,
  fix = 232548,
  header = 20,
  gamebryo = 20,
  gamebryoWalk = 29921,
  gamebryoTree = 11,
})
