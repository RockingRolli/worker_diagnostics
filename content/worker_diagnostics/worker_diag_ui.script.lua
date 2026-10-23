-- Worker Diagnostics: notice in the industry window and the details window (GUI thread).
--
-- Hook: worker_diag_eow.res.lua -> ::IndustryEowExtensionPoint (no game files replaced).
-- Engine reads go through try() (pcall): a missing API after a game update shows "?" or "-" instead of breaking the
-- window. Optional game GUI modules are loaded guarded and have plain fallbacks.
-- Log lines are prefixed [WorkerDiag] in crash_dump/stdout.txt.
--
-- Rules of the game's React learned the hard way:
--   * a recipe must return a layout (BoxLayout, TableLayout, ...), not a component like ScrollArea or TextView;
--   * a ScrollArea takes a Component as content, not a layout;
--   * windows are styled through a class (Window!some-class), an id selector with dots doesn't match.
-- The look follows the game's entity windows: ContentCards, icons with numbers, a status box tinted by severity.

local req = ug_require or require

-- A game module the UI can do without: nil if it is missing (e.g. moved in a game update); its users fall back
-- to plain text or an empty slot.
local function optional(path)
	local ok, module = pcall(req, path)
	if not ok then
		pcall(function() print("[WorkerDiag] optional module missing: " .. path) end)
		return nil
	end
	return module
end

-- Required: the UI can't be built without these, so a missing one should fail loudly.
local react = req "::/gui/main/react.lua"
local builtin = req "::/gui/main/builtin.lua"
local engine_react_util = req "::/gui/main/engine_react_util.tl"
local content_card = req "::/gui/main/content_card.tl"
local productivity = req "::/industries/industry_productivity_util.tl"
-- Optional, with fallbacks: names without locate button, vehicle count instead of images, "-" instead of cargo
-- icons, an empty slot instead of the destination icon, the arrival count instead of the booster bar,
-- a plain icon instead of the notification tile.
local line_react_util = optional "::/gui/line_vehicle_mgmt/line_react_util.tl"
local vehicle_react_util = optional "::/gui/line_vehicle_mgmt/vehicle_react_util.tl"
local cargo_util = optional "::/gui/main/cargo_util.tl"
local cargo_react_util = optional "::/gui/main/cargo_react_util.tl"
local entity_window_util = optional "::/gui/entity_window/entity_window_util.tl"
local industry_react_util = optional "::/gui/entity_window/industry_react_util.tl"
local notification_react_util = optional "::/game_mechanics/notifications/types/notification_react_util.tl"
-- the game's text formatting: placeholders and numbers (lang_util), long durations (util); plain fallbacks without them
local lang_util = optional "::/scripts/lang_util.tl"
-- own files relative to this mod (the folder is named after the mod.io id once installed from there)
local core = req(type(resolve) == "function" and resolve("worker_diag_core.lua")
	or "rockingrolli_worker_diagnostics::/worker_diagnostics/worker_diag_core.lua")

local WINDOW_ID = "worker_diagnostics.window"
local REFRESH_SECONDS = 2.0
local LINE_CHECK_SECONDS = 10.0 -- the line check scans all stations, so it runs every 10 s only
local CELL_REFRESH_SECONDS = 1.0 -- table cells: their values change slowly, no need to read them every frame
-- Lines tab: both tables share the column widths, so they line up ("Where" spans waiting + problems)
local LINE_COLUMNS = { line = 3.4, vehicles = 2.6, third = 1.4, waiting = 2.2, problems = 1.2 }
local MAX_PROBLEMS = 3 -- problems listed below the passenger lines table, the rest in a tooltip
local WAIT_WARNING_DAYS = 60
local WAIT_CRITICAL_DAYS = 120

local ICON = {
	waiting = "::/gui/entity_window/icons/symbol_stop_watch.tga",
	ok = "::/gui/entity_window/icons/circle_check.tga",
	problem = "::/gui/entity_window/icons/exclamation.tga",
	info = "::/gui/entity_window/design/symbol_info_outline.tga",
	details = "::/gui/entity_window/design/symbol_info.tga",
	worker = "::/gui/entity_window/icons/symbol_person.tga",
}

local SEVERITY_ICON = { error = ICON.problem, warning = ICON.problem, success = ICON.ok, info = ICON.info }

