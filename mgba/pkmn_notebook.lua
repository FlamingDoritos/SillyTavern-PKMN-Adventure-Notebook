--[[
  PKMN Adventure Notebook — mGBA bridge (Gen 3: Ruby / Sapphire / Emerald / FireRed / LeafGreen + romhacks)

  Load in mGBA 0.10+:  Tools > Scripting... > File > Load script... > pkmn_notebook.lua

  What it does
    * Reads the ROM once and extracts the game's own data (Pokémon, moves, abilities, items, types,
      map names, trainers, trainer classes) so names are right for romhacks too.
    * Watches RAM while you play and records an adventure log: routes visited, battles, catches,
      party changes, level-ups, evolutions, faints, badges, black-outs ...
    * Saves the log to logs/<adventure>.jsonl and serves it on http://127.0.0.1:<port> for the
      SillyTavern "PKMN Adventure Notebook" extension.
]]

local VERSION = "1.4.0"

---------------------------------------------------------------------------------------------------
-- Paths & config
---------------------------------------------------------------------------------------------------
local SCRIPT_DIR = "./"
do
  local src = debug.getinfo(1, "S").source or ""
  local dir = src:match("^@(.*[/\\])")
  if dir then SCRIPT_DIR = dir end
end

local CFG = {
  port = 8888,
  pollFrames = 20,
  writeLogFile = true,
  logWildBattles = true,
  logMoveChanges = true,
  showConsoleBuffer = true,
  symFile = nil,
  forceProfile = nil,
  addressOverrides = {},
  badgeNames = nil,
  romName = nil,
  mgbaFolder = nil,
}
do
  local f = loadfile(SCRIPT_DIR .. "notebook_config.lua")
  if f then
    local ok, user = pcall(f)
    if ok and type(user) == "table" then
      for k, v in pairs(user) do CFG[k] = v end
    elseif not ok then
      console:warn("[Notebook] notebook_config.lua has an error, using defaults: " .. tostring(user))
    end
  end
end

-- Crash-safe step log next to the script: if mGBA ever closes unexpectedly, the last line tells where.
local DEBUG_FILE = SCRIPT_DIR .. "notebook_debug.log"
local dbgCount = 0
local function dbg(msg)
  if dbgCount > 300 then return end
  dbgCount = dbgCount + 1
  pcall(function()
    local f = io.open(DEBUG_FILE, dbgCount == 1 and "w" or "a")
    if f then f:write(os.date("%H:%M:%S "), tostring(msg), "\n"); f:close() end
  end)
end
dbg("script start, version " .. VERSION .. ", " .. tostring(_VERSION) .. ", dir " .. SCRIPT_DIR)

local function log(msg) console:log("[Notebook] " .. msg); dbg(msg) end
local function warn(msg) console:warn("[Notebook] " .. msg); dbg("WARN " .. msg) end

---------------------------------------------------------------------------------------------------
-- Gen 3 text
---------------------------------------------------------------------------------------------------
local CHARMAP = { [0] =
  " ", "À", "Á", "Â", "Ç", "È", "É", "Ê", "Ë", "Ì", "こ", "Î", "Ï", "Ò", "Ó", "Ô",
  "Œ", "Ù", "Ú", "Û", "Ñ", "ß", "à", "á", "ね", "ç", "è", "é", "ê", "ë", "ì", "ま",
  "î", "ï", "ò", "ó", "ô", "œ", "ù", "ú", "û", "ñ", "º", "ª", "ᵉʳ", "&", "+", "あ",
  "ぃ", "ぅ", "ぇ", "ぉ", "Lv", "=", "ょ", "が", "ぎ", "ぐ", "げ", "ご", "ざ", "じ", "ず", "ぜ",
  "ぞ", "だ", "ぢ", "づ", "で", "ど", "ば", "び", "ぶ", "べ", "ぼ", "ぱ", "ぴ", "ぷ", "ぺ", "ぽ",
  "っ", "¿", "¡", "PK", "MN", "PO", "Ké", "BL", "OC", "K", "Í", "%", "(", ")", "セ", "ソ",
  "タ", "チ", "ツ", "テ", "ト", "ナ", "ニ", "ヌ", "â", "ノ", "ハ", "ヒ", "フ", "ヘ", "ホ", "í",
  "ミ", "ム", "メ", "モ", "ヤ", "ユ", "ヨ", "ラ", "リ", "↑", "↓", "←", "→", "ヲ", "ン", "ァ",
  "ィ", "ゥ", "ェ", "ォ", "ャ", "ュ", "ョ", "ガ", "ギ", "グ", "ゲ", "ゴ", "ザ", "ジ", "ズ", "ゼ",
  "ゾ", "ダ", "ヂ", "ヅ", "デ", "ド", "バ", "ビ", "ブ", "ベ", "ボ", "パ", "ピ", "プ", "ペ", "ポ",
  "ッ", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "!", "?", ".", "-", "・",
  "…", "“", "”", "‘", "'", "♂", "♀", "$", ",", "×", "/", "A", "B", "C", "D", "E",
  "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U",
  "V", "W", "X", "Y", "Z", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k",
  "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "▶",
  ":", "Ä", "Ö", "Ü", "ä", "ö", "ü", "", "", "", "", "", "", "", "", "",
}
-- Bytes allowed inside a "name-like" string (used to validate tables found in the ROM)
local NAMECHAR = {}
for b = 0x00, 0x2F do NAMECHAR[b] = true end
for b = 0x51, 0x5D do NAMECHAR[b] = true end
for b = 0xA1, 0xF6 do NAMECHAR[b] = true end
NAMECHAR[0x0A] = nil; NAMECHAR[0x18] = nil; NAMECHAR[0x1F] = nil; NAMECHAR[0x2F] = nil -- hiragana

local ENCODE = {}
for _, range in ipairs({ { 0xA1, 0xF6 }, { 0x00, 0xA0 } }) do
  for b = range[1], range[2] do
    local c = CHARMAP[b]
    if c and #c == 1 and not ENCODE[c] then ENCODE[c] = b end
  end
end
ENCODE[" "] = 0x00; ENCODE["'"] = 0xB4; ENCODE["é"] = 0x1B

