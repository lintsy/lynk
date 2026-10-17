--!strict
--[[
	LYNK — Roblox Studio plugin
	────────────────────────────────────────────────────────────────────────────
	Import-only Figma → Roblox UI pipeline.

	Flow:
	  Figma plugin → "Copy code for Roblox" → paste into the LYNK widget → Load →
	  interactive slide-down preview → Import (assets uploaded + code generated)
	  → ServerStorage/LYNK_UI

	This plugin never fabricates capability the platform doesn't provide:
	  • assets are uploaded through AssetService:CreateAssetAsync (EditableImage)
	  • generated .luau/.ts files are source artifacts (ModuleScripts), not runtime
	    modules — they require a React runtime configured in the target project.
]]

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local Selection = game:GetService("Selection")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")
local AssetService = game:GetService("AssetService")

local PLUGIN_VERSION = "1.0.0"
local SCHEMA_VERSION = "1.0.0"
local ROOT_FOLDER_NAME = "LYNK_UI"
local CACHE_FOLDER_NAME = "_LYNK_Assets"
local PREVIEW_GUI_NAME = "LYNK_Preview"
local LYNK_ICON = "rbxassetid://125735302212859"

-- ═══════════════════════════════════════════════════════════════════════════
--  UTILITIES
-- ═══════════════════════════════════════════════════════════════════════════

local Util = {}

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_REV = {}
for i = 1, #B64_CHARS do
	B64_REV[string.byte(B64_CHARS, i)] = i - 1
end

