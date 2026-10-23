-- Worker Diagnostics: collects everything that decides whether workers reach an industry, and names the
-- step at which the chain breaks.
--
-- How the base game counts workers (base/content/industries/industry_workers.script.tl and
-- industry_productivity_util.tl):
--   * a person counts when it arrives at the industry and its last trip was by lines;
--   * only arrivals within workersTimeIntervalMax (2 game years) count, at most 20 are kept;
--   * the boost needs capacity * RequiredWorkersFractionForBoost (20 * 0.5 = 10) of them;
--   * the log doesn't care who works here now: residents re-choose their workplace often, so the arrival log
--     and the current workers (getSimPersonsForDestination) are two different lists;
--   * industries forbid WALK and DRIVE for workers (industryutil.lua), so only residents who can reach the
--     industry by lines ever choose it as workplace.
--
-- Plain Lua without game-only globals at load time, so tests can run it with a fake `api`.

local M = {}

M.MAX_TRANSFERS = 2

local function try(fn, ...)
	local ok, result = pcall(fn, ...)
	if ok then
		return result
	end
	return nil
end

local function field(obj, key)
	if obj == nil then
		return nil
	end
	return try(function() return obj[key] end)
end

local function len(obj)
	if obj == nil then
		return 0
	end
	return try(function() return #obj end) or 0
end

local function toList(list)
	local result = {}
	for i = 1, len(list) do
		result[#result + 1] = field(list, i)
	end
	return result
end

local function component(entity, name)
	return try(function() return api.engine.getComponent(entity, api.type.ComponentType[name]) end)
end

local function enumValue(enumName, key)
	return try(function() return api.type["enum"][enumName][key] end)
end

function M.gameTime()
	local gt = try(function()
		return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
	end)
	return gt and gt.gameTime or 0
end

-- ---------------------------------------------------------------------------------------------
-- Translation hooks. The core builds its texts from English keys through these; the defaults keep them English, so
-- tests run without the game. The UI replaces them with the game's functions (see worker_diag_ui.script.lua):
--   M.tr(key)                      -> _(key)
--   M.trn(singular, plural, n)     -> nGetText, then _ (our own keys live in strings.json)
--   M.fmt(template, values)        -> lang_util.format: replaces {name} by values.name
--   M.int(n)                       -> lang_util.formatInt
--   M.duration(ticks)              -> the game's day / month / year formatting at the current calendar speed
-- Every sentence with values is one key with named placeholders; never join translated fragments.

function M.tr(key)
	return key
end

function M.trn(singular, plural, n)
	if n == 1 then
		return singular
	end
	return plural
end

-- plainFmt / plainInt stay the defaults, as the UI's fallbacks
function M.plainFmt(template, values)
	return (template:gsub("{([%w_]+)}", function(name)
		local value = values[name]
		return value ~= nil and tostring(value) or nil
	end))
end

function M.plainInt(n)
	return string.format("%d", math.floor(n + 0.5))
end

M.fmt, M.int = M.plainFmt, M.plainInt

-- nil: yearsText uses its English fallback
M.duration = nil

-- late-bound, so the UI's replacements take effect
local function tr(key) return M.tr(key) end
local function trn(singular, plural, n) return M.trn(singular, plural, n) end
local function fmt(template, values) return M.fmt(template, values) end
local function int(n) return M.int(n) end

-- The base game's arrival log keeps at most this many entries (KeepHistoryCount in industry_workers.script.tl,
-- not exposed to mods). Help names it; the number needed for the boost comes from the industry.
M.KEEP_HISTORY_COUNT = 20

-- The arrival window as text ("2 Years" through M.duration in the game), for texts about it, so they follow
-- industry_productivity_util.workersTimeIntervalMax instead of repeating its value. Without M.duration (tests):
-- English whole or decimal years.
function M.yearsText(ticks)
	if type(ticks) ~= "number" then
		return "?"
	end
	if M.duration then
		local ok, text = pcall(M.duration, ticks)
		if ok and type(text) == "string" then
			return text
		end
	end
	local year = try(function() return api.util.getDefaultYearDuration() end)
		or try(function() return api.util.getDefaultDayDuration() * 365 end)
	if type(year) ~= "number" or year <= 0 then
		return "?"
	end
	local years = ticks / year
	if math.abs(years - math.floor(years + 0.5)) < 0.05 then
		local n = math.floor(years + 0.5)
		return n == 1 and "1 year" or string.format("%d years", n)
	end
	return string.format("%.1f years", years)
end

-- ---------------------------------------------------------------------------------------------
-- Persons

-- What a person is doing right now.
--   place:   AT_WORK | AT_HOME | AT_SHOP | AT_OTHER  (inside a building)  or nil (on the way)
--   purpose: WORK | HOME | SHOP | OTHER             (where it is or where it heads to)
--   state:   WAITING | RIDING | WALKING              (only on the way)
--   line, waitingTime                               (line it waits for / rides on, time at the stop)
--   home, town                                      (home building and its town, nil if unknown)
function M.personInfo(person, industry, now)
	local simPerson = component(person, "SIM_PERSON")
	if not simPerson then
		return { person = person, gone = true }
	end
	local target = simPerson.targetOrAtEntity
	local purpose = "OTHER"
	if target == industry then
		purpose = "WORK"
	elseif target == field(simPerson.destinations, 1) then
		purpose = "HOME"
	elseif target == field(simPerson.destinations, 2) then
		purpose = "SHOP"
	end
	local info = { person = person, purpose = purpose }
	local home = field(simPerson.destinations, 1)
	if home and home >= 0 then
		info.home = home
		info.town = field(component(home, "TOWN_BUILDING"), "town")
	end
	if component(person, "SIM_ENTITY_AT_BUILDING") then
		info.place = "AT_" .. purpose
		return info
	end
	local atTerminal = component(person, "SIM_ENTITY_AT_TERMINAL")
	local atVehicle = component(person, "SIM_PERSON_AT_VEHICLE")
	if atTerminal then
		info.state = "WAITING"
		info.line = atTerminal.line
		if atTerminal.arrivalTime and now then
			info.waitingTime = now - atTerminal.arrivalTime
		end
	elseif atVehicle then
		info.state = "RIDING"
		local vehicle = component(atVehicle.vehicle, "TRANSPORT_VEHICLE")
		info.line = vehicle and vehicle.line
	else
		info.state = "WALKING"
	end
	return info
end

-- One entry of the base game's arrival log (industry_workers.script.tl). The log keeps everyone who arrived by
-- lines within the last 2 years, whether or not they still work here: residents re-choose their destinations
-- all the time (SimPerson.lastDestinationUpdate, baseConfig.simPersonDestinationRecomputationProbability).
--   person, time, expires
--   gone: the person no longer exists (entity removed or reused); the game still counts the entry
function M.arrivalInfo(visitor, windowLength)
	local ref = visitor.entity
	local person = field(ref, "entity")
	local info = { person = person, time = visitor.time, expires = visitor.time + windowLength }
	local exists = person ~= nil and try(function() return api.engine.entityExists(person) end) ~= false
	local revision = try(function() return api.engine.getRevision(person).num[1] end)
	local stored = field(field(field(ref, "revision"), "num"), 1)
	local simPerson = exists and component(person, "SIM_PERSON")
	if not simPerson or (revision and stored and stored < revision) then
		info.gone = true
	end
	return info
end

M.PURPOSES = { "WORK", "HOME", "SHOP", "OTHER" }

-- summary[purpose] = { AT = n (inside the building), WAITING = n, RIDING = n, WALKING = n (on the way there) }
local function newSummary()
	local summary = {}
	for __, purpose in ipairs(M.PURPOSES) do
		summary[purpose] = { AT = 0, WAITING = 0, RIDING = 0, WALKING = 0 }
	end
	return summary
end

local function addToSummary(summary, info)
	if info.gone then
		return
	end
	local counts = summary[info.purpose]
	local key = info.place and "AT" or info.state
	counts[key] = counts[key] + 1
end

-- ---------------------------------------------------------------------------------------------
-- Industry snapshot

-- deps.productivity: content.industries.industry_productivity_util
function M.collect(industry, deps)
	local now = M.gameTime()
	local personCapacity = component(industry, "PERSON_CAPACITY")
	local s = {
		industry = industry,
		now = now,
		hasCapacity = personCapacity ~= nil and (personCapacity.capacity or 0) > 0,
	}
	if not s.hasCapacity then
		return s
	end

	local productivity = deps.productivity
	s.capacity = personCapacity.capacity
	s.needed = math.ceil(personCapacity.capacity * productivity.RequiredWorkersFractionForBoost)
	s.windowLength = productivity.workersTimeIntervalMax
	s.windowText = M.yearsText(s.windowLength)
	local cutoff = now - productivity.workersTimeIntervalMax
	s.counted = 0
	s.arrivals = {}
	s.arrivalByPerson = {} -- person -> arrival
	for __, visitor in ipairs(try(productivity.getVisitors, industry) or {}) do
		if visitor.time and visitor.time >= cutoff then
			s.counted = s.counted + 1
			local arrival = M.arrivalInfo(visitor, productivity.workersTimeIntervalMax)
			s.arrivals[#s.arrivals + 1] = arrival
			if arrival.person then
				s.arrivalByPerson[arrival.person] = arrival
			end
			if s.nextExpiry == nil or arrival.expires < s.nextExpiry then
				s.nextExpiry = arrival.expires
			end
			-- only within the window: an older arrival no longer counts and would contradict "none in 2 years"
			if s.lastArrival == nil or visitor.time > s.lastArrival then
				s.lastArrival = visitor.time
			end
		end
	end
	table.sort(s.arrivals, function(a, b)
		if a.time ~= b.time then
			return a.time > b.time
		end
		return (a.person or -1) < (b.person or -1)
	end)
	s.boosted = (try(productivity.getIndustryProductivity, industry) or 1.0) > 1.0

	local persons = toList(try(function() return api.engine.system.simPersonSystem.getSimPersonsForDestination(industry) end))
	s.assigned = #persons
	s.summary = newSummary()
	s.lineWaits = {} -- line -> { waiting, toWork, longest }
	local infos = {}
	for __, person in ipairs(persons) do
		local info = M.personInfo(person, industry, now)
		infos[#infos + 1] = info
		addToSummary(s.summary, info)
		if info.state == "WAITING" and info.line then
			local w = s.lineWaits[info.line] or { waiting = 0, toWork = 0, longest = 0 }
			w.waiting = w.waiting + 1
			if info.purpose == "WORK" then
				w.toWork = w.toWork + 1
			end
			w.longest = math.max(w.longest, info.waitingTime or 0)
			s.lineWaits[info.line] = w
		end
		-- every waiting worker counts in summary.WORK.WAITING, with or without a known line, so this one too:
		-- diagnose relies on it being set whenever that count is above 0
		if info.state == "WAITING" and info.purpose == "WORK"
			and (s.longestWaitToWork == nil or (info.waitingTime or 0) > s.longestWaitToWork.time) then
			s.longestWaitToWork = { time = info.waitingTime or 0, line = info.line }
		end
	end
	-- longest waits first, then by entity for a stable order
	table.sort(infos, function(a, b)
		local wa, wb = a.waitingTime or -1, b.waitingTime or -1
		if wa ~= wb then
			return wa > wb
		end
		return a.person < b.person
	end)
	-- all workers, and split: on the way to work or at work (toWork), everyone else (elsewhere)
	s.workers, s.toWork, s.elsewhere = {}, {}, {}
	for i, info in ipairs(infos) do
		s.workers[i] = info.person
		local list = info.purpose == "WORK" and s.toWork or s.elsewhere
		list[#list + 1] = info.person
	end
	return s
end

-- ---------------------------------------------------------------------------------------------
-- Line check: which passenger lines can bring residents to the industry.
--
-- A resident can only choose the industry if a trip home -> walk -> line(s) -> walk -> industry exists:
--   * a station must cover the industry (passenger catchables = its catchment circle) AND its walking area must reach
--     the industry's entrance (see entranceWalk); covering alone doesn't bring workers, e.g. with no or a too long road;
--   * a line must stop there, have vehicles, and its stops near homes must load passengers;
--   * or homes must reach that line with up to MAX_TRANSFERS transfers (other lines at the same or a walkable station).
-- Only lines that load passengers at one stop at least are checked, so pure cargo lines don't show up.
-- Line.Stop.station / .terminal are 0-based, stopConfig.load is indexed by cargoTypeId + 1 (see subvention_util.tl).

local function passengerCargoTypeId()
	return try(function() return api.res.cargoTypeRep.getPassengerCargoTypeId() end) or 0
end

local function passengerCatchables(station)
	return toList(try(function() return api.engine.system.catchmentAreaSystem.getStationCatchables(station, false) end))
end

-- home entity -> residential capacity, for homes within walking distance of the station
-- catchables: optional (memoized) replacement for passengerCatchables
local function homesNear(station, catchables)
	local result = {}
	local residential = enumValue("LandUseType", "RESIDENTIAL")
	for __, entity in ipairs((catchables or passengerCatchables)(station)) do
		local pc = component(entity, "PERSON_CAPACITY")
		if pc and pc.type == residential then
			result[entity] = pc.capacity or 0
		end
	end
	return result
end

local function sumCapacity(homes)
	local total = 0
	for __, capacity in pairs(homes) do
		total = total + capacity
	end
	return total
end

local function stopStation(stop)
	local group = component(stop.stationGroup, "STATION_GROUP")
	return group and field(group.stations, (stop.station or 0) + 1)
end

local function stopTerminal(station, stop)
	local stationComp = component(station, "STATION")
	return stationComp and field(stationComp.terminals, (stop.terminal or 0) + 1)
end

-- Stations within walking distance of `station`, including itself.
local function walkableStations(station, distancesMap)
	local result = { [station] = true }
	local reachable = distancesMap and field(distancesMap, station)
	if type(reachable) == "table" then
		for other in pairs(reachable) do
			result[other] = true
		end
	end
	return result
end

local function linesAtStation(station)
	local result = {}
	for __, ref in ipairs(toList(try(function() return api.engine.system.lineSystem.getLineStopsForStation(station) end))) do
		local line = field(ref, 1)
		if line then
			result[line] = true
		end
	end
	return result
end

-- Stops of a line with what matters for passengers.
function M.describeLineStops(line, industryStations, passengerId)
	local lineComp = component(line, "LINE")
	local stops = {}
	for i, stop in ipairs(toList(lineComp and lineComp.stops)) do
		local station = stopStation(stop)
		local terminal = station and stopTerminal(station, stop)
		stops[i] = {
			index = i,
			station = station,
			isIndustryStop = station ~= nil and industryStations[station] == true,
			loadsPassengers = field(field(stop.stopConfig, "load"), passengerId + 1) == true,
			terminalLoad = terminal == nil or field(terminal, "passengersLoad") ~= false,
			terminalUnload = terminal == nil or field(terminal, "passengersUnload") ~= false,
		}
	end
	return stops
end

local function isPassengerLine(stops)
	for __, stop in ipairs(stops) do
		if stop.loadsPassengers then
			return true
		end
	end
	return false
end

-- One result per station and collectLines call: the same stations come up for every line and BFS level, and each
-- lookup is an engine call. Results are shared, so callers must not change them.
local function memoize(fn)
	local cache = {}
	return function(station)
		local value = cache[station]
		if value == nil then
			value = fn(station)
			cache[station] = value
		end
		return value
	end
end

-- Residents that reach `line` with 0..MAX_TRANSFERS transfers. Returns {[0] = n, [1] = n, ...}; each home is
-- counted once, at its lowest number of transfers.
-- lookup: the memoized station lookups of collectLines (homesNear, linesAtStation, walkableStations)
local function homesByTransfers(line, industryStations, passengerId, lookup, stopsCache)
	local function stopsOf(l)
		stopsCache[l] = stopsCache[l] or M.describeLineStops(l, industryStations, passengerId)
		return stopsCache[l]
	end
	local seenHomes, seenLines = {}, { [line] = true }
	local result = {}
	local level = { line }
	for transfers = 0, M.MAX_TRANSFERS do
		local total = 0
		local nextLevel = {}
		for __, l in ipairs(level) do
			for __, stop in ipairs(stopsOf(l)) do
				if stop.station and stop.loadsPassengers and stop.terminalLoad and not stop.isIndustryStop then
					for home, capacity in pairs(lookup.homesNear(stop.station)) do
						if not seenHomes[home] then
							seenHomes[home] = true
							total = total + capacity
						end
					end
				end
				-- feeder lines: board this line at the stop, coming from a line at the same or a walkable station;
				-- not at the industry's stop: who gets there has arrived, a line meeting this one there brings nobody
				if stop.station and stop.loadsPassengers and not stop.isIndustryStop and transfers < M.MAX_TRANSFERS then
					for transferStation in pairs(lookup.walkableStations(stop.station)) do
						for other in pairs(lookup.linesAtStation(transferStation)) do
							if not seenLines[other] then
								seenLines[other] = true
								nextLevel[#nextLevel + 1] = other
							end
						end
					end
				end
			end
		end
		result[transfers] = total
		table.sort(nextLevel)
		level = nextLevel
	end
	return result
end

-- Returns walk(station) -> walking distance in metres from the station to the industry's entrance (nil if the station's
-- walking area doesn't reach it), and true for the industry's own station (distance 0).
-- The entrance is the construction's frozen node; streetSystem.getNodeSegments lists the road pieces attached to it,
-- and catchmentAreaSystem.getStation2edgesMap the road pieces each station reaches on foot, with distance.
-- Without that data (older game version) every station counts, with an unknown distance (-1).
function M.entranceWalk(industry)
	local streets = function() return api.engine.system.streetConnectorSystem end
	local construction = try(function() return streets().getConstructionEntityForIndustry(industry) end)
		or try(function() return streets().getConstructionEntityForSubconstruction(industry) end)
	local constructionComp = construction and construction >= 0 and component(construction, "CONSTRUCTION")
	local entranceSegments, any = {}, false
	for __, node in ipairs(toList(constructionComp and constructionComp.frozenNodes)) do
		for __, segment in ipairs(toList(try(function() return api.engine.system.streetSystem.getNodeSegments(node) end))) do
			entranceSegments[segment] = true
			any = true
		end
	end
	local station2edges = try(function() return api.engine.system.catchmentAreaSystem.getStation2edgesMap() end)
	if not (constructionComp and any and station2edges) then
		return function() return -1 end
	end
	return function(station)
		if try(function() return streets().getConstructionEntityForStation(station) end) == construction then
			return 0, true
		end
		local nearest
		for __, entry in ipairs(toList(field(station2edges, station))) do
			local edgeEntity = field(field(entry, 1), "entity")
			local distance = field(entry, 2)
			if edgeEntity and entranceSegments[edgeEntity] and (nearest == nil or (distance or 0) < nearest) then
				nearest = distance or 0
			end
		end
		return nearest
	end
end

function M.collectLines(industry)
	local passengerId = passengerCargoTypeId()
	local result = { industryStations = {}, lines = {} }

	-- Stations whose catchment circle covers the industry (all stations, also those outside towns). Covering is not
	-- enough: people only walk there if the station's walking area reaches a road piece at the industry's entrance
	-- (the walk highlight when the station is selected). The industry's own station is inside and always counts.
	--   industryStations = stations people can walk from, walkDistance[station] = metres to the entrance (0 for own)
	--   own[station]     = the industry's own station; every industry has one, so it's only named when a line uses it
	--   stops            = the walkable stations worth naming: built by the player, or own and served by a passenger line
	--   coveredOnly      = stations that cover the industry but can't reach its entrance on foot
	local walk = M.entranceWalk(industry)
	local distancesMap = try(function() return api.engine.system.catchmentAreaSystem.getStation2stationsAndDistancesMap() end)
	local catchables = memoize(passengerCatchables)
	local lookup = {
		homesNear = memoize(function(station) return homesNear(station, catchables) end),
		linesAtStation = memoize(linesAtStation),
		walkableStations = memoize(function(station) return walkableStations(station, distancesMap) end),
	}
	local industryStations = {}
	result.walkDistance = {}
	result.coveredOnly = {}
	result.own = {}
	local candidates = {}
	try(function()
		api.engine.forEachEntityWithComponent(function(station)
			candidates[#candidates + 1] = station
		end, api.type.ComponentType.STATION)
	end)
	table.sort(candidates)
	for __, station in ipairs(candidates) do
		local covers = false
		for __, entity in ipairs(catchables(station)) do
			if entity == industry then
				covers = true
				break
			end
		end
		if covers then
			local distance, own = walk(station)
			if distance then
				industryStations[station] = true
				result.industryStations[#result.industryStations + 1] = station
				result.walkDistance[station] = distance
				result.own[station] = own or nil
			else
				result.coveredOnly[#result.coveredOnly + 1] = station
			end
		end
	end

	local stopsCache = {}

	local lineSet = {}
	for __, station in ipairs(result.industryStations) do
		for line in pairs(lookup.linesAtStation(station)) do
			lineSet[line] = true
		end
	end
	local lineList = {}
	for line in pairs(lineSet) do
		lineList[#lineList + 1] = line
	end
	table.sort(lineList)

	-- Other lines nearby: cargo-only lines at the industry's stations, and lines at stations within walking
	-- distance of them (candidates for a transfer or for an extra stop).
	--   nearby = { {line, reason = "CARGO" | "WALK", station, distance} }, sorted by distance
	result.nearby = {}
	local nearbyByLine = {}
	for __, station in ipairs(result.industryStations) do
		local reachable = distancesMap and field(distancesMap, station)
		if type(reachable) == "table" then
			for other, distance in pairs(reachable) do
				if not industryStations[other] then
					for line in pairs(lookup.linesAtStation(other)) do
						local entry = nearbyByLine[line]
						if not lineSet[line] and (entry == nil or distance < entry.distance) then
							nearbyByLine[line] = { line = line, reason = "WALK", station = other, distance = distance }
						end
					end
				end
			end
		end
	end

	local served = {} -- walkable stations where a passenger line stops
	for __, line in ipairs(lineList) do
		local stops = M.describeLineStops(line, industryStations, passengerId)
		stopsCache[line] = stops
		if not isPassengerLine(stops) then
			local station
			for __, stop in ipairs(stops) do
				if stop.isIndustryStop then
					station = stop.station
					break
				end
			end
			nearbyByLine[line] = { line = line, reason = "CARGO", station = station, distance = 0 }
		else
			local info = {
				line = line,
				vehicles = #toList(try(function() return api.engine.system.transportVehicleSystem.getLineVehicles(line) end)),
				problems = {},
				industryStopOk = false,
			}
			for __, stop in ipairs(stops) do
				if stop.isIndustryStop then
					served[stop.station] = true
					if stop.terminalUnload then
						info.industryStopOk = true
					else
						info.problems[#info.problems + 1] = fmt(tr("stop {stop} (industry): passengers can't get off"), { stop = int(stop.index) })
					end
					if not stop.loadsPassengers then
						info.problems[#info.problems + 1] = fmt(tr("stop {stop} (industry): passenger loading off, workers can't ride home"), { stop = int(stop.index) })
					end
				elseif stop.station and not (stop.loadsPassengers and stop.terminalLoad) then
					local nearby = sumCapacity(lookup.homesNear(stop.station))
					if nearby > 0 then
						info.problems[#info.problems + 1] = fmt(trn("stop {stop}: passenger loading off, {count} resident nearby",
							"stop {stop}: passenger loading off, {count} residents nearby", nearby), { stop = int(stop.index), count = int(nearby) })
					end
				end
			end
			info.residents = homesByTransfers(line, industryStations, passengerId, lookup, stopsCache)
			local total = 0
			for transfers = 0, M.MAX_TRANSFERS do
				total = total + info.residents[transfers]
			end
			info.residentsTotal = total
			if info.vehicles == 0 then
				info.problems[#info.problems + 1] = tr("no vehicles")
			end
			if total == 0 then
				info.problems[#info.problems + 1] = fmt(trn("no homes near any stop, even with {count} transfer",
					"no homes near any stop, even with {count} transfers", M.MAX_TRANSFERS), { count = int(M.MAX_TRANSFERS) })
			end
			result.lines[#result.lines + 1] = info
		end
	end

	for __, entry in pairs(nearbyByLine) do
		result.nearby[#result.nearby + 1] = entry
	end
	table.sort(result.nearby, function(a, b)
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.line < b.line
	end)

	result.stops = {}
	for __, station in ipairs(result.industryStations) do
		if not result.own[station] or served[station] then
			result.stops[#result.stops + 1] = station
		end
	end
	return result
end

-- ---------------------------------------------------------------------------------------------
-- Diagnosis

function M.ownStationHint()
	return tr("The industry's own station can also serve as a stop.")
end

local function stationName(station)
	local group = try(function() return api.engine.system.stationGroupSystem.getStationGroup(station) end)
	local name = group and group >= 0 and field(component(group, "NAME"), "name")
	return name or field(component(station, "NAME"), "name") or ("#" .. tostring(station))
end

M.stationName = stationName

-- The stops within walking distance as text: "Fürth Station North (120 m)", "the industry's station".
function M.stopNames(lineCheck)
	local names = {}
	for __, station in ipairs(lineCheck.stops or lineCheck.industryStations) do
		local d = lineCheck.walkDistance and lineCheck.walkDistance[station] or -1
		if lineCheck.own and lineCheck.own[station] then
			names[#names + 1] = tr("the industry's station")
		elseif d > 0 then
			-- no words in the template: the name and the game's "{distance} m"
			names[#names + 1] = fmt("{name} ({distance})", { name = stationName(station), distance = fmt(tr("{distance} m"), { distance = int(d) }) })
		else
			names[#names + 1] = stationName(station)
		end
	end
	return names
end

-- A line that can bring workers: it runs, lets passengers off at the industry and loads them near homes.
function M.isUsable(line)
	return line.vehicles > 0 and line.industryStopOk and line.residentsTotal > 0
end

-- Explains from the line check why no home can reach the industry, or returns nil if a usable line exists.
function M.diagnoseLines(lineCheck)
	if not lineCheck then
		return nil
	end
	-- no passenger line at any walkable station, but other stations cover the industry: the walk is the problem,
	-- either no road or path leads to the entrance or the way is too long (both look the same in the walking area).
	-- Telling them apart would need a path search; api.engine.util.pathfinding.findPathNodeToNode returned nothing for
	-- station terminal nodes, not even between two nodes of the same station, so we don't try.
	-- Only when no stop is within walking reach: with a nameable stop there, the missing line is the problem.
	local stops = M.stopNames(lineCheck)
	if #lineCheck.lines == 0 and #stops == 0 and #(lineCheck.coveredOnly or {}) > 0 then
		local names = {}
		for __, station in ipairs(lineCheck.coveredOnly) do
			names[#names + 1] = stationName(station)
		end
		return { status = "PROBLEM", severity = "error", tab = "LINES", notice = "neutral", title = tr("Stops nearby, but out of walking reach"),
			detail = fmt(tr("The walking area of {stations} doesn't reach the entrance: no road, or the way is too long."),
				{ stations = table.concat(names, ", ") }) }
	end
	if #lineCheck.lines == 0 and #stops == 0 then
		return { status = "PROBLEM", severity = "error", tab = "LINES", notice = "neutral", title = tr("No stop within walking distance"),
			detail = tr("No station reaches the entrance on foot.") }
	end
	if #lineCheck.lines == 0 then
		return { status = "PROBLEM", severity = "error", tab = "LINES", notice = "neutral", title = tr("No passenger line stops near the industry"),
			detail = fmt(tr("No passenger line stops at {stops}."), { stops = table.concat(stops, ", ") }) }
	end
	for __, line in ipairs(lineCheck.lines) do
		if M.isUsable(line) then
			return nil
		end
	end
	return { status = "PROBLEM", severity = "error", tab = "LINES", notice = "caution", title = tr("No line brings residents here"),
		detail = tr("None of the lines stopping here can bring workers. See the problems under Lines.") }
end

-- fmt.duration(ticks) -> string, fmt.lineName(line) -> string; both optional.
-- Returns { status = "OK" | "PROBLEM" | "INFO", severity = "success" | "info" | "warning" | "error",
--           tab = "ARRIVALS" | "WORKERS" | "LINES" (where the details explain it), title = string, detail = string,
--           notice = "caution" | "neutral" | "ok" (look of the card in the industry window: caution only when the
--           player evidently tried to bring workers and it doesn't work yet; not serving an industry may be a choice) }
-- severity "error": no resident can or does work here; "warning": workers exist but arrive too rarely.
-- Titles and details are built through M.tr / M.trn / M.fmt (English unless the UI sets the game's functions).
function M.diagnose(s, fmtFns)
	fmtFns = fmtFns or {}
	local duration = fmtFns.duration or function(t) return tostring(t) end
	local lineName = fmtFns.lineName or function(l) return "#" .. tostring(l) end
	-- the last arrival, only when someone arrived (each sentence has a key with and one without it)
	local last = (s.lastArrival and s.now) and duration(s.now - s.lastArrival) or nil
	local window = s.windowText or M.yearsText(s.windowLength)

	if not s.hasCapacity then
		return { status = "INFO", severity = "info", tab = "ARRIVALS", notice = "neutral", title = tr("No workplaces"),
			detail = tr("This industry has no workplaces.") }
	end
	if s.boosted then
		local counted = s.counted or 0
		local template = last
			and trn("{count} arrival in {window}, the last {duration} ago.", "{count} arrivals in {window}, the last {duration} ago.", counted)
			or trn("{count} arrival in {window}.", "{count} arrivals in {window}.", counted)
		return { status = "OK", severity = "success", tab = "ARRIVALS", notice = "ok", title = tr("No issues"),
			detail = fmt(template, { count = int(counted), window = window, duration = last }) }
	end
	if s.assigned == 0 then
		local lineProblem = M.diagnoseLines(s.lineCheck)
		if lineProblem then
			return lineProblem
		end
		if s.lineCheck then
			-- often only temporary: residents pick new workplaces from time to time
			return { status = "PROBLEM", severity = "warning", tab = "LINES", notice = "caution", title = tr("Connected, but nobody chose it"),
				detail = tr("A usable line exists, but no resident has picked this workplace yet.") }
		end
		return { status = "PROBLEM", severity = "error", tab = "LINES", notice = "neutral", title = tr("No resident works here"),
			detail = tr("The line check couldn't run.") }
	end
	-- Workers are assigned, but not enough arrive. The title is what the game counts for the boost; the detail names
	-- the most likely cause: a line problem, then workers waiting at stops.
	local title, arrived
	if s.counted == 0 then
		title = tr("No worker arrived yet")
		arrived = fmt(trn("The only worker didn't arrive in {window}.", "None of the {count} workers arrived in {window}.", s.assigned),
			{ count = int(s.assigned), window = window })
	else
		title = tr("Not enough workers")
		arrived = fmt(last and tr("{count} of {needed} needed arrived in {window}, the last {duration} ago.")
			or tr("{count} of {needed} needed arrived in {window}."),
			{ count = int(s.counted), needed = int(s.needed), window = window, duration = last })
	end
	local cause, tab = M.lineCause(s.lineCheck, lineName), "LINES"
	local waiting = s.summary.WORK.WAITING
	if not cause and waiting > 0 then
		-- collect sets longestWaitToWork for every waiting worker; a hand-made snapshot may lack it
		local longest = s.longestWaitToWork and s.longestWaitToWork.time
		cause = longest
			and fmt(trn("{count} waiting at a stop for {duration}.", "{count} waiting at stops, longest {duration}.", waiting),
				{ count = int(waiting), duration = duration(longest) })
			or fmt(trn("{count} waiting at a stop.", "{count} waiting at stops.", waiting), { count = int(waiting) })
		tab = "WORKERS"
	end
	if not cause then
		tab = "ARRIVALS"
		cause = s.assigned >= s.capacity and tr("All workplaces are taken.") or ""
	end
	-- two whole sentences
	return { status = "PROBLEM", severity = "warning", tab = tab, notice = "caution", title = title,
		detail = cause ~= "" and (arrived .. " " .. cause) or arrived }
end

-- The line problem most likely to keep workers away, as a sentence, or nil.
-- Only lines that can't bring workers count: a usable line's problem (e.g. one stop with loading off) doesn't keep
-- workers away, so naming it would hide the real cause, such as workers waiting at stops.
function M.lineCause(lineCheck, lineName)
	local general = M.diagnoseLines(lineCheck)
	if general then
		return fmt(tr("Cause: {problem}."), { problem = general.title })
	end
	local problems, firstLine, firstProblem = 0, nil, nil
	for __, line in ipairs(lineCheck and lineCheck.lines or {}) do
		for __, problem in ipairs(M.isUsable(line) and {} or line.problems) do
			problems = problems + 1
			if not firstLine then
				firstLine, firstProblem = lineName(line.line), problem
			end
		end
	end
	if not firstLine then
		return nil
	end
	if problems == 1 then
		return fmt(tr("Cause: {line}: {problem}."), { line = firstLine, problem = firstProblem })
	end
	return fmt(trn("Cause: {line}: {problem} (+{count} more problem).", "Cause: {line}: {problem} (+{count} more problems).", problems - 1),
		{ line = firstLine, problem = firstProblem, count = int(problems - 1) })
end

return M