local function encode(str)
  local out = {}
  local i = 1
  while i <= #str do
    local c = str:sub(i, i)
    if str:sub(i, i + 5) == "{PKMN}" then out[#out + 1] = string.char(0x53, 0x54); i = i + 6
    elseif str:sub(i, i + 1) == "é" then out[#out + 1] = string.char(0x1B); i = i + 2
    else out[#out + 1] = string.char(ENCODE[c] or 0x00); i = i + 1 end
  end
  return table.concat(out)
end

-- Decode a Gen-3 string. `buf` is a Lua string, `pos` 1-based, `maxLen` bytes.
local PLACEHOLDERS = { [1] = "{PLAYER}", [2] = "{STR1}", [3] = "{STR2}", [4] = "{STR3}", [6] = "{RIVAL}" }
local function decodeAt(buf, pos, maxLen)
  local out = {}
  local i, stop = pos, pos + maxLen - 1
  while i <= stop do
    local b = buf:byte(i)
    if not b or b == 0xFF then break end
    if b == 0xFD then
      out[#out + 1] = PLACEHOLDERS[buf:byte(i + 1) or 0] or ""
      i = i + 2
    elseif b == 0xFC then
      i = i + 2 -- control code + 1 arg (good enough for names)
    elseif b == 0xFE or b == 0xFA or b == 0xFB then
      out[#out + 1] = " "; i = i + 1
    else
      out[#out + 1] = CHARMAP[b] or ""; i = i + 1
    end
  end
  return (table.concat(out):gsub("%s+$", ""))
end

-- Is there a plausible name at buf[pos] (terminated by 0xFF within maxLen)?
local function isNameAt(buf, pos, maxLen)
  if buf:byte(pos) == 0x00 then return false end -- real names never start with a space
  local len = 0
  for i = pos, pos + maxLen - 1 do
    local b = buf:byte(i)
    if not b then return false end
    if b == 0xFF then return len > 0 end
    if b == 0xFD then
      -- placeholder, skip its argument
    elseif not NAMECHAR[b] then
      local prev = buf:byte(i - 1)
      if prev ~= 0xFD then return false end
    end
    len = len + 1
  end
  return false
end

local function titleCase(s)
  if s:find("%l") then return s end -- already mixed case (romhacks): keep as written
  -- "ROUTE 101" -> "Route 101", "POKéMON CENTER" -> "Pokémon Center", keeps short words like "of" lowercase
  local small = { OF = true, THE = true, AND = true, IN = true, ON = true, TO = true }
  local first = true
  return (s:gsub("([%a\128-\255][%w\128-\255'.]*)", function(w)
    local up = w:upper()
    local r
    if not first and small[up] then r = w:lower()
    elseif up == "TM" or up == "HM" or up == "PP" or up == "HP" or up == "S.S." or up == "PKMN" or up == "PC" or up == "TV" then r = w
    elseif #w <= 1 then r = w
    else r = w:sub(1, 1) .. w:sub(2):lower() end
    first = false
    return r
  end))
end

---------------------------------------------------------------------------------------------------
-- Minimal JSON encoder
---------------------------------------------------------------------------------------------------
local json = {}
local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true, n
end
local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
function json.str(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end
function json.encode(v)
  local t = type(v)
  if v == nil or v == json.null then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.type(v) == "integer" then return tostring(v) end
    return string.format("%.14g", v)
  elseif t == "string" then return json.str(v)
  elseif t == "table" then
    local arr, n = isArray(v)
    local parts = {}
    if arr and (n > 0 or getmetatable(v) == json.arrayMT) then
      for i = 1, n do parts[i] = json.encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    elseif arr and n == 0 then
      return (getmetatable(v) == json.objectMT) and "{}" or "[]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local val = v[k]
      if val == nil then val = v[tonumber(k)] end
      parts[#parts + 1] = json.str(k) .. ":" .. json.encode(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end
json.null = setmetatable({}, { __tostring = function() return "null" end })
json.arrayMT = {}
json.objectMT = {}

---------------------------------------------------------------------------------------------------
-- Memory profiles (US releases; romhacks built on them usually keep these addresses)
---------------------------------------------------------------------------------------------------
local PROFILES = {
  E = {
    name = "Emerald", family = "E",
    party = 0x020244EC, partyCount = 0x020244E9, enemy = 0x02024744,
    sb1ptr = 0x03005D8C, sb2ptr = 0x03005D90,
    battleType = 0x02022FEC, outcome = 0x0202433A, opponentA = 0x02038BCA,
    mapHeader = 0x02037318,
    flagsOff = 0x1270, badgeFlag = 0x867,
    moneyOff = 0x490, moneyKeyOff = 0xAC,
    badges = { "Stone", "Knuckle", "Dynamo", "Heat", "Balance", "Feather", "Mind", "Rain" },
  },
  FR = {
    name = "FireRed/LeafGreen", family = "FR",
    party = 0x02024284, partyCount = 0x02024029, enemy = 0x0202402C,
    sb1ptr = 0x03005008, sb2ptr = 0x0300500C,
    battleType = 0x02022B4C, outcome = 0x02023E8A, opponentA = 0x020386AE,
    mapHeader = 0x02036DFC,
    flagsOff = 0xEE0, badgeFlag = 0x820,
    moneyOff = 0x290, moneyKeyOff = 0xF20,
    rivalNameOff = 0x3A4C,
    badges = { "Boulder", "Cascade", "Thunder", "Rainbow", "Soul", "Marsh", "Volcano", "Earth" },
  },
  RS = {
    name = "Ruby/Sapphire", family = "RS",
    party = 0x03004360, partyCount = 0x03004350, enemy = 0x030045C0,
    sb1 = 0x02025734, sb2 = 0x02024EA4,
    battleType = 0x020239F8, outcome = 0x02024D26, opponentA = 0x0202FF5E,
    mapHeader = 0x0202E828,
    flagsOff = 0x1220, badgeFlag = 0x807,
    moneyOff = 0x490,
    badges = { "Stone", "Knuckle", "Dynamo", "Heat", "Balance", "Feather", "Mind", "Rain" },
  },
}
local CODE_TO_PROFILE = { BPEE = "E", BPRE = "FR", BPGE = "FR", AXVE = "RS", AXPE = "RS" }

local SYM_KEYS = {
  gPlayerParty = "party", gPlayerPartyCount = "partyCount", gEnemyParty = "enemy",
  gSaveBlock1Ptr = "sb1ptr", gSaveBlock2Ptr = "sb2ptr", gSaveBlock1 = "sb1", gSaveBlock2 = "sb2",
  gBattleTypeFlags = "battleType", gBattleOutcome = "outcome",
  gTrainerBattleOpponent_A = "opponentA", gTrainerBattleOpponent = "opponentA", gMapHeader = "mapHeader",
}

local function loadSymFile(path)
  local f = io.open(path, "r")
  if not f then warn("Could not open symFile " .. tostring(path)); return nil end
  local out = {}
  for line in f:lines() do
    local addr, name = line:match("^(%x+)%s+%a%s+%x+%s+(%S+)")
    if addr and SYM_KEYS[name] then out[SYM_KEYS[name]] = tonumber(addr, 16) end
  end
  f:close()
  return out
end

---------------------------------------------------------------------------------------------------
-- ROM data extraction
---------------------------------------------------------------------------------------------------
local ROM -- full ROM as a Lua string
local ROMSIZE = 0
local function ru8(o) return ROM:byte(o + 1) end
local function ru32(o) if o < 0 or o + 4 > ROMSIZE then return 0 end return (string.unpack("<I4", ROM, o + 1)) end

local function findAll(needle, limit, align)
  local res, init = {}, 1
  limit = limit or 64
  while #res < limit do
    local s = ROM:find(needle, init, true)
    if not s then break end
    local off = s - 1
    if not align or off % align == 0 then res[#res + 1] = off end
    init = s + 1
  end
  return res
end

local function ptrBytes(off) return string.pack("<I4", off + 0x08000000) end
local function romPtrToOff(p)
  if p >= 0x08000000 and p < 0x08000000 + ROMSIZE then return p - 0x08000000 end
  return nil
end

-- A table is { mode="inline"|"ptr", base=<rom offset of entry 0>, stride=n, maxLen=n, first=index of first valid entry }
local Table = {}
Table.__index = Table
function Table:nameOffset(i)
  local e = self.base + i * self.stride
  if e < 0 or e + 4 > ROMSIZE then return nil end
  if self.mode == "inline" then return e end
  return romPtrToOff(ru32(e))
end
function Table:valid(i)
  local o = self:nameOffset(i)
  return o ~= nil and isNameAt(ROM, o + 1, self.maxLen)
end
function Table:get(i)
  local o = self:nameOffset(i)
  if not o then return nil end
  return decodeAt(ROM, o + 1, self.maxLen)
end

-- "LITTLEROOT TOWN" -> { "LITTLEROOT TOWN", "Littleroot Town" } (romhacks often use mixed case)
local function caseVariants(str)
  local words = {}
  for w in str:gmatch("%S+") do
    if w:sub(1, 1) == "{" then words[#words + 1] = w
    else words[#words + 1] = w:sub(1, 1):upper() .. w:sub(2):lower() end
  end
  local title = table.concat(words, " ")
  if title == str then return { str } end
  return { str, title }
end

local function tableValid(t, from, count)
  for i = from, from + count - 1 do if not t:valid(i) then return false end end
  return true
end
-- like tableValid but tolerates one blank entry in the window
local function tableMostlyValid(t, from, count)
  local ok = 0
  for i = from, from + count do if t:valid(i) then ok = ok + 1 end end
  return ok >= count
end

-- Find a name table from two consecutive anchor entries (index i1 and i1+1), in any letter case.
-- opts: maxStride, ptrOnly, check (entries after the anchors that must also be valid names)
local function tableLength(t, from)
  local n, misses = 0, 0
  for i = from, from + 300 do
    if t:valid(i) then n = n + 1; misses = 0 else misses = misses + 1; if misses > 3 then break end end
  end
  return n
end

local function findByAnchors(pairsList, i1, maxLen, opts)
  opts = opts or {}
  local maxStride = opts.maxStride or 0x400
  local check = opts.check or 5
  local best, bestHow, bestLen = nil, nil, -1
  local function consider(t, how)
    if not opts.best then return true end
    local len = tableLength(t, i1)
    if len > bestLen then best, bestHow, bestLen = t, how, len end
    return false
  end
  local tries = {}
  for _, pr in ipairs(pairsList) do
    local v1, v2 = caseVariants(pr[1]), caseVariants(pr[2])
    for k = 1, math.max(#v1, #v2) do tries[#tries + 1] = { v1[math.min(k, #v1)], v2[math.min(k, #v2)] } end
  end
  for _, pr in ipairs(tries) do
    local A, B = findAll(encode(pr[1]) .. "\255", 200), findAll(encode(pr[2]) .. "\255", 200)
    if not opts.ptrOnly then
      for _, a in ipairs(A) do
        for _, b in ipairs(B) do
          local s = b - a
          if s > 0 and s <= maxStride then
            local t = setmetatable({ mode = "inline", base = a - i1 * s, stride = s, maxLen = maxLen }, Table)
            if tableMostlyValid(t, i1 + 2, check) and consider(t, "anchor") then return t, "anchor" end
          end
        end
      end
    end
    for _, a in ipairs(A) do
      local PA = findAll(ptrBytes(a), 32, 4)
      if #PA > 0 then
        for _, b in ipairs(B) do
          local PB = findAll(ptrBytes(b), 32, 4)
          for _, pa in ipairs(PA) do
            for _, pb in ipairs(PB) do
              local s = pb - pa
              if s > 0 and s <= maxStride and s % 4 == 0 then
                local t = setmetatable({ mode = "ptr", base = pa - i1 * s, stride = s, maxLen = maxLen }, Table)
                if tableMostlyValid(t, i1 + 2, check) and consider(t, "anchor-ptr") then return t, "anchor-ptr" end
              end
            end
          end
        end
      end
    end
  end
  if best then return best, bestHow end
  return nil
end

-- Species without known anchors (fakemon hacks, gSpeciesInfo structs): entry 0 is "??????????".
-- Some hacks blank out unused species, so score each stride by how many valid names it gives.
local function findSpeciesByPlaceholder()
  local q = string.rep("\172", 10) .. "\255"
  local probes = { 1, 4, 7, 25, 129, 133, 150, 151, 152, 248, 249, 250, 252, 255, 258, 384, 385 }
  local best, bestScore = nil, 0
  for _, a in ipairs(findAll(q, 80)) do
    local strides = { 11, 12, 13 }
    for st = 16, 0x400, 4 do strides[#strides + 1] = st end
    for _, st in ipairs(strides) do
      local t = setmetatable({ mode = "inline", base = a, stride = st, maxLen = 13 }, Table)
      local quick = 0
      for _, i in ipairs(probes) do if t:valid(i) then quick = quick + 1 end end
      if quick >= 6 then
        local score = 0
        for i = 1, 400 do if t:valid(i) then score = score + 1 end end
        if score > bestScore then best, bestScore = t, score end
      end
    end
  end
  if bestScore >= 60 then return best end
  return nil
end

-- A table whose address is stored in the ROM (Game Freak ROM header or a pointer inside the game code)
local function tableAtPointer(ptr, strides, maxLen, first, check, mode)
  local base = romPtrToOff(ptr or 0)
  if not base then return nil end
  for _, s in ipairs(strides) do
    local t = setmetatable({ mode = mode or "inline", base = base, stride = s, maxLen = maxLen }, Table)
    if tableValid(t, first, check or 6) then return t end
  end
  return nil
end

-- Read entries [from .. ] until the first invalid one (or `max`)
local function readNames(t, from, max, allowGaps)
  local out, lastValid = {}, from - 1
  local misses = 0
  for i = from, from + max - 1 do
    if t:valid(i) then
      out[i] = t:get(i); lastValid = i; misses = 0
    elseif lastValid < from and i - from < 2 then
      -- entry 0 is often blank ("" / NONE): skip it
    else
      misses = misses + 1
      if misses > (allowGaps or 0) then break end
    end
  end
  return out, lastValid
end

-- Generic fallback for map-section names: find a pointer table whose strings are mostly "ROUTE ..."
local function findMapsecTableGeneric(indexOffset)
  local ptrs = {}
  for _, word in ipairs({ "ROUTE ", "Route " }) do
    for _, off in ipairs(findAll(encode(word), 400)) do
      local prev = off > 0 and ru8(off - 1) or 0xFF
      if prev == 0xFF or prev == 0x00 then
        for _, p in ipairs(findAll(ptrBytes(off), 8, 4)) do ptrs[#ptrs + 1] = p end
      end
    end
  end
  table.sort(ptrs)
  local best, bestLen, bestStride = nil, 0, 4
  for _, stride in ipairs({ 4, 8, 12, 16 }) do
    local set = {}
    for _, p in ipairs(ptrs) do set[p] = true end
    for _, p in ipairs(ptrs) do
      local count, q, gap = 1, p, 0
      while gap <= 6 do
        q = q + stride
        if set[q] then count = count + 1; gap = 0 else gap = gap + 1 end
      end
      if count > bestLen then best, bestLen, bestStride = p, count, stride end
    end
  end
  if not best or bestLen < 8 then return nil end
  local t = setmetatable({ mode = "ptr", base = best, stride = bestStride, maxLen = 24 }, Table)
  local i = 0
  while t:valid(i - 1) and i > -300 do i = i - 1 end
  t.base = t.base + i * bestStride - indexOffset * bestStride
  return t
end

-- Trainers, vanilla layout: array of 40-byte `struct Trainer` (R/S/E/FR/LG and binary hacks)
local function findTrainerTableVanilla()
  local pat = "[\1-\6]\0\0\0...[\8\9]"
  local ok = {}
  local init = 1
  local count = 0
  while true do
    local s = ROM:find(pat, init)
    if not s then break end
    init = s + 1
    local off = s - 1 - 0x20
    if off >= 0 and off % 4 == 0 then
      local pflags, dbl = ru8(off), ru8(off + 0x18)
      if pflags <= 3 and dbl <= 1 and ru8(off + 0x19) == 0 and ru8(off + 0x1A) == 0 and ru8(off + 0x1B) == 0
        and (isNameAt(ROM, off + 5, 12) or ru8(off + 4) == 0xFF) then
        ok[off] = true
        count = count + 1
      end
    end
    if count > 20000 then break end
  end
  local bestStart, bestLast, bestLen = nil, nil, 0
  local seen = {}
  local keys = {}
  for off in pairs(ok) do keys[#keys + 1] = off end
  table.sort(keys)
  for _, off in ipairs(keys) do
    if not seen[off] then
      local last, n, q, gap = off, 1, off, 0
      seen[off] = true
      while gap <= 3 do
        q = q + 40
        if ok[q] then seen[q] = true; last = q; n = n + 1; gap = 0 else gap = gap + 1 end
      end
      if n > bestLen then bestStart, bestLast, bestLen = off, last, n end
    end
  end
  if not bestStart or bestLen < 20 then return nil end
  local base = bestStart
  if bestStart >= 40 and ru8(bestStart - 40 + 0x20) == 0 then base = bestStart - 40 end
  return { base = base, count = (bestLast - base) // 40 + 1, stride = 40, nameOff = 4, classOff = 1, sizeOff = 0x20 }
end

-- Trainers, any layout (pokeemerald-expansion & co): start from a gym leader's name and measure the struct
local function findTrainerTableGeneric(classNames, classCount)
  local leaderIdx = nil
  for i = 0, classCount - 1 do
    local n = (classNames[i] or ""):upper()
    if n == "LEADER" or n == "GYM LEADER" then leaderIdx = i; break end
  end
  local function nameOrEmpty(o)
    local b = ru8(o)
    if b == nil then return false end
    return isNameAt(ROM, o + 1, 12) or b == 0xFF or (b == 0 and ru8(o + 1) == 0)
  end
  local result, resultRun = nil, 0
  local LEADERS = { ROXANNE = true, BROCK = true, BRAWLY = true, WATTSON = true, MISTY = true, NORMAN = true }
  for _, anchorName in ipairs({ "ROXANNE", "BROCK", "SAWYER", "BRAWLY", "WATTSON", "MISTY", "NORMAN", "CALVIN" }) do
   for _, anchor in ipairs(caseVariants(anchorName)) do
    for _, a in ipairs(findAll(encode(anchor) .. "\255", 12)) do
      local bestS, bestRun = nil, 0
      for s = 24, 120, 4 do
        local run, k, misses = 0, 1, 0
        while k <= 1200 and misses < 3 do
          if isNameAt(ROM, a + k * s + 1, 12) then run = run + 1; misses = 0
          elseif nameOrEmpty(a + k * s) then misses = misses + 1 else break end
          k = k + 1
        end
        k, misses = 1, 0
        while k <= 1200 and misses < 3 do
          if a - k * s >= 0 and isNameAt(ROM, a - k * s + 1, 12) then run = run + 1; misses = 0
          elseif a - k * s >= 0 and nameOrEmpty(a - k * s) then misses = misses + 1 else break end
          k = k + 1
        end
        if run > bestRun then bestS, bestRun = s, run end
      end
      if bestS and bestRun >= 60 and bestRun > resultRun then
        local s = bestS
        -- walk back to the first entry
        local first, k, misses = a, 1, 0
        while misses < 3 and a - k * s >= 0 do
          local o = a - k * s
          if isNameAt(ROM, o + 1, 12) then first = o; misses = 0
          elseif nameOrEmpty(o) then misses = misses + 1; if misses == 1 then first = o end
          else break end
          k = k + 1
        end
        -- walk forward to the last entry
        local last, misses2 = a, 0
        k = 1
        while misses2 < 3 do
          local o = a + k * s
          if o + 12 > ROMSIZE then break end
          if isNameAt(ROM, o + 1, 12) then last = o; misses2 = 0
          elseif nameOrEmpty(o) then misses2 = misses2 + 1 else break end
          k = k + 1
        end
        local count = (last - first) // s + 1
        -- which byte holds the trainer class? (relative to the name)
        local classOff = nil
        for _, c in ipairs({ -3, -4, -2, -1, -5, -6, -7, -8, 12, 13, 14, 15, 16 }) do
          if (not leaderIdx) or (not LEADERS[anchorName]) or ru8(a + c) == leaderIdx then
            local okAll, distinct, seenV = true, 0, {}
            for i = 0, count - 1, math.max(1, count // 200) do
              local v = ru8(first + i * s + c)
              if not v or v >= math.max(classCount, 1) then okAll = false; break end
              if not seenV[v] then seenV[v] = true; distinct = distinct + 1 end
            end
            if okAll and distinct >= 6 then classOff = c; break end
          end
        end
        result, resultRun = { base = first, count = count, stride = s, nameOff = 0, classOff = classOff }, bestRun
      end
    end
   end
  end
  return result
end

-- Pointers to tables inside the vanilla game code (used for binary hacks that repointed tables)
local CODE_REFS = {
  FR = { trainerClasses = { 0xD80A0, 0x11B4B4 }, trainers = { 0xFC00, 0x1133C, 0x116C4 }, mapsecs = { 0xC0C94, 0xC4DB8 }, types = { 0x309C8, 0xD8510 } },
  E  = { trainerClasses = { 0x183B4, 0x6F0AC }, trainers = { 0x3587C, 0x36320, 0x36480 }, mapsecs = { 0x123B44, 0x123D54 }, types = { 0x166F4, 0x59C24 } },
}

local DATA = nil -- extracted names

local function serializeLua(v, indent)
  indent = indent or ""
  local t = type(v)
  if t == "string" then return string.format("%q", v)
  elseif t == "number" or t == "boolean" then return tostring(v)
  elseif t == "table" then
    local parts = {}
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then return a < b end
      return type(a) == "number"
    end)
    for _, k in ipairs(keys) do
      local ks = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
      parts[#parts + 1] = indent .. " " .. ks .. "=" .. serializeLua(v[k], indent .. " ")
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  end
  return "nil"
end

local function rawStringAt(off, maxLen)
  local out = {}
  for i = off, off + maxLen - 1 do
    local b = ru8(i)
    if not b or b == 0xFF then break end
    out[#out + 1] = string.char(b)
  end
  return table.concat(out)
end

-- Gender ratios live in the species stats table (vanilla: 28-byte BaseStats, ratio at +16).
-- Find it via the ROM header pointer and check the values look like real gender ratios.
local GENDER_OK = { [0] = true, [31] = true, [63] = true, [127] = true, [191] = true, [223] = true, [225] = true, [254] = true, [255] = true }
local function genderScore(base, stride, off, ids, need)
  local ok, n, seen = 0, 0, {}
  for _, i in ipairs(ids) do
    local v = ru8(base + i * stride + off)
    if v == nil then return 0 end
    n = n + 1
    if GENDER_OK[v] then ok = ok + 1; seen[v] = true
    elseif n - ok > #ids * (1 - need) then return 0 end
  end
  if n == 0 or not seen[255] or not seen[127] or not (seen[0] or seen[254]) then return 0 end
  return ok / n
end

local function findGenderTable(speciesNames, speciesTable)
  local ids = {}
  for i = 1, 400 do if speciesNames[i] and speciesNames[i] ~= "?" then ids[#ids + 1] = i end end
  if #ids < 40 then return nil end
  local quick = {}
  for k = 1, math.min(#ids, 150) do quick[k] = ids[k] end
  local bases = {}
  local hb = romPtrToOff(ru32(0x1BC))
  if hb then bases[#bases + 1] = hb end
  -- 1) vanilla layout (28-byte BaseStats). Hacks use custom ratios (any 0-255), so check the
  --    neighbouring fields instead: HP > 0, growth rate <= 5, egg groups <= 15
  for _, b in ipairs(bases) do
    local good = 0
    for _, i in ipairs(ids) do
      local e = b + i * 28
      local hp, growth, eg1, eg2 = ru8(e), ru8(e + 19), ru8(e + 20), ru8(e + 21)
      if hp and hp > 0 and growth <= 5 and eg1 <= 15 and eg2 <= 15 then good = good + 1 end
    end
    if good >= #ids * 0.9 then return { base = b, stride = 28, off = 16, how = "header" } end
  end
  -- 2) species info structs that also hold the name: same stride as the name table
  local strides = {}
  if speciesTable and speciesTable.mode == "inline" and speciesTable.stride > 28 then
    strides[#strides + 1] = speciesTable.stride
    if not hb then bases[#bases + 1] = speciesTable.base - (speciesTable.base % 4) end
  end
  for st = 24, 512, 4 do if st ~= 28 then strides[#strides + 1] = st end end
  for _, b in ipairs(bases) do
    for _, st in ipairs(strides) do
      for off = 0, math.min(st, 160) - 1 do
        if genderScore(b, st, off, quick, 0.95) >= 0.95 and genderScore(b, st, off, ids, 0.95) >= 0.95 then
          return { base = b, stride = st, off = off, how = "search" }
        end
      end
    end
  end
  return nil
end

local function extractRomData(family)
  local t0 = os.clock()
  local D = { species = {}, moves = {}, abilities = {}, items = {}, types = {}, mapsecs = {}, trainerClasses = {}, trainers = {}, found = {} }
  local T = {} -- found tables
  local refs = CODE_REFS[family] or CODE_REFS.E

  local function note(key, t, how)
    if t then
      T[key] = t
      D.found[key] = string.format("%s %s @0x%06X stride %d", how, t.mode, t.base, t.stride)
    end
    return t
  end

  -- 1) Game Freak ROM header (0x100): pointers to the species / move / ability / item name tables
  local hdrSpecies, hdrMoves, hdrAbil, hdrItems = ru32(0x144), ru32(0x148), ru32(0x1C0), ru32(0x1C8)
  local itemStrides = { 44 }
  for s = 20, 128, 4 do if s ~= 44 then itemStrides[#itemStrides + 1] = s end end
  note("species", tableAtPointer(hdrSpecies, { 11, 12, 13 }, 13, 1, 6), "header")
  note("moves", tableAtPointer(hdrMoves, { 13, 17, 15, 16 }, 17, 1, 6), "header")
  note("abilities", tableAtPointer(hdrAbil, { 13, 17, 15, 16 }, 17, 1, 6), "header")
  note("items", tableAtPointer(hdrItems, itemStrides, 17, 1, 6), "header")

  -- 2) anchors (any letter case, inline tables or structs, or pointer tables)
  if not T.species then note("species", findByAnchors({ { "BULBASAUR", "IVYSAUR" } }, 1, 13), "anchor") end
  local speciesGaps = 2
  if not T.species then
    if note("species", findSpeciesByPlaceholder(), "placeholder") then speciesGaps = 60 end
  end
  if not T.moves then note("moves", findByAnchors({ { "POUND", "KARATE CHOP" } }, 1, 17), "anchor") end
  if not T.abilities then note("abilities", findByAnchors({ { "STENCH", "DRIZZLE" } }, 1, 17, { best = true }), "anchor") end
  if not T.items then note("items", findByAnchors({ { "MASTER BALL", "ULTRA BALL" }, { "STRANGE BALL", "POKé BALL" }, { "POKé BALL", "GREAT BALL" } }, 1, 17), "anchor") end
  note("types", findByAnchors({ { "NORMAL", "FIGHT" }, { "NORMAL", "FIGHTING" } }, 0, 13, { check = 4 }), "anchor")
  if not T.types then
    for _, r in ipairs(refs.types or {}) do
      if note("types", tableAtPointer(ru32(r), { 7 }, 9, 0, 6), "code") then break end
    end
  end
  note("trainerClasses", findByAnchors({ { "{PKMN} TRAINER", "{PKMN} TRAINER" }, { "PKMN TRAINER", "PKMN TRAINER" },
    { "POKéMON TRAINER", "POKéMON TRAINER" } }, 0, 21, { maxStride = 64 }), "anchor")
  if not T.trainerClasses then
    note("trainerClasses", findByAnchors({ (family == "FR") and { "AQUA LEADER", "TEAM AQUA" } or { "HIKER", "TEAM AQUA" } }, 2, 21, { maxStride = 64 }), "anchor")
  end
  if not T.trainerClasses then
    for _, r in ipairs(refs.trainerClasses or {}) do
      if note("trainerClasses", tableAtPointer(ru32(r), { 13 }, 13, 1, 6), "code") then break end
    end
  end

  -- Map section names: always pointer tables (the strings themselves are packed back to back)
  local hoenn = { "LITTLEROOT TOWN", "OLDALE TOWN" }
  local kanto = { "PALLET TOWN", "VIRIDIAN CITY" }
  local mapFrom = (family == "FR") and 0x58 or 0
  for _, r in ipairs(refs.mapsecs or {}) do
    local p = romPtrToOff(ru32(r))
    if p then
      local t = (family == "FR") and setmetatable({ mode = "ptr", base = p - 0x58 * 4, stride = 4, maxLen = 24 }, Table)
        or setmetatable({ mode = "ptr", base = p + 4, stride = 8, maxLen = 24 }, Table)
      if tableValid(t, mapFrom, 8) then note("mapsecs", t, "code"); break end
    end
  end
  if not T.mapsecs then
    local first = (family == "FR") and { kanto, 0x58 } or { hoenn, 0 }
    local second = (family == "FR") and { hoenn, 0 } or { kanto, 0x58 }
    for _, a in ipairs({ first, second }) do
      -- Emerald-engine tables hold Hoenn and Kanto names, so they are always read from index 0
      if note("mapsecs", findByAnchors({ a[1] }, a[2], 24, { ptrOnly = true, maxStride = 64, best = true }), "anchor") then break end
    end
  end
  if not T.mapsecs then
    if note("mapsecs", findMapsecTableGeneric(mapFrom), "generic") then end
  end

  -- Clip inline tables so one table never runs into the next one
  local limits = {}
  for k, t in pairs(T) do
    if t.mode == "inline" then
      local lim = nil
      for k2, t2 in pairs(T) do
        if k2 ~= k and t2.base > t.base and (not lim or t2.base < lim) then lim = t2.base end
      end
      if lim then limits[k] = (lim - t.base) // t.stride end
    end
  end
  local function read(key, from, max, gaps)
    local t = T[key]
    if not t then D.found[key] = D.found[key] or "not found"; return end
    if limits[key] then max = math.min(max, limits[key] - from) end
    D[key] = readNames(t, from, max, gaps)
  end
  read("species", 0, 2500, speciesGaps)
  read("moves", 0, 2000, 0)
  read("abilities", 0, 1000, 0)
  read("items", 0, 2000, 0)
  read("types", 0, 40, 1)
  read("trainerClasses", 0, 256, 0)
  read("mapsecs", mapFrom, 256 - mapFrom, 3)

  -- Key items (vanilla 44-byte Item struct: pocket byte at +26, 5 = key items)
  D.keyItems = {}
  if T.items and T.items.mode == "inline" and T.items.stride == 44 then
    for i in pairs(D.items) do
      local o = T.items:nameOffset(i)
      if o and ru8(o + 26) == 5 then D.keyItems[i] = true end
    end
  end

  -- Gender ratios (for ♂/♀)
  D.genderRatio = {}
  local gt = findGenderTable(D.species, T.species)
  if gt then
    for i in pairs(D.species) do
      local v = ru8(gt.base + i * gt.stride + gt.off)
      if v then D.genderRatio[i] = v end
    end
    D.found.gender = string.format("%s @0x%06X stride %d +%d", gt.how, gt.base, gt.stride, gt.off)
  else
    D.found.gender = "not found"
  end

  -- Raw class-name bytes (to recognise "LEADER ROXANNE" in battle text)
  local classRaw = {}
  if T.trainerClasses then
    for i in pairs(D.trainerClasses) do
      local o = T.trainerClasses:nameOffset(i)
      if o then classRaw[i] = rawStringAt(o, 13) end
    end
  end

  D.classRaw = classRaw
  -- Trainers
  local classCount = 0
  for i in pairs(D.trainerClasses) do if i + 1 > classCount then classCount = i + 1 end end
  local tt = findTrainerTableVanilla()
  local how = "struct"
  if not tt then
    for _, r in ipairs(refs.trainers or {}) do
      local p = romPtrToOff(ru32(r))
      if p and isNameAt(ROM, p + 40 + 5, 12) and isNameAt(ROM, p + 80 + 5, 12) then
        tt = { base = p, count = 700, stride = 40, nameOff = 4, classOff = 1, sizeOff = 0x20 }; how = "code"; break
      end
    end
  end
  if not tt then tt = findTrainerTableGeneric(D.trainerClasses, classCount); how = "anchor" end
  if tt then
    D.trainerTable = { base = tt.base, count = tt.count, stride = tt.stride }
    local n = 0
    for i = 0, tt.count - 1 do
      local e = tt.base + i * tt.stride
      local no = e + tt.nameOff
      if isNameAt(ROM, no + 1, 12) then
        local cls = tt.classOff and ru8(e + tt.classOff) or nil
        local entry = { n = decodeAt(ROM, no + 1, 12), c = cls }
        if tt.sizeOff then entry.s = ru8(e + tt.sizeOff) end
        if cls and classRaw[cls] then entry.r = classRaw[cls] .. "\0" .. rawStringAt(no, 12) end
        D.trainers[i] = entry
        n = n + 1
      end
    end
    D.found.trainers = string.format("%s @0x%06X x%d stride %d", how, tt.base, n, tt.stride)
  else
    D.found.trainers = "not found"
  end

  D.scanSeconds = os.clock() - t0
  return D
end

---------------------------------------------------------------------------------------------------
-- RAM helpers
---------------------------------------------------------------------------------------------------
local P = nil -- active profile (table of addresses)
local GAME = { code = "", title = "", crc = "", family = "?", profileName = "?", file = nil, fileTries = 0 }

local function r8(a) return emu:read8(a) end
-- The GBA bus rounds unaligned 16/32-bit reads down, so read unaligned values byte by byte
local function r16(a)
  if a & 1 == 0 then return emu:read16(a) end
  return (string.unpack("<I2", emu:readRange(a, 2)))
end
local function r32(a)
  if a & 3 == 0 then return emu:read32(a) end
  return (string.unpack("<I4", emu:readRange(a, 4)))
end
local function rrange(a, n) return emu:readRange(a, n) end

local function sb1() if P.sb1 then return P.sb1 end local p = r32(P.sb1ptr); if p >= 0x02000000 and p < 0x02040000 then return p end return nil end
local function sb2() if P.sb2 then return P.sb2 end local p = r32(P.sb2ptr); if p >= 0x02000000 and p < 0x02040000 then return p end return nil end

local SUBSTRUCT = {
  [0] = { 0, 1, 2, 3 }, { 0, 1, 3, 2 }, { 0, 2, 1, 3 }, { 0, 3, 1, 2 }, { 0, 2, 3, 1 }, { 0, 3, 2, 1 },
  { 1, 0, 2, 3 }, { 1, 0, 3, 2 }, { 2, 0, 1, 3 }, { 3, 0, 1, 2 }, { 2, 0, 3, 1 }, { 3, 0, 2, 1 },
  { 1, 2, 0, 3 }, { 1, 3, 0, 2 }, { 2, 1, 0, 3 }, { 3, 1, 0, 2 }, { 2, 3, 0, 1 }, { 3, 2, 0, 1 },
  { 1, 2, 3, 0 }, { 1, 3, 2, 0 }, { 2, 1, 3, 0 }, { 3, 1, 2, 0 }, { 2, 3, 1, 0 }, { 3, 2, 1, 0 },
}

local function speciesName(id)
  if DATA and DATA.species[id] then return DATA.species[id] end
  return "Pokémon #" .. tostring(id)
end
local function moveName(id) if DATA and DATA.moves[id] then return DATA.moves[id] end return "Move #" .. id end
local function itemName(id) if DATA and DATA.items[id] then return DATA.items[id] end return "Item #" .. id end
local function abilityName(id) if DATA and DATA.abilities[id] then return DATA.abilities[id] end return nil end
local function mapsecName(id) if DATA and DATA.mapsecs[id] then return DATA.mapsecs[id] end return nil end

-- Decode a 100-byte party Pokémon. Returns nil if empty / invalid.
local function decodeMon(raw)
  if not raw or #raw < 100 then return nil end
  local pid, otid = string.unpack("<I4I4", raw)
  if pid == 0 and otid == 0 then return nil end
  local key = pid ~ otid
  local w = {}
  local sum = 0
  for i = 0, 11 do
    local v = (string.unpack("<I4", raw, 33 + i * 4)) ~ key
    w[i] = v
    sum = sum + (v & 0xFFFF) + (v >> 16)
  end
  local chk = string.unpack("<I2", raw, 29)
  local sel = SUBSTRUCT[pid % 24]
  local G, A, M = sel[1] * 3, sel[2] * 3, sel[4] * 3
  if (sum & 0xFFFF) ~= chk then
    -- Some hacks (CFRU "unencrypted" option, e.g. Pokemon Odyssey) store the data in plain order without checksum
    if chk ~= 0 then return nil end
    local lvl, hp, maxHP = raw:byte(85), string.unpack("<I2", raw, 87), string.unpack("<I2", raw, 89)
    if lvl < 1 or lvl > 100 or maxHP == 0 or hp > maxHP then return nil end
    for i = 0, 11 do w[i] = string.unpack("<I4", raw, 33 + i * 4) end
    G, A, M = 0, 3, 9
    local sp = w[0] & 0xFFFF
    if sp == 0 or not (DATA and DATA.species and DATA.species[sp]) then return nil end
  end
  local species = w[G] & 0xFFFF
  if species == 0 then return nil end
  local flags = raw:byte(20)
  local m = {
    pid = pid, otid = otid,
    species = species,
    item = w[G] >> 16,
    exp = w[G + 1],
    friendship = (w[G + 2] >> 8) & 0xFF,
    moves = { w[A] & 0xFFFF, w[A] >> 16, w[A + 1] & 0xFFFF, w[A + 1] >> 16 },
    metLocation = (w[M] >> 8) & 0xFF,
    metLevel = (w[M] >> 16) & 0x7F,
    isEgg = ((flags >> 2) & 1) == 1 or ((w[M + 1] >> 30) & 1) == 1,
    abilityNum = (w[M + 1] >> 31) & 1,
    nickRaw = decodeAt(raw, 9, 10),
    status = string.unpack("<I4", raw, 81),
    level = raw:byte(85),
    hp = string.unpack("<I2", raw, 87),
    maxHP = string.unpack("<I2", raw, 89),
  }
  m.speciesName = speciesName(species)
  m.nickname = m.nickRaw
  if m.isEgg then m.speciesName = "Egg" end
  m.key = string.format("%08x%08x", pid, otid)
  m.shiny = (((otid >> 16) ~ (otid & 0xFFFF) ~ (pid >> 16) ~ (pid & 0xFFFF)) < 8)
  m.nature = pid % 25
  m.gender = nil
  return m
end

local NATURES = { [0] = "Hardy", "Lonely", "Brave", "Adamant", "Naughty", "Bold", "Docile", "Relaxed", "Impish", "Lax",
  "Timid", "Hasty", "Serious", "Jolly", "Naive", "Modest", "Mild", "Quiet", "Bashful", "Rash", "Calm", "Gentle", "Sassy",
  "Careful", "Quirky" }

local function monDisplayName(m)
  if m.isEgg then return "Egg" end
  local nick = titleCase(m.nickname or "")
  local sp = titleCase(m.speciesName or "")
  if nick == "" or nick:upper() == sp:upper() then return sp end
  return nick .. " the " .. sp
end
local function monShort(m)
  if m.isEgg then return "Egg" end
  local nick = titleCase(m.nickname or "")
  local sp = titleCase(m.speciesName or "")
  if nick == "" or nick:upper() == sp:upper() then return sp end
  return nick
end

local function readParty(base, count)
  local out = {}
  for i = 0, (count or 6) - 1 do
    local m = decodeMon(rrange(base + i * 100, 100))
    if m then m.slot = i + 1; out[#out + 1] = m end
  end
  return out
end

local function monGender(m)
  if m.isEgg or not DATA or not DATA.genderRatio then return nil end
  local r = DATA.genderRatio[m.species]
  if r == nil then return nil end
  if r == 255 then return "genderless" end
  if r == 254 then return "female" end
  if r == 0 then return "male" end
  return ((m.pid & 0xFF) < r) and "female" or "male"
end

local function monPublic(m)
  local moves = {}
  for _, mv in ipairs(m.moves) do if mv ~= 0 then moves[#moves + 1] = titleCase(moveName(mv)) end end
  local status = nil
  local s = m.status or 0
  if m.hp == 0 then status = "FNT"
  elseif s & 0x7 ~= 0 then status = "SLP"
  elseif s & 0x8 ~= 0 then status = "PSN"
  elseif s & 0x10 ~= 0 then status = "BRN"
  elseif s & 0x20 ~= 0 then status = "FRZ"
  elseif s & 0x40 ~= 0 then status = "PAR"
  elseif s & 0x80 ~= 0 then status = "TOX" end
  return {
    slot = m.slot, species = titleCase(m.speciesName), speciesId = m.species, nickname = titleCase(m.nickname or ""),
    name = monShort(m), level = m.level, hp = m.hp, maxHP = m.maxHP, status = status, isEgg = m.isEgg,
    item = (m.item ~= 0) and titleCase(itemName(m.item)) or nil, moves = setmetatable(moves, json.arrayMT),
    nature = NATURES[m.nature], shiny = m.shiny or nil, gender = monGender(m),
    metAt = mapsecName(m.metLocation) and titleCase(mapsecName(m.metLocation)) or nil, metLevel = m.metLevel,
    friendship = m.friendship,
  }
end

---------------------------------------------------------------------------------------------------
-- Adventure state, events & persistence
---------------------------------------------------------------------------------------------------
local ADV = nil         -- { id, player, tid, file, events = {json lines}, seq }
local S = nil           -- last snapshot
local BATTLE = nil      -- active battle
local LASTBATTLE = nil  -- most recently finished battle
local PENDING_CATCH = nil
local FRAME = 0
local VISITED = {}

local function playTime()
  local b = sb2(); if not b then return nil end
  local h, m = r16(b + 0xE), r8(b + 0x10)
  return string.format("%d:%02d", h, m)
end

local function currentLocName()
  if S and S.loc then return S.loc end
  return nil
end

-- Is this folder there and writable? (Lua can't create folders without a shell command,
-- and starting one from inside mGBA isn't safe, so missing folders just fall back to the script's folder.)
local function ensureDir(path)
  local f = io.open(path .. ".keep", "a")
  if f then f:close(); return true end
  return false
end

-- Every event carries a revision number ("rev"). Updating an event (e.g. adding the outcome of a wild
-- encounter) gives it a new rev, so SillyTavern picks up changed events as well as new ones.
local function writeEventLine(line)
  if CFG.writeLogFile and ADV.file then
    local f = io.open(ADV.file, "a")
    if f then f:write(line, "\n"); f:close() end
  end
end

local function addEvent(etype, text, imp, data)
  if not ADV then return end
  ADV.seq = ADV.seq + 1
  ADV.rev = ADV.rev + 1
  local ev = {
    seq = ADV.seq, rev = ADV.rev, t = os.time(), pt = playTime(), type = etype, imp = imp or 1,
    text = text, loc = currentLocName(), data = data,
  }
  local line = json.encode(ev)
  ADV.events[#ADV.events + 1] = line
  ADV.index[ev.seq] = #ADV.events
  ADV.objs[ev.seq] = ev
  writeEventLine(line)
  log(text)
  return ev.seq
end

-- Change an event logged earlier in this session. The log file gets the new version appended
-- (when the file is read back, the last line for a given seq wins).
local function updateEvent(seq, text, imp, dataPatch)
  if not ADV or not seq then return false end
  local ev, idx = ADV.objs[seq], ADV.index[seq]
  if not ev or not idx then return false end
  ADV.rev = ADV.rev + 1
  ev.rev = ADV.rev
  if text then ev.text = text end
  if imp then ev.imp = imp end
  if dataPatch then
    ev.data = ev.data or {}
    for k, v in pairs(dataPatch) do ev.data[k] = v end
  end
  local line = json.encode(ev)
  ADV.events[idx] = line
  writeEventLine(line)
  log(ev.text)
  return true
end

local function sanitizeFile(s) return (s:gsub("[^%w%-_]", "_")) end

local function openAdventure(player, tid)
  local id = string.format("%s-%s-%05d", GAME.code ~= "" and GAME.code or "GBA", sanitizeFile(player ~= "" and player or "Player"), tid & 0xFFFF)
  if ADV and ADV.id == id then return false end
  ADV = { id = id, player = player, tid = tid & 0xFFFF, sid = tid >> 16, events = {}, seq = 0, rev = 0, index = {}, objs = {} }
  VISITED = {}
  local dir = SCRIPT_DIR .. "logs/"
  if not ensureDir(dir) then dir = SCRIPT_DIR end
  ADV.file = dir .. id .. ".jsonl"
  local f = io.open(ADV.file, "r")
  if f then
    for line in f:lines() do
      local seq = tonumber(line:match('"seq":(%d+)'))
      if seq then
        local rev = tonumber(line:match('"rev":(%d+)')) or seq
        if ADV.index[seq] then
          ADV.events[ADV.index[seq]] = line -- a later version of the same event
        else
          ADV.events[#ADV.events + 1] = line
          ADV.index[seq] = #ADV.events
        end
        if seq > ADV.seq then ADV.seq = seq end
        if rev > ADV.rev then ADV.rev = rev end
        if line:find('"type":"location"', 1, true) then
          local loc = line:match('"to":"(.-)"')
          if loc then VISITED[loc] = true end
        end
      end
    end
    f:close()
    log(string.format("Resumed adventure %s (%d events)", id, #ADV.events))
  else
    log("New adventure " .. id)
  end
  return true
end

---------------------------------------------------------------------------------------------------
-- Snapshot
---------------------------------------------------------------------------------------------------
local function readBadges()
  local b = sb1(); if not b then return 0 end
  local flags = b + P.flagsOff
  local mask = 0
  for i = 0, 7 do
    local f = P.badgeFlag + i
    if (r8(flags + (f >> 3)) >> (f & 7)) & 1 == 1 then mask = mask | (1 << i) end
  end
  return mask
end

local function popcount(x) local c = 0; while x ~= 0 do c = c + (x & 1); x = x >> 1 end; return c end

local function readMoney()
  local b1 = sb1(); if not b1 or not P.moneyOff then return nil end
  local v = r32(b1 + P.moneyOff)
  if P.moneyKeyOff then local b2 = sb2(); if b2 then v = v ~ r32(b2 + P.moneyKeyOff) end end
  if v > 999999 then return nil end
  return v
end

local function readLocation()
  local b = sb1(); if not b then return nil end
  local group, num = r8(b + 4), r8(b + 5)
  local mapsec, name = nil, nil
  if P.mapHeader then
    local layout = r32(P.mapHeader)
    if layout >= 0x08000000 and layout < 0x0A000000 then
      mapsec = r8(P.mapHeader + 0x14)
      name = mapsecName(mapsec)
    end
  end
  if name then name = titleCase(name) end
  return { group = group, num = num, mapsec = mapsec, name = name or string.format("Map %d.%d", group, num) }
end

-- Bag ----------------------------------------------------------------------------------------------
-- Pockets are {u16 item, u16 quantity XOR key}. Their layout comes from the ROM header (pocket sizes
-- and the PC-items offset); hacks that moved the bag elsewhere are found by scanning for item slots.
local BAG = { regions = nil, gen = 0, lastScan = -100000, itemMax = 0 }

local function bagKey()
  local b2 = sb2(); if not b2 then return 0 end
  if P.family == "FR" then return r32(b2 + 0xF20) & 0xFFFF end
  if P.family == "E" then return r32(b2 + 0xAC) & 0xFFFF end
  return 0
end

local function headerPockets()
  if not (P.family == "E" or P.family == "FR") then return nil end
  local c = {}
  for i = 0, 5 do c[i] = emu.memory.cart0:read8(0x1E4 + i) end
  local pcOff = emu.memory.cart0:read32(0x1EC)
  if pcOff == 0 or pcOff > 0x4000 then return nil end
  local off = pcOff + c[5] * 4
  local regions = {}
  for i = 0, 4 do
    if c[i] > 0 then regions[#regions + 1] = { off = off, n = c[i], rel = true, key = (i == 1) } end
    off = off + c[i] * 4
  end
  return regions
end

local function readRegions(regions, key)
  local items, keys, used, bad = {}, {}, 0, 0
  local b1 = sb1()
  for _, reg in ipairs(regions) do
    local base = reg.rel and (b1 and b1 + reg.off) or (not reg.rel and reg.off)
    if base then
      local raw = rrange(base, reg.n * 4)
      for k = 0, reg.n - 1 do
        local id, q = string.unpack("<I2I2", raw, k * 4 + 1)
        if id ~= 0 then
          q = q ~ key
          if id < BAG.itemMax and q >= 1 and q <= 999 then
            items[id] = (items[id] or 0) + q; used = used + 1
            if reg.key then keys[id] = true end
          else
            bad = bad + 1
          end
        end
      end
    end
  end
  return items, keys, used, bad
end

local function scanForBag(key)
  local b1 = sb1()
  local ew = rrange(0x02000000, 0x40000)
  local regions, total = {}, 0
  local a = 0
  while a <= #ew - 16 do
    local n = 0
    while a + n * 4 + 4 <= #ew do
      local id, q = string.unpack("<I2I2", ew, a + n * 4 + 1)
      q = q ~ key
      if id >= 1 and id < BAG.itemMax and q >= 1 and q <= 999 then n = n + 1 else break end
    end
    if n >= 4 then
      local addr = 0x02000000 + a
      if b1 and addr >= b1 and addr < b1 + 0x4000 then
        regions[#regions + 1] = { off = addr - b1, n = n, rel = true }
      else
        regions[#regions + 1] = { off = addr, n = n, rel = false }
      end
      total = total + n
      a = a + n * 4
    else
      a = a + 4
    end
    if total > 1000 then break end
  end
  if total >= 6 then return regions end
  return nil
end

local function readBag(progressed)
  if BAG.itemMax == 0 then return nil end
  local key = bagKey()
  if not BAG.regions then
    local hp = headerPockets()
    if hp then
      local _, _, used, bad = readRegions(hp, key)
      -- an all-empty bag in a game that is clearly under way means the hack moved the bag
      if bad == 0 and (used > 0 or not progressed) then BAG.regions = hp; BAG.gen = BAG.gen + 1 end
    end
    if not BAG.regions and FRAME - BAG.lastScan > 1800 then
      BAG.lastScan = FRAME
      local found = scanForBag(key)
      if found then BAG.regions = found; BAG.gen = BAG.gen + 1; log("Bag found by scanning memory (this game moved it)") end
    end
    if not BAG.regions then return nil end
  end
  local items, keys = readRegions(BAG.regions, key)
  return { items = items, keys = keys, gen = BAG.gen }
end

-- PC boxes (gPokemonStoragePtr sits right after gSaveBlock2Ptr): set of personality values
local function storagePids()
  if not P.sb2ptr then return nil end
  local st = r32(P.sb2ptr + 4)
  if st < 0x02000000 or st >= 0x02040000 then return nil end
  local raw = rrange(st + 4, 14 * 30 * 80)
  local set = {}
  for k = 0, 14 * 30 - 1 do
    local pid = string.unpack("<I4", raw, k * 80 + 1)
    if pid ~= 0 then set[pid] = true end
  end
  return set
end
local PCSET = nil

local function readLayoutId()
  if not P.mapHeader then return nil end
  local l = r32(P.mapHeader)
  if l < 0x08000000 or l >= 0x0A000000 then return nil end
  return r16(P.mapHeader + 0x12)
end

local function takeSnapshot()
  local b2 = sb2()
  if not b2 then return nil end
  local player = decodeAt(rrange(b2, 8), 1, 8)
  local tid = r32(b2 + 0xA)
  local count = r8(P.partyCount)
  if count > 6 then count = 6 end
  local party = readParty(P.party, count)
  local loc = readLocation()
  local snap = {
    player = player, tid = tid, party = party, badges = readBadges(),
    location = loc, loc = loc and loc.name, money = readMoney(), layout = readLayoutId(),
  }
  local okBag, bag = pcall(readBag, snap.badges ~= 0 or #party >= 2)
  if okBag then snap.bag = bag end
  return snap
end

---------------------------------------------------------------------------------------------------
-- Battles
---------------------------------------------------------------------------------------------------
local function trainerInfo(id)
  if not DATA or not DATA.trainers or not DATA.trainers[id] then return nil end
  local t = DATA.trainers[id]
  local cls = DATA.trainerClasses[t.c] or ""
  local name = t.n or ""
  if P.rivalNameOff and (name == "TERRY" or cls == "RIVAL") then
    local b = sb1()
    if b then
      local rn = decodeAt(rrange(b + P.rivalNameOff, 8), 1, 8)
      if rn ~= "" then name = rn end
    end
  end
  cls = cls:gsub("PKMN", "Pokémon")
  return { id = id, class = titleCase(cls), name = titleCase(name), rawClass = cls }
end

local function trainerImportance(info)
  if not info then return 1 end
  local c = (info.rawClass or ""):upper()
  if c:find("LEADER") or c:find("ELITE") or c:find("CHAMPION") or c:find("BOSS") or c:find("FRONTIER BRAIN") then return 3 end
  if c:find("RIVAL") or c:find("ADMIN") or (info.name or ""):upper():find("WALLY") then return 2 end
  return 1
end

local function enemyListText(list)
  local parts = {}
  for _, m in ipairs(list) do parts[#parts + 1] = string.format("%s Lv%d", titleCase(m.speciesName), m.level) end
  return table.concat(parts, ", ")
end

-- Wild battles: log the encounter when it starts, fill in the result when it ends
local function wildEncounterText(lead, result)
  local bits = { "Lv" .. lead.level }
  if NATURES[lead.nature] then bits[#bits + 1] = NATURES[lead.nature] .. " nature" end
  local t = string.format("Encountered a wild %s%s (%s)", lead.shiny and "shiny " or "", titleCase(lead.speciesName), table.concat(bits, ", "))
  if result then t = t .. " — " .. result end
  return t
end

local function logWildEncounter(B)
  local lead = B.enemies and B.enemies[1]
  if B.isTrainer or not lead or not CFG.logWildBattles then return end
  B.encounterSeq = addEvent("wild_encounter", wildEncounterText(lead), lead.shiny and 3 or 0, {
    species = titleCase(lead.speciesName), level = lead.level, nature = NATURES[lead.nature],
    shiny = lead.shiny or nil, gender = monGender(lead), double = B.isDouble or nil,
  })
end

local function startBattle(enemyLead)
  local flags = r32(P.battleType)
  local isTrainer = (flags & 0x8) ~= 0
  local enemies = readParty(P.enemy, 6)
  if #enemies == 0 then enemies = { enemyLead } end
  BATTLE = {
    flags = flags, isTrainer = isTrainer, isDouble = (flags & 0x1) ~= 0, isSafari = (flags & 0x80) ~= 0,
    enemies = enemies, startFrame = FRAME, loc = currentLocName(), fainted = {},
  }
  if isTrainer then
    local id = r16(P.opponentA)
    BATTLE.trainerId = id
    BATTLE.trainer = trainerInfo(id)
  end
  logWildEncounter(BATTLE)
end

local function trainerLabel(t, id)
  if not t then return "a trainer (#" .. tostring(id) .. ")" end
  if t.class ~= "" and t.name ~= "" then return t.class .. " " .. t.name end
  return (t.name ~= "" and t.name) or t.class
end

local function endBattle(outcome)
  local B = BATTLE
  BATTLE = nil
  if not B then return end
  B.outcome = outcome
  LASTBATTLE = B
  local lead = B.enemies[1]
  local data = {
    kind = B.isTrainer and "trainer" or "wild", outcome = outcome,
    enemies = {}, double = B.isDouble or nil,
  }
  for _, m in ipairs(B.enemies) do data.enemies[#data.enemies + 1] = { species = titleCase(m.speciesName), level = m.level } end

  if B.isTrainer then
    local who = trainerLabel(B.trainer, B.trainerId)
    local imp = trainerImportance(B.trainer)
    data.trainer = B.trainer and (B.trainer.class .. " " .. B.trainer.name) or nil
    data.trainerClass = B.trainer and B.trainer.class or nil
    data.trainerId = B.trainerId
    local team = enemyListText(B.enemies)
    if outcome == 1 then
      addEvent("battle_won", string.format("Defeated %s (%s)", who, team), imp, data)
      local c = B.trainer and (B.trainer.rawClass or ""):upper() or ""
      if c:find("CHAMPION") then
        addEvent("champion", "Defeated the Champion and entered the Hall of Fame!", 3, data)
      end
    elseif outcome == 2 or outcome == 9 then
      addEvent("battle_lost", string.format("Lost to %s (%s) and blacked out", who, team), math.max(imp, 2), data)
    elseif outcome == 3 then
      addEvent("battle_draw", string.format("Battle with %s ended in a draw", who), imp, data)
    else
      addEvent("battle_end", string.format("Battle with %s ended", who), imp, data)
    end
  else
    if outcome == 7 then PENDING_CATCH = { mon = lead, frame = FRAME, loc = B.loc, data = data } end
    if not lead then return end
    local results = {
      [1] = { "defeated it", "defeated" }, [2] = { "blacked out", "lost" }, [9] = { "blacked out", "lost" },
      [4] = { "ran away", "ran" }, [5] = { "ran away", "ran" }, [6] = { "it fled", "fled" }, [10] = { "it fled", "fled" },
      [7] = { "caught it!", "caught" }, [8] = { "ran out of Safari Balls", "fled" },
    }
    local r = results[outcome]
    if not r then return end
    local imp = lead.shiny and 3 or ((outcome == 2 or outcome == 9) and 2 or 0)
    local patch = { result = r[1], outcome = r[2] }
    if CFG.logWildBattles or outcome == 2 or outcome == 9 then
      -- update the encounter logged at the start; if it wasn't (script started mid-battle), log it now
      if not updateEvent(B.encounterSeq, wildEncounterText(lead, r[1]), imp, patch) then
        addEvent("wild_encounter", wildEncounterText(lead, r[1]), imp, {
          species = titleCase(lead.speciesName), level = lead.level, nature = NATURES[lead.nature],
          shiny = lead.shiny or nil, gender = monGender(lead), result = r[1], outcome = r[2],
        })
      end
    end
  end
end

---------------------------------------------------------------------------------------------------
-- Diffing
---------------------------------------------------------------------------------------------------
local function indexByKey(list) local t = {} for _, m in ipairs(list) do t[m.key] = m end return t end

local function partySummary(party)
  local parts = {}
  for _, m in ipairs(party) do
    parts[#parts + 1] = m.isEgg and "Egg" or string.format("%s Lv%d", monDisplayName(m), m.level)
  end
  return table.concat(parts, ", ")
end

local function resolveCatch(m, toPC)
  local pc = PENDING_CATCH
  PENDING_CATCH = nil
  local lead = pc.mon
  local where = pc.loc and (" at " .. pc.loc) or ""
  local text
  if m then
    text = string.format("Caught %s (Lv%d)%s", monDisplayName(m), m.level, where)
  else
    text = string.format("Caught a %s (Lv%d)%s and sent it to the PC", titleCase(lead.speciesName), lead.level, where)
  end
  local data = pc.data or {}
  data.species = titleCase(lead.speciesName); data.level = lead.level; data.nickname = m and titleCase(m.nickname) or nil
  data.toPC = toPC or nil
  addEvent("catch", text, (lead.shiny and 3) or 2, data)
end

local function diffParty(old, new)
  local oldBy, newBy = indexByKey(old), indexByKey(new)
  -- arrivals
  for _, m in ipairs(new) do
    local o = oldBy[m.key]
    if not o then
      if not PENDING_CATCH and BATTLE then
        -- caught mid-battle: the mon is copied to the party before the battle is over
        for _, e in ipairs(BATTLE.enemies) do
          if e.pid == m.pid then PENDING_CATCH = { mon = e, frame = FRAME, loc = BATTLE.loc, data = { kind = "wild" } } end
        end
      end
      if PENDING_CATCH and PENDING_CATCH.mon and PENDING_CATCH.mon.pid == m.pid then
        PENDING_CATCH.found = m
        PENDING_CATCH.foundFrame = FRAME
      elseif m.isEgg then
        addEvent("party_join", "Received a Pokémon Egg", 2, { egg = true })
      elseif PCSET and PCSET[m.pid] then
        addEvent("pc_withdraw", string.format("Withdrew %s (Lv%d) from the PC", monDisplayName(m), m.level), 1,
          { species = titleCase(m.speciesName), level = m.level })
      else
        addEvent("party_join", string.format("%s (Lv%d) joined the party", monDisplayName(m), m.level), 2,
          { species = titleCase(m.speciesName), level = m.level })
      end
    else
      -- same Pokémon, look for changes
      local name = monShort(m)
      if o.isEgg and not m.isEgg then
        addEvent("hatch", string.format("An Egg hatched into %s!", titleCase(m.speciesName)), 2, { species = titleCase(m.speciesName) })
      elseif o.species ~= m.species and not m.isEgg then
        addEvent("evolution", string.format("%s evolved into %s!", monShort(o), titleCase(m.speciesName)), 2,
          { from = titleCase(o.speciesName), to = titleCase(m.speciesName) })
      end
      if m.level > o.level and not m.isEgg then
        addEvent("level_up", string.format("%s grew to Lv%d", name, m.level), (m.level % 10 == 0) and 2 or 1,
          { name = name, level = m.level, from = o.level })
      end
      local justCaught = PENDING_CATCH and PENDING_CATCH.found and PENDING_CATCH.found.key == m.key
      if o.nickname ~= m.nickname and o.species == m.species and not m.isEgg and not o.isEgg and not justCaught then
        addEvent("nickname", string.format("%s was nicknamed %s", titleCase(o.nickname), titleCase(m.nickname)), 1, nil)
      end
      if o.hp > 0 and m.hp == 0 and m.maxHP > 0 then
        local by = ""
        if BATTLE then
          if BATTLE.isTrainer then by = " against " .. trainerLabel(BATTLE.trainer, BATTLE.trainerId)
          elseif BATTLE.enemies[1] then by = " against a wild " .. titleCase(BATTLE.enemies[1].speciesName) end
          BATTLE.fainted[#BATTLE.fainted + 1] = name
        end
        addEvent("faint", string.format("%s fainted%s", name, by), 2, { name = name })
      end
      if CFG.logMoveChanges and not m.isEgg then
        local had = {}
        for _, mv in ipairs(o.moves) do if mv ~= 0 then had[mv] = true end end
        local has = {}
        for _, mv in ipairs(m.moves) do if mv ~= 0 then has[mv] = true end end
        local learned, forgot = {}, {}
        for mv in pairs(has) do if not had[mv] then learned[#learned + 1] = titleCase(moveName(mv)) end end
        for mv in pairs(had) do if not has[mv] then forgot[#forgot + 1] = titleCase(moveName(mv)) end end
        if #learned > 0 and o.species == m.species then
          local t = string.format("%s learned %s", name, table.concat(learned, " and "))
          if #forgot > 0 then t = t .. " (forgot " .. table.concat(forgot, ", ") .. ")" end
          addEvent("move_learned", t, 1, { name = name, learned = learned, forgot = forgot })
        end
      end
    end
  end
  -- departures
  local nowInPC = nil
  for _, o in ipairs(old) do
    if not newBy[o.key] then
      if nowInPC == nil then nowInPC = storagePids() or false end
      if nowInPC and nowInPC[o.pid] then
        addEvent("pc_deposit", string.format("Deposited %s (Lv%d) in the PC", monDisplayName(o), o.level), 1,
          { species = titleCase(o.speciesName), level = o.level })
      else
        addEvent("party_leave", string.format("%s (Lv%d) left the party", monDisplayName(o), o.level), 1,
          { species = titleCase(o.speciesName), level = o.level })
      end
    end
  end
  if nowInPC then PCSET = nowInPC end

  -- whole party healed (Pokémon Center, Mom, healing NPCs): several hurt Pokémon all back to full at once
  if not BATTLE and #new > 0 then
    local healed, allFull = 0, true
    for _, m in ipairs(new) do
      if not m.isEgg then
        if m.hp < m.maxHP or (m.status or 0) ~= 0 then allFull = false end
        local o = oldBy[m.key]
        if o and o.level == m.level and (o.hp < o.maxHP or (o.status or 0) ~= 0) and m.hp == m.maxHP and (m.status or 0) == 0 then
          healed = healed + 1
        end
      end
    end
    if allFull and (healed >= 2 or (healed == 1 and #new == 1)) then
      addEvent("heal", "The whole party was healed", 1, { healed = healed })
    end
  end
end

local BADGES_ORDINAL = { "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth" }

-- Shopping & key items ------------------------------------------------------------------------------
local MART_LAYOUTS = {}
local SHOP = nil
local function martFile() return (ensureDir(SCRIPT_DIR .. "data/") and (SCRIPT_DIR .. "data/") or (SCRIPT_DIR .. "notebook_")) .. "marts_" .. sanitizeFile(GAME.code .. "_" .. GAME.crc) .. ".txt" end
local function loadMarts()
  MART_LAYOUTS = {}
  local f = io.open(martFile(), "r")
  if f then for line in f:lines() do local n = tonumber(line); if n then MART_LAYOUTS[n] = true end end; f:close() end
end
local function learnMart(layout)
  if not layout or MART_LAYOUTS[layout] then return end
  MART_LAYOUTS[layout] = true
  local f = io.open(martFile(), "a")
  if f then f:write(layout, "\n"); f:close() end
end

local function itemPhrase(id, qty)
  local name = titleCase(itemName(id))
  if qty == 1 then
    return ((name:match("^[AEIOUaeiou]") and "an " or "a ") .. name)
  end
  local plural = name
  if not name:match("[sS]$") then
    if name:match("[^aeiouAEIOU]y$") then plural = name:sub(1, -2) .. "ies"
    elseif name:match("[^aeiouAEIOU]Y$") then plural = name:sub(1, -2) .. "IES"
    elseif name:match("%u$") and not name:match("%l") then plural = name .. "S"
    else plural = name .. "s" end
  end
  return ((qty <= 5) and "some " or "many ") .. plural
end

local function listPhrase(t)
  local parts = {}
  local ids = {}
  for id in pairs(t) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do parts[#parts + 1] = itemPhrase(id, t[id]) end
  if #parts <= 1 then return parts[1] or "" end
  return table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
end

local function shopText(sh)
  local t = "Visited the Poké Mart in " .. (sh.where or "?")
  local b, so = next(sh.bought) ~= nil, next(sh.sold) ~= nil
  if b then t = t .. " and bought " .. listPhrase(sh.bought) end
  if so then t = t .. (b and ", and sold " or " and sold ") .. listPhrase(sh.sold) end
  return t
end

local function diffItems(old, new)
  local mapKey = new.location and (new.location.group .. "." .. new.location.num) or "?"
  local oldKey = old.location and (old.location.group .. "." .. old.location.num) or "?"
  if mapKey ~= oldKey then
    SHOP = nil
    if new.layout and MART_LAYOUTS[new.layout] then
      SHOP = { map = mapKey, where = new.loc, bought = {}, sold = {} }
      SHOP.seq = addEvent("shop", shopText(SHOP), 0, { visit = true })
    end
  end
  if BATTLE or not old.bag or not new.bag or old.bag.gen ~= new.bag.gen then return end
  local gains, losses = {}, {}
  for id, q in pairs(new.bag.items) do
    local d = q - (old.bag.items[id] or 0)
    if d > 0 then gains[id] = d end
  end
  for id, q in pairs(old.bag.items) do
    local d = q - (new.bag.items[id] or 0)
    if d > 0 then losses[id] = d end
  end
  -- key items
  for id in pairs(gains) do
    if not old.bag.items[id] and (DATA.keyItems[id] or new.bag.keys[id]) then
      addEvent("key_item", "Obtained the " .. titleCase(itemName(id)) .. " (key item)", 2, { item = titleCase(itemName(id)) })
      gains[id] = nil
    end
  end
  local dm = (new.money and old.money) and (new.money - old.money) or 0
  local bought = (dm < 0 and next(gains) ~= nil)
  local sold = (dm > 0 and next(losses) ~= nil)
  if not bought and not sold then return end
  if not SHOP or SHOP.map ~= mapKey then
    SHOP = { map = mapKey, where = new.loc, bought = {}, sold = {} }
  end
  learnMart(new.layout)
  if bought then for id, d in pairs(gains) do SHOP.bought[id] = (SHOP.bought[id] or 0) + d end end
  if sold then for id, d in pairs(losses) do SHOP.sold[id] = (SHOP.sold[id] or 0) + d end end
  local data = { visit = true, spent = nil }
  if SHOP.seq and updateEvent(SHOP.seq, shopText(SHOP), 1, data) then return end
  SHOP.seq = addEvent("shop", shopText(SHOP), 1, data)
end

local function diffSnapshot(old, new)
  -- location
  if new.location and (not old.location or new.location.name ~= old.location.name) then
    local to = new.location.name
    local first = not VISITED[to]
    VISITED[to] = true
    if not (new.location.name or ""):match("^Map %d") or not new.location.mapsec then
      addEvent("location", (first and "Arrived at " or "Returned to ") .. to .. (first and " for the first time" or ""),
        first and 1 or 0, { from = old.location and old.location.name or nil, to = to, first = first })
    end
  end
  -- badges
  local gained = new.badges & ~old.badges
  if gained ~= 0 then
    local names = CFG.badgeNames or P.badges or {}
    for i = 0, 7 do
      if (gained >> i) & 1 == 1 then
        local bn = names[i + 1] and (names[i + 1] .. " Badge") or ("Badge #" .. (i + 1))
        addEvent("badge", string.format("Earned the %s! (%d/8 badges)", bn, popcount(new.badges)), 3,
          { badge = bn, index = i + 1, total = popcount(new.badges) })
      end
    end
  end
  diffParty(old.party, new.party)
  local okItems, errItems = pcall(diffItems, old, new)
  if not okItems then dbg("diffItems: " .. tostring(errItems)) end
end

---------------------------------------------------------------------------------------------------
-- RAM layout check & auto-discovery (decomp-built romhacks move everything around)
---------------------------------------------------------------------------------------------------
local RAMSTATE = { verified = false, lastTry = -100000, mode = "?" }
local function isRomPtr(x) return x >= 0x08000000 and x < 0x0A000000 end
local function isEwramPtr(x) return x >= 0x02000000 and x < 0x0203FFF0 end

local function validMapHeaderAt(a)
  if not a then return false end
  local l, e, sc, c = r32(a), r32(a + 4), r32(a + 8), r32(a + 12)
  if not (isRomPtr(l) and isRomPtr(e) and isRomPtr(sc) and (c == 0 or isRomPtr(c))) then return false end
  local w, h = r32(l), r32(l + 4)
  if w < 1 or w > 1024 or h < 1 or h > 1024 then return false end
  -- border and map data must be ROM pointers (tilesets can live elsewhere in some hacks)
  if not isRomPtr(r32(l + 8)) or not isRomPtr(r32(l + 12)) then return false end
  return true
end

-- Does the memory profile match this game? true = yes, false = no, nil = can't tell yet (title screen)
local function verifyProfile()
  local cnt = r8(P.partyCount)
  local b2 = sb2()
  if cnt > 6 or not b2 then return false end
  local tid = r32(b2 + 0xA)
  local name = decodeAt(rrange(b2, 8), 1, 8)
  if cnt >= 1 then
    for _, m in ipairs(readParty(P.party, cnt)) do if m.otid == tid then return true end end
    return false
  end
  if tid == 0 and name == "" then return nil end
  if validMapHeaderAt(P.mapHeader) and name ~= "" then return true end
  return false
end

local function discoverRAM()
  local ew = rrange(0x02000000, 0x40000)
  -- 1) party: runs of valid 100-byte Pokémon with the party count 3 bytes before (Emerald layout)
  --    or 603 bytes before (FireRed layout: count, enemy party, player party)
  local cands = {}
  local a = 0
  local size = #ew
  while a <= size - 100 do
    local lang, fl = ew:byte(a + 19), ew:byte(a + 20)
    local m = nil
    if lang and lang >= 1 and lang <= 7 and (fl & 0x02) ~= 0 then m = decodeMon(ew:sub(a + 1, a + 100)) end
    if m then
      local n, otids = 1, { [m.otid] = true }
      while n < 6 do
        local m2 = decodeMon(ew:sub(a + n * 100 + 1, a + n * 100 + 100))
        if not m2 then break end
        otids[m2.otid] = true
        n = n + 1
      end
      local addr = 0x02000000 + a
      if a >= 3 and ew:byte(a - 3 + 1) == n then cands[#cands + 1] = { party = addr, partyCount = addr - 3, enemy = addr + 600, otids = otids } end
      if a >= 603 and ew:byte(a - 603 + 1) == n then cands[#cands + 1] = { party = addr, partyCount = addr - 603, enemy = addr - 600, otids = otids } end
      a = a + n * 100
    else
      a = a + 4
    end
  end
  if #cands == 0 then return nil end
  -- 2) save block pointers (IWRAM): gSaveBlock2Ptr -> trainer ID matches the party's OT
  local iw = rrange(0x03000000, 0x8000)
  local found = nil
  for i = 4, #iw - 4, 4 do
    local p = string.unpack("<I4", iw, i + 1)
    if isEwramPtr(p) then
      local off = p - 0x02000000 + 0xA
      if off + 4 <= size then
        local tid = string.unpack("<I4", ew, off + 1)
        for _, c in ipairs(cands) do
          if c.otids[tid] and decodeAt(ew, p - 0x02000000 + 1, 8) ~= "" then
            local p1 = string.unpack("<I4", iw, i - 4 + 1)
            if isEwramPtr(p1) then
              found = c; found.sb2ptr = 0x03000000 + i; found.sb1ptr = 0x03000000 + i - 4
              break
            end
          end
        end
      end
    end
    if found then break end
  end
  if not found then return nil end
  -- 3) gMapHeader (EWRAM): a copy of the current map's header, validated against the ROM
  for i = 0, size - 0x20, 4 do
    local l = string.unpack("<I4", ew, i + 1)
    if isRomPtr(l) and validMapHeaderAt(0x02000000 + i) then found.mapHeader = 0x02000000 + i; break end
  end
  return found
end

local function ensureRAM()
  if RAMSTATE.verified then return true end
  if FRAME - RAMSTATE.lastTry < 300 then return false end
  RAMSTATE.lastTry = FRAME
  local v = verifyProfile()
  if v == true then
    RAMSTATE.verified = true; RAMSTATE.mode = "profile"
    log("Memory layout: " .. P.name .. " (exact battle tracking)")
    return true
  end
  if v == nil then return false end
  local ok, f = pcall(discoverRAM)
  if ok and f then
    P.party, P.partyCount, P.enemy = f.party, f.partyCount, f.enemy
    P.sb1ptr, P.sb2ptr, P.sb1, P.sb2 = f.sb1ptr, f.sb2ptr, nil, nil
    P.mapHeader = f.mapHeader
    P.heuristic = true
    RAMSTATE.verified = true; RAMSTATE.mode = "auto"
    GAME.profileName = P.name .. " (auto-detected RAM)"
    log(string.format("Memory layout auto-detected: party %08X, save blocks %08X/%08X, map header %s. Battles are tracked from the enemy party.",
      f.party, f.sb1ptr, f.sb2ptr, f.mapHeader and string.format("%08X", f.mapHeader) or "not found"))
    return true
  elseif not ok then
    warn("RAM discovery failed: " .. tostring(f))
  end
  return false
end

-- Heuristic battle tracking (used when the battle variables' addresses are unknown)
local HB = { lastEnemy = nil }
local TRAINER_TEXT = nil
local function trainerTextMatches()
  if not DATA or not DATA.trainers then return {} end
  if not TRAINER_TEXT then
    TRAINER_TEXT = {}
    local seen = {}
    for id, t in pairs(DATA.trainers) do
      if type(t) == "table" and t.r and #t.r > 4 and not seen[t.r] then
        seen[t.r] = true; TRAINER_TEXT[#TRAINER_TEXT + 1] = { raw = t.r, id = id }
      end
    end
    table.sort(TRAINER_TEXT, function(x, y) return #x.raw > #y.raw end)
  end
  local ram = rrange(0x02000000, 0x40000)
  local out = {}
  for _, e in ipairs(TRAINER_TEXT) do
    if ram:find(e.raw, 1, true) then out[e.raw] = e.id end
  end
  return out
end

-- No trainer table? Read "<CLASS> <NAME>" straight out of the battle text in RAM
local function trainerTextFromClasses()
  if not DATA or not DATA.classRaw then return {} end
  local ram = rrange(0x02000000, 0x40000)
  local out = {}
  for ci, raw in pairs(DATA.classRaw) do
    if #raw >= 3 then
      local init = 1
      while true do
        local i = ram:find(raw .. "\0", init, true)
        if not i then break end
        init = i + 1
        local nameStart = i + #raw + 1
        if isNameAt(ram, nameStart, 13) then
          local name = decodeAt(ram, nameStart, 13)
          name = name:match("^(.-)%s*$")
          if name ~= "" then out[ci .. ":" .. name] = { class = ci, name = name } end
        end
      end
    end
  end
  return out
end

local function inPC(pid)
  local b2p = P.sb2ptr and (P.sb2ptr + 4)
  if not b2p then return false end
  local st = r32(b2p)
  if not isEwramPtr(st) then return false end
  local boxes = rrange(st + 4, 14 * 30 * 80)
  local needle = string.pack("<I4", pid)
  local init = 1
  while true do
    local i = boxes:find(needle, init, true)
    if not i then return false end
    if (i - 1) % 80 == 0 then return true end
    init = i + 1
  end
end

local function playerPos()
  local b = sb1(); if not b then return "" end
  return string.format("%d,%d,%d,%d", r16(b), r16(b + 2), r8(b + 4), r8(b + 5))
end

---------------------------------------------------------------------------------------------------
-- Main tick
---------------------------------------------------------------------------------------------------
local READY = false
local function looksLikeNewSave(old, new)
  if old.tid ~= new.tid or old.player ~= new.player then return true end
  local oldBy = indexByKey(old.party)
  local changed = 0
  for _, m in ipairs(new.party) do if not oldBy[m.key] then changed = changed + 1 end end
  return changed >= 3 and #old.party > 0
end

local function heuristicBattle(snap)
  local enemies = readParty(P.enemy, 6)
  local lead = enemies[1]
  local pos = playerPos()
  if lead and lead.key ~= HB.lastEnemy then
    HB.lastEnemy = lead.key
    if BATTLE then endBattle(BATTLE.isTrainer and 0 or 4) end
    local isTrainer = lead.otid ~= snap.tid -- wild Pokémon carry the player's trainer ID
    BATTLE = { isTrainer = isTrainer, enemies = enemies, startFrame = FRAME, loc = currentLocName(), fainted = {}, pos = pos, heuristic = true, textTries = 0 }
    logWildEncounter(BATTLE)
    if isTrainer then BATTLE.textBaseline = trainerTextMatches(); BATTLE.classBaseline = trainerTextFromClasses() end
    return
  end
  if not BATTLE then return end
  if #enemies > 0 then BATTLE.enemies = enemies end
  if BATTLE.isTrainer and not BATTLE.trainer and BATTLE.textTries < 10 then
    BATTLE.textTries = BATTLE.textTries + 1
    -- 1) any "<CLASS> <NAME>" text that wasn't in RAM before the battle (works without a trainer table)
    for key, v in pairs(trainerTextFromClasses()) do
      if not BATTLE.classBaseline[key] then
        local cls = ((DATA.trainerClasses[v.class] or ""):gsub("PKMN", "Pokémon"))
        BATTLE.trainer = { class = titleCase(cls), name = titleCase(v.name), rawClass = cls }
        break
      end
    end
    -- 2) a trainer from the ROM table whose class + name newly appeared
    if not BATTLE.trainer then
      for raw, id in pairs(trainerTextMatches()) do
        if not BATTLE.textBaseline[raw] then BATTLE.trainer = trainerInfo(id); BATTLE.trainerId = id; break end
      end
    end
  end
  local allFoe = #BATTLE.enemies > 0
  for _, e in ipairs(BATTLE.enemies) do if e.hp > 0 then allFoe = false end end
  local allMine = #snap.party > 0
  for _, m in ipairs(snap.party) do if not m.isEgg and m.hp > 0 then allMine = false end end
  local wildLead = (not BATTLE.isTrainer) and BATTLE.enemies[1] or nil
  local caught = false
  if wildLead then for _, m in ipairs(snap.party) do if m.pid == wildLead.pid then caught = true end end end
  if allMine then endBattle(2)
  elseif caught then endBattle(7)
  elseif allFoe then endBattle(1)
  elseif pos ~= BATTLE.pos then
    if wildLead and inPC(wildLead.pid) then endBattle(7)
    elseif wildLead then endBattle(4)
    else endBattle(0) end
  end
end

local function tick()
  if not READY then return end
  if not ensureRAM() then return end
  local snap = takeSnapshot()
  if FRAME < 400 then dbg("tick ok at frame " .. FRAME) end
  if not snap then return end
  -- wait for a real save (title screen / new game intro have no trainer yet)
  if snap.tid == 0 and snap.player == "" then return end

  local isNewAdventure = openAdventure(snap.player, snap.tid)
  if isNewAdventure or not S or looksLikeNewSave(S, snap) then
    S = snap
    BATTLE = nil
    PENDING_CATCH = nil
    local verb = (#ADV.events == 0) and "began" or "resumed"
    addEvent("session", string.format("%s's adventure %s at %s. Party: %s", titleCase(snap.player), verb, snap.loc or "?", #snap.party > 0 and partySummary(snap.party) or "none yet"), 0,
      { party = partySummary(snap.party), badges = popcount(snap.badges) })
    if snap.location then VISITED[snap.location.name] = true end
    local lead = decodeMon(rrange(P.enemy, 100))
    HB.lastEnemy = lead and lead.key or nil
    return
  end

  if P.heuristic then
    heuristicBattle(snap)
  else
  -- battles
  local outcome = r8(P.outcome)
  local enemyLead = decodeMon(rrange(P.enemy, 100))
  local active = (outcome == 0) and (enemyLead ~= nil)
  if active and not BATTLE then
    startBattle(enemyLead)
  elseif BATTLE and not active then
    endBattle(outcome)
  elseif BATTLE then
    -- refresh enemy party (trainer may send out more, wild species known)
    local enemies = readParty(P.enemy, 6)
    if #enemies > 0 then BATTLE.enemies = enemies end
  end
  end

  diffSnapshot(S, snap)
  S = snap
  -- remember who is in the PC (after diffing, so a withdrawal is still recognised this tick)
  if not BATTLE and (PCSET == nil or FRAME % 120 < CFG.pollFrames) then PCSET = storagePids() or PCSET end

  -- resolve catches
  if PENDING_CATCH then
    local pc = PENDING_CATCH
    if pc.found then
      -- give the player time to nickname it
      local current = nil
      for _, m in ipairs(snap.party) do if m.key == pc.found.key then current = m end end
      if current and (current.nickname ~= current.speciesName or FRAME - pc.foundFrame > 60 * 30) then
        resolveCatch(current)
      elseif not current then
        resolveCatch(pc.found)
      end
    elseif FRAME - pc.frame > 60 * 25 then
      resolveCatch(nil, true)
    end
  end
end

---------------------------------------------------------------------------------------------------
-- Status JSON
---------------------------------------------------------------------------------------------------
local function statusTable()
  local st = {
    ok = true, version = VERSION, ready = READY,
    game = { code = GAME.code, title = GAME.title, crc = GAME.crc, profile = GAME.profileName, family = GAME.family, ram = RAMSTATE.mode, file = GAME.file },
    data = DATA and {
      species = DATA.counts and DATA.counts.species or 0, found = DATA.found,
    } or json.null,
  }
  if ADV then st.adventure = { id = ADV.id, player = titleCase(ADV.player), tid = ADV.tid, seq = ADV.rev, events = #ADV.events } end
  if S then
    local party = {}
    for _, m in ipairs(S.party) do party[#party + 1] = monPublic(m) end
    st.party = setmetatable(party, json.arrayMT)
    st.location = S.loc
    st.badges = popcount(S.badges)
    local list = {}
    local names = CFG.badgeNames or P.badges or {}
    for i = 0, 7 do if (S.badges >> i) & 1 == 1 then list[#list + 1] = names[i + 1] or ("#" .. (i + 1)) end end
    st.badgeList = setmetatable(list, json.arrayMT)
    st.money = S.money
    st.playTime = playTime()
    st.player = titleCase(S.player)
  end
  if BATTLE then
    local en = {}
    for _, m in ipairs(BATTLE.enemies) do en[#en + 1] = { species = titleCase(m.speciesName), level = m.level, hp = m.hp, maxHP = m.maxHP } end
    st.battle = {
      kind = BATTLE.isTrainer and "trainer" or "wild",
      trainer = BATTLE.trainer and trainerLabel(BATTLE.trainer, BATTLE.trainerId) or nil,
      enemies = setmetatable(en, json.arrayMT),
    }
  end
  return st
end

local function dataTable()
  if not DATA then return { ok = false } end
  local function arr(t, from, title)
    local out = {}
    for i, v in pairs(t) do if type(i) == "number" and i >= (from or 0) then out[#out + 1] = { id = i, name = title and titleCase(v) or v } end end
    table.sort(out, function(a, b) return a.id < b.id end)
    return setmetatable(out, json.arrayMT)
  end
  local trainers = {}
  for i, t in pairs(DATA.trainers or {}) do
    if type(t) == "table" and (t.s == nil or t.s > 0) then
      local cls = (DATA.trainerClasses[t.c] or ""):gsub("PKMN", "Pokémon")
      trainers[#trainers + 1] = { id = i, class = titleCase(cls), name = titleCase(t.n or ""), size = t.s }
    end
  end
  table.sort(trainers, function(a, b) return a.id < b.id end)
  return {
    ok = true, game = GAME, found = DATA.found,
    species = arr(DATA.species, 1, true), moves = arr(DATA.moves, 1, true), abilities = arr(DATA.abilities, 1, true),
    items = arr(DATA.items, 1, true), types = arr(DATA.types, 0, true), maps = arr(DATA.mapsecs, 0, true),
    trainerClasses = arr(DATA.trainerClasses, 0, true), trainers = setmetatable(trainers, json.arrayMT),
  }
end

---------------------------------------------------------------------------------------------------
-- HTTP server (mGBA sockets)
---------------------------------------------------------------------------------------------------
local server = nil
local clients = {}
local toClose = {}
local nextClient = 1

local function httpResponse(code, body, ctype)
  local status = ({ [200] = "OK", [204] = "No Content", [404] = "Not Found", [503] = "Service Unavailable" })[code] or "OK"
  return table.concat({
    "HTTP/1.1 ", code, " ", status, "\r\n",
    "Content-Type: ", ctype or "application/json; charset=utf-8", "\r\n",
    "Access-Control-Allow-Origin: *\r\n",
    "Access-Control-Allow-Methods: GET, OPTIONS\r\n",
    "Access-Control-Allow-Headers: *\r\n",
    "Access-Control-Allow-Private-Network: true\r\n",
    "Cache-Control: no-store\r\n",
    "Content-Length: ", #body, "\r\n",
    "Connection: close\r\n\r\n", body,
  })
end

local firstRequest = true
local function handleRequest(req)
  local method, path = req:match("^(%u+)%s+(%S+)")
  if firstRequest then firstRequest = false; dbg("first HTTP request: " .. tostring(path)) end
  if not method then return httpResponse(404, '{"ok":false}') end
  if method == "OPTIONS" then return httpResponse(204, "") end
  local route = path:match("^([^?]*)")
  if route == "/" or route == "/status" then
    return httpResponse(200, json.encode(statusTable()))
  elseif route == "/events" then
    local since = tonumber(path:match("[?&]since=(%d+)")) or 0
    local want = path:match("[?&]adventure=([^&]+)")
    local parts = {}
    if ADV and (not want or want == ADV.id) then
      for _, line in ipairs(ADV.events) do
        local rev = tonumber(line:match('"rev":(%d+)')) or tonumber(line:match('"seq":(%d+)'))
        if rev and rev > since then parts[#parts + 1] = line end
      end
    end
    -- "seq" here is the sync cursor (highest revision), kept under the old name for compatibility
    local body = string.format('{"ok":true,"adventure":%s,"seq":%d,"events":[%s]}',
      ADV and json.str(ADV.id) or "null", ADV and ADV.rev or 0, table.concat(parts, ","))
    return httpResponse(200, body)
  elseif route == "/data" then
    return httpResponse(200, json.encode(dataTable()))
  elseif route == "/note" then
    -- /note?text=... lets the SillyTavern side add a manual journal entry to the game log
    local text = path:match("[?&]text=([^&]*)")
    if text and ADV then
      text = text:gsub("%+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
      addEvent("note", text, 2, nil)
    end
    return httpResponse(200, '{"ok":true}')
  end
  return httpResponse(404, '{"ok":false,"error":"not found"}')
end

local function sendAll(sock, data)
  local i = 1
  local tries = 0
  while i <= #data and tries < 2000 do
    local sent, err = sock:send(data, i, math.min(#data, i + 16383))
    if not sent then
      if err ~= socket.ERRORS.AGAIN then return false end
      tries = tries + 1
    elseif sent < i then
      tries = tries + 1
    else
      i = sent + 1
    end
  end
  return true
end

local function onClientData(id)
  local c = clients[id]
  if not c then return end
  while true do
    local p, err = c.sock:receive(4096)
    if p then
      c.buf = c.buf .. p
      if c.buf:find("\r\n\r\n", 1, true) and not c.done then
        c.done = true
        local ok, resp = pcall(handleRequest, c.buf)
        if not ok then resp = httpResponse(503, json.encode({ ok = false, error = tostring(resp) })) end
        sendAll(c.sock, resp)
        toClose[#toClose + 1] = id
        return
      end
      if #c.buf > 65536 then toClose[#toClose + 1] = id; return end
    else
      if err ~= socket.ERRORS.AGAIN then toClose[#toClose + 1] = id end
      return
    end
  end
end

-- mGBA 0.10 bug: a closed socket gets closed *again* when Lua garbage-collects it, and by then the
-- OS has often handed the same socket number to a newer connection, which then dies with an empty
-- reply. Keeping closed sockets referenced means they are never collected (a few bytes each).
local SOCKET_GRAVEYARD = {}
local function closePending()
  for _, id in ipairs(toClose) do
    local c = clients[id]
    if c then
      clients[id] = nil
      pcall(function() c.sock:close() end)
      SOCKET_GRAVEYARD[#SOCKET_GRAVEYARD + 1] = c.sock
    end
  end
  toClose = {}
end

local function onAccept()
  local sock, err = server:accept()
  if not sock then return end
  local id = nextClient
  nextClient = nextClient + 1
  clients[id] = { sock = sock, buf = "", born = FRAME }
  sock:add("received", function() onClientData(id) end)
  sock:add("error", function() toClose[#toClose + 1] = id end)
end

local function startServer()
  if server then return end
  local port = CFG.port
  local err
  server, err = socket.bind(nil, port)
  if not server then
    warn("Could not open port " .. port .. ": " .. tostring(err) .. " (is another copy of the script running?)")
    return
  end
  local ok
  ok, err = server:listen(8)
  if not ok then
    warn("Listen failed: " .. tostring(err)); server:close(); server = nil; return
  end
  server:add("received", onAccept)
  log("SillyTavern bridge listening on http://127.0.0.1:" .. port)
end

---------------------------------------------------------------------------------------------------
-- Console status panel
---------------------------------------------------------------------------------------------------
local BUF = nil
local LAST_BUFFER_TEXT = nil
local function drawBuffer()
  if not CFG.showConsoleBuffer then return end
  local lines = {}
  local function add(t) lines[#lines + 1] = t end
  add(string.format("PKMN Adventure Notebook v%s | port %d | %s", VERSION, CFG.port, server and "bridge ON" or "bridge OFF"))
  add(string.format("Game: %s [%s] %s", GAME.file or GAME.title, GAME.code, GAME.profileName))
  if not READY then add("Waiting for a game...")
  elseif not ADV or not S then add("Waiting for a save file to be loaded...")
  else
    add(string.format("%s | %s | Badges %d/8 | Events: %d", titleCase(S.player), S.loc or "?", popcount(S.badges), #ADV.events))
    for _, m in ipairs(S.party) do add(string.format("  %-12s Lv%3d  %3d/%3d HP", monShort(m), m.level, m.hp, m.maxHP)) end
    if BATTLE then add("In battle: " .. (BATTLE.isTrainer and trainerLabel(BATTLE.trainer, BATTLE.trainerId) or "wild") .. " - " .. enemyListText(BATTLE.enemies)) end
    add("Recent:")
    for i = math.max(1, #ADV.events - 5), #ADV.events do
      add("  - " .. (ADV.events[i]:match('"text":"(.-)","type"') or ""))
    end
  end
  -- keep lines short and few: mGBA's text panel is fragile with long or many lines
  for i, l in ipairs(lines) do
    if #l > 70 then lines[i] = l:sub(1, 67):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "..." end
  end
  while #lines > 18 do table.remove(lines) end
  local text = table.concat(lines, "\n")
  if text == LAST_BUFFER_TEXT then return end
  LAST_BUFFER_TEXT = text
  if not BUF then BUF = console:createBuffer("Adventure Notebook") end
  BUF:clear()
  for _, l in ipairs(lines) do BUF:print(l .. "\n") end
end

---------------------------------------------------------------------------------------------------
-- Game detection
---------------------------------------------------------------------------------------------------
-- mGBA's Lua API doesn't expose the ROM's file name, but mGBA lists recent ROMs in qt.ini.
-- Take the first entry whose size and header match the running game.
local function findRomFileName()
  if CFG.romName then return CFG.romName end
  local candidates = { "qt.ini", SCRIPT_DIR .. "qt.ini", SCRIPT_DIR .. "../qt.ini", SCRIPT_DIR .. "../../qt.ini" }
  if CFG.mgbaFolder then table.insert(candidates, 1, (CFG.mgbaFolder:gsub("[/\\]?$", "/")) .. "qt.ini") end
  local appdata = os.getenv("APPDATA")
  if appdata then candidates[#candidates + 1] = appdata .. "/mGBA/qt.ini" end
  local home = os.getenv("HOME")
  if home then candidates[#candidates + 1] = home .. "/.config/mgba/qt.ini" end
  local size = emu:romSize()
  local header = emu.memory.cart0:readRange(0xA0, 0x20)
  for _, ini in ipairs(candidates) do
    local f = io.open(ini, "r")
    if f then
      local inMru, paths = false, {}
      for line in f:lines() do
        local sec = line:match("^%[(.-)%]")
        if sec then inMru = (sec == "mru") end
        if inMru then
          local idx, path = line:match("^(%d+)=(.+)$")
          if idx then paths[#paths + 1] = { tonumber(idx), (path:gsub('^"(.*)"$', "%1")) } end
        end
      end
      f:close()
      table.sort(paths, function(a, b) return a[1] < b[1] end)
      for _, pth in ipairs(paths) do
        local rf = io.open(pth[2], "rb")
        if rf then
          local fsize = rf:seek("end")
          local ok = false
          if fsize == size then rf:seek("set", 0xA0); ok = (rf:read(0x20) == header) end
          rf:close()
          if ok then return (pth[2]:match("([^/\\]+)$") or pth[2]):gsub("%.[^.]*$", "") end
        end
      end
    end
  end
  return nil
end

local function crcHex()
  local ok, sum = pcall(function() return emu:checksum(C.CHECKSUM.CRC32) end)
  if not ok or not sum then dbg("checksum unavailable"); return "00000000" end
  local v = 0
  for i = 1, #sum do v = v * 256 + sum:byte(i) end
  return string.format("%08x", v)
end

local function partyLooksValid(prof)
  local cnt = emu:read8(prof.partyCount)
  if cnt > 6 then return false end
  if cnt == 0 then return nil end
  return decodeMon(emu:readRange(prof.party, 100)) ~= nil
end

local function chooseProfile()
  local code4 = (GAME.code or ""):match("(%w%w%w%w)$") or ""
  local key = CFG.forceProfile or CODE_TO_PROFILE[code4]
  -- Game Freak ROM header version: 3 = Emerald engine, 4/5 = FireRed/LeafGreen engine
  -- (some hacks keep a misleading game code, e.g. Clover says Emerald but runs on FireRed)
  local hdrVersion = emu.memory.cart0:read32(0x100)
  if not CFG.forceProfile and (key == "E" or key == "FR" or not key) then
    if hdrVersion == 3 then key = "E" elseif hdrVersion == 4 or hdrVersion == 5 then key = "FR" end
  end
  if not key then
    -- unknown game code (romhack changed it): pick the profile whose party data validates
    for _, k in ipairs({ "FR", "E", "RS" }) do
      if partyLooksValid(PROFILES[k]) then key = k; break end
    end
  end
  key = key or "FR"
  local prof = {}
  for k, v in pairs(PROFILES[key]) do prof[k] = v end
  if CFG.symFile then
    local syms = loadSymFile(CFG.symFile)
    if syms then
      for k, v in pairs(syms) do prof[k] = v end
      if syms.sb1 then prof.sb1ptr = nil end
      if syms.sb1ptr then prof.sb1 = nil end
      if syms.sb2 then prof.sb2ptr = nil end
      if syms.sb2ptr then prof.sb2 = nil end
      log("Loaded RAM addresses from " .. CFG.symFile)
    end
  end
  -- flags offset inside SaveBlock1 (expansion hacks move it); read from the ROM header
  if prof.family ~= "RS" then
    local fo = emu.memory.cart0:read32(0x150)
    if fo >= 0x800 and fo < 0x4000 then prof.flagsOff = fo end
  end
  for k, v in pairs(CFG.addressOverrides or {}) do prof[k] = v end
  GAME.family = prof.family
  GAME.profileName = prof.name .. (CODE_TO_PROFILE[code4] and "" or " (auto)")
  return prof
end

local function loadRomString()
  local size = emu:romSize()
  local parts = {}
  local chunk = 0x100000
  local off = 0
  while off < size do
    local n = math.min(chunk, size - off)
    parts[#parts + 1] = emu.memory.cart0:readRange(off, n)
    off = off + n
  end
  return table.concat(parts), size
end

local function countKeys(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

local function loadGameData()
  local cacheDir = SCRIPT_DIR .. "data/"
  if not ensureDir(cacheDir) then cacheDir = SCRIPT_DIR .. "notebook_cache_" end
  local cacheFile = cacheDir .. sanitizeFile(GAME.code .. "_" .. GAME.crc) .. ".lua"
  local f = loadfile(cacheFile)
  if f then
    local ok, d = pcall(f)
    if ok and type(d) == "table" and d.version == VERSION then
      log("Loaded game data from cache (" .. cacheFile .. ")")
      return d
    end
  end
  log("Scanning ROM for game data (first time only, a few seconds)...")
  ROM, ROMSIZE = loadRomString()
  dbg("ROM read: " .. tostring(ROMSIZE) .. " bytes")
  local d = extractRomData(GAME.family)
  ROM = nil
  collectgarbage()
  d.version = VERSION
  d.counts = {
    species = countKeys(d.species), moves = countKeys(d.moves), abilities = countKeys(d.abilities), items = countKeys(d.items),
    types = countKeys(d.types), maps = countKeys(d.mapsecs), trainers = countKeys(d.trainers), trainerClasses = countKeys(d.trainerClasses),
  }
  dbg("ROM scan done, writing cache " .. cacheFile)
  local out = io.open(cacheFile, "w")
  if out then out:write("return " .. serializeLua(d) .. "\n"); out:close() end
  for k, v in pairs(d.found) do log(string.format("  %-14s %s (%d)", k, v, d.counts[k == "mapsecs" and "maps" or k] or 0)) end
  log(string.format("ROM scan done in %.1fs", d.scanSeconds or 0))
  return d
end

local function onGameStart()
  READY = false
  S, BATTLE, ADV, PENDING_CATCH, LASTBATTLE = nil, nil, nil, nil, nil
  RAMSTATE.verified = false; RAMSTATE.lastTry = -100000; RAMSTATE.mode = "?"
  HB.lastEnemy = nil; TRAINER_TEXT = nil
  if not emu then return end
  if C.PLATFORM and emu:platform() ~= C.PLATFORM.GBA then
    warn("This notebook supports Game Boy Advance Pokémon games (Gen 3) only.")
    return
  end
  dbg("onGameStart: reading game code")
  GAME.code = emu:getGameCode() or ""
  GAME.title = emu:getGameTitle() or ""
  GAME.crc = crcHex()
  P = chooseProfile()
  log(string.format("Game: %s [%s] -> %s memory profile", GAME.title, GAME.code, GAME.profileName))
  local ok, d = pcall(loadGameData)
  if ok then DATA = d else warn("ROM scan failed: " .. tostring(d)); DATA = { species = {}, moves = {}, abilities = {}, items = {}, types = {}, mapsecs = {}, trainerClasses = {}, trainers = {}, found = {} } end
  DATA.keyItems = DATA.keyItems or {}
  BAG.regions, BAG.lastScan, BAG.itemMax = nil, -100000, 0
  for i in pairs(DATA.items or {}) do if i + 1 > BAG.itemMax then BAG.itemMax = i + 1 end end
  PCSET, SHOP = nil, nil
  pcall(loadMarts)
  GAME.file, GAME.fileTries = nil, 0
  local okName, name = pcall(findRomFileName)
  if okName and name then GAME.file = name; log("ROM file: " .. name) end
  READY = true
end

callbacks:add("start", function() local ok, e = pcall(onGameStart); if not ok then warn(tostring(e)) end end)
callbacks:add("reset", function() S = nil; BATTLE = nil; PENDING_CATCH = nil end)
callbacks:add("stop", function() READY = false end)
local PENDING_START = false
callbacks:add("frame", function()
  FRAME = FRAME + 1
  if FRAME == 1 then dbg("first frame") end
  if PENDING_START then
    PENDING_START = false
    dbg("starting game detection")
    local ok, e = pcall(onGameStart)
    if not ok then warn(tostring(e)) end
    dbg("game detection finished")
  end
  if #toClose > 0 then closePending() end
  if READY and not GAME.file and GAME.fileTries < 20 and FRAME % 180 == 0 then
    GAME.fileTries = GAME.fileTries + 1
    local okName, name = pcall(findRomFileName)
    if okName and name then GAME.file = name; log("ROM file: " .. name) end
  end
  if FRAME % CFG.pollFrames == 0 then
    local ok, e = pcall(tick)
    if not ok then warn("tick: " .. tostring(e)) end
  end
  if FRAME % 120 == 0 then
    -- drop stuck connections
    for id, c in pairs(clients) do if FRAME - c.born > 600 then toClose[#toClose + 1] = id end end
    local ok, e = pcall(drawBuffer)
    if not ok then dbg("drawBuffer: " .. tostring(e)) end
  end
end)

dbg("callbacks registered")
local okServer, errServer = pcall(startServer)
if not okServer then warn("bridge failed: " .. tostring(errServer)) end
-- The heavy work (reading the ROM) runs on the first emulated frame, not while mGBA is loading the script
PENDING_START = (emu ~= nil)
log("PKMN Adventure Notebook " .. VERSION .. " loaded" .. (PENDING_START and " - reading the game on the next frame..." or " - waiting for a game."))

-- exported for tests. This must stay a global and NOT become a `return` value of the script:
-- mGBA 0.10 leaves a script's return value on the Lua stack and then crashes on the next frame.
PKMN_NOTEBOOK_TEST = {
  _test = {
    encode = encode, decodeAt = decodeAt, decodeMon = decodeMon, extractRomData = extractRomData,
    setRom = function(r) ROM = r; ROMSIZE = #r end, json = json, handleRequest = handleRequest, tick = tick,
    titleCase = titleCase, getData = function() return DATA end, getAdv = function() return ADV end,
    setFrame = function(f) FRAME = f end, getFrame = function() return FRAME end,
  },
}