-- SimPerson.destinations index (0-based, as the game's GetDestinationIcon expects)
local DESTINATION_INDEX = { HOME = 0, SHOP = 1, WORK = 2 }

local worker_diag_ui = {}

local function log(msg)
	pcall(function() print("[WorkerDiag] " .. tostring(msg)) end)
end

local logged = {} -- error message -> true: try() runs every refresh, so each distinct error is logged once

local function try(fn, ...)
	local ok, result = pcall(fn, ...)
	if not ok then
		local msg = tostring(result)
		if not logged[msg] then
			logged[msg] = true
			log(msg)
		end
		return nil
	end
	return result
end

-- engine lists (userdata or tables) as plain Lua tables
local function toListSafe(list)
	local result = {}
	local n = list and (try(function() return #list end) or 0) or 0
	for i = 1, n do
		result[#result + 1] = list[i]
	end
	return result
end

-- ---------------------------------------------------------------------------------------------
-- Translation. English text is the key: _() looks it up in the game's catalogue, then in the mod's strings.json
-- ("de" only; other languages show the English key). strings.json holds only our own keys, never the game's: a game
-- key there would override the game's translation everywhere. tools/check_strings.py checks both.
-- Every sentence with values is one key with named placeholders ({count}), filled by fmt.

local function tr(key)
	if type(_) == "function" then
		local ok, text = pcall(_, key)
		if ok and type(text) == "string" then
			return text
		end
	end
	return key
end

-- Plural keys: nGetText picks the form for the language and translates game keys; our own keys aren't in the game's
-- catalogue, so the English form it returns then goes through _() and strings.json (German has the same two forms).
local function trn(singular, plural, n)
	local form
	if type(nGetText) == "function" then
		local ok, text = pcall(nGetText, singular, plural, n)
		form = ok and type(text) == "string" and text or nil
	end
	if form == nil then
		form = n == 1 and singular or plural
	end
	if form == singular or form == plural then
		return tr(form)
	end
	return form
end

local function fmt(template, values)
	if lang_util and lang_util.format then
		local ok, text = pcall(lang_util.format, template, values)
		if ok and type(text) == "string" then
			return text
		end
	end
	return core.plainFmt(template, values)
end

local function int(n)
	n = math.floor(n + 0.5)
	if lang_util and lang_util.formatInt then
		local ok, text = pcall(lang_util.formatInt, n)
		if ok and type(text) == "string" then
			return text
		end
	end
	return core.plainInt(n)
end

-- ---------------------------------------------------------------------------------------------
-- Formatting

local DAYS_LIMIT = 60 -- durations up to this many days are shown in days, longer ones in years and months

local function dayLength()
	return try(api.util.getDefaultDayDuration) or 0
end

-- The game time of one calendar day at the player's calendar speed (GAME_SPEED.millisPerDay, as the game's industry
-- window reads it), 0 when the calendar doesn't run (then durations are shown as minutes and seconds), or the default
-- day length if GAME_SPEED can't be read.
local function millisPerDay()
	local speed = try(function()
		return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_SPEED).millisPerDay
	end)
	if type(speed) == "number" and speed >= 0 then
		return speed
	end
	return dayLength()
end

-- Durations in our own lowercase plural keys ("12 days", "1 year 8 months"): the game's keys ("%s Day", "%s Year")
-- are title case and read wrong inside English sentences; in German the nouns are capitalized either way. The
-- calendar math follows util.formatDurationWithCurrentCalenderSpeed(..., "Month") and uses the game's year and month
-- lengths at the current calendar speed; only whole numbers, so nothing locale-specific is formatted here.
local function fmtDays(days)
	return string.format(trn("%s day", "%s days", days), int(days))
end

local function fmtYearsMonths(ticks, perDay)
	local yearLength = try(api.util.getYearDuration, perDay)
	local monthLength = try(api.util.getMonthDuration, perDay)
	if type(yearLength) ~= "number" or type(monthLength) ~= "number" or yearLength <= 0 or monthLength <= 0 then
		return nil
	end
	local years = math.floor(ticks / yearLength)
	-- whole months, rounded like the game rounds the leftover days
	local months = math.floor((ticks - years * yearLength) / monthLength + 0.5)
	local monthsPerYear = math.floor(yearLength / monthLength + 0.5)
	if months >= monthsPerYear then
		years, months = years + 1, 0
	end
	local y = years > 0 and string.format(trn("%s year", "%s years", years), int(years)) or nil
	local m = months > 0 and string.format(trn("%s month", "%s months", months), int(months)) or nil
	if y and m then
		return fmt(tr("{years} {months}"), { years = y, months = m })
	end
	return y or m
end

-- A game-time duration: up to DAYS_LIMIT days as days, longer as years and months, both at the current calendar
-- speed; without a running calendar as minutes and seconds (like industry_react_util's formatDuration).
local function fmtDuration(ticks)
	if type(ticks) ~= "number" then
		return "?"
	end
	local perDay = millisPerDay()
	if perDay == 0 then
		local seconds = math.floor(ticks / 1000 + 0.5)
		local text = try(api.util.formatMinutesSeconds, seconds)
		return type(text) == "string" and text or int(seconds)
	end
	local days = math.floor(ticks / perDay + 0.5)
	if days > DAYS_LIMIT then
		local text = fmtYearsMonths(ticks, perDay)
		if text then
			return text
		end
	end
	return fmtDays(days)
end

-- A duration rounded down to the unit it is shown in (a calendar day, or a second without a running calendar), so the
-- table cells only redraw when the text can change.
local function quantize(ticks)
	if type(ticks) ~= "number" then
		return -1
	end
	local unit = millisPerDay()
	unit = unit > 0 and unit or 1000
	return math.floor(math.max(0, ticks) / unit) * unit
end

-- in calendar days, like the durations shown next to it
local function toDays(ticks)
	local day = millisPerDay()
	return day > 0 and ticks / day or nil
end

-- the core's texts in the player's language
core.tr, core.trn, core.fmt, core.int, core.duration = tr, trn, fmt, int, fmtDuration

-- "" / "warning" / "error": text colour class for a waiting time
local function waitClass(ticks)
	local days = type(ticks) == "number" and ticks >= 0 and toDays(ticks)
	if not days then
		return ""
	end
	if days >= WAIT_CRITICAL_DAYS then
		return "error"
	end
	if days >= WAIT_WARNING_DAYS then
		return "warning"
	end
	return ""
end

local function entityName(entity)
	local name = try(function() return api.engine.getComponent(entity, api.type.ComponentType.NAME).name end)
	return name or ("#" .. tostring(entity))
end

local function industryName(industry)
	local name = try(function() return api.engine.getComponent(industry, api.type.ComponentType.NAME).name end)
	if name then
		return name
	end
	local construction = try(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction(industry) end)
	return construction and entityName(construction) or tr("Industry")
end

local stationName = core.stationName

-- Texts by token, translated when shown. The status words are the game's, as in its person window.
local STATUS_TEXT = {
	WAITING = function() return tr("Waiting at Station") end,
	RIDING = function() return tr("Riding Vehicle") end,
	WALKING = function() return tr("Walking") end,
	AT_WORK = function() return tr("At Work") end,
	AT_HOME = function() return tr("At Home") end,
	AT_SHOP = function() return tr("Shopping") end,
	AT_OTHER = function() return tr("At another place") end,
	GONE = function() return tr("No longer exists") end,
}
-- tooltip of the destination icon: on the way there, or the game's name of the place
local DESTINATION_TOOLTIP = {
	WORK = function() return tr("On the way to work") end,
	HOME = function() return tr("On the way home") end,
	SHOP = function() return tr("On the way to shopping") end,
	OTHER = function() return tr("Other trip") end,
	AT_WORK = function() return tr("Work") end,
	AT_HOME = function() return tr("Home") end,
	AT_SHOP = function() return tr("Shop") end,
	AT_OTHER = function() return tr("Other") end,
}

-- What the person is doing, as a token of STATUS_TEXT (the icon shows the destination).
local function statusToken(info)
	if info.gone then
		return "GONE"
	end
	return info.place or info.state or "?"
end

local function statusText(token)
	local fn = STATUS_TEXT[token]
	return fn and fn() or "?"
end

-- token of DESTINATION_TOOLTIP
local function destinationToken(info)
	return info.place or info.purpose or "OTHER"
end

local function destinationTooltip(token)
	local fn = DESTINATION_TOOLTIP[token]
	return fn and fn() or ""
end

-- ---------------------------------------------------------------------------------------------
-- Data

local lineCheckCache = {} -- industry -> { check, time }
local latest = {}         -- industry -> latest snapshot, read by the table cells

-- Wall-clock seconds, independent of game speed and pause. os.time, not os.clock: os.clock is the process's CPU
-- time, which a multi-threaded game uses up several times faster than real time. Without os.time, count calls
-- instead: each refresh of the notice or the details window is about REFRESH_SECONDS apart.
local calls = 0
local function clock()
	local t = try(function() return os.time() end)
	if type(t) == "number" then
		return t
	end
	calls = calls + 1
	return calls * REFRESH_SECONDS
end

local function lineCheckFor(industry)
	local now = clock()
	local cached = lineCheckCache[industry]
	if cached and now - cached.time < LINE_CHECK_SECONDS then
		return cached.check
	end
	local check = try(core.collectLines, industry)
	lineCheckCache[industry] = { check = check, time = now }
	return check
end

-- shown when core.diagnose fails, so the window and the notice still open
local function diagnosisUnavailable()
	return { status = "INFO", severity = "info", tab = "ARRIVALS", notice = "neutral", title = tr("Diagnosis unavailable"), detail = "" }
end

-- Deterministic text form of plain tables, used to detect changes between refreshes.
local function serialize(value)
	if type(value) ~= "table" then
		return tostring(value)
	end
	local keys = {}
	for k in pairs(value) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for __, k in ipairs(keys) do
		parts[#parts + 1] = tostring(k) .. "=" .. serialize(value[k])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- withLines: always run the line check (details window); otherwise only when the diagnosis needs it (card: not boosted).
local function collectSafe(industry, withLines)
	local s = try(core.collect, industry, { productivity = productivity })
	if not s then
		return { failed = true, key = "failed" }
	end
	if s.hasCapacity and (withLines or not s.boosted) then
		s.lineCheck = lineCheckFor(industry)
	end
	s.diagnosis = try(core.diagnose, s, { duration = fmtDuration, lineName = entityName }) or diagnosisUnavailable()
	local now = s.now
	s.now = nil
	local day = dayLength()
	s.key = serialize(s) .. "@" .. tostring(day > 0 and math.floor(now / day) or now)
	s.now = now
	-- only the details window's full snapshot feeds the table cells; the industry window's notice skips the line
	-- check when boosted, and storing that one too made the line cells flicker between "-" and their values
	if withLines then
		latest[industry] = s
	end
	return s
end

local function useSnapshot(industry, withLines)
	return engine_react_util.useStepStateTimer(function()
		return collectSafe(industry, withLines)
	end, REFRESH_SECONDS, function(a, b)
		return a ~= nil and b ~= nil and a.key == b.key
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Widgets

local function text(str, class)
	return builtin.TextView { meta = { class = "font-scale-body" .. (class and class ~= "" and (", " .. class) or "") }, text = str }
end

-- Explanation in the details window: muted and wrapping over the full width.
local function note(str)
	return builtin.TextView { meta = { class = "font-scale-annotation, worker-diag-note" }, text = str }
end

local function icon(path, tooltip)
	return builtin.ImageView { meta = { class = "worker-diag-icon", tooltip = tooltip }, path = path }
end

local function hbox(children, class)
	return builtin.Component {
		meta = { class = class },
		layout = builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = children },
	}
end

local function vbox(children, class)
	return builtin.Component {
		meta = { class = class },
		layout = builtin.BoxLayout { orientation = builtin.type.Orientation.Vertical, children = children },
	}
end

local function spacer()
	return builtin.Component { meta = { class = "horizontal-spacer" } }
end

-- nameEntity: entity whose name is shown (default: entity), e.g. the town of a home
local function entityLink(entity, nameEntity)
	local child = line_react_util
		and line_react_util.NameTextView { entity = entity, nameEntity = nameEntity, locationButton = true }
		or text(entityName(nameEntity or entity))
	return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { child } }
end

local function destinationIcon(purpose)
	local index = DESTINATION_INDEX[purpose]
	if index == nil or not entity_window_util then
		return builtin.Component { meta = { class = "worker-diag-icon" } }
	end
	return entity_window_util.GetDestinationIcon { destinationIndex = index, iconClass = "worker-diag-icon" }
end

-- The verdict: one box tinted in the severity colour, with icon, title and explanation.
-- place: "window" (details window), sets the text width.
local function statusBox(d, place)
	local severity = d.severity or "info"
	local body = { text(d.title, severity .. ", worker-diag-status-title") }
	if d.detail ~= "" then
		body[#body + 1] = text(d.detail, "worker-diag-status-text")
	end
	return builtin.Component {
		meta = { class = "worker-diag-status, worker-diag-sev-" .. severity .. ", worker-diag-in-" .. place },
		layout = builtin.BoxLayout {
			meta = { class = "worker-diag-status-row" },
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				builtin.ImageView { meta = { class = "worker-diag-status-icon" }, path = SEVERITY_ICON[severity] or ICON.info },
				builtin.BoxLayout { meta = { class = "worker-diag-status-body" }, orientation = builtin.type.Orientation.Vertical, children = body },
			},
		},
	}
end

local function lastArrivalText(s)
	if not s.lastArrival then
		return fmt(tr("Last arrival: none in the last {window}"), { window = s.windowText or "?" })
	end
	return fmt(tr("Last arrival: {duration} ago"), { duration = fmtDuration(math.max(0, s.now - s.lastArrival)) })
end

local function lastArrival(s)
	return hbox({ icon(ICON.waiting, tr("Last worker who arrived by public transport")), text(lastArrivalText(s)) })
end

local function card(title, children)
	return content_card.ContentCard {
		title = title,
		extraChildrenPermanent = { vbox(children, "worker-diag-card-body") },
	}
end

-- ---------------------------------------------------------------------------------------------
-- Tables. Cells only get userParam when they are created, so they read live data on every step:
-- the person's components, or the latest snapshot of the industry (latest[industry]).
-- Each column has getCompareValue, which is what the table sorts by when a header is clicked.

-- Worker table. rowKey = person entity, userParam.industry = industry entity.

local function workerInfo(person, industry)
	return try(core.personInfo, person, industry, core.gameTime())
end

local function personState(params, fn)
	return engine_react_util.useStepStateTimer(function()
		local info = workerInfo(params.rowKey, params.userParam.industry)
		if not info then
			return "?"
		end
		return fn(info)
	end, CELL_REFRESH_SECONDS)
end

local CellName = react.RegisterRecipe("WorkerDiagCellName", function(params)
	return entityLink(params.rowKey)
end)

-- Status: destination icon (tooltip names it) and what the person is doing.
local CellStatus = react.RegisterRecipe("WorkerDiagCellStatus", function(params)
	-- tokens only ("WORK|WAITING|WORK"): translated here, not in the step state
	local state = personState(params, function(info)
		return (info.purpose or "OTHER") .. "|" .. destinationToken(info) .. "|" .. statusToken(info)
	end)
	local purpose, destination, status = string.match(state:old(), "^([^|]*)|([^|]*)|(.*)$")
	return builtin.BoxLayout {
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.Component {
				meta = { tooltip = destinationTooltip(destination) },
				layout = builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { destinationIcon(purpose) } },
			},
			text(statusText(status)),
		},
	}
end)

local CellLine = react.RegisterRecipe("WorkerDiagCellLine", function(params)
	local state = personState(params, function(info) return info.line or -1 end)
	local line = state:old()
	if type(line) ~= "number" or line < 0 then
		return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text("-") } }
	end
	return entityLink(line)