--- Decode a base64 string into a Luau buffer.
function Util.base64ToBuffer(b64: string): buffer
	local clean = string.gsub(b64, "[^A-Za-z0-9+/]", "")
	local outLen = math.floor(#clean * 3 / 4)
	local buf = buffer.create(outLen)
	local p = 0
	local i = 1
	while i <= #clean do
		local c0 = B64_REV[string.byte(clean, i)] or 0
		local c1 = B64_REV[string.byte(clean, i + 1)] or 0
		local c2 = B64_REV[string.byte(clean, i + 2)] or 0
		local c3 = B64_REV[string.byte(clean, i + 3)] or 0
		if p < outLen then
			buffer.writeu8(buf, p, bit32.bor(bit32.lshift(c0, 2), bit32.rshift(c1, 4)))
			p += 1
		end
		if p < outLen then
			buffer.writeu8(buf, p, bit32.bor(bit32.lshift(bit32.band(c1, 15), 4), bit32.rshift(c2, 2)))
			p += 1
		end
		if p < outLen then
			buffer.writeu8(buf, p, bit32.bor(bit32.lshift(bit32.band(c2, 3), 6), c3))
			p += 1
		end
		i += 4
	end
	return buf
end

function Util.round(n: number, places: number?): number
	local m = 10 ^ (places or 3)
	return math.floor(n * m + 0.5) / m
end

--- Format a number for generated source: integers stay integer, others trimmed.
function Util.num(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		return "0"
	end
	if math.abs(n - math.floor(n + 0.5)) < 1e-6 then
		return tostring(math.floor(n + 0.5))
	end
	return (string.format("%.3f", n):gsub("0+$", ""):gsub("%.$", ""))
end

function Util.clamp01(n: number): number
	return math.clamp(n, 0, 1)
end

--- Roblox-safe identifier / folder name from a Figma name.
function Util.sanitizeName(name: string): string
	local s = name
		:gsub("[%c]", " ")
		:gsub("[<>:\"/\\|%?%*]", "_")
		:gsub("^%s+", "")
		:gsub("%s+$", "")
	if s == "" then
		s = "LYNK_UI"
	end
	if #s > 100 then
		s = string.sub(s, 1, 100)
	end
	return s
end

--- Safe Lua identifier for a function name inside generated source.
function Util.luaIdentifier(name: string): string
	local s = name:gsub("[^%w_]", "_")
	if s == "" or string.match(s, "^%d") then
		s = "UI_" .. s
	end
	if #s > 60 then
		s = string.sub(s, 1, 60)
	end
	return s
end

function Util.isHexColor(hex: string): boolean
	return string.match(hex, "^%x%x%x%x%x%x$") ~= nil
end

--- Walk a subtree looking for an instance carrying a FigmaNodeId attribute.
function Util.findByFigmaId(root: Instance, figmaId: string): Instance?
	local attr = root:GetAttribute("FigmaNodeId")
	if attr == figmaId then
		return root
	end
	for _, child in ipairs(root:GetDescendants()) do
		if child:GetAttribute("FigmaNodeId") == figmaId then
			return child
		end
	end
	return nil
end

function Util.getOrCreate(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

-- ═══════════════════════════════════════════════════════════════════════════
--  PNG DECODER (zlib inflate + unfilter) → RGBA8 buffer
--    Required because assets arrive from Figma as PNG bytes and are uploaded
--    through EditableImage (which needs raw pixels).
-- ═══════════════════════════════════════════════════════════════════════════

local Png = {}

type Huffman = { count: { number }, symbol: { number } }

local function newHuffman(): Huffman
	local count = table.create(16, 0)
	return { count = count, symbol = {} }
end

local function buildHuffman(lengths: { number }, n: number): Huffman
	local h = newHuffman()
	for sym = 1, n do
		local l = lengths[sym] or 0
		h.count[l + 1] += 1
	end
	-- start[len] = number of codes shorter than len (puff.c "offs")
	local start = table.create(16, 0)
	local running = 0
	for len = 1, 16 do
		start[len] = running
		running += h.count[len + 1] or 0
	end
	for sym = 1, n do
		local l = lengths[sym] or 0
		if l ~= 0 then
			start[l] += 1
			h.symbol[start[l]] = sym - 1
		end
	end
	return h
end

type BitReader = {
	data: string,
	pos: number,
	bitbuf: number,
	bitcnt: number,
}

local function bits(r: BitReader, need: number): number
	local val = r.bitbuf
	while r.bitcnt < need do
		if r.pos > #r.data then
			error("inflate: out of input")
		end
		val += string.byte(r.data, r.pos) * 2 ^ r.bitcnt
		r.pos += 1
		r.bitcnt += 8
	end
	r.bitbuf = math.floor(val / 2 ^ need)
	r.bitcnt -= need
	return val % 2 ^ need
end

local function decodeSymbol(r: BitReader, h: Huffman): number
	local code = 0
	local first = 0
	local index = 0
	for len = 1, 16 do
		code += bits(r, 1)
		local count = h.count[len + 1] or 0
		if code - count < first then
			return h.symbol[index + (code - first) + 1] or -1
		end
		index += count
		first += count
		first *= 2
		code *= 2
	end
	return -1
end

local LENGTH_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LENGTH_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CLEN_ORDER = { 17, 18, 19, 1, 9, 8, 10, 7, 11, 6, 12, 5, 13, 4, 14, 3, 15, 2, 16 }

local function inflateBlockData(r: BitReader, out: { number }): () 
	local hlit = bits(r, 5) + 257
	local hdist = bits(r, 5) + 1
	local hclen = bits(r, 4) + 4
	local clenLengths = table.create(19, 0)
	for i = 1, hclen do
		clenLengths[CLEN_ORDER[i]] = bits(r, 3)
	end
	local clenHuff = buildHuffman(clenLengths, 19)
	local lengths = table.create(hlit + hdist, 0)
	local i = 1
	while i <= hlit + hdist do
		local sym = decodeSymbol(r, clenHuff)
		if sym < 0 then
			error("inflate: bad code length symbol")
		elseif sym < 16 then
			lengths[i] = sym
			i += 1
		elseif sym == 16 then
			local prev = lengths[i - 1] or 0
			local repeatCount = bits(r, 2) + 3
			for _ = 1, repeatCount do
				if i > hlit + hdist then
					break
				end
				lengths[i] = prev
				i += 1
			end
		elseif sym == 17 then
			local repeatCount = bits(r, 3) + 3
			i += repeatCount
		else -- 18
			local repeatCount = bits(r, 7) + 11
			i += repeatCount
		end
	end
	local litLengths = table.create(hlit, 0)
	for k = 1, hlit do
		litLengths[k] = lengths[k]
	end
	local distLengths = table.create(hdist, 0)
	for k = 1, hdist do
		distLengths[k] = lengths[hlit + k]
	end
	local litHuff = buildHuffman(litLengths, hlit)
	local distHuff = buildHuffman(distLengths, hdist)
	while true do
		local sym = decodeSymbol(r, litHuff)
		if sym < 0 then
			error("inflate: bad literal symbol")
		elseif sym < 256 then
			table.insert(out, sym)
		elseif sym == 256 then
			break
		else
			local li = sym - 256
			local length = LENGTH_BASE[li] + bits(r, LENGTH_EXTRA[li])
			local dsym = decodeSymbol(r, distHuff)
			local dist = DIST_BASE[dsym + 1] + bits(r, DIST_EXTRA[dsym + 1])
			local start = #out - dist + 1
			for k = 0, length - 1 do
				table.insert(out, out[start + k])
			end
		end
	end
end

--- Inflate a zlib stream (RFC1950) into a byte array.
function Png.inflate(data: string): { number }
	local r: BitReader = { data = data, pos = 1, bitbuf = 0, bitcnt = 0 }
	-- zlib header
	local cmf = bits(r, 8)
	local flg = bits(r, 8)
	local _ = cmf
	if bit32.band(flg, 32) ~= 0 then
		-- preset dictionary not supported (never used by PNG encoders)
		error("inflate: preset dictionary unsupported")
	end
	local out: { number } = {}
	while true do
		local last = bits(r, 1)
		local btype = bits(r, 2)
		if btype == 0 then
			-- stored
			local ignore = r.bitcnt % 8
			r.bitbuf = math.floor(r.bitbuf / 2 ^ ignore)
			r.bitcnt -= ignore
			local len = bits(r, 16)
			local _nlen = bits(r, 16)
			for _ = 1, len do
				table.insert(out, bits(r, 8))
			end
		elseif btype == 1 then
			local litLengths = table.create(288, 0)
			for s = 1, 144 do litLengths[s] = 8 end
			for s = 145, 256 do litLengths[s] = 9 end
			for s = 257, 280 do litLengths[s] = 7 end
			for s = 281, 288 do litLengths[s] = 8 end
			local litHuff = buildHuffman(litLengths, 288)
			local distLengths = table.create(30, 5)
			local distHuff = buildHuffman(distLengths, 30)
			-- decode using shared routine
			while true do
				local sym = decodeSymbol(r, litHuff)
				if sym < 0 then
					error("inflate: bad fixed symbol")
				elseif sym < 256 then
					table.insert(out, sym)
				elseif sym == 256 then
					break
				else
					local li = sym - 256
					local length = LENGTH_BASE[li] + bits(r, LENGTH_EXTRA[li])
					local dsym = decodeSymbol(r, distHuff)
					local dist = DIST_BASE[dsym + 1] + bits(r, DIST_EXTRA[dsym + 1])
					local start = #out - dist + 1
					for k = 0, length - 1 do
						table.insert(out, out[start + k])
					end
				end
			end
		elseif btype == 2 then
			inflateBlockData(r, out)
		else
			error("inflate: invalid block type")
		end
		if last == 1 then
			break
		end
	end
	return out
end

--- Decode a PNG into { width, height, buffer (RGBA8) }.
function Png.decode(buf: buffer): ({ width: number, height: number, rgba: buffer }?, string?)
	local data = buffer.tostring(buf)
	if string.sub(data, 1, 8) ~= "\137PNG\r\n\26\n" then
		return nil, "not a PNG file"
	end
	local pos = 9
	local width, height, bitDepth, colorType, interlace = 0, 0, 0, 0, 0
	local idat: { string } = {}
	local palette: { { number } } = {}
	while pos <= #data do
		local len = string.unpack(">I4", data, pos)
		local ctype = string.sub(data, pos + 4, pos + 7)
		local chunkData = string.sub(data, pos + 8, pos + 7 + len)
		pos = pos + 12 + len
		if ctype == "IHDR" then
			width = string.unpack(">I4", chunkData, 1)
			height = string.unpack(">I4", chunkData, 5)
			bitDepth = string.byte(chunkData, 9)
			colorType = string.byte(chunkData, 10)
			interlace = string.byte(chunkData, 13)
		elseif ctype == "PLTE" then
			for i = 1, #chunkData, 3 do
				table.insert(palette, { string.byte(chunkData, i), string.byte(chunkData, i + 1), string.byte(chunkData, i + 2) })
			end
		elseif ctype == "IDAT" then
			table.insert(idat, chunkData)
		elseif ctype == "IEND" then
			break
		end
	end
	if width == 0 or height == 0 then
		return nil, "PNG missing IHDR"
	end
	if interlace ~= 0 then
		return nil, "interlaced PNG unsupported"
	end
	if bitDepth ~= 8 then
		return nil, "PNG bit depth " .. tostring(bitDepth) .. " unsupported"
	end

	local raw = Png.inflate(table.concat(idat))

	local channels: number
	if colorType == 0 then
		channels = 1
	elseif colorType == 2 then
		channels = 3
	elseif colorType == 3 then
		channels = 1
	elseif colorType == 4 then
		channels = 2
	elseif colorType == 6 then
		channels = 4
	else
		return nil, "PNG color type " .. tostring(colorType) .. " unsupported"
	end

	local stride = width * channels
	local prev = table.create(stride, 0)
	local pixels: { number } = table.create(width * height * 4, 0)
	local rawPos = 1
	for y = 0, height - 1 do
		local filter = raw[rawPos]
		rawPos += 1
		local row = table.create(stride, 0)
		for x = 0, stride - 1 do
			local rawByte = raw[rawPos] or 0
			rawPos += 1
			local a = x >= channels and row[x - channels + 1] or 0
			local b = prev[x + 1] or 0
			local c = (x >= channels) and (prev[x - channels + 1] or 0) or 0
			local val
			if filter == 0 then
				val = rawByte
			elseif filter == 1 then
				val = rawByte + a
			elseif filter == 2 then
				val = rawByte + b
			elseif filter == 3 then
				val = rawByte + math.floor((a + b) / 2)
			elseif filter == 4 then
				local p = a + b - c
				local pa = math.abs(p - a)
				local pb = math.abs(p - b)
				local pc = math.abs(p - c)
				local pr
				if pa <= pb and pa <= pc then
					pr = a
				elseif pb <= pc then
					pr = b
				else
					pr = c
				end
				val = rawByte + pr
			else
				return nil, "PNG bad filter " .. tostring(filter)
			end
			row[x + 1] = bit32.band(val, 255)
		end
		-- expand to RGBA
		for x = 0, width - 1 do
			local r, g, b, al
			if colorType == 0 then
				r = row[x + 1]; g = r; b = r; al = 255
			elseif colorType == 2 then
				r = row[x * 3 + 1]; g = row[x * 3 + 2]; b = row[x * 3 + 3]; al = 255
			elseif colorType == 3 then
				local idx = row[x + 1] + 1
				local entry = palette[idx]
				if entry then
					r, g, b = entry[1], entry[2], entry[3]
				else
					r, g, b = 0, 0, 0
				end
				al = 255
			elseif colorType == 4 then
				r = row[x * 2 + 1]; g = r; b = r; al = row[x * 2 + 2]
			else
				r = row[x * 4 + 1]; g = row[x * 4 + 2]; b = row[x * 4 + 3]; al = row[x * 4 + 4]
			end
			local base = (y * width + x) * 4
			pixels[base + 1] = r
			pixels[base + 2] = g
			pixels[base + 3] = b
			pixels[base + 4] = al
		end
		prev = row
	end

	local rgba = buffer.create(width * height * 4)
	for i = 1, #pixels do
		buffer.writeu8(rgba, i - 1, pixels[i])
	end
	return { width = width, height = height, rgba = rgba }
end

-- ═══════════════════════════════════════════════════════════════════════════
--  UI KIT (compact dark developer-tool styling)
-- ═══════════════════════════════════════════════════════════════════════════

local Theme = {
	bg = Color3.fromRGB(30, 30, 30),
	panel = Color3.fromRGB(38, 38, 38),
	panelAlt = Color3.fromRGB(44, 44, 44),
	border = Color3.fromRGB(58, 58, 58),
	text = Color3.fromRGB(240, 240, 240),
	textDim = Color3.fromRGB(160, 160, 160),
	accent = Color3.fromRGB(13, 153, 255),
	accentHover = Color3.fromRGB(43, 166, 255),
	success = Color3.fromRGB(20, 174, 92),
	warning = Color3.fromRGB(255, 205, 41),
	danger = Color3.fromRGB(242, 72, 34),
}

local function new(className: string, props: { [string]: any }, children: { Instance }?): Instance
	local inst = Instance.new(className)
	for k, v in pairs(props or {}) do
		if k ~= "Parent" then
			local ok, propErr = pcall(function()
				(inst :: any)[k] = v
			end)
			if not ok then
				warn(string.format("[LYNK] Ignored invalid property %s.%s: %s", className, k, tostring(propErr)))
			end
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	return inst
end

local function corner(radius: number): Instance
	return new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function padding(px: number, py: number?): Instance
	return new("UIPadding", {
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
		PaddingTop = UDim.new(0, py or px),
		PaddingBottom = UDim.new(0, py or px),
	})
end

local function makeButton(text: string, primary: boolean): TextButton
	local btn = new("TextButton", {
		Text = text,
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = primary and Theme.accent or Theme.panelAlt,
		TextColor3 = primary and Color3.new(1, 1, 1) or Theme.text,
		TextSize = 13,
		Font = Enum.Font.GothamMedium,
		AutoButtonColor = true,
		BorderSizePixel = 0,
	}, { corner(6) }) :: TextButton
	return btn
end

local function makeLabel(text: string, color: Color3, size: number, bold: boolean?): TextLabel
	return new("TextLabel", {
		Text = text,
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		TextColor3 = color,
		TextSize = size,
		Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left,
	}) :: TextLabel
end

-- ═══════════════════════════════════════════════════════════════════════════
--  SETTINGS
-- ═══════════════════════════════════════════════════════════════════════════

local Settings = {
	generateCode = true,
	autoPreview = true,
	assetHandling = "upload", -- "upload" | "placeholder" | "skip"
}

local function loadSettings()
	if plugin then
		for key, default in pairs(Settings) do
			local stored = plugin:GetSetting("lynk_" .. key)
			if stored ~= nil then
				Settings[key] = stored
			else
				Settings[key] = default
			end
		end
	end
end

local function saveSetting(key: string, value: any)
	Settings[key] = value
	if plugin then
		plugin:SetSetting("lynk_" .. key, value)
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  STATE
-- ═══════════════════════════════════════════════════════════════════════════

local State = {
	schema = nil :: any,
	status = "No code loaded",
	figmaName = "—",
	nodeCount = 0,
	eventCount = 0,
	assetCount = 0,
	history = {} :: { { time: number, text: string } },
	assets = {} :: { [string]: { status: string, name: string } },
	instanceByFigmaId = {} :: { [string]: Instance },
	assetCache = {} :: { [string]: string },
	importing = false,
	structure = nil :: any,
}

-- ═══════════════════════════════════════════════════════════════════════════
--  ASSET PIPELINE
-- ═══════════════════════════════════════════════════════════════════════════

local Assets = {}

local function cacheFolder(): Folder
	local root = Util.getOrCreate(ServerStorage, "Folder", ROOT_FOLDER_NAME) :: Folder
	root:SetAttribute("LYNKRoot", true)
	return Util.getOrCreate(root, "Folder", CACHE_FOLDER_NAME) :: Folder
end

function Assets.loadCache()
	State.assetCache = {}
	local folder = cacheFolder()
	for _, child in ipairs(folder:GetChildren()) do
		local hash = child:GetAttribute("AssetHash")
		local id = child:GetAttribute("RobloxAssetId")
		if type(hash) == "string" and type(id) == "number" then
			State.assetCache[hash] = "rbxassetid://" .. tostring(id)
		end
	end
end

local function storeCache(hash: string, assetId: number, name: string)
	local folder = cacheFolder()
	local existing = folder:FindFirstChild(hash)
	local entry = existing or Instance.new("Folder")
	entry.Name = hash
	entry:SetAttribute("AssetHash", hash)
	entry:SetAttribute("RobloxAssetId", assetId)
	entry:SetAttribute("Name", name)
	entry.Parent = folder
	State.assetCache[hash] = "rbxassetid://" .. tostring(assetId)
end

--- Upload one asset (EditableImage → CreateAssetAsync). Returns robloxAssetId or nil+reason.
function Assets.upload(asset: any): (string?, string?)
	if asset.robloxAssetId then
		return "rbxassetid://" .. tostring(asset.robloxAssetId), nil
	end
	local cached = State.assetCache[asset.assetHash]
	if cached then
		return cached, nil
	end
	if not asset.base64 then
		return nil, "no image bytes provided"
	end
	local ok, result, reason = pcall(function()
		local buf = Util.base64ToBuffer(asset.base64)
		local decoded, decodeErr = Png.decode(buf)
		if not decoded then
			error(decodeErr or "decode failed")
		end
		if decoded.width > 1024 or decoded.height > 1024 then
			error(string.format("image too large (%dx%d, EditableImage max is 1024x1024)", decoded.width, decoded.height))
		end
		local editable = AssetService:CreateEditableImage({ Size = Vector2.new(decoded.width, decoded.height) })
		if not editable then
			error(string.format("CreateEditableImage returned nil (budget exceeded for %dx%d)", decoded.width, decoded.height))
		end
		editable:WritePixelsBuffer(Vector2.zero, Vector2.new(decoded.width, decoded.height), decoded.rgba)
		local createResult, idOrErr = AssetService:CreateAssetAsync(editable, Enum.AssetType.Image, {
			Name = asset.name or "LYNK Image",
			Description = "Imported from Figma by LYNK",
		})
		if createResult ~= Enum.CreateAssetResult.Success then
			error("upload result " .. tostring(createResult) .. " " .. tostring(idOrErr))
		end
		local assetId = tonumber(idOrErr)
		if not assetId then
			error("no asset id returned")
		end
		storeCache(asset.assetHash, assetId, asset.name or "")
		return assetId
	end)
	if not ok then
		return nil, tostring(result)
	end
	return "rbxassetid://" .. tostring(result), nil
end

--- Resolve all assets in the current schema. Mutates asset records in place.
function Assets.resolveAll(progress: (string, string) -> ())
	local assets = State.schema and State.schema.assets or {}
	local ordered = {}
	for _, asset in pairs(assets) do
		table.insert(ordered, asset)
	end
	table.sort(ordered, function(a, b)
		return (a.name or "") < (b.name or "")
	end)

	Assets.loadCache()

	for _, asset in ipairs(ordered) do
		if asset.robloxAssetId then
			asset.status = "RESOLVED"
		elseif Settings.assetHandling == "skip" then
			asset.status = "FAILED"
			asset.error = "skipped by settings"
		elseif Settings.assetHandling == "placeholder" then
			asset.status = "PENDING"
		else
			if progress then
				progress(asset.name or asset.assetId, "uploading")
			end
			local id, err = Assets.upload(asset)
			if id then
				asset.status = "RESOLVED"
				asset.robloxUri = id
				if progress then
					progress(asset.name or asset.assetId, "resolved")
				end
			else
				asset.status = "FAILED"
				asset.error = err
				if progress then
					progress(asset.name or asset.assetId, "failed: " .. tostring(err))
				end
			end
		end
	end
	return ordered
end

function Assets.uriFor(nodeAssetId: string): string?
	local assets = State.schema and State.schema.assets or {}
	local asset = assets[nodeAssetId]
	if not asset then
		return nil
	end
	return asset.robloxUri or asset.robloxAssetId and ("rbxassetid://" .. tostring(asset.robloxAssetId)) or nil
end

-- ═══════════════════════════════════════════════════════════════════════════
--  ROBLOX INSTANCE MAPPER (schema → instances)
-- ═══════════════════════════════════════════════════════════════════════════

local Mapper = {}

local function rgbaToColor3(c: any): Color3
	local cf = c or { r = 1, g = 1, b = 1, a = 1 }
	return Color3.fromRGB(
		math.floor(Util.clamp01(cf.r) * 255 + 0.5),
		math.floor(Util.clamp01(cf.g) * 255 + 0.5),
		math.floor(Util.clamp01(cf.b) * 255 + 0.5)
	)
end

local function solidPaint(paints: any): any?
	if type(paints) ~= "table" then
		return nil
	end
	for _, p in ipairs(paints) do
		if p.type == "SOLID" and p.visible ~= false then
			return p
		end
	end
	return nil
end

local function imagePaint(paints: any): any?
	if type(paints) ~= "table" then
		return nil
	end
	for _, p in ipairs(paints) do
		if p.type == "IMAGE" and p.visible ~= false then
			return p
		end
	end
	return nil
end

local function gradientPaint(paints: any): any?
	if type(paints) ~= "table" then
		return nil
	end
	for _, p in ipairs(paints) do
		if type(p.type) == "string" and string.find(p.type, "GRADIENT") and p.visible ~= false then
			return p
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- layer-name tags: "MyName_Class_Prop=Value" authored in Figma layer names
-- ---------------------------------------------------------------------------

--- Semantic class tags an author can append to a Figma layer name.
local TAG_CLASSES: { [string]: string } = {
	frame = "Frame",
	text = "TextLabel",
	label = "TextLabel",
	textlabel = "TextLabel",
	button = "TextButton",
	textbutton = "TextButton",
	image = "ImageLabel",
	imagelabel = "ImageLabel",
	imagebutton = "ImageButton",
	scroll = "ScrollingFrame",
	scrollingframe = "ScrollingFrame",
	canvasgroup = "CanvasGroup",
	viewportframe = "ViewportFrame",
	videoframe = "VideoFrame",
	screengui = "ScreenGui",
}

local NameTag = {}

--- Split a Figma layer name into segments and locate the optional trailing
--- class tag (any trailing "Key=Value" segments are left as candidates).
function NameTag.parse(rawName: any): any
	local name = tostring(rawName or "")
	local segments = {}
	for seg in string.gmatch(name, "[^_]+") do
		table.insert(segments, seg)
	end
	local tagIndex: number? = nil
	local i = #segments
	while i >= 1 and string.find(segments[i], "=", 1, true) do
		i -= 1
	end
	if i >= 1 then
		local semantic = string.lower(segments[i])
		if TAG_CLASSES[semantic] then
			tagIndex = i
		end
	end
	local semantic = tagIndex and string.lower(segments[tagIndex]) or nil
	-- a "Parent=<layerName>" segment is a structural directive, not a property:
	-- it re-parents the node under another node with that display name.
	local parentIndex: number? = nil
	local parentName: string? = nil
	for idx, seg in ipairs(segments) do
		if idx ~= tagIndex then
			local key, val = string.match(seg, "^([%a_][%w_]*)%s*=(.+)$")
			if key and string.lower(key) == "parent" then
				parentIndex = idx
				parentName = val
			end
		end
	end
	return {
		segments = segments,
		tagIndex = tagIndex,
		semantic = semantic,
		tagClass = semantic and TAG_CLASSES[semantic] or nil,
		parentIndex = parentIndex,
		parentName = parentName,
	}
end

--- Coerce a tag value into a Roblox value plus a Lua/TS source literal.
function NameTag.coerce(raw: string): (boolean, string?, any?)
	local v = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if v == "true" then
		return true, "true", true
	end
	if v == "false" then
		return true, "false", false
	end
	local n = tonumber(v)
	if n ~= nil then
		return true, tostring(n), n
	end
	local et, ei = string.match(v, "^Enum%.([%w_]+)%.([%w_]+)$")
	if et and ei then
		local group = (Enum :: any)[et]
		if group and group[ei] then
			return true, string.format("Enum.%s.%s", et, ei), group[ei]
		end
	end
	local r, g, b = string.match(v, "^Color3%.fromRGB%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)$")
	if r then
		return true, string.format("Color3.fromRGB(%s, %s, %s)", r, g, b), Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b))
	end
	local hex = string.match(v, "^#(%x%x%x%x%x%x)$")
	if hex then
		local ok, c3 = pcall(Color3.fromHex, "#" .. hex)
		if ok then
			return true, string.format("Color3.fromHex(\"#%s\")", hex), c3
		end
	end
	local ua, ub = string.match(v, "^UDim%.new%s*%(%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*%)$")
	if ua then
		return true, string.format("UDim.new(%s, %s)", ua, ub), UDim.new(tonumber(ua), tonumber(ub))
	end
	local oa, ob = string.match(v, "^UDim2%.fromOffset%s*%(%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*%)$")
	if oa then
		return true, string.format("UDim2.fromOffset(%s, %s)", oa, ob), UDim2.fromOffset(tonumber(oa), tonumber(ob))
	end
	local sa, sb = string.match(v, "^UDim2%.fromScale%s*%(%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*%)$")
	if sa then
		return true, string.format("UDim2.fromScale(%s, %s)", sa, sb), UDim2.fromScale(tonumber(sa), tonumber(sb))
	end
	return true, string.format("%q", v), v
end

--- Apply the property directives in a parsed name to an instance. Only exact,
--- writable Roblox properties are applied; everything else stays in the name.
--- Returns (displayName, appliedList of { name, lua }).
function NameTag.applyTo(inst: Instance, parsed: any): (string, { { name: string, lua: string } })
	local applied = {}
	local kept = {}
	for idx, seg in ipairs(parsed.segments) do
		if idx == parsed.tagIndex or idx == parsed.parentIndex then
			-- drop the class tag and any Parent=<name> directive from the name
		else
			local pname, rawValue = string.match(seg, "^([%a_][%w_]*)%s*=(.*)$")
			local used = false
			if pname then
				local ok, literal, value = NameTag.coerce(rawValue)
				if ok then
					local readOk, current = pcall(function()
						return (inst :: any)[pname]
					end)
					if readOk and current ~= nil then
						local setOk = pcall(function()
							(inst :: any)[pname] = value
						end)
						if setOk then
							table.insert(applied, { name = pname, lua = literal :: string })
							used = true
						end
					end
				end
			end
			if not used then
				table.insert(kept, seg)
			end
		end
	end
	return table.concat(kept, "_"), applied
end

--- Figma rotation is counter-clockwise; Roblox Rotation is clockwise.
local function robloxRotation(node: any): number
	return -(node.rotation or 0)
end

--- Parent-relative top-left of a rotated node. Figma's node.x/node.y are the
--- relativeTransform translation (the image of the node's *local origin*) and
--- Figma rotates about that top-left ("rotation is with respect to the top-left
--- of the object... independent from the position"). Roblox with AnchorPoint
--- (0,0) also rotates about its top-left, so the values map straight across:
--- Position = (x, y) and Rotation = -rotation. No center correction is needed.
local function rotatedOffset(node: any): (number, number)
	return node.x or 0, node.y or 0
end

local function mapClass(node: any, hasImage: boolean, forceButton: boolean?, tagClass: string?): string
	if tagClass then
		return tagClass
	end
	local t = node.type
	local hasText = node.typography ~= nil
	local hasClick = false
	for _, eid in ipairs(node.events or {}) do
		local inter = State.schema.interactions[eid]
		if inter and (inter.event == "click" or inter.event == "tap" or inter.event == "press") then
			hasClick = true
		end
	end
	if hasClick or forceButton then
		return hasImage and "ImageButton" or "TextButton"
	end
	if hasText then
		return "TextLabel"
	end
	if hasImage or t == "RECTANGLE" or t == "ELLIPSE" then
		return (hasImage and "ImageLabel") or "Frame"
	end
	if t == "VECTOR" or t == "BOOLEAN_OPERATION" or t == "STAR" or t == "POLYGON" or t == "LINE" then
		return "ImageLabel"
	end
	return "Frame"
end

-- ---------------------------------------------------------------------------
-- variant collapse: render one control per (component set × non-state props)
-- and keep the other variants as interactive states
-- ---------------------------------------------------------------------------

local STATE_VALUE_MAP: { [string]: string } = {
	["default"] = "default", ["rest"] = "default", ["idle"] = "default", ["normal"] = "default",
	["none"] = "default", ["initial"] = "default", ["base"] = "default", ["defaultstate"] = "default",
	["hover"] = "hover", ["hovering"] = "hover", ["whilehovering"] = "hover", ["onhover"] = "hover",
	["hoverstate"] = "hover", ["over"] = "hover",
	["pressed"] = "pressed", ["pressing"] = "pressed", ["active"] = "pressed", ["down"] = "pressed",
	["mousedown"] = "pressed", ["presseddown"] = "pressed", ["clicked"] = "pressed", ["click"] = "pressed",
	["onpress"] = "pressed", ["pressedstate"] = "pressed", ["tapped"] = "pressed", ["pressedactive"] = "pressed",
	["disabled"] = "disabled", ["inactive"] = "disabled", ["disabledstate"] = "disabled",
	["focused"] = "focused", ["focus"] = "focused",
}

local function normalizeStateKey(value: any): string?
	if type(value) ~= "string" then
		return nil
	end
	local key = string.lower(value)
	key = string.gsub(key, "[%s%-_]", "")
	return STATE_VALUE_MAP[key]
end

--- Given a parent node, decide which of its children are non-default variants of
--- the same control. Returns (childId -> true for skipped renders, baseId ->
--- { state -> variantNodeId }).
function Mapper.planVariantChildren(schema: any, parentNode: any)
	local skipped: { [string]: boolean } = {}
	local states: { [string]: { [string]: string } } = {}
	local children = parentNode and parentNode.children
	if type(children) ~= "table" or #children < 2 then
		return skipped, states
	end

	-- collect candidates (siblings belonging to a component set) and the set of
	-- values seen on each variant axis
	local candidates = {}
	local axisValues: { [string]: { [string]: true } } = {}
	for _, childId in ipairs(children) do
		local child = schema.nodes[childId]
		local comp = child and child.component
		local vp = comp and comp.variantProperties
		if child and comp and type(vp) == "table" and next(vp) ~= nil then
			local setId = comp.componentSetId
			if setId then
				table.insert(candidates, { id = childId, setId = setId, vp = vp })
				for axis, value in pairs(vp) do
					if type(value) == "string" then
						if not axisValues[axis] then
							axisValues[axis] = {}
						end
						axisValues[axis][value] = true
					end
				end
			end
		end
	end
	if #candidates < 2 then
		return skipped, states
	end

	-- choose one state axis for the whole parent: every value seen on it must
	-- be a known state word, with at least two distinct states present
	local chosenAxis = nil
	local bestScore = -1
	local bestName = nil
	for axis, values in pairs(axisValues) do
		local allMapped = true
		local distinct = 0
		local hasHoverish = false
		for rawValue in pairs(values) do
			local canon = normalizeStateKey(rawValue)
			if not canon then
				allMapped = false
				break
			end
			distinct += 1
			if canon == "hover" or canon == "pressed" then
				hasHoverish = true
			end
		end
		if allMapped and distinct >= 2 then
			local axisName = string.lower(tostring(axis))
			local stateNamed = axisName == "state" or axisName == "status" or axisName == "interaction"
			local score = (stateNamed and 8 or 0) + (hasHoverish and 2 or 0) + math.min(distinct, 4)
			if score > bestScore or (score == bestScore and (bestName == nil or axisName < bestName)) then
				chosenAxis = axis
				bestScore = score
				bestName = axisName
			end
		end
	end
	if not chosenAxis then
		return skipped, states
	end

	-- group candidates by set + every variant property except the state axis
	local groups: { [string]: { members: { { id: string, state: string } } } } = {}
	for _, cand in ipairs(candidates) do
		local state = normalizeStateKey(cand.vp[chosenAxis])
		if state then
			local parts = {}
			for axis, value in pairs(cand.vp) do
				if axis ~= chosenAxis then
					table.insert(parts, axis .. "=" .. tostring(value))
				end
			end
			table.sort(parts)
			local gid = cand.setId .. "|" .. table.concat(parts, "&")
			local g = groups[gid]
			if not g then
				g = { members = {} }
				groups[gid] = g
			end
			table.insert(g.members, { id = cand.id, state = state })
		end
	end

	local stateOrder = { default = 1, hover = 2, pressed = 3, disabled = 4, focused = 5 }
	for _, g in pairs(groups) do
		-- only collapse when every state appears exactly once (avoids eating
		-- legitimately duplicated controls)
		local seen: { [string]: boolean } = {}
		local unique = true
		local distinct = 0
		for _, m in ipairs(g.members) do
			if seen[m.state] then
				unique = false
				break
			end
			seen[m.state] = true
			distinct += 1
		end
		if unique and #g.members >= 2 and distinct >= 2 then
			local baseId = nil
			for _, m in ipairs(g.members) do
				if m.state == "default" then
					baseId = m.id
					break
				end
			end
			if not baseId then
				table.sort(g.members, function(a, b)
					return (stateOrder[a.state] or 9) < (stateOrder[b.state] or 9)
				end)
				baseId = g.members[1].id
			end
			local stateMap: { [string]: string } = {}
			for _, m in ipairs(g.members) do
				if m.id ~= baseId then
					skipped[m.id] = true
					stateMap[m.state] = m.id
				end
			end
			states[baseId] = stateMap
		end
	end
	return skipped, states
end

--- Position relative to parent's top-left (absolute layout support).
function Mapper.relativePosition(node: any, parentNode: any?): Vector2
	local na = node.absolute
	local pa = parentNode and parentNode.absolute
	if na and pa then
		-- page-space bboxes: the difference is always parent-relative
		return Vector2.new((na.x or 0) - (pa.x or 0), (na.y or 0) - (pa.y or 0))
	end
	-- extractor reports node.x/y relative to the parent already
	return Vector2.new(node.x or 0, node.y or 0)
end

--- Apply the visual/typography/layout block of a node to an existing instance.
function Mapper.applyVisual(inst: Instance, node: any, parentNode: any?)
	local visual = node.visual or {}
	local layout = node.layout or {}

	local function setProp(prop: string, value: any)
		pcall(function()
			(inst :: any)[prop] = value
		end)
	end

	-- size / position
	local rel = Mapper.relativePosition(node, parentNode)
	local inAutoLayout = parentNode and parentNode.layout and parentNode.layout.mode ~= "NONE"
		and not (layout.absolute or false)
	if inAutoLayout then
		if (node.layout and node.layout.layoutGrow or 0) > 0 then
			setProp("Size", UDim2.fromScale(1, node.height and UDim2.fromOffset(0, node.height).Y.Scale or 0))
			setProp("Size", UDim2.fromOffset(node.width or 0, node.height or 0))
		else
			setProp("Size", UDim2.fromOffset(node.width or 0, node.height or 0))
		end
		setProp("Position", UDim2.fromOffset(0, 0))
	else
		setProp("Size", UDim2.fromOffset(node.width or 0, node.height or 0))
		if math.abs(node.rotation or 0) > 0.001 then
			local px, py = rotatedOffset(node)
			setProp("Position", UDim2.fromOffset(px, py))
		else
			setProp("Position", UDim2.fromOffset(rel.X, rel.Y))
		end
	end
	setProp("AnchorPoint", Vector2.new(0, 0))

	-- rotation
	if type(node.rotation) == "number" and math.abs(node.rotation) > 0.001 then
		setProp("Rotation", robloxRotation(node))
	end

	-- background — a TEXT node's fills carry the glyph color, never a background
	local isText = node.typography ~= nil
	local img = imagePaint(visual.fills)
	local solid: any? = nil
	if not isText then
		solid = solidPaint(visual.fills) or solidPaint(visual.background)
	end
	if solid then
		setProp("BackgroundColor3", rgbaToColor3(solid.color))
		local a = (solid.color and solid.color.a or 1) * (solid.opacity or 1) * (visual.opacity or 1)
		setProp("BackgroundTransparency", 1 - Util.clamp01(a))
	elseif not isText and not img and gradientPaint(visual.fills) then
		-- white base under the UIGradient so gradients show as authored
		setProp("BackgroundColor3", Color3.new(1, 1, 1))
		setProp("BackgroundTransparency", 1 - Util.clamp01(visual.opacity or 1))
	else
		setProp("BackgroundTransparency", 1)
	end
	setProp("BorderSizePixel", 0)

	-- image fill
	if img then
		local uri = img.assetId and Assets.uriFor(img.assetId)
		setProp("Image", uri or "")
		local scaleMode = img.scaleMode
		if scaleMode == "FILL" then
			setProp("ScaleType", Enum.ScaleType.Crop)
		elseif scaleMode == "FIT" then
			setProp("ScaleType", Enum.ScaleType.Fit)
		elseif scaleMode == "TILE" then
			setProp("ScaleType", Enum.ScaleType.Tile)
		else
			setProp("ScaleType", Enum.ScaleType.Crop)
		end
		local imgAlpha = (img.color and img.color.a or 1) * (img.opacity or 1)
		if img.color then
			setProp("ImageColor3", rgbaToColor3({ r = 1, g = 1, b = 1, a = 1 }))
		end
		setProp("ImageTransparency", 1 - Util.clamp01(imgAlpha))
	end

	-- text
	local typo = node.typography
	if typo then
		setProp("Text", typo.characters or "")
		setProp("TextSize", math.max(1, math.floor((typo.fontSize or 14) + 0.5)))
		local textPaint = solidPaint(visual.fills)
		if textPaint then
			setProp("TextColor3", rgbaToColor3(textPaint.color))
			setProp("TextTransparency", 1 - Util.clamp01((textPaint.color and textPaint.color.a or 1) * (textPaint.opacity or 1)))
		end
		local weight = typo.fontWeight or 400
		local font
		if weight >= 800 then
			font = Enum.Font.GothamBlack
		elseif weight >= 700 then
			font = Enum.Font.GothamBold
		elseif weight >= 500 then
			font = Enum.Font.GothamMedium
		else
			font = Enum.Font.Gotham
		end
		setProp("Font", font)
		local alignH = typo.textAlignHorizontal
		if alignH == "CENTER" then
			setProp("TextXAlignment", Enum.TextXAlignment.Center)
		elseif alignH == "RIGHT" then
			setProp("TextXAlignment", Enum.TextXAlignment.Right)
		else
			setProp("TextXAlignment", Enum.TextXAlignment.Left)
		end
		local alignV = typo.textAlignVertical
		if alignV == "CENTER" then
			setProp("TextYAlignment", Enum.TextYAlignment.Center)
		elseif alignV == "BOTTOM" then
			setProp("TextYAlignment", Enum.TextYAlignment.Bottom)
		else
			setProp("TextYAlignment", Enum.TextYAlignment.Top)
		end
		setProp("TextWrapped", typo.textAutoResize ~= "WIDTH_AND_HEIGHT")
		setProp("TextScaled", false)
		setProp("RichText", false)
	end

	-- clipping
	if layout.clipsContent then
		setProp("ClipsDescendants", true)
	end

	-- visible
	setProp("Visible", node.visible ~= false)
end

--- Create/refresh a UICorner honoring per-corner radii from Figma.
local function applyCorners(inst: Instance, visual: any)
	local radius = visual.cornerRadius
	local radii = visual.rectangleCornerRadii
	local existing = inst:FindFirstChild("LYNK_Corner")
	if type(radii) == "table" and radii[1] ~= nil then
		local c = existing or new("UICorner", { Name = "LYNK_Corner" })
		local ci = c :: any
		pcall(function()
			ci.CornerRadius = UDim.new(0, radii[1] or 0)
		end)
		pcall(function()
			ci.TopLeftRadius = UDim.new(0, radii[1] or 0)
			ci.TopRightRadius = UDim.new(0, radii[2] or 0)
			ci.BottomRightRadius = UDim.new(0, radii[3] or 0)
			ci.BottomLeftRadius = UDim.new(0, radii[4] or 0)
		end)
		c.Parent = inst
	elseif type(radius) == "number" and radius > 0 then
		local c = existing or new("UICorner", { Name = "LYNK_Corner" })
		;(c :: any).CornerRadius = UDim.new(0, radius)
		c.Parent = inst
	elseif existing then
		existing:Destroy()
	end
end

--- Ensure/refresh child modifier instances (UICorner/UIStroke/UIGradient/UIPadding/layouts).
function Mapper.applyModifiers(inst: Instance, node: any)
	local visual = node.visual or {}
	local layout = node.layout or {}

	-- corner radius (per-corner from Figma when mixed)
	applyCorners(inst, visual)

	-- stroke
	local strokePaint = solidPaint(visual.strokes)
	local strokeWeight = visual.strokeWeight
	if type(strokeWeight) == "table" then
		strokeWeight = strokeWeight.top or 0
	end
	if strokePaint and type(strokeWeight) == "number" and strokeWeight > 0 then
		local s = inst:FindFirstChild("LYNK_Stroke") or new("UIStroke", { Name = "LYNK_Stroke" })
		local si = s :: any
		si.Color = rgbaToColor3(strokePaint.color)
		si.Thickness = strokeWeight
		si.Transparency = 1 - Util.clamp01((strokePaint.color and strokePaint.color.a or 1) * (strokePaint.opacity or 1))
		si.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Parent = inst
	else
		local existing = inst:FindFirstChild("LYNK_Stroke")
		if existing then
			existing:Destroy()
		end
	end

	-- gradient
	local grad = gradientPaint(visual.fills)
	if grad and grad.stops then
		local g = inst:FindFirstChild("LYNK_Gradient") or new("UIGradient", { Name = "LYNK_Gradient" })
		local gi = g :: any
		local colorKeys = {}
		local transKeys = {}
		for _, stop in ipairs(grad.stops) do
			local c = stop.color or { r = 0, g = 0, b = 0, a = 1 }
			table.insert(colorKeys, ColorSequenceKeypoint.new(Util.clamp01(stop.position or 0), rgbaToColor3(c)))
			table.insert(transKeys, NumberSequenceKeypoint.new(Util.clamp01(stop.position or 0), 1 - Util.clamp01(c.a or 1)))
		end
		if #colorKeys >= 2 then
			gi.Color = ColorSequence.new(colorKeys)
			gi.Transparency = NumberSequence.new(transKeys)
			gi.Rotation = (grad.type == "GRADIENT_LINEAR" and 45 or 0)
			g.Parent = inst
		end
	end

	-- padding
	local pad = layout.padding
	if pad and (pad.top or 0) + (pad.right or 0) + (pad.bottom or 0) + (pad.left or 0) > 0 then
		local p = inst:FindFirstChild("LYNK_Padding") or new("UIPadding", { Name = "LYNK_Padding" })
		local pi = p :: any
		pi.PaddingTop = UDim.new(0, pad.top or 0)
		pi.PaddingRight = UDim.new(0, pad.right or 0)
		pi.PaddingBottom = UDim.new(0, pad.bottom or 0)
		pi.PaddingLeft = UDim.new(0, pad.left or 0)
		p.Parent = inst
	end

	-- auto layout
	local existingLayout = inst:FindFirstChild("LYNK_Layout")
	if layout.mode == "VERTICAL" or layout.mode == "HORIZONTAL" then
		local l = existingLayout or new("UIListLayout", { Name = "LYNK_Layout" })
		local li = l :: any
		li.FillDirection = layout.mode == "VERTICAL" and Enum.FillDirection.Vertical or Enum.FillDirection.Horizontal
		li.Padding = UDim.new(0, layout.itemSpacing or 0)
		if layout.primaryAxisAlignItems == "CENTER" then
			li.HorizontalAlignment = Enum.HorizontalAlignment.Center
			li.VerticalAlignment = Enum.VerticalAlignment.Center
		elseif layout.primaryAxisAlignItems == "MAX" then
			li.HorizontalAlignment = Enum.HorizontalAlignment.Right
			li.VerticalAlignment = Enum.VerticalAlignment.Bottom
		else
			li.HorizontalAlignment = Enum.HorizontalAlignment.Left
			li.VerticalAlignment = Enum.VerticalAlignment.Top
		end
		l.Parent = inst
	elseif existingLayout then
		existingLayout:Destroy()
	end
end

--- Apply a variant node's look (background, stroke, corners, text color) to an
--- already-rendered instance — drives hover/press states in the preview.
function Mapper.applyStateVisual(inst: Instance, node: any)
	if type(node) ~= "table" then
		return
	end
	local visual = node.visual or {}
	local function setP(prop: string, value: any)
		pcall(function()
			(inst :: any)[prop] = value
		end)
	end

	-- background (TEXT fills are glyph color, never a background)
	local isText = node.typography ~= nil
	local solid: any? = nil
	if not isText then
		solid = solidPaint(visual.fills) or solidPaint(visual.background)
	end
	if solid then
		setP("BackgroundColor3", rgbaToColor3(solid.color))
		local a = (solid.color and solid.color.a or 1) * (solid.opacity or 1) * (visual.opacity or 1)
		setP("BackgroundTransparency", 1 - Util.clamp01(a))
	elseif not isText and gradientPaint(visual.fills) then
		setP("BackgroundColor3", Color3.new(1, 1, 1))
		setP("BackgroundTransparency", 1 - Util.clamp01(visual.opacity or 1))
	else
		setP("BackgroundTransparency", 1)
	end

	-- stroke
	local strokePaint = solidPaint(visual.strokes)
	local sw = visual.strokeWeight
	if type(sw) == "table" then
		sw = sw.top or 0
	end
	local strokeInst = inst:FindFirstChild("LYNK_Stroke")
	if strokePaint and type(sw) == "number" and sw > 0 then
		if not strokeInst then
			strokeInst = new("UIStroke", { Name = "LYNK_Stroke" })
			strokeInst.Parent = inst
		end
		local si = strokeInst :: any
		si.Color = rgbaToColor3(strokePaint.color)
		si.Thickness = sw
		si.Transparency = 1 - Util.clamp01((strokePaint.color and strokePaint.color.a or 1) * (strokePaint.opacity or 1))
	elseif strokeInst then
		(strokeInst :: any).Transparency = 1
	end

	-- corners
	applyCorners(inst, visual)

	-- text color when the control itself carries the label
	if isText and (inst:IsA("TextLabel") or inst:IsA("TextButton")) then
		local tp = solidPaint(visual.fills)
		if tp then
			setP("TextColor3", rgbaToColor3(tp.color))
			setP("TextTransparency", 1 - Util.clamp01((tp.color and tp.color.a or 1) * (tp.opacity or 1)))
		end
	end

	-- children: pair rendered children (skipping LYNK_ modifiers) by index
	local schema = State.schema
	if not schema then
		return
	end
	local rendered = {}
	for _, ch in ipairs(inst:GetChildren()) do
		if not ch:IsA("UICorner") and not ch:IsA("UIStroke") and not ch:IsA("UIGradient")
			and not ch:IsA("UIPadding") and not ch:IsA("UIListLayout") and not ch:IsA("UIScale") then
			table.insert(rendered, ch)
		end
	end
	local childIds = node.children or {}
	for i, childInst in ipairs(rendered) do
		local childId = childIds[i]
		local childNode = childId and schema.nodes[childId]
		if childNode then
			Mapper.applyStateVisual(childInst, childNode)
		end
	end
end

--- Resolve "Parent=<layerName>" tags into a structural override map.
--- A node whose layer name carries `Parent=<name>` is re-parented under the node
--- whose display name matches <name> (case-insensitive). Returns:
---   displayName    – nodeId → sanitized instance name (mirrors the build)
---   overrideParent – childId → targetId
---   children       – effective parentId → ordered child ids (Figma DFS order)
function Mapper.computeStructure(schema: any): any
	local nodes = (schema and schema.nodes) or {}
	local rootId = schema and schema.metadata and schema.metadata.rootId or nil

	local displayName: { [string]: string } = {}
	local wantedParent: { [string]: string } = {}
	for id, node in pairs(nodes) do
		local img = imagePaint((node.visual or {}).fills)
		local parsed = NameTag.parse(node.name)
		local class = mapClass(node, img ~= nil, false, parsed.tagClass)
		local name = node.name or class
		local ok, probe = pcall(Instance.new, class)
		if ok and probe then
			local dn = NameTag.applyTo(probe, parsed)
			probe:Destroy()
			if dn ~= "" then
				name = dn
			end
		end
		displayName[id] = Util.sanitizeName(name)
		if parsed.parentName and parsed.parentName ~= "" then
			wantedParent[id] = parsed.parentName :: string
		end
	end

	-- deterministic traversal order (Figma DFS from the root)
	local order: { string } = {}
	local function walk(id: string)
		local node = nodes[id]
		if not node then
			return
		end
		table.insert(order, id)
		for _, cid in ipairs(node.children or {}) do
			walk(cid)
		end
	end
	if rootId and nodes[rootId] then
		walk(rootId)
	end
	for id in pairs(nodes) do
		if not table.find(order, id) then
			table.insert(order, id)
		end
	end

	local nameIndex: { [string]: string } = {}
	for _, id in ipairs(order) do
		local key = string.lower(displayName[id] or "")
		if key ~= "" and nameIndex[key] == nil then
			nameIndex[key] = id
		end
	end

	local function isAncestor(ancestorId: string, ofId: string): boolean
		local cur = nodes[ofId] and nodes[ofId].parentId
		local guard = 0
		while cur and guard < 1000 do
			if cur == ancestorId then
				return true
			end
			cur = nodes[cur] and nodes[cur].parentId
			guard += 1
		end
		return false
	end

	local overrideParent: { [string]: string } = {}
	for id, pname in pairs(wantedParent) do
		local target = nameIndex[string.lower(pname)]
		-- skip self-referential or cyclic re-parenting
		if target and target ~= id and not isAncestor(id, target) then
			overrideParent[id] = target
		end
	end

	local children: { [string]: { string } } = {}
	for _, id in ipairs(order) do
		local effParent = overrideParent[id] or (nodes[id] and nodes[id].parentId)
		if effParent then
			if children[effParent] == nil then
				children[effParent] = {}
			end
			table.insert(children[effParent], id)
		end
	end

	return { displayName = displayName, overrideParent = overrideParent, children = children }
end

--- Move nodes carrying a `Parent=<name>` tag under their resolved target. Run
--- after the full tree is built so every target instance already exists.
function Mapper.applyParentOverrides(): ()
	local structure = State.structure
	local schema = State.schema
	if not structure or not schema then
		return
	end
	local nodes = schema.nodes
	local function isUnder(inst: Instance, ancestor: Instance): boolean
		local cur = inst.Parent
		local guard = 0
		while cur and guard < 1000 do
			if cur == ancestor then
				return true
			end
			cur = cur.Parent
			guard += 1
		end
		return false
	end
	for childId, parentId in pairs(structure.overrideParent) do
		local child = State.instanceByFigmaId[childId]
		local parent = State.instanceByFigmaId[parentId]
		if child and parent and child.Parent ~= parent and not isUnder(parent, child) then
			child.Parent = parent
			local cn, pn = nodes[childId], nodes[parentId]
			local ca, pa = cn and cn.absolute, pn and pn.absolute
			if ca and pa and not (cn.layout and cn.layout.absolute) then
				pcall(function()
					(child :: any).Position = UDim2.fromOffset((ca.x or 0) - (pa.x or 0), (ca.y or 0) - (pa.y or 0))
				end)
			end
		end
	end
end

--- Create a fresh instance tree from a schema node.
function Mapper.createTree(nodeId: string, parentNode: any?, forceButton: boolean?): Instance?
	local schema = State.schema
	if not schema then
		return nil
	end
	local node = schema.nodes[nodeId]
	if not node then
		return nil
	end
	local img = imagePaint((node.visual or {}).fills)
	local parsed = NameTag.parse(node.name)
	local class = mapClass(node, img ~= nil, forceButton, parsed.tagClass)
	local inst = Instance.new(class)
	inst:SetAttribute("FigmaNodeId", node.id)
	inst:SetAttribute("LYNKGenerated", true)

	Mapper.applyVisual(inst, node, parentNode)
	Mapper.applyModifiers(inst, node)
	if parsed.semantic == "button" then
		pcall(function()
			(inst :: any).Text = ""
		end)
	end
	local displayName = NameTag.applyTo(inst, parsed)
	inst.Name = Util.sanitizeName(displayName ~= "" and displayName or (node.name or class))

	State.instanceByFigmaId[node.id] = inst

	local skipped, states = Mapper.planVariantChildren(schema, node)
	for _, childId in ipairs(node.children or {}) do
		if not skipped[childId] then
			local child = Mapper.createTree(childId, node, states[childId] ~= nil)
			if child then
				child.Parent = inst
				local stateMap = states[childId]
				if stateMap then
					for stateName, variantId in pairs(stateMap) do
						(child :: any):SetAttribute("LYNK_State_" .. stateName, variantId)
					end
				end
			end
		end
	end
	return inst
end

--- Apply an incremental change (dotted paths) to an existing instance.
function Mapper.applyChanges(nodeId: string, changes: any)
	local schema = State.schema
	if not schema then
		return
	end
	local node = schema.nodes[nodeId]
	if not node then
		return
	end

	-- merge into schema
	for key, value in pairs(changes or {}) do
		if not string.find(key, "[%.:]") then
			node[key] = value
		else
			-- dotted path
			local parts = {}
			for part in string.gmatch(key, "[^%.:%[%]]+") do
				table.insert(parts, part)
			end
			local cursor = node
			for i = 1, #parts - 1 do
				local k = parts[i]
				if tonumber(k) then
					k = tonumber(k) + 1
				end
				cursor = cursor[k]
				if cursor == nil then
					break
				end
			end
			if cursor ~= nil then
				local k = parts[#parts]
				if tonumber(k) then
					k = tonumber(k) + 1
				end
				cursor[k] = value
			end
		end
	end

	local inst = State.instanceByFigmaId[nodeId]
	if inst then
		local parentNode = node.parentId and schema.nodes[node.parentId] or nil
		Mapper.applyVisual(inst, node, parentNode)
		Mapper.applyModifiers(inst, node)
		if node.name then
			inst.Name = Util.sanitizeName(node.name)
		end
	end
end

function Mapper.rebuildAll(rootParent: Instance, rootNodeId: string): Instance?
	State.instanceByFigmaId = {}
	State.structure = Mapper.computeStructure(State.schema)
	local inst = Mapper.createTree(rootNodeId, nil)
	if inst then
		inst.Parent = rootParent
	end
	Mapper.applyParentOverrides()
	return inst
end

--- Reorder/resize children to match schema order.
function Mapper.reorder(nodeId: string, order: any)
	local schema = State.schema
	if not schema then
		return
	end
	local parentNode = schema.nodes[nodeId]
	if not parentNode then
		return
	end
	parentNode.children = order
	local parentInst = State.instanceByFigmaId[nodeId]
	if not parentInst then
		return
	end
	local sorted = {}
	for _, childId in ipairs(order) do
		local inst = State.instanceByFigmaId[childId]
		if inst then
			table.insert(sorted, inst)
		end
	end
	local layoutObj = parentInst:FindFirstChild("LYNK_Layout")
	for index, inst in ipairs(sorted) do
		inst.LayoutOrder = index
		if layoutObj then
			inst.LayoutOrder = index
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  CODE GENERATION (roblox-ts + Luau React)
-- ═══════════════════════════════════════════════════════════════════════════

local CodeGen = {}

local function fontEnum(weight: number): string
	if weight >= 800 then
		return "Enum.Font.GothamBlack"
	elseif weight >= 700 then
		return "Enum.Font.GothamBold"
	elseif weight >= 500 then
		return "Enum.Font.GothamMedium"
	end
	return "Enum.Font.Gotham"
end

local function tsFontEnum(weight: number): string
	if weight >= 800 then
		return "Enum.Font.GothamBlack"
	elseif weight >= 700 then
		return "Enum.Font.GothamBold"
	elseif weight >= 500 then
		return "Enum.Font.GothamMedium"
	end
	return "Enum.Font.Gotham"
end

local function escapeString(s: string): string
	return (s:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "\\r"))
end

--- Build a flat property table for a node (shared between Luau and TS emitters).
function CodeGen.propsFor(node: any, parentNode: any?, nameProps: { { name: string, lua: string } }?, buttonTag: boolean?): { { string } }
	-- returns list of { luaKey, luaValue, tsValue }
	local props = {}
	local visual = node.visual or {}
	local layout = node.layout or {}

	local function add(key: string, luaValue: string, tsValue: string?)
		table.insert(props, { key, luaValue, tsValue or luaValue })
	end

	local function setProp(key: string, luaValue: string, tsValue: string?)
		for i = #props, 1, -1 do
			if props[i][1] == key then
				table.remove(props, i)
			end
		end
		add(key, luaValue, tsValue)
	end

	local rel = Mapper.relativePosition(node, parentNode)
	local inAutoLayout = parentNode and parentNode.layout and parentNode.layout.mode ~= "NONE"
		and not (layout.absolute or false)
	if inAutoLayout then
		add("Position", "UDim2.fromOffset(0, 0)")
	elseif math.abs(node.rotation or 0) > 0.001 then
		local px, py = rotatedOffset(node)
		add("Position", string.format("UDim2.fromOffset(%s, %s)", Util.num(px), Util.num(py)))
	else
		add("Position", string.format("UDim2.fromOffset(%s, %s)", Util.num(rel.X), Util.num(rel.Y)))
	end
	add("Size", string.format("UDim2.fromOffset(%s, %s)", Util.num(node.width or 0), Util.num(node.height or 0)))
	add("AnchorPoint", "Vector2.new(0, 0)")
	add("BorderSizePixel", "0")

	if type(node.rotation) == "number" and math.abs(node.rotation or 0) > 0.001 then
		add("Rotation", Util.num(robloxRotation(node)))
	end

	local img = imagePaint(visual.fills)
	local solid: any? = nil
	if not node.typography then
		solid = solidPaint(visual.fills) or solidPaint(visual.background)
	end
	if node.typography then
		-- TEXT fills carry the glyph color; the background stays clear
		add("BackgroundTransparency", "1")
	elseif img then
		local uri = (img.assetId and Assets.uriFor(img.assetId)) or ""
		if uri == "" then
			add("Image", "\"\" --[[ TODO: asset pending — see assets.json ]]")
		else
			add("Image", string.format("\"%s\"", uri))
		end
		local scaleType = "Enum.ScaleType.Crop"
		if img.scaleMode == "FIT" then
			scaleType = "Enum.ScaleType.Fit"
		elseif img.scaleMode == "TILE" then
			scaleType = "Enum.ScaleType.Tile"
		end
		add("ScaleType", scaleType)
		add("ImageTransparency", Util.num(1 - Util.clamp01((img.opacity or 1) * ((img.color and img.color.a) or 1))))
		if solid then
			local ic = solid.color or { r = 1, g = 1, b = 1, a = 1 }
			add("BackgroundColor3", string.format("Color3.fromRGB(%d, %d, %d)",
				math.floor(Util.clamp01(ic.r) * 255 + 0.5),
				math.floor(Util.clamp01(ic.g) * 255 + 0.5),
				math.floor(Util.clamp01(ic.b) * 255 + 0.5)))
			add("BackgroundTransparency", Util.num(1 - Util.clamp01((ic.a or 1) * (solid.opacity or 1) * (visual.opacity or 1))))
		else
			add("BackgroundTransparency", "1")
		end
	elseif solid then
		local c = solid.color or { r = 1, g = 1, b = 1, a = 1 }
		add("BackgroundColor3", string.format("Color3.fromRGB(%d, %d, %d)",
			math.floor(Util.clamp01(c.r) * 255 + 0.5),
			math.floor(Util.clamp01(c.g) * 255 + 0.5),
			math.floor(Util.clamp01(c.b) * 255 + 0.5)))
		add("BackgroundTransparency", Util.num(1 - Util.clamp01((c.a or 1) * (solid.opacity or 1) * (visual.opacity or 1))))
	elseif gradientPaint(visual.fills) then
		-- white base under the UIGradient so gradients show as authored
		add("BackgroundColor3", "Color3.new(1, 1, 1)")
		add("BackgroundTransparency", Util.num(1 - Util.clamp01(visual.opacity or 1)))
	else
		add("BackgroundTransparency", "1")
	end

	if layout.clipsContent then
		add("ClipsDescendants", "true")
	end
	if node.visible == false then
		add("Visible", "false")
	end

	local typo = node.typography
	if typo then
		add("Text", string.format("\"%s\"", escapeString(typo.characters or "")))
		add("TextSize", tostring(math.max(1, math.floor((typo.fontSize or 14) + 0.5))))
		local textPaint = solidPaint(visual.fills)
		if textPaint then
			local c = textPaint.color or { r = 1, g = 1, b = 1, a = 1 }
			add("TextColor3", string.format("Color3.fromRGB(%d, %d, %d)",
				math.floor(Util.clamp01(c.r) * 255 + 0.5),
				math.floor(Util.clamp01(c.g) * 255 + 0.5),
				math.floor(Util.clamp01(c.b) * 255 + 0.5)))
			add("TextTransparency", Util.num(1 - Util.clamp01((c.a or 1) * (textPaint.opacity or 1))))
		end
		add("Font", fontEnum(typo.fontWeight or 400), tsFontEnum(typo.fontWeight or 400))
		local alignH = typo.textAlignHorizontal
		add("TextXAlignment", alignH == "CENTER" and "Enum.TextXAlignment.Center"
			or alignH == "RIGHT" and "Enum.TextXAlignment.Right"
			or "Enum.TextXAlignment.Left")
		local alignV = typo.textAlignVertical
		add("TextYAlignment", alignV == "CENTER" and "Enum.TextYAlignment.Center"
			or alignV == "BOTTOM" and "Enum.TextYAlignment.Bottom"
			or "Enum.TextYAlignment.Top")
		add("TextWrapped", "true")
	end

	-- a "_Button" tag is always an empty-text button (content lives in children)
	if buttonTag then
		setProp("Text", "\"\"")
	end
	for _, np in ipairs(nameProps or {}) do
		setProp(np.name, np.lua)
	end

	return props
end

--- Collect interaction-derived event handlers for a node.
function CodeGen.eventsFor(node: any): { { name: string, event: string, action: any } }
	local out = {}
	local schema = State.schema
	if not schema then
		return out
	end
	for _, eid in ipairs(node.events or {}) do
		local inter = schema.interactions[eid]
		if inter then
			table.insert(out, {
				name = inter.event,
				event = inter.event,
				action = inter.action,
				animation = inter.animation,
				id = inter.id,
			})
		end
	end
	return out
end

local function hasHoverAnimation(node: any): (boolean, number, number)
	for _, ev in ipairs(CodeGen.eventsFor(node)) do
		if ev.event == "whileHovering" or ev.event == "hover" or ev.event == "mouseEnter" then
			local anim = ev.animation
			local duration = anim and anim.duration or 0.15
			return true, duration, 1.05
		end
	end
	return false, 0, 0
end

local function stateRefName(nodeId: string): string
	return "ref_" .. Util.luaIdentifier(nodeId)
end

--- Build Event entries that animate a variant-set control through its
--- Default/Hover/Pressed looks (emitted into the generated Luau component).
local function stateEventProps(schema: any, node: any, stateMap: { [string]: string }, indent: string)
	local out = {}
	local baseRef = stateRefName(node.id)

	-- stable label lookup name comes from the rendered (base) variant
	local textChildName: string? = nil
	for _, cid in ipairs(node.children or {}) do
		local c = schema.nodes[cid]
		if c and c.typography then
			textChildName = Util.sanitizeName(c.name or "Label")
			break
		end
	end

	local function goalsFor(stateNode: any): string
		local visual = stateNode.visual or {}
		local isText = stateNode.typography ~= nil
		local solid: any? = nil
		if not isText then
			solid = solidPaint(visual.fills) or solidPaint(visual.background)
		end
		local goals = {}
		if solid then
			local c = solid.color or { r = 1, g = 1, b = 1, a = 1 }
			table.insert(goals, string.format("BackgroundColor3 = Color3.fromRGB(%d, %d, %d)",
				math.floor(Util.clamp01(c.r) * 255 + 0.5),
				math.floor(Util.clamp01(c.g) * 255 + 0.5),
				math.floor(Util.clamp01(c.b) * 255 + 0.5)))
			local a = (c.a or 1) * (solid.opacity or 1) * (visual.opacity or 1)
			table.insert(goals, "BackgroundTransparency = " .. Util.num(1 - Util.clamp01(a)))
		elseif not isText and gradientPaint(visual.fills) then
			table.insert(goals, "BackgroundColor3 = Color3.new(1, 1, 1)")
			table.insert(goals, "BackgroundTransparency = " .. Util.num(1 - Util.clamp01(visual.opacity or 1)))
		else
			table.insert(goals, "BackgroundTransparency = 1")
		end
		if isText then
			local tp = solidPaint(visual.fills)
			if tp then
				local c = tp.color or { r = 1, g = 1, b = 1, a = 1 }
				table.insert(goals, string.format("TextColor3 = Color3.fromRGB(%d, %d, %d)",
					math.floor(Util.clamp01(c.r) * 255 + 0.5),
					math.floor(Util.clamp01(c.g) * 255 + 0.5),
					math.floor(Util.clamp01(c.b) * 255 + 0.5)))
				table.insert(goals, "TextTransparency = " .. Util.num(1 - Util.clamp01((c.a or 1) * (tp.opacity or 1))))
			end
		end
		return "{ " .. table.concat(goals, ", ") .. " }"
	end

	local function handler(stateNode: any): string
		local visual = stateNode.visual or {}
		local lines = {}
		local function line(s: string)
			table.insert(lines, indent .. "\t\t\t" .. s)
		end
		line("local inst = " .. baseRef .. ".current")
		line("if inst then")
		line("\tuiAnimate(inst, " .. goalsFor(stateNode) .. ", 0.15)")

		local strokePaint = solidPaint(visual.strokes)
		local sw = visual.strokeWeight
		if type(sw) == "table" then
			sw = sw.top or 0
		end
		line("\tlocal s = inst:FindFirstChild(\"LYNK_Stroke\")")
		if strokePaint and type(sw) == "number" and sw > 0 then
			local c = strokePaint.color or { r = 1, g = 1, b = 1, a = 1 }
			line(string.format(
				"\tif s then uiAnimate(s, { Color = Color3.fromRGB(%d, %d, %d), Transparency = %s, Thickness = %s }, 0.15) end",
				math.floor(Util.clamp01(c.r) * 255 + 0.5),
				math.floor(Util.clamp01(c.g) * 255 + 0.5),
				math.floor(Util.clamp01(c.b) * 255 + 0.5),
				Util.num(1 - Util.clamp01((c.a or 1) * (strokePaint.opacity or 1))),
				Util.num(sw)))
		else
			line("\tif s then uiAnimate(s, { Transparency = 1 }, 0.15) end")
		end

		local radii = visual.rectangleCornerRadii
		local radius = visual.cornerRadius
		line("\tlocal cornerInst = inst:FindFirstChild(\"LYNK_Corner\")")
		if type(radii) == "table" and radii[1] ~= nil then
			line(string.format(
				"\tif cornerInst then uiAnimate(cornerInst, { CornerRadius = UDim.new(0, %s), TopLeftRadius = UDim.new(0, %s), TopRightRadius = UDim.new(0, %s), BottomRightRadius = UDim.new(0, %s), BottomLeftRadius = UDim.new(0, %s) }, 0.15) end",
				Util.num(radii[1] or 0), Util.num(radii[1] or 0), Util.num(radii[2] or 0),
				Util.num(radii[3] or 0), Util.num(radii[4] or 0)))
		elseif type(radius) == "number" and radius > 0 then
			line("\tif cornerInst then uiAnimate(cornerInst, { CornerRadius = UDim.new(0, " .. Util.num(radius) .. ") }, 0.15) end")
		else
			line("\tif cornerInst then uiAnimate(cornerInst, { CornerRadius = UDim.new(0, 0) }, 0.15) end")
		end

		if textChildName then
			local stateTextNode = nil
			for _, cid in ipairs(stateNode.children or {}) do
				local c2 = schema.nodes[cid]
				if c2 and c2.typography then
					stateTextNode = c2
					break
				end
			end
			if stateTextNode then
				local tp = solidPaint((stateTextNode.visual or {}).fills)
				if tp then
					local c = tp.color or { r = 1, g = 1, b = 1, a = 1 }
					line("\tlocal label = inst:FindFirstChild(\"" .. escapeString(textChildName) .. "\")")
					line(string.format(
						"\tif label and (label:IsA(\"TextLabel\") or label:IsA(\"TextButton\")) then uiAnimate(label, { TextColor3 = Color3.fromRGB(%d, %d, %d), TextTransparency = %s }, 0.15) end",
						math.floor(Util.clamp01(c.r) * 255 + 0.5),
						math.floor(Util.clamp01(c.g) * 255 + 0.5),
						math.floor(Util.clamp01(c.b) * 255 + 0.5),
						Util.num(1 - Util.clamp01((c.a or 1) * (tp.opacity or 1)))))
				end
			end
		end
		line("end")
		return string.format("function()\n%s\n%s\t\tend", table.concat(lines, "\n"), indent .. "\t\t")
	end

	local function push(key: string, stateId: string)
		local sn = schema.nodes[stateId]
		if sn then
			table.insert(out, { key = key, handler = handler(sn) })
		end
	end
	if stateMap.hover then
		push("MouseEnter", stateMap.hover)
	end
	if stateMap.hover or stateMap.pressed then
		push("MouseLeave", node.id)
	end
	if stateMap.pressed then
		push("MouseButton1Down", stateMap.pressed)
		push("MouseButton1Up", stateMap.hover or node.id)
	end
	return out
end

--- Emit Luau (react-lua) source.
function CodeGen.emitLuau(schema: any): string
	local rootNode = schema.nodes[schema.metadata.rootId]
	local structure = Mapper.computeStructure(schema)
	local funcName = Util.luaIdentifier(schema.metadata.name or "LYNKUI")
	local lines = {}
	local function w(line: string)
		table.insert(lines, line)
	end

	w("--!strict")
	w("-- ─────────────────────────────────────────────────────────────────────────")
	w(string.format("--  Generated by LYNK v%s — DO NOT EDIT BY HAND", PLUGIN_VERSION))
	w(string.format("--  Figma: %s  (node %s)", schema.metadata.name or "?", schema.metadata.rootId))
	w(string.format("--  Revision: %d   Captured: %s", schema.revision or 0, os.date("!%Y-%m-%d %H:%M:%SZ")))
	w("--  Regenerate through the LYNK Studio plugin; manual edits will be replaced.")
	w("-- ─────────────────────────────────────────────────────────────────────────")
	w("")
	w("local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")")
	w("local TweenService = game:GetService(\"TweenService\")")
	w("")
	w("-- LYNK requires a luau React runtime (e.g. react-lua). Adjust this path if")
	w("-- your project hosts React elsewhere.")
	w("local React = require(ReplicatedStorage:WaitForChild(\"Packages\"):WaitForChild(\"React\"))")
	w("")
	w("local e = React.createElement")
	w("")
	w("-- LYNK: abstract animation layer. Swap the body for a custom animation")
	w("-- system without touching the generated UI tree.")
	w("local function uiAnimate(instance: Instance, goal: { [string]: any }, duration: number)")
	w("\tlocal info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)")
	w("\tTweenService:Create(instance, info, goal):Play()")
	w("end")
	w("")

	-- recursive emitter
	local function emitNode(nodeId: string, indent: string, parentNode: any?)
		local node = schema.nodes[nodeId]
		if not node then
			return
		end
		local stateMap: { [string]: string }? = nil
		if parentNode then
			local _, sMap = Mapper.planVariantChildren(schema, parentNode)
			stateMap = sMap[nodeId]
		end
		local img = imagePaint((node.visual or {}).fills)
		local parsed = NameTag.parse(node.name)
		local class = mapClass(node, img ~= nil, stateMap ~= nil, parsed.tagClass)
		local probe = Instance.new(class)
		local displayName, nameProps = NameTag.applyTo(probe, parsed)
		probe:Destroy()
		local props = CodeGen.propsFor(node, parentNode, nameProps, parsed.semantic == "button")
		local events = CodeGen.eventsFor(node)
		local hover, hoverDuration, hoverScale = hasHoverAnimation(node)
		if stateMap then
			-- real variant looks replace the scale-fallback hover
			hover = false
		end

		w(indent .. "e(\"" .. class .. "\", {")
		w(indent .. "\tName = \"" .. escapeString(Util.sanitizeName(displayName ~= "" and displayName or (node.name or class))) .. "\",")
		for _, kv in ipairs(props) do
			w(indent .. "\t" .. kv[1] .. " = " .. kv[2] .. ",")
		end
		if stateMap then
			w(indent .. "\tRef = " .. stateRefName(node.id) .. ",")
		end

		-- event wiring
		local eventProps = {}
		for _, ev in ipairs(events) do
			if ev.event == "click" or ev.event == "tap" then
				table.insert(eventProps, {
					key = (class == "TextButton" or class == "ImageButton") and "Activated" or "InputBegan",
					handler = string.format("function()\n%s\t\t\t-- LYNK: Figma click action %s -> implement game logic here\n%s\t\tend",
						indent .. "\t\t\t", tostring(ev.action and ev.action.type or "unknown"), indent .. "\t\t"),
				})
			elseif ev.event == "whileHovering" or ev.event == "hover" or ev.event == "mouseEnter" then
				if not hover and not stateMap then
					table.insert(eventProps, { key = "MouseEnter", handler = "function() end" })
				end
			end
		end
		if hover then
			table.insert(eventProps, {
				key = "MouseEnter",
				handler = string.format("function()\n%s\t\t\tlocal s = script.Parent:FindFirstChild(\"HoverScale\")\n%s\t\t\tif s then uiAnimate(s, { Scale = %.2f }, %.2f) end\n%s\t\tend", indent .. "\t\t\t", indent .. "\t\t\t", hoverScale, hoverDuration, indent .. "\t\t"),
			})
			table.insert(eventProps, {
				key = "MouseLeave",
				handler = string.format("function()\n%s\t\t\tlocal s = script.Parent:FindFirstChild(\"HoverScale\")\n%s\t\t\tif s then uiAnimate(s, { Scale = 1 }, %.2f) end\n%s\t\tend", indent .. "\t\t\t", indent .. "\t\t\t", hoverDuration, indent .. "\t\t"),
			})
		end
		if stateMap then
			for _, ep in ipairs(stateEventProps(schema, node, stateMap, indent)) do
				table.insert(eventProps, ep)
			end
		end
		if #eventProps > 0 then
			w(indent .. "\tEvent = {")
			for _, ep in ipairs(eventProps) do
				w(indent .. "\t\t" .. ep.key .. " = " .. ep.handler .. ",")
			end
			w(indent .. "\t},")
		end
		w(indent .. "}, {")

		-- modifiers
		local luauRadii = (node.visual or {}).rectangleCornerRadii
		if type(luauRadii) == "table" and luauRadii[1] ~= nil then
			w(string.format("%se(\"UICorner\", { CornerRadius = UDim.new(0, %s), TopLeftRadius = UDim.new(0, %s), TopRightRadius = UDim.new(0, %s), BottomRightRadius = UDim.new(0, %s), BottomLeftRadius = UDim.new(0, %s) }),",
				indent .. "\t",
				Util.num(luauRadii[1] or 0), Util.num(luauRadii[1] or 0), Util.num(luauRadii[2] or 0),
				Util.num(luauRadii[3] or 0), Util.num(luauRadii[4] or 0)))
		elseif (node.visual or {}).cornerRadius and node.visual.cornerRadius > 0 then
			w(indent .. "\te(\"UICorner\", { CornerRadius = UDim.new(0, " .. Util.num(node.visual.cornerRadius) .. ") }),")
		end
		local strokePaint = solidPaint((node.visual or {}).strokes)
		local strokeWeight = (node.visual or {}).strokeWeight
		if type(strokeWeight) == "table" then
			strokeWeight = strokeWeight.top
		end
		if strokePaint and type(strokeWeight) == "number" and strokeWeight > 0 then
			local c = strokePaint.color or { r = 1, g = 1, b = 1 }
			w(string.format("%se(\"UIStroke\", { Color = Color3.fromRGB(%d, %d, %d), Thickness = %s }),",
				indent .. "\t",
				math.floor(Util.clamp01(c.r) * 255 + 0.5),
				math.floor(Util.clamp01(c.g) * 255 + 0.5),
				math.floor(Util.clamp01(c.b) * 255 + 0.5),
				Util.num(strokeWeight)))
		end
		local grad = gradientPaint((node.visual or {}).fills)
		if grad and grad.stops then
			local keys = {}
			for _, stop in ipairs(grad.stops) do
				local c = stop.color or { r = 0, g = 0, b = 0, a = 1 }
				table.insert(keys, string.format("ColorSequenceKeypoint.new(%s, Color3.fromRGB(%d, %d, %d))",
					Util.num(Util.clamp01(stop.position or 0)),
					math.floor(Util.clamp01(c.r) * 255 + 0.5),
					math.floor(Util.clamp01(c.g) * 255 + 0.5),
					math.floor(Util.clamp01(c.b) * 255 + 0.5)))
			end
			if #keys >= 2 then
				w(indent .. "\te(\"UIGradient\", { Color = ColorSequence.new({ " .. table.concat(keys, ", ") .. " }) }),")
			end
		end
		local layout = node.layout or {}
		local pad = layout.padding
		if pad and (pad.top or 0) + (pad.right or 0) + (pad.bottom or 0) + (pad.left or 0) > 0 then
			w(string.format("%se(\"UIPadding\", { PaddingTop = UDim.new(0, %s), PaddingRight = UDim.new(0, %s), PaddingBottom = UDim.new(0, %s), PaddingLeft = UDim.new(0, %s) }),",
				indent .. "\t", Util.num(pad.top or 0), Util.num(pad.right or 0), Util.num(pad.bottom or 0), Util.num(pad.left or 0)))
		end
		if layout.mode == "VERTICAL" or layout.mode == "HORIZONTAL" then
			w(string.format("%se(\"UIListLayout\", { FillDirection = %s, Padding = UDim.new(0, %s) }),",
				indent .. "\t",
				layout.mode == "VERTICAL" and "Enum.FillDirection.Vertical" or "Enum.FillDirection.Horizontal",
				Util.num(layout.itemSpacing or 0)))
		end
		if hover then
			w(indent .. "\te(\"UIScale\", { Name = \"HoverScale\", Scale = 1 }),")
		end

		-- effects → metadata comments
		local effects = (node.visual or {}).effects or {}
		for _, effect in ipairs(effects) do
			if effect.type == "DROP_SHADOW" or effect.type == "INNER_SHADOW" then
				w(string.format("%s-- LYNK: %s not directly representable (offset %s,%s radius %s) — preserved in schema.json",
					indent .. "\t", effect.type, Util.num(effect.offset and effect.offset.x or 0), Util.num(effect.offset and effect.offset.y or 0), Util.num(effect.radius or 0)))
			elseif effect.type == "LAYER_BLUR" or effect.type == "BACKGROUND_BLUR" then
				w(string.format("%s-- LYNK: %s radius %s — preserved in schema.json", indent .. "\t", effect.type, Util.num(effect.radius or 0)))
			end
		end

		-- children (collapsed variants never render twice; Parent= overrides applied)
		local luauSkipped = Mapper.planVariantChildren(schema, node)
		for _, childId in ipairs(structure.children[node.id] or {}) do
			if not luauSkipped[childId] then
				emitNode(childId, indent .. "\t", node)
			end
		end

		w(indent .. "}),")
	end

	-- collapsed variant controls need their refs declared before the return
	local refDecls = {}
	local function collectStateRefs(nodeId: string, parentNode: any?)
		local node = schema.nodes[nodeId]
		if not node then
			return
		end
		if parentNode then
			local _, sMap = Mapper.planVariantChildren(schema, parentNode)
			if sMap[nodeId] then
				table.insert(refDecls, nodeId)
			end
		end
		local skipped = Mapper.planVariantChildren(schema, node)
		for _, childId in ipairs(structure.children[nodeId] or {}) do
			if not skipped[childId] then
				collectStateRefs(childId, node)
			end
		end
	end
	if rootNode then
		if rootNode.visual and rootNode.visual.fills and #rootNode.visual.fills > 0 then
			collectStateRefs(schema.metadata.rootId, nil)
		else
			for _, childId in ipairs(structure.children[schema.metadata.rootId] or {}) do
				collectStateRefs(childId, rootNode)
			end
		end
	end
	for _, refId in ipairs(refDecls) do
		w(string.format("local %s = React.useRef(nil :: any)", stateRefName(refId)))
	end
	if #refDecls > 0 then
		w("")
	end

	w(string.format("local function %s(props: { [string]: any }?)", funcName))
	w("\treturn e(\"ScreenGui\", {")
	w(string.format("\t\tName = \"%s\",", escapeString(Util.sanitizeName(schema.metadata.name or "LYNKUI"))))
	w("\t\tResetOnSpawn = false,")
	w("\t\tIgnoreGuiInset = true,")
	w("\t}, {")
	if rootNode then
		if rootNode.visual and rootNode.visual.fills and #rootNode.visual.fills > 0 then
			emitNode(schema.metadata.rootId, "\t\t", nil)
		else
			local rootSkipped = Mapper.planVariantChildren(schema, rootNode)
			for _, childId in ipairs(structure.children[schema.metadata.rootId] or {}) do
				if not rootSkipped[childId] then
					emitNode(childId, "\t\t", rootNode)
				end
			end
		end
	end
	w("\t})")
	w("end")
	w("")
	w("return " .. funcName)

	return table.concat(lines, "\n")
end

local function tsxTagFor(class: string): string
	local map = {
		Frame = "frame",
		TextLabel = "textlabel",
		TextButton = "textbutton",
		ImageLabel = "imagelabel",
		ImageButton = "imagebutton",
	}
	return map[class] or "frame"
end

--- Emit roblox-ts (JSX) source.
function CodeGen.emitTs(schema: any): string
	local rootNode = schema.nodes[schema.metadata.rootId]
	local structure = Mapper.computeStructure(schema)
	local funcName = Util.luaIdentifier(schema.metadata.name or "LYNKUI"):gsub("_", "")
	if string.match(funcName, "^%d") then
		funcName = "UI" .. funcName
	end
	local lines = {}
	local function w(line: string)
		table.insert(lines, line)
	end

	w("// ─────────────────────────────────────────────────────────────────────────")
	w(string.format("//  Generated by LYNK v%s — DO NOT EDIT BY HAND", PLUGIN_VERSION))
	w(string.format("//  Figma: %s  (node %s)", schema.metadata.name or "?", schema.metadata.rootId))
	w(string.format("//  Revision: %d   Captured: %s", schema.revision or 0, os.date("!%Y-%m-%d %H:%M:%SZ")))
	w("//  Regenerate through the LYNK Studio plugin; manual edits will be replaced.")
	w("// ─────────────────────────────────────────────────────────────────────────")
	w("")
	w("import React from \"@rbxts/react\";")
	w("import { TweenService } from \"@rbxts/services\";")
	w("")
	w("function uiAnimate(instance: Instance, goal: Record<string, unknown>, duration: number): void {")
	w("\tTweenService.Create(instance, new TweenInfo(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal).Play();")
	w("}")
	w("")
	w(string.format("export function %s(props: {}): React.ReactElement {", funcName))
	w("\treturn (")
	w(string.format("\t\t<screengui Name=\"%s\" ResetOnSpawn={false} IgnoreGuiInset>",
		escapeString(Util.sanitizeName(schema.metadata.name or "LYNKUI"))))

	local function emitNodeTs(nodeId: string, indent: string, parentNode: any?)
		local node = schema.nodes[nodeId]
		if not node then
			return
		end
		local stateMap: { [string]: string }? = nil
		if parentNode then
			local _, sMap = Mapper.planVariantChildren(schema, parentNode)
			stateMap = sMap[nodeId]
		end
		local img = imagePaint((node.visual or {}).fills)
		local parsed = NameTag.parse(node.name)
		local class = mapClass(node, img ~= nil, stateMap ~= nil, parsed.tagClass)
		local tag = tsxTagFor(class)
		local probe = Instance.new(class)
		local displayName, nameProps = NameTag.applyTo(probe, parsed)
		probe:Destroy()
		local props = CodeGen.propsFor(node, parentNode, nameProps, parsed.semantic == "button")
		local hover, hoverDuration, hoverScale = hasHoverAnimation(node)
		if stateMap then
			hover = false
		end

		w(indent .. "<" .. tag)
		w(indent .. "\tName=\"" .. escapeString(Util.sanitizeName(displayName ~= "" and displayName or (node.name or class))) .. "\"")
		for _, kv in ipairs(props) do
			if not string.find(kv[2], "TODO") then
				w(indent .. "\t" .. kv[1] .. "={" .. kv[3] .. "}")
			else
				w(indent .. "\t" .. kv[1] .. "={\"\"} // TODO: asset pending")
			end
		end
		if stateMap then
			local stateNames = {}
			for stateName in pairs(stateMap) do
				table.insert(stateNames, stateName)
			end
			table.sort(stateNames)
			w(string.format("%s\t// LYNK: one interactive control — Figma variant states (%s). Attach a ref and animate between them on hover/press.",
				indent, table.concat(stateNames, ", ")))
		end
		if hover then
			w(string.format("%s\t// LYNK: hover animation (%.2fs) — wire Event={{MouseEnter,MouseLeave}} with a ref to Instance", indent, hoverDuration))
		end
		w(indent .. ">")

		local tsxRadii = (node.visual or {}).rectangleCornerRadii
		if type(tsxRadii) == "table" and tsxRadii[1] ~= nil then
			w(string.format("%s\t<uicorner CornerRadius={new UDim(0, %s)} TopLeftRadius={new UDim(0, %s)} TopRightRadius={new UDim(0, %s)} BottomRightRadius={new UDim(0, %s)} BottomLeftRadius={new UDim(0, %s)} />",
				indent, Util.num(tsxRadii[1] or 0), Util.num(tsxRadii[1] or 0), Util.num(tsxRadii[2] or 0),
				Util.num(tsxRadii[3] or 0), Util.num(tsxRadii[4] or 0)))
		elseif (node.visual or {}).cornerRadius and node.visual.cornerRadius > 0 then
			w(indent .. "\t<uicorner CornerRadius={new UDim(0, " .. Util.num(node.visual.cornerRadius) .. ")} />")
		end
		local strokePaint = solidPaint((node.visual or {}).strokes)
		local strokeWeight = (node.visual or {}).strokeWeight
		if type(strokeWeight) == "table" then
			strokeWeight = strokeWeight.top
		end
		if strokePaint and type(strokeWeight) == "number" and strokeWeight > 0 then
			local c = strokePaint.color or { r = 1, g = 1, b = 1 }
			w(string.format("%s\t<uistroke Color={Color3.fromRGB(%d, %d, %d)} Thickness={%s} />",
				indent,
				math.floor(Util.clamp01(c.r) * 255 + 0.5),
				math.floor(Util.clamp01(c.g) * 255 + 0.5),
				math.floor(Util.clamp01(c.b) * 255 + 0.5),
				Util.num(strokeWeight)))
		end
		local layout = node.layout or {}
		local pad = layout.padding
		if pad and (pad.top or 0) + (pad.right or 0) + (pad.bottom or 0) + (pad.left or 0) > 0 then
			w(string.format("%s\t<uipadding PaddingTop={new UDim(0, %s)} PaddingRight={new UDim(0, %s)} PaddingBottom={new UDim(0, %s)} PaddingLeft={new UDim(0, %s)} />",
				indent, Util.num(pad.top or 0), Util.num(pad.right or 0), Util.num(pad.bottom or 0), Util.num(pad.left or 0)))
		end
		if layout.mode == "VERTICAL" or layout.mode == "HORIZONTAL" then
			w(string.format("%s\t<uilistlayout FillDirection={%s} Padding={new UDim(0, %s)} />",
				indent,
				layout.mode == "VERTICAL" and "Enum.FillDirection.Vertical" or "Enum.FillDirection.Horizontal",
				Util.num(layout.itemSpacing or 0)))
		end
		if hover then
			w(indent .. "\t<uiscale Name=\"HoverScale\" Scale={1} />")
		end

		local tsxSkipped = Mapper.planVariantChildren(schema, node)
		for _, childId in ipairs(structure.children[node.id] or {}) do
			if not tsxSkipped[childId] then
				emitNodeTs(childId, indent .. "\t", node)
			end
		end
		w(indent .. "</" .. tag .. ">")
	end

	if rootNode then
		if rootNode.visual and rootNode.visual.fills and #rootNode.visual.fills > 0 then
			emitNodeTs(schema.metadata.rootId, "\t\t\t", nil)
		else
			local tsxRootSkipped = Mapper.planVariantChildren(schema, rootNode)
			for _, childId in ipairs(structure.children[schema.metadata.rootId] or {}) do
				if not tsxRootSkipped[childId] then
					emitNodeTs(childId, "\t\t\t", rootNode)
				end
			end
		end
	end

	w("\t\t</screengui>")
	w("\t);")
	w("}")
	w("")
	w("export default " .. funcName .. ";")

	return table.concat(lines, "\n")
end

-- ═══════════════════════════════════════════════════════════════════════════
--  SCHEMA VALIDATION + HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function validateSchema(schema: any): (boolean, string?)
	if type(schema) ~= "table" then
		return false, "schema is not a table"
	end
	if type(schema.nodes) ~= "table" then
		return false, "schema.nodes missing"
	end
	if type(schema.metadata) ~= "table" or type(schema.metadata.rootId) ~= "string" then
		return false, "schema.metadata.rootId missing"
	end
	if not schema.nodes[schema.metadata.rootId] then
		return false, "root node not present in schema.nodes"
	end
	schema.assets = schema.assets or {}
	schema.interactions = schema.interactions or {}
	schema.variables = schema.variables or {}
	schema.components = schema.components or {}
	schema.animations = schema.animations or {}
	schema.revisions = schema.revisions or {}
	return true, nil
end

local function schemaStats(schema: any)
	local events = 0
	for _, node in pairs(schema.nodes or {}) do
		events += #(node.events or {})
	end
	local assets = 0
	for _ in pairs(schema.assets or {}) do
		assets += 1
	end
	local nodes = 0
	for _ in pairs(schema.nodes or {}) do
		nodes += 1
	end
	return nodes, events, assets
end

-- ═══════════════════════════════════════════════════════════════════════════
--  FIGMA EXPORT DECODER (import-only flow)
-- ═══════════════════════════════════════════════════════════════════════════

local Export = {}

--- Encode a schema into a "LYNK1:<base64(json)>" export string.
function Export.encode(schema: any): string
	local json = HttpService:JSONEncode(schema)
	local out = {}
	local n = #json
	local i = 1
	while i <= n do
		local b0 = string.byte(json, i) or 0
		local b1 = string.byte(json, i + 1)
		local b2 = string.byte(json, i + 2)
		local c0 = bit32.rshift(b0, 2)
		local c1 = bit32.bor(bit32.lshift(bit32.band(b0, 3), 4), b1 and bit32.rshift(b1, 4) or 0)
		out[#out + 1] = string.sub(B64_CHARS, c0 + 1, c0 + 1)
		out[#out + 1] = string.sub(B64_CHARS, c1 + 1, c1 + 1)
		if b1 then
			local c2 = bit32.bor(bit32.lshift(bit32.band(b1, 15), 2), b2 and bit32.rshift(b2, 6) or 0)
			out[#out + 1] = string.sub(B64_CHARS, c2 + 1, c2 + 1)
		else
			out[#out + 1] = "="
		end
		if b2 then
			out[#out + 1] = string.sub(B64_CHARS, bit32.band(b2, 63) + 1, bit32.band(b2, 63) + 1)
		else
			out[#out + 1] = "="
		end
		i += 3
	end
	return "LYNK1:" .. table.concat(out)
end

function Export.decode(code: string): (any?, string?)
	local trimmed = string.gsub(code or "", "%s", "")
	if trimmed == "" then
		return nil, "Paste a LYNK code first."
	end
	local prefix, payload = string.match(trimmed, "^([A-Za-z0-9]+):(.+)$")
	if not prefix or not payload then
		return nil, "Not a LYNK code (expected \"LYNK1:<data>\")."
	end
	if prefix ~= "LYNK1" then
		return nil, "Unsupported code version \"" .. prefix .. "\"."
	end
	local okBuf, json = pcall(function()
		return buffer.tostring(Util.base64ToBuffer(payload))
	end)
	if not okBuf or type(json) ~= "string" or json == "" then
		return nil, "Code payload is not valid base64."
	end
	local okJson, decoded = pcall(function()
		return HttpService:JSONDecode(json)
	end)
	if not okJson or type(decoded) ~= "table" then
		return nil, "Code payload is not valid JSON."
	end
	local okSchema, schemaErr = validateSchema(decoded)
	if not okSchema then
		return nil, "Invalid LYNK schema: " .. tostring(schemaErr)
	end
	return decoded, nil
end

-- ═══════════════════════════════════════════════════════════════════════════
--  INTERACTIVE PREVIEW (rendered inside the plugin dock)
-- ═══════════════════════════════════════════════════════════════════════════

local Preview = {}

function Preview.rootSize(): (number, number)
	local schema = State.schema
	local root = schema and schema.nodes[schema.metadata.rootId] or nil
	local w = (root and root.width) or 320
	local h = (root and root.height) or 240
	if type(w) ~= "number" or w <= 0 then
		w = 320
	end
	if type(h) ~= "number" or h <= 0 then
		h = 240
	end
	return w, h
end

--- First click/tap/press action type bound to a node, if any.
local function clickActionFor(node: any): string?
	local schema = State.schema
	if not schema or type(node) ~= "table" then
		return nil
	end
	for _, eid in ipairs(node.events or {}) do
		local inter = schema.interactions[eid]
		if inter and (inter.event == "click" or inter.event == "tap" or inter.event == "press") then
			return (inter.action and inter.action.type) or "click"
		end
	end
	return nil
end

--- Attach preview-only interactivity: fire handlers as log lines + hover state.
function Preview.wireInteractivity(root: Instance, onLog: (string) -> ())
	local schema = State.schema
	for _, inst in ipairs(root:GetDescendants()) do
		if inst:IsA("GuiButton") then
			local b = inst :: any
			local figmaId = b:GetAttribute("FigmaNodeId")
			local node = (schema and figmaId) and schema.nodes[figmaId] or nil
			b.Activated:Connect(function()
				local action = clickActionFor(node)
				onLog(string.format("▸ %s clicked%s", b.Name, action and ("  →  " .. action) or ""))
			end)

			-- collapsed component variants: one control, Default/Hover/Pressed looks
			local hoverId = b:GetAttribute("LYNK_State_hover")
			local pressedId = b:GetAttribute("LYNK_State_pressed")
			local function applyState(stateId: string?)
				if not schema or not stateId then
					return
				end
				local n = schema.nodes[stateId]
				if n then
					Mapper.applyStateVisual(b, n)
				end
			end
			if hoverId then
				b.MouseEnter:Connect(function()
					applyState(hoverId)
				end)
				b.MouseLeave:Connect(function()
					applyState(figmaId)
				end)
			end
			if pressedId then
				b.MouseButton1Down:Connect(function()
					applyState(pressedId)
				end)
				b.MouseButton1Up:Connect(function()
					applyState(hoverId or figmaId)
				end)
				if not hoverId then
					b.MouseLeave:Connect(function()
						applyState(figmaId)
					end)
				end
			end

			local hover = new("UIScale", { Name = "PreviewHover", Scale = 1 })
			hover.Parent = b
			b.MouseEnter:Connect(function()
				TweenService:Create(hover, TweenInfo.new(0.12), { Scale = 1.06 }):Play()
			end)
			b.MouseLeave:Connect(function()
				TweenService:Create(hover, TweenInfo.new(0.12), { Scale = 1 }):Play()
			end)
		end
	end
end

--- Scale the canvas to fit (and center within) the viewport.
function Preview.fit(viewport: Instance, canvas: Instance?)
	if not canvas then
		return
	end
	local size = (viewport :: any).AbsoluteSize :: Vector2
	if size.X <= 1 or size.Y <= 1 then
		return
	end
	local scaleObj = canvas:FindFirstChild("PreviewScale")
	if not scaleObj then
		return
	end
	local w, h = Preview.rootSize()
	local scale = math.min(size.X / w, size.Y / h)
	;(scaleObj :: any).Scale = math.clamp(scale, 0.05, 4)
end

--- Build the preview tree into `parent`. Returns the canvas frame.
function Preview.build(parent: Instance, onLog: (string) -> ()): Instance?
	local schema = State.schema
	if not schema then
		return nil
	end
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	State.instanceByFigmaId = {}
	State.structure = Mapper.computeStructure(schema)
	local w, h = Preview.rootSize()

	local canvas = new("Frame", {
		Name = "PreviewCanvas",
		Size = UDim2.fromOffset(w, h),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	})
	new("UIScale", { Name = "PreviewScale", Scale = 1 }).Parent = canvas
	canvas.Parent = parent

	local tree = Mapper.createTree(schema.metadata.rootId, nil)
	if tree then
		local t = tree :: any
		t.Position = UDim2.fromOffset(0, 0)
		t.AnchorPoint = Vector2.new(0, 0)
		t.Parent = canvas
	end
	Mapper.applyParentOverrides()

	Preview.wireInteractivity(canvas, onLog)
	Preview.fit(parent, canvas)
	return canvas
end

-- ═══════════════════════════════════════════════════════════════════════════
--  IMPORTER
-- ═══════════════════════════════════════════════════════════════════════════

local Importer = {}

local function lynkRoot(): Folder
	local root = Util.getOrCreate(ServerStorage, "Folder", ROOT_FOLDER_NAME) :: Folder
	root:SetAttribute("LYNKRoot", true)
	return root
end

local function serializeSchema(schema: any): string
	-- strip base64 payloads from the persisted copy to keep files small
	local copy = {}
	for k, v in pairs(schema) do
		copy[k] = v
	end
	copy.assets = {}
	for id, asset in pairs(schema.assets or {}) do
		local a = {}
		for k, v in pairs(asset) do
			if k ~= "base64" then
				a[k] = v
			end
		end
		copy.assets[id] = a
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(copy)
	end)
	return ok and encoded or "{}"
end

--- Build the generated folder contents (does not touch the live tree).
function Importer.generate(schema: any, progress: (string, any) -> ()): (boolean, string?, any?)
	local ok, err = validateSchema(schema)
	if not ok then
		return false, err, nil
	end
	if progress then
		progress("Validating schema", true)
	end

	local luau = CodeGen.emitLuau(schema)
	local ts = CodeGen.emitTs(schema)
	local schemaJson = serializeSchema(schema)

	local folderName = Util.sanitizeName(schema.metadata.name or "LYNK_UI")
	return true, nil, {
		folderName = folderName,
		luau = luau,
		ts = ts,
		schemaJson = schemaJson,
		schema = schema,
	}
end

--- Write the generated bundle into ServerStorage/LYNK_UI/<name>, replacing a
--- previously generated folder of the same name (exact-name replacement).
function Importer.write(bundle: any, progress: (string, any) -> ()): (boolean, string?)
	local root = lynkRoot()
	local folderName = bundle.folderName
	local existing = root:FindFirstChild(folderName)

	if existing then
		local generated = existing:GetAttribute("LYNKGenerated")
		if generated ~= true then
			return false, string.format(
				"LYNK_UI contains a non-LYNK folder named \"%s\". Refusing to overwrite unrelated content.",
				folderName)
		end
		if progress then
			progress("Replacing existing generated folder " .. folderName, true)
		end
		existing:Destroy()
	end

	if progress then
		progress("Writing " .. folderName, true)
	end
	local folder = Instance.new("Folder")
	folder.Name = folderName
	folder:SetAttribute("LYNKGenerated", true)
	folder:SetAttribute("LYNKVersion", PLUGIN_VERSION)
	folder:SetAttribute("FigmaNodeId", bundle.schema.metadata.rootId)
	folder:SetAttribute("Revision", bundle.schema.revision or 0)
	folder:SetAttribute("ImportedAt", os.time())

	if Settings.generateCode then
		local luauModule = Instance.new("ModuleScript")
		luauModule.Name = folderName .. ".luau"
		luauModule.Source = bundle.luau
		luauModule:SetAttribute("LYNKGenerated", true)
		luauModule.Parent = folder

		local tsModule = Instance.new("ModuleScript")
		tsModule.Name = folderName .. ".ts"
		tsModule.Source = bundle.ts
		tsModule:SetAttribute("LYNKGenerated", true)
		tsModule.Parent = folder

		local schemaValue = Instance.new("StringValue")
		schemaValue.Name = "schema.json"
		schemaValue.Value = bundle.schemaJson
		schemaValue:SetAttribute("LYNKGenerated", true)
		schemaValue.Parent = folder
	end

	-- asset reference index
	local assetsFolder = Instance.new("Folder")
	assetsFolder.Name = "assets"
	assetsFolder:SetAttribute("LYNKGenerated", true)
	assetsFolder.Parent = folder
	for _, asset in pairs(bundle.schema.assets or {}) do
		if asset.status == "RESOLVED" or asset.robloxUri or asset.robloxAssetId then
			local entry = Instance.new("StringValue")
			entry.Name = Util.sanitizeName(asset.name or asset.assetId)
			entry.Value = asset.robloxUri or ("rbxassetid://" .. tostring(asset.robloxAssetId))
			entry:SetAttribute("LYNKGenerated", true)
			entry:SetAttribute("AssetHash", asset.assetHash)
			entry:SetAttribute("Status", asset.status or "RESOLVED")
			entry.Parent = assetsFolder
		end
	end

	folder.Parent = root
	return true, nil
end

--- Import the current schema: resolve assets → generate → write → preview.
function Importer.import(progress: (string, any) -> ()): (boolean, string?)
	if not State.schema then
		return false, "No schema received from Figma yet."
	end
	if State.importing then
		return false, "An import is already running."
	end
	State.importing = true

	local ok = false
	local err

	local success, message = pcall(function()
		-- 1. assets first, so generated source references real Roblox IDs
		Assets.resolveAll(function(name, status)
			State.assets[name] = { status = status, name = name }
			if progress then
				progress(string.format("Asset %s: %s", name, status), true)
			end
			if UI and UI.refreshAssets then
				UI.refreshAssets()
			end
		end)

		local unresolved = 0
		for _, asset in pairs(State.schema.assets or {}) do
			if asset.status ~= "RESOLVED" then
				unresolved += 1
			end
		end

		-- 2. generate
		local genOk, genErr, bundle = Importer.generate(State.schema, progress)
		if not genOk then
			error(genErr)
		end

		-- 3. write (the interactive dock preview is rebuilt by the caller)
		local writeOk, writeErr = Importer.write(bundle, progress)
		if not writeOk then
			error(writeErr)
		end

		if progress then
			progress(string.format("Imported %s (%d unresolved asset%s)",
				bundle.folderName, unresolved, unresolved == 1 and "" or "s"), true)
		end
	end)

	if success then
		ok = true
	else
		err = tostring(message)
	end

	State.importing = false
	return ok, err
end

-- ═══════════════════════════════════════════════════════════════════════════
--  PLUGIN UI
-- ═══════════════════════════════════════════════════════════════════════════

local UI = {}
UI.refreshAssets = nil

local gui = nil :: DockWidgetPluginGui?
local widgets = {} :: { [string]: Instance }

local function historyPush(text: string)
	table.insert(State.history, 1, { time = os.time(), text = text })
	while #State.history > 40 do
		table.remove(State.history)
	end
	if UI.refreshActivity then
		UI.refreshActivity()
	end
end

local function buildUi()
	local root = new("Frame", {
		Name = "Root",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.bg,
		BorderSizePixel = 0,
	}) :: Frame

	-- header
	local header = new("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundTransparency = 1,
	}, { padding(14, 0) })
	local logo = new("ImageLabel", {
		Name = "Logo",
		Image = LYNK_ICON,
		Size = UDim2.fromOffset(26, 26),
		Position = UDim2.fromOffset(0, 7),
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Fit,
	})
	local title = new("TextLabel", {
		Name = "Title",
		Text = "LYNK",
		Size = UDim2.new(0, 120, 0, 40),
		Position = UDim2.fromOffset(34, 0),
		BackgroundTransparency = 1,
		TextColor3 = Theme.text,
		TextSize = 18,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	})
	header.Parent = root
	logo.Parent = header
	title.Parent = header

	local statusDot = new("Frame", {
		Name = "StatusDot",
		Size = UDim2.fromOffset(8, 8),
		Position = UDim2.new(1, -14, 0, 16),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = Theme.textDim,
		BorderSizePixel = 0,
	}, { corner(4) })
	statusDot.Parent = header

	local body = new("ScrollingFrame", {
		Name = "Body",
		Size = UDim2.new(1, 0, 1, -40),
		Position = UDim2.fromOffset(0, 40),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.border,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, { padding(14) })

	local layout = new("UIListLayout", {
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	layout.Parent = body
	body.Parent = root

	local mainPage = new("Frame", {
		Name = "MainPage",
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	local mainLayout = new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder })
	mainLayout.Parent = mainPage
	mainPage.Parent = body

	local function section(name: string, order: number): Frame
		local frame = new("Frame", {
			Name = name,
			Size = UDim2.new(1, 0, 0, 0),
			BackgroundColor3 = Theme.panel,
			BorderSizePixel = 0,
			LayoutOrder = order,
			AutomaticSize = Enum.AutomaticSize.Y,
		}) :: Frame
		frame.Parent = mainPage
		padding(10).Parent = frame
		local list = new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder })
		list.Parent = frame
		corner(8).Parent = frame
		return frame
	end

	-- ── code (import-only) ─────────────────────────────────────────────────
	local connectSection = section("Code", 1)
	local hint = makeLabel("Paste a LYNK code copied from Figma, then Load.", Theme.textDim, 12)
	hint.Size = UDim2.new(1, 0, 0, 28)
	hint.TextWrapped = true
	hint.Parent = connectSection

	local codeStroke = new("UIStroke", {
		Color = Theme.border,
		Thickness = 1,
		Transparency = 0.35,
	})
	local codeBox = new("TextBox", {
		Name = "Code",
		Size = UDim2.new(1, 0, 0, 104),
		BackgroundColor3 = Theme.bg,
		BorderSizePixel = 0,
		Text = "",
		PlaceholderText = "Paste the LYNK1:… code copied from Figma",
		PlaceholderColor3 = Theme.textDim,
		TextColor3 = Theme.text,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		MultiLine = true,
		ClearTextOnFocus = false,
	}, {
		corner(8),
		new("UIPadding", {
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 10),
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 8),
		}),
		codeStroke,
		new("UIShadow", {
			Color = Color3.new(0, 0, 0),
			Transparency = 0.8,
			Offset = UDim2.fromOffset(0, 4),
			Spread = UDim2.fromOffset(0, 0),
		}),
	})
	codeBox.Parent = connectSection
	codeBox.Focused:Connect(function()
		codeStroke.Color = Theme.accent
		codeStroke.Transparency = 0
	end)
	codeBox.FocusLost:Connect(function()
		codeStroke.Color = Theme.border
		codeStroke.Transparency = 0.35
	end)

	local connectBtn = makeButton("Load", true)
	connectBtn.Parent = connectSection

	local statusLabel = makeLabel("No code loaded", Theme.textDim, 12)
	statusLabel.Parent = connectSection

	-- ── connected: session ─────────────────────────────────────────────────
	local sessionSection = section("Session", 2)
	sessionSection.Visible = false
	local figmaLabel = makeLabel("Figma: —", Theme.text, 13, true)
	figmaLabel.Parent = sessionSection

	local statsGrid = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	statsGrid.Parent = sessionSection
	local gridLayout = new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder })
	gridLayout.Parent = statsGrid

	local statLabels = {}
	for _, key in ipairs({ "Nodes", "Events", "Assets" }) do
		local chip = new("TextLabel", {
			Name = key,
			Text = key .. ": 0",
			Size = UDim2.fromOffset(96, 24),
			BackgroundColor3 = Theme.panelAlt,
			BorderSizePixel = 0,
			TextColor3 = Theme.text,
			TextSize = 11,
			Font = Enum.Font.GothamMedium,
		}, { corner(4) })
		chip.Parent = statsGrid
		statLabels[key] = chip
	end

	local statusLine = makeLabel("No code loaded", Theme.textDim, 11)
	statusLine.Parent = sessionSection

	local buttonRow = new("Frame", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
	})
	buttonRow.Parent = sessionSection
	local rowLayout = new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder })
	rowLayout.Parent = buttonRow
	local importBtn = makeButton("Import", true)
	importBtn.Size = UDim2.new(0.5, -4, 1, 0)
	importBtn.Parent = buttonRow
	local resyncBtn = makeButton("Reload", false)
	resyncBtn.Size = UDim2.new(0.25, -4, 1, 0)
	resyncBtn.Parent = buttonRow
	local disconnectBtn = makeButton("Clear", false)
	disconnectBtn.Size = UDim2.new(0.25, -4, 1, 0)
	disconnectBtn.Parent = buttonRow

	local previewBtn = makeButton("Preview  ▾", false)
	previewBtn.Parent = sessionSection

	local previewPanel = new("Frame", {
		Name = "PreviewPanel",
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundColor3 = Theme.panelAlt,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	})
	corner(6).Parent = previewPanel
	previewPanel.Parent = sessionSection

	local previewViewport = new("Frame", {
		Name = "Viewport",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	})
	previewViewport.Parent = previewPanel

	local previewToast = new("TextLabel", {
		Name = "Toast",
		Size = UDim2.new(1, -12, 0, 22),
		Position = UDim2.new(0, 6, 1, -26),
		BackgroundColor3 = Theme.bg,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Text = "",
		TextColor3 = Theme.text,
		TextSize = 11,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Visible = false,
		ZIndex = 2,
	})
	new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }).Parent = previewToast
	corner(4).Parent = previewToast
	previewToast.Parent = previewPanel

	-- ── hierarchy ──────────────────────────────────────────────────────────
	local treeSection = section("Hierarchy", 3)
	treeSection.Visible = false
	local treeFrame = new("ScrollingFrame", {
		Name = "Tree",
		Size = UDim2.new(1, 0, 0, 160),
		BackgroundColor3 = Theme.panelAlt,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, { padding(6) })
	treeFrame.Parent = treeSection
	local treeLayout = new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder })
	treeLayout.Parent = treeFrame

	-- ── assets ─────────────────────────────────────────────────────────────
	local assetSection = section("Assets", 4)
	assetSection.Visible = false
	local assetList = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	assetList.Parent = assetSection
	local assetLayout = new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder })
	assetLayout.Parent = assetList

	-- ── activity ───────────────────────────────────────────────────────────
	local activitySection = section("Activity", 5)
	activitySection.Visible = false
	local activityList = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	activityList.Parent = activitySection
	local activityLayout = new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder })
	activityLayout.Parent = activityList

	-- ── settings page (own screen, opened from the main page) ─────────────
	local settingsPage = new("Frame", {
		Name = "SettingsPage",
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
	})
	local settingsLayout = new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder })
	settingsLayout.Parent = settingsPage
	settingsPage.Parent = body

	local backBtn = makeButton("← Back", false)
	backBtn.LayoutOrder = 0
	backBtn.Parent = settingsPage

	local settingsTitle = makeLabel("Settings", Theme.text, 15, true)
	settingsTitle.LayoutOrder = 1
	settingsTitle.Size = UDim2.new(1, 0, 0, 20)
	settingsTitle.Parent = settingsPage

	local function toggleRow(label: string, desc: string, key: string, order: number): TextButton
		local row = new("TextButton", {
			Name = key,
			Size = UDim2.new(1, 0, 0, 48),
			BackgroundColor3 = Theme.panelAlt,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = order,
		}) :: TextButton
		corner(6).Parent = row
		local labelEl = makeLabel(label, Theme.text, 13, true)
		labelEl.Size = UDim2.new(1, -76, 0, 17)
		labelEl.Position = UDim2.fromOffset(10, 4)
		labelEl.Parent = row
		local descEl = makeLabel(desc, Theme.textDim, 11)
		descEl.Size = UDim2.new(1, -76, 0, 26)
		descEl.Position = UDim2.fromOffset(10, 21)
		descEl.TextWrapped = true
		descEl.Parent = row
		local stateEl = makeLabel(Settings[key] and "ON" or "OFF", Settings[key] and Theme.success or Theme.textDim, 11, true)
		stateEl.Size = UDim2.fromOffset(44, 16)
		stateEl.Position = UDim2.new(1, -54, 0.5, -8)
		stateEl.TextXAlignment = Enum.TextXAlignment.Right
		stateEl.Name = "Value"
		stateEl.Parent = row
		row.Parent = settingsPage
		row.MouseEnter:Connect(function()
			(row :: any).BackgroundTransparency = 0.7
		end)
		row.MouseLeave:Connect(function()
			(row :: any).BackgroundTransparency = 1
		end)
		row.MouseButton1Click:Connect(function()
			local newValue = not Settings[key]
			saveSetting(key, newValue)
			;(stateEl :: any).Text = newValue and "ON" or "OFF"
			;(stateEl :: any).TextColor3 = newValue and Theme.success or Theme.textDim
		end)
		return row
	end

	toggleRow("Generate Code", "Write .luau / .ts modules and schema.json when importing.", "generateCode", 2)
	toggleRow("Preview on Load", "Open the interactive preview as soon as a code is loaded.", "autoPreview", 3)

	local assetModeBtn = makeButton("Asset Handling: " .. string.upper(Settings.assetHandling), false)
	assetModeBtn.LayoutOrder = 4
	assetModeBtn.Parent = settingsPage
	assetModeBtn.MouseButton1Click:Connect(function()
		local modes = { "upload", "placeholder", "skip" }
		local idx = 1
		for i, m in ipairs(modes) do
			if m == Settings.assetHandling then
				idx = i
			end
		end
		local nextMode = modes[(idx % #modes) + 1]
		saveSetting("assetHandling", nextMode)
		assetModeBtn.Text = "Asset Handling: " .. string.upper(nextMode)
	end)
	local assetDesc = makeLabel("Images: upload to Roblox, use a placeholder, or skip them.", Theme.textDim, 11)
	assetDesc.LayoutOrder = 5
	assetDesc.Size = UDim2.new(1, 0, 0, 26)
	assetDesc.TextWrapped = true
	assetDesc.Parent = settingsPage

	-- settings entry point, at the bottom of the main page
	local settingsBtn = makeButton("Settings", false)
	settingsBtn.LayoutOrder = 6
	settingsBtn.Parent = mainPage

	root.Parent = nil
	return {
		root = root,
		statusDot = statusDot,
		body = body,
		mainPage = mainPage,
		settingsPage = settingsPage,
		settingsBtn = settingsBtn,
		backBtn = backBtn,
		connectSection = connectSection,
		sessionSection = sessionSection,
		treeSection = treeSection,
		assetSection = assetSection,
		activitySection = activitySection,
		codeBox = codeBox,
		connectBtn = connectBtn,
		statusLabel = statusLabel,
		figmaLabel = figmaLabel,
		statLabels = statLabels,
		statusLine = statusLine,
		importBtn = importBtn,
		resyncBtn = resyncBtn,
		disconnectBtn = disconnectBtn,
		previewBtn = previewBtn,
		previewPanel = previewPanel,
		previewViewport = previewViewport,
		previewToast = previewToast,
		treeFrame = treeFrame,
		assetList = assetList,
		activityList = activityList,
	}
end

local refs: any

local function setStatusDot(color: Color3)
	if refs then
		(refs.statusDot :: any).BackgroundColor3 = color
	end
end

local function refreshSessionUi()
	if not refs then
		return
	end
	local loaded = State.schema ~= nil
	refs.connectSection.Visible = not loaded
	refs.sessionSection.Visible = loaded
	refs.treeSection.Visible = loaded
	refs.assetSection.Visible = loaded
	refs.activitySection.Visible = loaded
	refs.statusLabel.Text = State.status
	refs.figmaLabel.Text = "Figma: " .. State.figmaName
	refs.statLabels.Nodes.Text = "Nodes: " .. State.nodeCount
	refs.statLabels.Events.Text = "Events: " .. State.eventCount
	refs.statLabels.Assets.Text = "Assets: " .. State.assetCount
	refs.statusLine.Text = State.importing and "Importing…" or State.status
	setStatusDot(loaded and Theme.success or Theme.textDim)
end

function UI.refreshActivity()
	if not refs then
		return
	end
	for _, child in ipairs(refs.activityList:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	for index, entry in ipairs(State.history) do
		local label = makeLabel(string.format("%s  %s", os.date("%H:%M:%S", entry.time), entry.text), Theme.textDim, 10)
		label.LayoutOrder = index
		label.TextWrapped = true
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.Size = UDim2.new(1, 0, 0, 0)
		label.Parent = refs.activityList
	end
end

function UI.refreshAssets()
	if not refs then
		return
	end
	for _, child in ipairs(refs.assetList:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	local names = {}
	for name in pairs(State.assets) do
		table.insert(names, name)
	end
	table.sort(names)
	local index = 0
	for _, name in ipairs(names) do
		index += 1
		local info = State.assets[name]
		local glyph = "↻"
		local color = Theme.textDim
		if info.status == "resolved" then
			glyph, color = "✓", Theme.success
		elseif string.find(info.status, "failed") then
			glyph, color = "⚠", Theme.danger
		end
		local label = makeLabel(string.format("%s %s", glyph, name), color, 10)
		label.LayoutOrder = index
		label.Parent = refs.assetList
	end
end

local function refreshTree()
	if not refs or not State.schema then
		return
	end
	for _, child in ipairs(refs.treeFrame:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	local order = 0
	local function addNode(nodeId: string, depth: number)
		local node = State.schema.nodes[nodeId]
		if not node then
			return
		end
		order += 1
		local row = new("TextButton", {
			Name = nodeId,
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
			Text = string.rep("  ", depth) .. "▸ " .. (node.name or node.type),
			TextColor3 = Theme.text,
			TextSize = 11,
			Font = Enum.Font.Code,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = order,
			AutoButtonColor = false,
		}) :: TextButton
		row.Parent = refs.treeFrame
		row.MouseEnter:Connect(function()
			(row :: any).BackgroundTransparency = 0.85
			;(row :: any).BackgroundColor3 = Theme.accent
		end)
		row.MouseLeave:Connect(function()
			(row :: any).BackgroundTransparency = 1
		end)
		row.MouseButton1Click:Connect(function()
			local inst = State.instanceByFigmaId[nodeId]
			if inst then
				Selection:Set({ inst })
			end
		end)
		for _, childId in ipairs(node.children or {}) do
			addNode(childId, depth + 1)
		end
	end
	addNode(State.schema.metadata.rootId, 0)
end

local state = {}

-- ═══════════════════════════════════════════════════════════════════════════
--  PLUGIN STATE ACTIONS
-- ═══════════════════════════════════════════════════════════════════════════

function state:setStatus(status: string)
	State.status = status
	if refs then
		refs.statusLine.Text = status
	end
end

function state:pushHistory(text: string)
	historyPush(text)
end

function state:pushError(text: string)
	warn("[LYNK] " .. text)
	historyPush("⚠ " .. text)
end

-- ── import-only preview ───────────────────────────────────────────────────

local PREVIEW_HEIGHT = 220
local previewExpanded = false
local previewToastToken = 0

local function previewLog(msg: string)
	historyPush(msg)
	if refs and refs.previewToast then
		local toast = refs.previewToast
		toast.Text = msg
		toast.Visible = true
		toast.TextTransparency = 0
		toast.BackgroundTransparency = 0.15
		previewToastToken += 1
		local token = previewToastToken
		task.delay(2.5, function()
			if token == previewToastToken and refs and refs.previewToast then
				refs.previewToast.Visible = false
			end
		end)
	end
end

function state:refreshPreview()
	if not refs or not State.schema then
		return
	end
	Preview.build(refs.previewViewport, previewLog)
end

function state:setPreviewExpanded(expanded: boolean)
	if not refs then
		return
	end
	previewExpanded = expanded
	refs.previewBtn.Text = expanded and "Preview  ▴" or "Preview  ▾"
	local goal = expanded and UDim2.new(1, 0, 0, PREVIEW_HEIGHT) or UDim2.new(1, 0, 0, 0)
	TweenService:Create(refs.previewPanel,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = goal }):Play()
	if expanded then
		state:refreshPreview()
		-- re-fit once the panel has finished sliding open
		task.delay(0.22, function()
			if previewExpanded and refs then
				Preview.fit(refs.previewViewport, refs.previewViewport:FindFirstChild("PreviewCanvas"))
			end
		end)
	end
end

function state:togglePreview()
	state:setPreviewExpanded(not previewExpanded)
end

--- Load a schema from a pasted LYNK export string.
function state:load(code: string): boolean
	local schema, err = Export.decode(code)
	if not schema then
		state:pushError(err or "Could not read code.")
		return false
	end
	State.schema = schema
	State.figmaName = schema.metadata.name or "?"
	State.nodeCount, State.eventCount, State.assetCount = schemaStats(schema)
	State.instanceByFigmaId = {}
	State.structure = Mapper.computeStructure(schema)
	State.assets = {}
	state:setStatus(string.format("Loaded %d nodes", State.nodeCount))
	historyPush(string.format("Loaded %s (%d nodes, %d events)", State.figmaName, State.nodeCount, State.eventCount))
	refreshSessionUi()
	refreshTree()
	state:setPreviewExpanded(Settings.autoPreview)
	-- resolve/upload image assets so the preview is faithful, then repaint
	task.spawn(function()
		pcall(function()
			Assets.resolveAll(function(name, status)
				State.assets[name] = { status = status, name = name }
				if UI and UI.refreshAssets then
					UI.refreshAssets()
				end
			end)
		end)
		if previewExpanded then
			state:refreshPreview()
		end
	end)
	return true
end

function state:import()
	if not State.schema then
		state:pushError("Nothing to import yet — paste a LYNK code and Load it first.")
		return
	end
	state.importing = true
	refreshSessionUi()
	historyPush("Importing " .. State.figmaName .. "…")
	local ok, err = Importer.import(function(text: string)
		state:setStatus(text)
	end)
	state.importing = false
	if ok then
		state:setStatus(string.format("Imported %d nodes", State.nodeCount))
		historyPush("Import complete")
		refreshTree()
		if previewExpanded then
			state:refreshPreview()
		end
	else
		state:pushError("Import failed: " .. tostring(err))
		state:setStatus("Import failed")
	end
	refreshSessionUi()
end

-- ═══════════════════════════════════════════════════════════════════════════
--  BOOT
-- ═══════════════════════════════════════════════════════════════════════════

loadSettings()
Assets.loadCache()

local toolbar = plugin:CreateToolbar("Lynk")
local button = toolbar:CreateButton("Lynk", "Import Roblox UI from a pasted Figma code", LYNK_ICON)

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false,
	true,
	380,
	600,
	340,
	420
)
local dock = plugin:CreateDockWidgetPluginGui("LYNK_Widget", widgetInfo)
dock.Title = "LYNK"
dock.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

refs = buildUi()
refs.root.Parent = dock
refreshSessionUi()

button.Click:Connect(function()
	dock.Enabled = not dock.Enabled
end)

refs.connectBtn.MouseButton1Click:Connect(function()
	local raw = refs.codeBox.Text or ""
	if string.gsub(raw, "%s", "") == "" then
		state:pushError("Paste a LYNK code first.")
		return
	end
	state:load(raw)
end)

refs.codeBox.Focused:Connect(function()
	if not State.schema then
		refs.statusLine.Text = "Paste the code copied from Figma."
	end
end)

refs.settingsBtn.MouseButton1Click:Connect(function()
	refs.mainPage.Visible = false
	refs.settingsPage.Visible = true
	refs.body.CanvasPosition = Vector2.new(0, 0)
end)

refs.backBtn.MouseButton1Click:Connect(function()
	refs.settingsPage.Visible = false
	refs.mainPage.Visible = true
	refs.body.CanvasPosition = Vector2.new(0, 0)
end)

refs.importBtn.MouseButton1Click:Connect(function()
	state:import()
end)

refs.resyncBtn.MouseButton1Click:Connect(function()
	if not State.schema then
		state:pushError("Nothing loaded to reload.")
		return
	end
	state:load(refs.codeBox.Text)
end)

refs.disconnectBtn.MouseButton1Click:Connect(function()
	State.schema = nil
	State.instanceByFigmaId = {}
	State.structure = nil
	State.figmaName = "—"
	State.nodeCount, State.eventCount, State.assetCount = 0, 0, 0
	state:setPreviewExpanded(false)
	for _, child in ipairs(refs.previewViewport:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	refs.previewToast.Visible = false
	state:setStatus("Cleared")
	historyPush("Cleared loaded code")
	refreshSessionUi()
end)

refs.previewBtn.MouseButton1Click:Connect(function()
	if not State.schema then
		state:pushError("Load a code before previewing.")
		return
	end
	state:togglePreview()
end)

historyPush("LYNK " .. PLUGIN_VERSION .. " ready")
setStatusDot(Theme.textDim)

return nil
