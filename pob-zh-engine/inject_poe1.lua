-- inject_poe1.lua
--
-- PoE1-only rules for poecharm_inject.lua; loaded only when the engine says the game is poe1
-- (PobToolsGame). Returns the rules table the entry asks (list in inject_poe2.lua).
-- PoE1 has no headed drop-down rows: its crafting rows are translated whole by stat id.

local rules = {}

-- POB1 keeps the backdrop in tree.assets and pans it with the tree
-- (PassiveTreeView.lua:547-555); Zoom() clamps at 12.
rules.treeBackdrop = {
	zoomLevelMax = 12,
	draw = function(self, tree, bg, size, vp)
		local scale = math.min(vp.width, vp.height) / tree.size * self.zoom
		local bgSize = size.w * scale * 1.33 * 2.5
		DrawImage(bg.handle, vp.x, vp.y, vp.width, vp.height,
			(self.zoomX + vp.width / 2) / -bgSize, (self.zoomY + vp.height / 2) / -bgSize,
			(vp.width / 2 - self.zoomX) / bgSize, (vp.height / 2 - self.zoomY) / bgSize)
	end,
}

local cnTradeRoot = "https://poe.game.qq.com"
local cnSearchRoot = cnTradeRoot .. "/trade/search/"
local cnLeagueError = "PoE1 国服市集：暂未取得联盟列表，请稍后重试。"
local cnItemError = "PoE1 国服市集：找不到这个物品的简体市集名称。"
local scriptDir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""

local function marketEncode(s)
	return (s:gsub("[^A-Za-z0-9_.~-]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function marketDecode(s)
	return (s:gsub("%+", " "):gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

function rules.installChinaTrade()
	if os.getenv("POB_ZH_CN_TRADE") ~= "1" then return end
	local json = require("dkjson")
	local market = { league = nil }
	local nextFetch = 0
	local fetching = false
	local function fetchLeague()
		if market.league or fetching or os.time() < nextFetch then return end
		fetching = true
		-- This is a public request. Do not pass PoB's international OAuth headers.
		launch:DownloadPage(cnTradeRoot .. "/api/trade/data/leagues", function(response)
			fetching = false
			nextFetch = os.time() + 5
			local data = response and type(response.body) == "string" and json.decode(response.body)
			for _, row in ipairs(type(data) == "table" and type(data.result) == "table" and data.result or {}) do
				if type(row) == "table" and row.realm == "pc" and type(row.id) == "string" and row.id ~= "" then
					market.league = row.id
					break
				end
			end
		end)
	end
	local entries = {}
	local function lookup(file, value)
		if type(value) ~= "string" or value == "" then return end
		if value:find("[\228-\233][\128-\191][\128-\191]") then return value end
		if not entries[file] then
			local f = io.open(scriptDir .. "../Data/poe1/zh-rCN/" .. file .. ".json", "rb")
			local data
			if f then data = json.decode((f:read("*a"):gsub("^\239\187\191", ""))); f:close() end
			entries[file] = type(data) == "table" and type(data.entries) == "table" and data.entries or {}
		end
		local zh = entries[file][value]
		return type(zh) == "string" and zh:find("[\228-\233][\128-\191][\128-\191]") and zh or nil
	end
	function market.build(payload, item)
		if type(payload) ~= "table" then return nil, "PoB could not build the trade query" end
		fetchLeague()
		if not market.league then return nil, cnLeagueError end
		local query = payload.query or payload
		if type(query) ~= "table" then return nil, "PoB could not build the trade query" end
		-- The trade generator may still use its query internally. Only adapt a copy.
		local body = {}
		for k, v in pairs(query) do body[k] = v end
		body.status = { option = "any" }
		if item and (item.rarity == "UNIQUE" or item.rarity == "RELIC") then
			-- PoB can omit the name when its unique index is not loaded yet.
			body.name = body.name or (type(item.title) == "string" and item.title:gsub("^Foulborn%s+", "") or nil)
			body.type = body.type or item.baseName
		end
		if body.name then
			body.name = lookup("uniques", body.name)
			if not body.name then return nil, cnItemError end
		end
		if body.type then
			body.type = lookup("items", body.type)
			local filters = body.filters and body.filters.type_filters and body.filters.type_filters.filters
			if not (body.type or body.name or (filters and filters.category)) then return nil, cnItemError end
		end
		local group = body.stats and body.stats[1]
		local sort = payload.sort or (group and group.type == "weight" and { ["statgroup.0"] = "desc" } or { price = "asc" })
		return cnSearchRoot .. marketEncode(market.league) .. "?q=" .. marketEncode(json.encode({ query = body, sort = sort }))
	end
	function market.isUrl(url)
		return type(url) == "string" and url:sub(1, #cnSearchRoot) == cnSearchRoot
	end
	function market.fromUrl(url, item)
		if type(url) ~= "string" then return url end
		local path = url:match("^https://www%.pathofexile%.com/trade/search/(.+)$")
		if not path then return url end
		local text = path:match("%?q=([^&]+)")
		if text then
			text = marketDecode(text)
		else
			-- IDs assigned by the international API are not portable. Only redirect URLs carrying a query.
			local blob = path:match("/([A-Za-z0-9_=-]+)$")
			if not blob then return url end
			local ok, decoded = pcall(function() return require("Classes.TradeHelpers").B64GzipDecode(blob) end)
			if not ok or not decoded then return url end
			text = decoded
		end
		local payload = json.decode(text)
		if type(payload) ~= "table" or not (payload.stats or payload.query) then return url end
		return market.build(payload, item)
	end

	local buyItem
	local originalOpenURL, originalCopy = OpenURL, Copy
	OpenURL = function(url)
		local mapped, err = market.fromUrl(url, buyItem)
		if mapped then return originalOpenURL(mapped) end
		if err then main:OpenMessagePopup("PoE1 国服市集", err) end
	end
	Copy = function(text)
		local mapped = market.fromUrl(text, buyItem)
		if mapped then return originalCopy(mapped) end
	end

	local ok, buy = pcall(require, "Classes.CompareBuySimilar")
	if ok and type(buy) == "table" and type(buy.openPopup) == "function" then
		local originalPopup = buy.openPopup
		buy.openPopup = function(item, ...)
			local open = main.OpenPopup
			main.OpenPopup = function(self, width, height, title, controls, ...)
				local search = controls and controls.search
				if search and type(search.onClick) == "function" then
					local click = search.onClick
					search.onClick = function(...)
						local previous = buyItem
						buyItem = item
						local success, result = pcall(click, ...)
						buyItem = previous
						if not success then error(result, 0) end
						return result
					end
				end
				return open(self, width, height, title, controls, ...)
			end
			local success, result = pcall(originalPopup, item, ...)
			main.OpenPopup = open
			if not success then error(result, 0) end
			return result
		end
	end
	PobToolsCnTrade = market
	fetchLeague()
end

return rules