end)

local CellWait = react.RegisterRecipe("WorkerDiagCellWait", function(params)
	local state = personState(params, function(info) return quantize(info.waitingTime) end)
	local ticks = state:old()
	if type(ticks) ~= "number" or ticks < 0 then
		return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text("-") } }
	end
	return builtin.BoxLayout {
		orientation = builtin.type.Orientation.Horizontal,
		children = { text(fmtDuration(ticks), waitClass(ticks)) },
	}
end)

-- Home: the town name; the locate button jumps to the home building (like the game's person window).
local CellHome = react.RegisterRecipe("WorkerDiagCellHome", function(params)
	local state = personState(params, function(info)
		return string.format("%d|%d", info.home or -1, info.town or -1)
	end)
	local home, town = string.match(state:old(), "^(-?%d+)|(-?%d+)$")
	home, town = tonumber(home), tonumber(town)
	if not home or home < 0 then
		return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text("-") } }
	end
	return entityLink(home, town and town >= 0 and town or home)
end)

-- One table of workers.
local function workersTable(persons, industry)
	local function compare(fn)
		return function(person)
			return fn(workerInfo(person, industry), person)
		end
	end
	return builtin.DataTable {
		columns = {
			builtin.ColumnDesc { name = tr("Name"), recipe = CellName, weight = 2.6,
				getCompareValue = compare(function(_, person) return entityName(person) end) },
			builtin.ColumnDesc { name = tr("Home"), recipe = CellHome, weight = 2.4, tooltip = tr("Town the worker lives in"),
				getCompareValue = compare(function(info) return info and info.town and entityName(info.town) or "" end) },
			builtin.ColumnDesc { name = tr("Destination / Status"), recipe = CellStatus, weight = 2.4,
				-- grouped by destination, then by what they are doing
				getCompareValue = compare(function(info) return info and ((info.purpose or "") .. " " .. statusText(statusToken(info))) or "" end) },
			builtin.ColumnDesc { name = tr("Line"), recipe = CellLine, weight = 3.4, tooltip = tr("Line the worker waits for or rides on"),
				getCompareValue = compare(function(info) return info and info.line and entityName(info.line) or "" end) },
			builtin.ColumnDesc { name = tr("Waiting"), recipe = CellWait, weight = 1.2,
				tooltip = fmt(tr("Time at the current stop; orange from {warning}, red from {critical}"),
					{ warning = fmtDays(WAIT_WARNING_DAYS), critical = fmtDays(WAIT_CRITICAL_DAYS) }),
				getCompareValue = compare(function(info) return info and info.waitingTime or -1 end) },
		},
		rowKeys = persons,
		disableSortKey = true,
		initialSortColumn = { 5, false }, -- Waiting, longest first
		userParam = { industry = industry },
	}
