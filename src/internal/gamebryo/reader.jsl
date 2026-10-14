--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
NIFs of every version OpenMW reads, from Morrowind to Starfield: a port of jess-nif's
multi-version reader, which ports OpenMW's `components/nif`. Records are read the way OpenMW
reads them, into tables named after its classes with every base class's fields, and every link
is checked after loading: it must point to a record of the class it needs. This reader is for
inspecting and checking; `nif.open` is the editable model of Morrowind NIFs.
]]

local Classes = require './classes'
local Stream = require './stream'
local Header = require '../header'
-- Generated nonstrict; a codec is the record class's `read` and `check`.
local Links = require './links'
local Load: { [string]: any } = require './load' :: any

local Factory = Classes.factory

export type File = {
  header: Header.Header,
  --- Each record, by 1-based index: its fields, and its record name as `type`.
  records: { any },
  --- Each record's class, as OpenMW reads it.
  classes: { string },
  --- Each record's `RecordType`.
  recordTypes: { string },
  --- Each record's name in the file. A record's `type` is its name too, except where the class
  --- has a field of that name (`BSShaderProperty`), as jess-nif's dump has it.
  names: { string },
  --- The root links as written, -1 for none.
  roots: { number },
}

--- Reads a NIF the way OpenMW does: the header, every record through its factory, the roots,
--- and then every link, which must point to a record of the right class. Errors are tables,
--- `{ message, record }`, worded as OpenMW words them.
local function open(data: buffer | string): File
  local bytes = if type(data) == 'string' then buffer.fromstring(data) else data
  local header = Header.parse(bytes)
  local fileVersion = header.version
  local stream: Stream.Stream = {
    bytes = bytes,
    length = buffer.len(bytes),
    version = fileVersion,
    userVersion = header.userVersion,
    bethVersion = header.bethVersion or 0,
    strings = header.strings,
    recordName = '',
  }

  local listed = fileVersion >= 0x05000001
  local separators = fileVersion >= 0x0A000000 and fileVersion < 0x0A020000
  local count = header.recordCount
  local reserve = math.min(count, buffer.len(bytes) // 4)
  local records: { any } = table.create(reserve)
  local names, classes, recordTypes =
    table.create(reserve) :: { string },
    table.create(reserve) :: { string },
    table.create(reserve) :: { string }
  local cursor = header.size
  for slot = 1, count do
    Stream.at(slot - 1)
    local name: string
    if listed then
      name = Header.recordType(header, slot - 1) or Stream.fail(`Record {slot - 1} has no type`)
    else
      name, cursor = Stream.string(stream, cursor)
    end

    if name == '' then Stream.fail(`Record type is blank (index {slot - 1})`) end

    if separators and string.sub(name, 1, 3) ~= 'bhk' then
      local separator = buffer.readi32(bytes, cursor)
      cursor += 4
      if separator ~= 0 then Stream.fail(`Non-zero separator precedes {name}, index {slot - 1}`) end
    end

    local entry = Factory[name]
    if not entry then Stream.fail(`Unknown record type {name}`) end

    local codec = Load[entry[1]]
    if not codec then Stream.fail(`No reader for class {entry[1]} ({name})`) end

    stream.recordName = name
    records[slot], cursor = codec.read(stream, cursor)
    names[slot], classes[slot], recordTypes[slot] = name, entry[1], entry[2]
  end

  Stream.at(nil)
  local rootCount = buffer.readu32(bytes, cursor)
  local roots = table.create(math.min(rootCount, buffer.len(bytes) // 4)) :: { number }
  for entry = 1, rootCount do
    roots[entry] = buffer.readi32(bytes, cursor + entry * 4)
  end

  Links.setNames(names)
  for slot, record in records do
    Stream.at(slot - 1)
    Load[classes[slot]].check(record, records, classes, slot - 1)
  end

  Stream.at(nil)
  return {
    header = header,
    records = records,
    names = names,
    classes = classes,
    recordTypes = recordTypes,
    roots = roots,
  }
end

return table.freeze { open = open }