end

-- Workers tab: who heads to or is at work, and everyone else.
local function workersCards(s)
	local toWork = {}
	if #s.workers == 0 then
		toWork[#toWork + 1] = text(tr("No resident has this industry as workplace."))
		return { card(tr("Current workers"), toWork) }
	end
	toWork[#toWork + 1] = #s.toWork > 0 and workersTable(s.toWork, s.industry)
		or text(tr("Nobody is on the way to work or at work right now."))
	local elsewhere = {
		#s.elsewhere > 0 and workersTable(s.elsewhere, s.industry) or text(tr("Everyone is on the way to work or at work.")),
	}
	return {
		card(fmt(tr("Going to work ({count})"), { count = int(#s.toWork) }), toWork),
		card(fmt(tr("Elsewhere ({count})"), { count = int(#s.elsewhere) }), elsewhere),
	}
end

-- Arrival log table. rowKey = person entity, userParam.industry = industry entity; the entry comes from
-- latest[industry].arrivalByPerson.

local function arrivalOf(industry, person)
	local s = latest[industry]
	return s and s.arrivalByPerson and s.arrivalByPerson[person], s and s.now
end

local function arrivalState(params, fn)
	return engine_react_util.useStepStateTimer(function()
		local arrival, now = arrivalOf(params.userParam.industry, params.rowKey)
		if not arrival or not now then
			return "-"
		end
		return fn(arrival, now)
	end, CELL_REFRESH_SECONDS)
end

local CellArrivalName = react.RegisterRecipe("WorkerDiagCellArrivalName", function(params)
	local gone = arrivalState(params, function(arrival) return arrival.gone and "gone" or "" end)
	if gone:old() == "gone" then
		return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text(tr("(person no longer exists)")) } }
	end
	return entityLink(params.rowKey)
end)

local CellArrived = react.RegisterRecipe("WorkerDiagCellArrived", function(params)
	local state = arrivalState(params, function(arrival, now) return quantize(now - arrival.time) end)
	local ticks = state:old()
	local str = type(ticks) == "number" and fmt(tr("{duration} ago"), { duration = fmtDuration(ticks) }) or "-"
	return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text(str) } }
end)

local CellCountsFor = react.RegisterRecipe("WorkerDiagCellCountsFor", function(params)
	local state = arrivalState(params, function(arrival, now) return quantize(arrival.expires - now) end)
	local ticks = state:old()
	return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text(type(ticks) == "number" and fmtDuration(ticks) or "-") } }
end)

-- ---------------------------------------------------------------------------------------------
-- Details window cards

-- The game's workplaces booster row, in its own card like in the industry window.
local function boosterCard(s)
	if not industry_react_util then
		return card(tr("Boosters"), { text(fmt(tr("{count} of {needed} arrivals needed for the boost."), { count = int(s.counted), needed = int(s.needed) })) })
	end
	return card(tr("Boosters"), {
		builtin.Component {
			meta = { class = "booster-widget, worker-diag-booster" },
			layout = builtin.TableLayout {
				rows = { industry_react_util.WorkplacesBoosterRow { entity = s.industry, boosted = s.boosted } },
				columnWeights = { -1, 1, -1, -1 }, -- the bar takes all spare width
			},
		},
	})
end

-- The arrival log: what the game counts for the boost.
local function arrivalsCard(s)
	local children = {
		hbox({
			lastArrival(s),
			spacer(),
			icon(ICON.waiting, tr("When the oldest entry drops out of the log")),
			text(s.nextExpiry and fmt(tr("Next entry expires in {duration}"), { duration = fmtDuration(math.max(0, s.nextExpiry - s.now)) })
				or tr("Next entry expires: -")),
		}),
		note(fmt(tr("Everyone who arrived by line in the last {window} counts, also if they work elsewhere now. {needed} needed."),
			{ window = s.windowText or "?", needed = int(s.needed) })),
	}
	local rowKeys = {}
	for __, arrival in ipairs(s.arrivals) do
		if arrival.person and s.arrivalByPerson[arrival.person] == arrival then
			rowKeys[#rowKeys + 1] = arrival.person
		end
	end
	if #rowKeys == 0 then
		children[#children + 1] = text(fmt(tr("Nobody arrived by line in the last {window}."), { window = s.windowText or "?" }))
	else
		local industry = s.industry
		local function compare(fn)
			return function(person)
				local arrival = arrivalOf(industry, person)
				return arrival and fn(arrival) or -1
			end
		end
		children[#children + 1] = builtin.DataTable {
			columns = {
				builtin.ColumnDesc { name = tr("Name"), recipe = CellArrivalName, weight = 2.4,
					getCompareValue = function(person) return entityName(person) end },
				builtin.ColumnDesc { name = tr("Home"), recipe = CellHome, weight = 2, tooltip = tr("Town the worker lives in"),
					getCompareValue = function(person)
						local info = workerInfo(person, industry)
						return info and info.town and entityName(info.town) or ""
					end },
				builtin.ColumnDesc { name = tr("Arrived"), recipe = CellArrived, weight = 1.3,
					getCompareValue = compare(function(arrival) return -arrival.time end) },
				builtin.ColumnDesc { name = tr("Time Left"), recipe = CellCountsFor, weight = 1.3, tooltip = tr("Time until the entry drops out of the log and no longer counts"),
					getCompareValue = compare(function(arrival) return arrival.expires end) },
			},
			rowKeys = rowKeys,
			disableSortKey = true,
			initialSortColumn = { 3, true }, -- Arrived, newest first
			userParam = { industry = industry },
		}
	end
	return card(tr("Arrival log"), children)
end

-- Lines tables. rowKey = line entity, userParam.industry = industry entity; cells read the line check from
-- latest[industry] on every step (userParam only reaches newly created cells).

local function lineCheckEntry(industry, line)
	local s = latest[industry]
	for __, entry in ipairs(s and s.lineCheck and s.lineCheck.lines or {}) do
		if entry.line == line then
			return entry, s
		end
	end
	return nil, s
end

local function nearbyEntry(industry, line)
	local s = latest[industry]
	for __, entry in ipairs(s and s.lineCheck and s.lineCheck.nearby or {}) do
		if entry.line == line then
			return entry
		end
	end
	return nil
end

local function residentsTotal(entry)
	if entry.residentsTotal then
		return entry.residentsTotal
	end
	local total = 0
	for transfers = 0, core.MAX_TRANSFERS do
		total = total + (entry.residents[transfers] or 0)
	end
	return total
end

-- residents by transfers as numbers only, "80|40|10" (translated when shown)
local function residentsTokens(entry)
	local parts = {}
	for transfers = 0, core.MAX_TRANSFERS do
		parts[#parts + 1] = string.format("%d", entry.residents[transfers] or 0)
	end
	return table.concat(parts, "|")
end

-- one line per number of transfers: "Directly: 80", "With 1 transfer: 40", ...
local function residentsBreakdown(counts)
	local lines = {}
	for transfers = 0, core.MAX_TRANSFERS do
		local count = int(counts[transfers + 1] or 0)
		lines[#lines + 1] = transfers == 0 and fmt(tr("Directly: {count}"), { count = count })
			or fmt(trn("With {transfers} transfer: {count}", "With {transfers} transfers: {count}", transfers),
				{ transfers = int(transfers), count = count })
	end
	return table.concat(lines, "\n")
end

local function lineState(params, fn)
	return engine_react_util.useStepStateTimer(function()
		local entry, s = lineCheckEntry(params.userParam.industry, params.rowKey)
		if not entry then
			return "-"
		end
		return fn(entry, s)
	end, CELL_REFRESH_SECONDS)
end

-- the line's vehicles as images, grouped like in the game's vehicle lists ("3x" and the composition)
local CellLineVehicles = react.RegisterRecipe("WorkerDiagCellLineVehicles", function(params)
	local vehicles = toListSafe(try(function() return api.engine.system.transportVehicleSystem.getLineVehicles(params.rowKey) end))
	if #vehicles == 0 then
		return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text("-") } }
	end
	if not vehicle_react_util then
		return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text(int(#vehicles)) } }
	end
	return builtin.BoxLayout {
		orientation = builtin.type.Orientation.Horizontal,
		children = { vehicle_react_util.VehicleWidget { vehicleEntities = vehicles } },
	}
end)

-- total residents, the breakdown by transfers in the tooltip
local CellLineResidents = react.RegisterRecipe("WorkerDiagCellLineResidents", function(params)
	-- numbers only, "130|80|40|10": the total, then by transfers
	local state = lineState(params, function(entry)
		return string.format("%d|%s", residentsTotal(entry), residentsTokens(entry))
	end)
	local numbers = {}
	for n in string.gmatch(state:old(), "[^|]+") do
		numbers[#numbers + 1] = tonumber(n)
	end
	if not numbers[1] then
		return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text("-") } }
	end
	local total = table.remove(numbers, 1)
	return builtin.BoxLayout {
		orientation = builtin.type.Orientation.Horizontal,
		children = { builtin.TextView { meta = { class = "font-scale-body", tooltip = residentsBreakdown(numbers) }, text = int(total) } },
	}
end)

local CellLineWaiting = react.RegisterRecipe("WorkerDiagCellLineWaiting", function(params)
	-- numbers only, "waiting|longest"
	local state = lineState(params, function(entry, s)
		local wait = s.lineWaits and s.lineWaits[entry.line]
		if not wait then
			return "-"
		end
		return string.format("%d|%d", wait.waiting, quantize(wait.longest))
	end)
	local waiting, longest = string.match(state:old(), "^(%d+)|(-?%d+)$")
	waiting, longest = tonumber(waiting), tonumber(longest)
	if not waiting then
		return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text("-") } }
	end
	local str = fmt(tr("{count}, longest {duration}"), { count = int(waiting), duration = fmtDuration(longest) })
	return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text(str, waitClass(longest)) } }
end)

local CellLineProblems = react.RegisterRecipe("WorkerDiagCellLineProblems", function(params)
	local state = lineState(params, function(entry) return tostring(#entry.problems) end)
	local n = tonumber(state:old()) or 0
	return builtin.BoxLayout {
		orientation = builtin.type.Orientation.Horizontal,
		children = { text(n > 0 and int(n) or "-", n > 0 and "warning" or "") },
	}
end)

-- Cargo: one icon per cargo type the line's vehicles carry, like the Cargo column of the game's line overview
-- (LineCargoTypesCell in statistic_lines.tl)
local CellLineCargo = react.RegisterRecipe("WorkerDiagCellLineCargo", function(params)
	local cargoTypes = engine_react_util.useStepStateTimer(function()
		if not (cargo_util and cargo_react_util) then
			return {}
		end
		return try(function()
			return cargo_util.getSortedProducedCargoTypes({ lineEntity = params.rowKey, getTendency = true, showEmpty = true },
				"CAPACITY", nil, nil, true)
		end) or {}
	end)
	local children = {}
	for __, cargoTypeId in ipairs(cargoTypes:old()) do
		children[#children + 1] = cargo_react_util.makeCargoIcon(cargoTypeId,
			"text-icon-size-hack, cargo-icon-only" .. (#children == 0 and ", first" or ""))
	end
	if #children == 0 then
		children[1] = text("-")
	end
	return builtin.BoxLayout {
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.Component {
				meta = { class = "cargo-icon-group" },
				layout = builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = children },
			},
		},
	}
end)

-- token and numbers only: "CARGO", or "WALK|station|metres"
local function nearbyToken(entry)
	if entry.reason == "CARGO" then
		return "CARGO"
	end
	return string.format("WALK|%d|%d", entry.station or -1, math.floor(entry.distance + 0.5))
end

local function nearbyWhere(token)
	if token == "CARGO" then
		return tr("at the industry")
	end
	local station, distance = string.match(token, "^WALK|(-?%d+)|(-?%d+)$")
	station, distance = tonumber(station), tonumber(distance)
	if not distance then
		return "-"
	end
	return fmt("{station}, {distance}", { -- no words: the name and the game's "{distance} m"
		station = station >= 0 and stationName(station) or "?",
		distance = fmt(tr("{distance} m"), { distance = int(distance) }),
	})
end

local CellNearbyWhere = react.RegisterRecipe("WorkerDiagCellNearbyWhere", function(params)
	local state = engine_react_util.useStepStateTimer(function()
		local entry = nearbyEntry(params.userParam.industry, params.rowKey)
		return entry and nearbyToken(entry) or "-"
	end, CELL_REFRESH_SECONDS)
	return builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = { text(nearbyWhere(state:old())) } }
end)

-- Which stops people can walk from, with distances, and which stations only cover the industry. The industry's own
-- station is only named when a passenger line uses it, otherwise mentioned as a hint when there are no lines.
local function stationsNote(check)
	local stops = core.stopNames(check)
	local covered = {}
	for __, station in ipairs(check.coveredOnly or {}) do
		covered[#covered + 1] = stationName(station)
	end
	local parts = {}
	parts[#parts + 1] = #stops > 0 and fmt(tr("Within walking reach: {stops}."), { stops = table.concat(stops, ", ") })
		or tr("No stop within walking reach.")
	if #covered > 0 then
		parts[#parts + 1] = fmt(tr("Out of walking reach: {stations}."), { stations = table.concat(covered, ", ") })
	end
	if #check.lines == 0 then
		parts[#parts + 1] = core.ownStationHint()
	end
	return table.concat(parts, " ") -- whole sentences
end

local function linesCard(s)
	local check = s.lineCheck
	if not check then
		return card(tr("Passenger lines"), { text(tr("The line check could not run. See [WorkerDiag] lines in stdout.txt.")) })
	end
	local children = {
		note(stationsNote(check)),
	}
	if #check.lines == 0 then
		if #core.stopNames(check) > 0 then
			children[#children + 1] = text(tr("No passenger line stops there."))
		end
		return card(tr("Passenger lines"), children)
	end
	local industry = s.industry
	local rowKeys = {}
	for __, entry in ipairs(check.lines) do
		rowKeys[#rowKeys + 1] = entry.line
	end
	local function compare(fn)
		return function(line)
			local entry, snapshot = lineCheckEntry(industry, line)
			return entry and fn(entry, snapshot) or -1
		end
	end
	children[#children + 1] = builtin.DataTable {
		columns = {
			builtin.ColumnDesc { name = tr("Line"), recipe = CellName, weight = LINE_COLUMNS.line,
				getCompareValue = function(line) return entityName(line) end },
			builtin.ColumnDesc { name = tr("Vehicles"), recipe = CellLineVehicles, weight = LINE_COLUMNS.vehicles,
				getCompareValue = compare(function(entry) return entry.vehicles end) },
			builtin.ColumnDesc { name = tr("Residents"), recipe = CellLineResidents, weight = LINE_COLUMNS.third,
				tooltip = fmt(trn("Residents near the line's stops, directly or with up to {count} transfer",
					"Residents near the line's stops, directly or with up to {count} transfers", core.MAX_TRANSFERS), { count = int(core.MAX_TRANSFERS) }),
				getCompareValue = compare(residentsTotal) },
			builtin.ColumnDesc { name = tr("Workers waiting"), recipe = CellLineWaiting, weight = LINE_COLUMNS.waiting,
				getCompareValue = compare(function(entry, snapshot)
					local wait = snapshot.lineWaits and snapshot.lineWaits[entry.line]
					return wait and wait.longest or -1
				end) },
			builtin.ColumnDesc { name = tr("Problems"), recipe = CellLineProblems, weight = LINE_COLUMNS.problems,
				getCompareValue = compare(function(entry) return #entry.problems end) },
		},
		rowKeys = rowKeys,
		disableSortKey = true,
		initialSortColumn = { 5, false }, -- lines with problems first
		userParam = { industry = industry },
	}
	-- problems grouped by line: the name once, then its problems; at most MAX_PROBLEMS, the rest in a tooltip
	local shown, hidden = 0, {}
	for __, entry in ipairs(check.lines) do
		local headed = false
		for __, problem in ipairs(entry.problems) do
			if shown < MAX_PROBLEMS then
				if not headed then
					children[#children + 1] = text(entityName(entry.line), "worker-diag-problem-line")
					headed = true
				end
				children[#children + 1] = hbox({ icon(ICON.problem, nil), text(problem, "warning, worker-diag-problem") }, "worker-diag-problem-row")
				shown = shown + 1
			else
				hidden[#hidden + 1] = fmt("{line}: {problem}", { line = entityName(entry.line), problem = problem }) -- no words
			end
		end
	end
	if #hidden > 0 then
		children[#children + 1] = builtin.TextView {
			meta = { class = "font-scale-body, warning, worker-diag-problem-more", tooltip = table.concat(hidden, "\n") },
			text = fmt(trn("+{count} more problem", "+{count} more problems", #hidden), { count = int(#hidden) }),
		}
	end
	return card(tr("Passenger lines"), children)
end

local function nearbyCard(s)
	local nearby = s.lineCheck and s.lineCheck.nearby or {}
	local children = {
		note(#nearby == 0 and tr("None.") or tr("Cargo lines at the industry, and lines at stations within walking distance.")),
	}
	if #nearby > 0 then
		local industry = s.industry
		local rowKeys = {}
		for __, entry in ipairs(nearby) do
			rowKeys[#rowKeys + 1] = entry.line
		end
		children[#children + 1] = builtin.DataTable {
			columns = {
				builtin.ColumnDesc { name = tr("Line"), recipe = CellName, weight = LINE_COLUMNS.line,
					getCompareValue = function(line) return entityName(line) end },
				builtin.ColumnDesc { name = tr("Vehicles"), recipe = CellLineVehicles, weight = LINE_COLUMNS.vehicles,
					getCompareValue = function(line)
						return #toListSafe(try(function() return api.engine.system.transportVehicleSystem.getLineVehicles(line) end))
					end },
				builtin.ColumnDesc { name = tr("Cargo"), recipe = CellLineCargo, weight = LINE_COLUMNS.third,
					getCompareValue = function(line)
						return cargo_util and try(cargo_util.calculateSortedLineCargoInfoCompareValue, line) or {}
					end },
				builtin.ColumnDesc { name = tr("Where"), recipe = CellNearbyWhere, weight = LINE_COLUMNS.waiting + LINE_COLUMNS.problems,
					getCompareValue = function(line)
						local entry = nearbyEntry(industry, line)
						return entry and entry.distance or -1
					end },
			},
			rowKeys = rowKeys,
			disableSortKey = true,
			initialSortColumn = { 4, true }, -- nearest first
			userParam = { industry = industry },
		}
	end
	return card(fmt(tr("Other lines nearby ({count})"), { count = int(#nearby) }), children)
end

-- ---------------------------------------------------------------------------------------------
-- Details window

local function failedLayout()
	return builtin.BoxLayout {
		children = { text(tr("Worker Diagnostics could not read this industry. See [WorkerDiag] lines in stdout.txt.")) },
	}
end

-- One tab: its own scroll area, so the status box above the tabs stays in view.
local function tab(key, label, children)
	return builtin.TabWidgetChild {
		localKey = key,
		value = key,
		indicator = builtin.TextView { meta = { class = "font-scale-tab-widget-indicator" }, text = label },
		item = builtin.Component {
			layout = builtin.BoxLayout {
				child = builtin.ScrollArea {
					meta = { class = "worker-diag-scroll" },
					horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
					verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
					content = builtin.Component {
						layout = builtin.BoxLayout {
							meta = { class = "worker-diag-body" },
							orientation = builtin.type.Orientation.Vertical,
							children = children,
						},
					},
				},
			},
		},
	}
end

-- Help: what the game doesn't tell. Observations from play come first (they explain most late-game problems) and
-- are marked as such; the facts below are verified in the game's scripts or tested in play.
-- Built when shown, in the player's language. Each key is one string literal (tools/check_strings.py reads them).
local function helpSections(s)
	return {
		{ title = tr("Observations"),
			note = tr("Seen in play, not confirmed in the game's code."),
			text = {
				tr("In a connected network, the trip to work often spans several lines. When lines are full or run too rarely, workers get stuck at stops along the way for months and never arrive. The Going to work tab shows who is waiting where, and for how long."),
				tr("When a town joins a larger network, its residents can reach more workplaces: they also take jobs in other towns, and an industry's workers come from several towns. A town without outside connections fills its industries more easily."),
			} },
		{ title = tr("The boost"),
			-- the window and the number needed come from the game; the log size isn't exposed (core.KEEP_HISTORY_COUNT)
			text = fmt(tr("The game counts everyone who arrived by line in the last {window}, at most {max} entries; with {needed} the boost is on. Walking or driving to an industry doesn't count. An entry keeps counting even if that person works elsewhere now."), {
				window = s.windowText or core.yearsText(productivity.workersTimeIntervalMax),
				max = int(core.KEEP_HISTORY_COUNT),
				needed = int(s.needed),
			}) },
		{ title = tr("Workers change jobs"),
			text = tr("Residents choose their home, shop and workplace again and again. Who works here today says little; what matters is who arrives. Workers stuck at a stop for a long time may change jobs before they ever arrive.") },
		{ title = tr("Walking reach"),
			text = tr("A stop only brings workers if its walking area reaches the industry's entrance; select the station to see it. Being inside the station's catchment circle is not enough, and without a road or path to the entrance nobody can walk there.") },
		{ title = tr("The industry's own station"),
			text = tr("Every industry has its own road station. A passenger line stopping there with passenger loading on brings workers right to the entrance.") },
		{ title = tr("Passenger loading"),
			text = tr("The game only switches on passenger loading by default when you add a passenger station to a line. At industry and cargo stations it is often off; check the stop settings of your lines.") },
	}
end

local function helpCards(s)
	local cards = {}
	for __, section in ipairs(helpSections(s)) do
		local children = {}
		if section.note then
			children[#children + 1] = note(section.note)
		end
		for __, paragraph in ipairs(type(section.text) == "table" and section.text or { section.text }) do
			children[#children + 1] = text(paragraph, "worker-diag-help")
		end
		cards[#cards + 1] = card(section.title, children)
	end
	return cards
end

-- Tab labels carry the key numbers, so the state is visible without switching tabs.
local function tabLabels(s)
	local labels = {
		ARRIVALS = fmt(tr("Arrivals ({count}/{needed})"), { count = int(s.counted), needed = int(s.needed) }),
		WORKERS = fmt(tr("Going to work ({count})"), { count = int(#s.toWork) }), -- going to or at work, as the first table
		LINES = tr("Lines"),
	}
	local check = s.lineCheck
	if check then
		local withProblems = 0
		for __, line in ipairs(check.lines) do
			if #line.problems > 0 then
				withProblems = withProblems + 1
			end
		end
		labels.LINES = withProblems > 0
			and fmt(tr("Lines ({count}, {problems} with problems)"), { count = int(#check.lines), problems = int(withProblems) })
			or fmt(tr("Lines ({count})"), { count = int(#check.lines) })
	end
	return labels
end

local WindowContent = react.RegisterRecipe("WorkerDiagWindowContent", function(params)
	-- hooks first: they must run on every render, also when the data can't be read
	local selectedTab = react.useState(nil)
	local s = useSnapshot(params.industry, true):old()
	if s == nil or s.failed then
		return failedLayout()
	end
	local children = { statusBox(s.diagnosis, "window") }
	if s.hasCapacity then
		local labels = tabLabels(s)
		children[#children + 1] = builtin.TabWidget {
			meta = { class = "worker-diag-tabs" },
			-- opens on the tab that explains the diagnosis, until the player picks one
			value = selectedTab:old() or s.diagnosis.tab or "ARRIVALS",
			onValueChange = function(value) selectedTab:set(value) end,
			tabs = {
				tab("ARRIVALS", labels.ARRIVALS, { boosterCard(s), arrivalsCard(s) }),
				tab("WORKERS", labels.WORKERS, workersCards(s)),
				tab("LINES", labels.LINES, { linesCard(s), nearbyCard(s) }),
				tab("HELP", tr("Help"), helpCards(s)),
			},
		}
	end
	return builtin.BoxLayout {
		meta = { class = "worker-diag-window-body" },
		orientation = builtin.type.Orientation.Vertical,
		children = children,
	}
end)

local DetailsWindow = react.RegisterWrapperRecipe("WorkerDiagWindow", builtin.Window, function(params)
	react.useInputAction("IA_MENU_BACK", react.iaHandler(function()
		params.onClose()
	end))
	return builtin.Window {
		meta = { class = "worker-diag-window" },
		id = WINDOW_ID,
		title = fmt(tr("Worker Diagnostics: {name}"), { name = params.title }),
		closable = true,
		onClose = function() params.onClose() end,
		autoFocusOnBecomingVisible = true,
		initialX = 0.5,
		initialY = 0.5,
		content = WindowContent {
			meta = { localKey = "request" .. tostring(params.requestId) },
			industry = params.industry,
		},
	}
end)

local requestCounter = 0

local function getWindowApi()
	local globals = try(function() return req "::/gui/main/game_react_globals.tl" end)
	return globals and try(globals.getDefaultWindowApi)
end

-- Drops the window's data too: the next open starts with a fresh line check.
function worker_diag_ui.close()
	for industry in pairs(latest) do
		latest[industry] = nil
	end
	for industry in pairs(lineCheckCache) do
		lineCheckCache[industry] = nil
	end
	local windowApi = getWindowApi()
	if windowApi then
		try(function() windowApi.removeAllWindows(DetailsWindow) end)
	end
end

function worker_diag_ui.open(industry)
	local windowApi = getWindowApi()
	if windowApi == nil then
		log("no window container")
		return
	end
	requestCounter = requestCounter + 1
	try(function()
		windowApi.addSingletonWindow(DetailsWindow, {
			industry = industry,
			title = industryName(industry),
			requestId = requestCounter,
			onClose = worker_diag_ui.close,
		})
		windowApi.moveSingletonWindowToFront(DetailsWindow)
	end)
	try(function() api.gui.byId.setVisible(WINDOW_ID, true) end)
end

-- ---------------------------------------------------------------------------------------------
-- Notice in the industry window

-- Notice, built like the game's notifications in entity windows (NotificationWidgetEntry in
-- entity_window_util.tl): an outlined, clickable bar with a coloured icon tile and one sentence.
--   caution: yellow tint and tile, the player tried to bring workers and it doesn't work yet
--   neutral: no tint, blue tile; not serving an industry may be a choice
--   ok:      no tint, green tile
local NOTICE = {
	caution = { type = "Caution", icon = ICON.worker },
	neutral = { type = "Info", icon = ICON.details },
	ok = { type = "Achievement", icon = ICON.ok },
}

local function noticeIcon(kind)
	local n = NOTICE[kind] or NOTICE.neutral
	if notification_react_util then
		return notification_react_util.NotificationSimpleIcon { icon = n.icon, type = n.type }
	end
	return builtin.BoxLayout { children = { icon(n.icon) } }
end

local CardContent = react.RegisterRecipe("WorkerDiagCardContent", function(params)
	local s = useSnapshot(params.industry, false):old()
	if s == nil or s.failed then
		return failedLayout()
	end
	local d = s.diagnosis
	local kind = NOTICE[d.notice] and d.notice or "neutral"
	return builtin.BoxLayout {
		meta = { class = "worker-diag-card" },
		children = {
			builtin.Component {
				meta = { class = "notification-entity-window-card-outline, worker-diag-notice, worker-diag-notice-" .. kind },
				layout = builtin.BoxLayout {
					children = {
						builtin.Button {
							meta = { tooltip = tr("Open worker details") },
							content = builtin.BoxLayout {
								orientation = builtin.type.Orientation.Horizontal,
								children = {
									noticeIcon(kind),
									builtin.TextView {
										meta = { class = "font-scale-body, worker-diag-notice-text" },
										text = d.detail ~= "" and d.detail or d.title,
									},
								},
							},
							onClick = function() worker_diag_ui.open(params.industry) end,
						},
					},
				},
			},
		},
	}
end)

local industryWindow = { id = "::IndustryEowExtensionPoint" }

worker_diag_ui.WorkerDiagPlugin = react.RegisterPluginRecipe(industryWindow, "WorkerDiagPlugin", function(params)
	-- the game's section title (as ContentCard draws it), then the notice without a card frame around it,
	-- like the game's notifications in entity windows; the title shows the notice comes from this mod
	return builtin.BoxLayout {
		orientation = builtin.type.Orientation.Vertical,
		children = {
			builtin.Component {
				layout = builtin.BoxLayout {
					orientation = builtin.type.Orientation.Horizontal,
					children = {
						builtin.TextView { meta = { class = "card-title, font-scale-headline, worker-diag-title" }, text = tr("Worker Diagnostics") },
						builtin.ImageView {
							meta = { class = "card-title-decor, worker-diag-title-decor" },
							path = "::/gui/entity_window/design/window_card_heading_decor.tga",
						},
					},
				},
			},
			CardContent { meta = { localKey = "workerDiagnostics" }, industry = params.entityId },
		},
	}
end)

function worker_diag_ui.conditionWorkerDiag(params)
	return try(function()
		return api.engine.getComponent(params.entityId, api.type.ComponentType.PERSON_CAPACITY) ~= nil
	end) == true
end

function data()
	return worker_diag_ui
end

return worker_diag_ui
