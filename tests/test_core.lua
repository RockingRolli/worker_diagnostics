-- Run from the mod folder: lua tests/test_core.lua
local here = arg[0]:match("(.*/)") or "./"
local core = dofile(here .. "../content/worker_diagnostics/worker_diag_core.lua")

-- ---------------------------------------------------------------------------------------------
-- Fake api

local MoveMode = { WALK = 0, DRIVE = 1, LINES = 2 }
local LandUseType = { RESIDENTIAL = 0, COMMERCIAL = 1, INDUSTRIAL = 2 }
local PASSENGERS = 0
local components = {}
local destinations = {}
local catchables = {}     -- station -> {entity}
local walkable = {}       -- station -> {station : distance}
local lineVehicles = {}   -- line -> {vehicle}
local now = 1000000

local function setComponent(entity, name, value)
	components[entity] = components[entity] or {}
	components[entity][name] = value
end

local YEAR = 100000

api = {
	util = { getDefaultYearDuration = function() return YEAR end },
	type = {
		ComponentType = setmetatable({}, { __index = function(_, k) return k end }),
		enum = { MoveMode = MoveMode, LandUseType = LandUseType },
	},
	res = { cargoTypeRep = { getPassengerCargoTypeId = function() return PASSENGERS end } },
	engine = {
		getComponent = function(entity, name)
			return components[entity] and components[entity][name]
		end,
		forEachEntityWithComponent = function(fn, name)
			local entities = {}
			for entity, comps in pairs(components) do
				if comps[name] then entities[#entities + 1] = entity end
			end
			table.sort(entities)
			for __, entity in ipairs(entities) do fn(entity) end
		end,
		util = {
			getWorld = function() return 1 end,
		},
		system = {
			simPersonSystem = {
				getSimPersonsForDestination = function(entity) return destinations[entity] or {} end,
			},
			catchmentAreaSystem = {
				getStationCatchables = function(station, cargo)
					assert(cargo == false)
					return catchables[station] or {}
				end,
				getStation2stationsAndDistancesMap = function() return walkable end,
			},
			lineSystem = {
				getLineStopsForStation = function(station)
					local result = {}
					for entity, comps in pairs(components) do
						if comps.LINE then
							for i, stop in ipairs(comps.LINE.stops) do
								local group = components[stop.stationGroup].STATION_GROUP
								if group.stations[stop.station + 1] == station then
									result[#result + 1] = { entity, i - 1 }
								end
							end
						end
					end
					return result
				end,
			},
			transportVehicleSystem = {
				getLineVehicles = function(line) return lineVehicles[line] or {} end,
			},
		},
	},
}

local visitors = {}
local productivity = {
	RequiredWorkersFractionForBoost = 0.5,
	workersTimeIntervalMax = 2 * YEAR,
	getVisitors = function() return visitors end,
	getIndustryProductivity = function() return 1.0 end,
}
local deps = { productivity = productivity }

local INDUSTRY = 50
local HOME, SHOP = 7, 8
local MAIN_STATION, TOWN_CENTER, INDUSTRY_STOP, SUBURB, VILLAGE = 200, 210, 220, 230, 240

local function reset()
	components, destinations, visitors = {}, {}, {}
	catchables, walkable, lineVehicles = {}, {}, {}
	setComponent(1, "GAME_TIME", { gameTime = now })
	setComponent(INDUSTRY, "PERSON_CAPACITY", { capacity = 20, type = LandUseType.INDUSTRIAL })
	productivity.getIndustryProductivity = function() return 1.0 end
end

-- extra.target: where the person is / heads to; extra.components: e.g. SIM_ENTITY_AT_TERMINAL
local function addWorker(person, extra)
	extra = extra or {}
	setComponent(person, "SIM_PERSON", {
		destinations = { HOME, SHOP, INDUSTRY },
		moveModes = { MoveMode.WALK, MoveMode.WALK, MoveMode.LINES },
		targetOrAtEntity = extra.target or HOME,
		lastMoveMode = MoveMode.LINES,
	})
	for name, value in pairs(extra.components or {}) do
		setComponent(person, name, value)
	end
	destinations[INDUSTRY] = destinations[INDUSTRY] or {}
	table.insert(destinations[INDUSTRY], person)
end

-- A station in its own station group, with a single terminal.
local function addStation(station, terminal)
	setComponent(station, "STATION", { terminals = { terminal or { passengersLoad = true, passengersUnload = true } } })
	setComponent(station + 1000, "STATION_GROUP", { stations = { station } })
end

local function addHome(entity, capacity, station)
	setComponent(entity, "PERSON_CAPACITY", { capacity = capacity, type = LandUseType.RESIDENTIAL })
	catchables[station] = catchables[station] or {}
	table.insert(catchables[station], entity)
end

-- stops = { {station, loadsPassengers, loadsCargo} }; cargo is cargo type 1 (passengers are 0)
local function addLine(line, stops, vehicles)
	local lineStops = {}
	for i, s in ipairs(stops) do
		lineStops[i] = { stationGroup = s[1] + 1000, station = 0, terminal = 0, stopConfig = { load = { s[2], s[3] == true } } }
	end
	setComponent(line, "LINE", { stops = lineStops })
	lineVehicles[line] = vehicles or { line * 10 }
end

local function industryStop()
	addStation(INDUSTRY_STOP)
	catchables[INDUSTRY_STOP] = { INDUSTRY }
end

local function snapshot()
	local s = core.collect(INDUSTRY, deps)
	s.lineCheck = core.collectLines(INDUSTRY)
	return s, core.diagnose(s)
end

-- ---------------------------------------------------------------------------------------------
-- Tests

local tests = {}

function tests.noCapacity()
	reset()
	components[INDUSTRY].PERSON_CAPACITY = nil
	assert(core.diagnose(core.collect(INDUSTRY, deps)).status == "INFO")
end

function tests.boostedIsNoIssue()
	reset()
	productivity.getIndustryProductivity = function() return 2.0 end
	local _, d = snapshot()
	assert(d.status == "OK" and d.title == "No issues" and d.detail == "0 arrivals in 2 years.", d.title .. ": " .. d.detail)
end

function tests.lastArrivalAndWindowFromBaseVisitors()
	reset()
	visitors = { { time = now - 10 }, { time = now - 3 * YEAR }, { time = now - 500 } }
	local s = core.collect(INDUSTRY, deps)
	assert(s.counted == 2, tostring(s.counted))
	assert(s.lastArrival == now - 10)
	assert(s.needed == 10)
	-- an arrival older than the window is no "last arrival"
	visitors = { { time = now - 3 * YEAR } }
	s = core.collect(INDUSTRY, deps)
	assert(s.counted == 0 and s.lastArrival == nil)
end

-- The window text follows workersTimeIntervalMax.
function tests.yearsText()
	assert(core.yearsText(2 * YEAR) == "2 years")
	assert(core.yearsText(YEAR) == "1 year")
	assert(core.yearsText(1.5 * YEAR) == "1.5 years")
	assert(core.yearsText(nil) == "?")
	-- in the game, M.duration formats it like every other duration
	core.duration = function(t) return math.floor(t / YEAR) .. " Years" end
	local ok, text = pcall(core.yearsText, 2 * YEAR)
	core.duration = nil
	assert(ok and text == "2 Years", tostring(text))
end

-- Texts go through the translation hooks: one key per sentence, named placeholders, plural keys by count.
function tests.translationHooks()
	assert(core.fmt("{count} of {needed}", { count = "1", needed = "10" }) == "1 of 10")
	assert(core.fmt("{missing} stays", {}) == "{missing} stays")
	assert(core.fmt("100% {x}", { x = "%1" }) == "100% %1")
	assert(core.trn("a", "b", 1) == "a" and core.trn("a", "b", 0) == "b" and core.trn("a", "b", 2) == "b")
	assert(core.int(497.8) == "498")
	local seen = {}
	local tr, trn = core.tr, core.trn
	core.tr = function(key) seen[#seen + 1] = key return "<" .. key .. ">" end
	core.trn = function(singular, plural, n) seen[#seen + 1] = n == 1 and singular or plural return "<" .. (n == 1 and singular or plural) .. ">" end
	reset()
	addWorker(101)
	addWorker(102)
	local ok, d = pcall(core.diagnose, core.collect(INDUSTRY, deps))
	core.tr, core.trn = tr, trn
	assert(ok, tostring(d))
	assert(d.title == "<No worker arrived yet>", d.title)
	assert(d.detail == "<None of the 2 workers arrived in 2 years.>", d.detail)
	assert(seen[#seen] == "None of the {count} workers arrived in {window}.", tostring(seen[#seen]))
end

-- The arrival log and the current workers are different lists: people who arrived may work elsewhere now.
function tests.arrivalLog()
	reset()
	addWorker(101)                                       -- works here, arrived
	setComponent(102, "SIM_PERSON", { destinations = { HOME, SHOP, 60 } })  -- moved to another workplace
	setComponent(103, "SIM_PERSON", { destinations = { HOME, SHOP, -1 } })  -- no workplace
	visitors = {
		{ time = now - 10, entity = { entity = 102, revision = { num = { 1, 0, 0 } } } },
		{ time = now - 300, entity = { entity = 101, revision = { num = { 1, 0, 0 } } } },
		{ time = now - 200, entity = { entity = 103, revision = { num = { 1, 0, 0 } } } },
		{ time = now - 100, entity = { entity = 104, revision = { num = { 1, 0, 0 } } } },  -- no longer exists
	}
	local s = core.collect(INDUSTRY, deps)
	assert(s.counted == 4)
	local order = {}
	for i, a in ipairs(s.arrivals) do order[i] = a.person end
	assert(table.concat(order, ",") == "102,104,103,101", table.concat(order, ","))
	assert(s.arrivals[2].gone and not s.arrivals[1].gone)
	assert(s.arrivalByPerson[103] == s.arrivals[3])
	assert(s.nextExpiry == now - 300 + 2 * YEAR)
	setComponent(HOME, "TOWN_BUILDING", { town = 30 })
	local info = core.personInfo(101, INDUSTRY, now)
	assert(info.home == HOME and info.town == 30)
end

function tests.noStopNearIndustry()
	reset()
	addStation(MAIN_STATION)
	addLine(300, { { MAIN_STATION, true } })
	local s, d = snapshot()
	assert(#s.lineCheck.industryStations == 0)
	assert(d.title == "No stop within walking distance", d.title)
end

function tests.cargoLinesAreIgnored()
	reset()
	industryStop()
	addLine(300, { { INDUSTRY_STOP, false }, { MAIN_STATION, false } })
	addStation(MAIN_STATION)
	local s, d = snapshot()
	assert(#s.lineCheck.lines == 0)
	assert(d.title == "No passenger line stops near the industry", d.title)
end

-- The case from the game: passengers on at the industries, off at the passenger stations.
-- Walking to the entrance: the industry's construction 900 has the entrance node 950 with road piece 960 attached.
-- reaches = { station -> distance } for stations whose walking area contains that road piece.
local function withEntrance(ownStation, reaches)
	setComponent(900, "CONSTRUCTION", { frozenNodes = { 950 }, frozenEdges = { 960 } })
	api.engine.system.streetConnectorSystem = {
		getConstructionEntityForIndustry = function(entity) return entity == INDUSTRY and 900 or -1 end,
		getConstructionEntityForStation = function(station) return station == ownStation and 900 or -1 end,
	}
	api.engine.system.streetSystem = {
		getNodeSegments = function(node) return node == 950 and { 960 } or {} end,
	}
	local edges = {}
	for station, distance in pairs(reaches or {}) do
		edges[station] = { { { entity = 999 }, 1 }, { { entity = 960 }, distance } }
	end
	api.engine.system.catchmentAreaSystem.getStation2edgesMap = function() return edges end
end

local function withoutEntrance()
	api.engine.system.streetConnectorSystem = nil
	api.engine.system.streetSystem = nil
	api.engine.system.catchmentAreaSystem.getStation2edgesMap = nil
end

-- Every industry has its own station; without a line there it isn't a stop worth naming, only a hint.
function tests.onlyOwnStation()
	reset()
	industryStop()
	withEntrance(INDUSTRY_STOP)
	local s, d = snapshot()
	withoutEntrance()
	assert(s.lineCheck.own[INDUSTRY_STOP] and s.lineCheck.walkDistance[INDUSTRY_STOP] == 0 and #s.lineCheck.stops == 0)
	assert(d.title == "No stop within walking distance" and d.detail == "No station reaches the entrance on foot.", d.title .. ": " .. d.detail)
end

-- A passenger line at the own station makes it a stop, named by its role.
function tests.servedOwnStationIsAStop()
	reset()
	industryStop()
	addStation(TOWN_CENTER)
	addHome(500, 20, TOWN_CENTER)
	addLine(300, { { TOWN_CENTER, true }, { INDUSTRY_STOP, true } })
	withEntrance(INDUSTRY_STOP)
	local s = snapshot()
	withoutEntrance()
	assert(s.lineCheck.stops[1] == INDUSTRY_STOP)
	assert(core.stopNames(s.lineCheck)[1] == "the industry's station")
end

-- A stop built next to the industry is named with its walking distance; the own station is left out.
function tests.ownStationNotCountedAsStop()
	reset()
	industryStop()
	addStation(MAIN_STATION)
	catchables[MAIN_STATION] = { INDUSTRY }
	setComponent(MAIN_STATION, "NAME", { name = "Fürth Station North" })
	withEntrance(INDUSTRY_STOP, { [MAIN_STATION] = 119.6 })
	local s, d = snapshot()
	withoutEntrance()
	assert(d.title == "No passenger line stops near the industry", d.title)
	assert(d.detail == "No passenger line stops at Fürth Station North (120 m).", d.detail)
end

-- A station whose circle covers the industry, but whose walking area doesn't reach the entrance, doesn't count.
function tests.coveredButTooFarToWalk()
	reset()
	industryStop()
	setComponent(INDUSTRY_STOP, "NAME", { name = "Fürth Station North" })
	addLine(300, { { INDUSTRY_STOP, true }, { MAIN_STATION, true } })
	addStation(MAIN_STATION)
	addHome(500, 20, MAIN_STATION)
	withEntrance(nil, {})
	local s, d = snapshot()
	withoutEntrance()
	assert(#s.lineCheck.industryStations == 0 and s.lineCheck.coveredOnly[1] == INDUSTRY_STOP)
	assert(d.title == "Stops nearby, but out of walking reach" and d.detail:find("walking area of Fürth Station North"), d.title .. ": " .. d.detail)
end

-- The industry's own station is walkable but has no passenger line; another station covers the industry but is too
-- far to walk: the walk is the problem, not the missing line at the own station.
function tests.tooFarToWalkBesidesOwnStation()
	reset()
	industryStop()
	addStation(MAIN_STATION)
	catchables[MAIN_STATION] = { INDUSTRY }
	setComponent(MAIN_STATION, "NAME", { name = "Fürth Station North" })
	addStation(TOWN_CENTER)
	addHome(500, 20, TOWN_CENTER)
	addLine(300, { { TOWN_CENTER, true }, { MAIN_STATION, true } })
	withEntrance(INDUSTRY_STOP, {})
	local s, d = snapshot()
	withoutEntrance()
	assert(s.lineCheck.own[INDUSTRY_STOP] and s.lineCheck.coveredOnly[1] == MAIN_STATION)
	assert(d.title == "Stops nearby, but out of walking reach" and d.detail:find("walking area of Fürth Station North"), d.title)
end

-- A player's stop within walking reach without a passenger line, and another station that only covers the industry:
-- the missing line is the problem, not the walk.
function tests.stopWithoutLineBesidesCoveredOnly()
	reset()
	industryStop()
	addStation(MAIN_STATION)
	catchables[MAIN_STATION] = { INDUSTRY }
	setComponent(MAIN_STATION, "NAME", { name = "Fürth Station North" })
	addStation(TOWN_CENTER)
	catchables[TOWN_CENTER] = { INDUSTRY }
	withEntrance(INDUSTRY_STOP, { [MAIN_STATION] = 80 })
	local s, d = snapshot()
	withoutEntrance()
	assert(s.lineCheck.coveredOnly[1] == TOWN_CENTER and s.lineCheck.stops[1] == MAIN_STATION)
	assert(d.title == "No passenger line stops near the industry", d.title)
	assert(d.detail == "No passenger line stops at Fürth Station North (80 m).", d.detail)
end

-- When the walking area reaches the entrance, the station counts, with the walking distance.
function tests.walkReachesEntrance()
	reset()
	industryStop()
	addLine(300, { { INDUSTRY_STOP, true }, { MAIN_STATION, true } })
	addStation(MAIN_STATION)
	addHome(500, 20, MAIN_STATION)
	withEntrance(nil, { [INDUSTRY_STOP] = 497.8 })
	local s = snapshot()
	withoutEntrance()
	assert(#s.lineCheck.industryStations == 1 and #s.lineCheck.coveredOnly == 0)
	assert(s.lineCheck.walkDistance[INDUSTRY_STOP] == 497.8)
	assert(#s.lineCheck.lines == 1 and s.lineCheck.lines[1].residents[0] == 20)
end

function tests.passengerLoadingOffNearHomes()
	reset()
	addStation(TOWN_CENTER)
	industryStop()
	addHome(500, 80, TOWN_CENTER)
	addLine(300, { { TOWN_CENTER, false }, { INDUSTRY_STOP, true } })
	local s, d = snapshot()
	local line = s.lineCheck.lines[1]
	assert(line.residents[0] == 0)
	assert(line.problems[1]:find("passenger loading off, 80 residents nearby"), line.problems[1])
	assert(d.title == "No line brings residents here", d.title)
end

function tests.industryTerminalNoUnload()
	reset()
	addStation(TOWN_CENTER)
	addStation(INDUSTRY_STOP, { passengersLoad = false, passengersUnload = false })
	catchables[INDUSTRY_STOP] = { INDUSTRY }
	addHome(500, 80, TOWN_CENTER)
	addLine(300, { { TOWN_CENTER, true }, { INDUSTRY_STOP, true } })
	local line = core.collectLines(INDUSTRY).lines[1]
	assert(line.residents[0] == 80)
	assert(line.industryStopOk == false)
	assert(line.problems[1]:find("passengers can't get off"), line.problems[1])
end

function tests.noVehicles()
	reset()
	addStation(TOWN_CENTER)
	industryStop()
	addHome(500, 80, TOWN_CENTER)
	addLine(300, { { TOWN_CENTER, true }, { INDUSTRY_STOP, true } }, {})
	local line = core.collectLines(INDUSTRY).lines[1]
	assert(line.problems[1] == "no vehicles", line.problems[1])
end

function tests.residentsByTransfers()
	reset()
	addStation(MAIN_STATION)
	addStation(TOWN_CENTER)
	addStation(SUBURB)
	addStation(VILLAGE)
	industryStop()
	addHome(500, 80, MAIN_STATION) -- direct
	addHome(501, 40, SUBURB)       -- one transfer at the main station
	addHome(502, 10, VILLAGE)      -- two transfers: line 302 to the suburb, line 301 to the town center, walk
	addHome(503, 5, MAIN_STATION)  -- direct, also reachable via feeders: counted once
	walkable[MAIN_STATION] = { [TOWN_CENTER] = 150 }
	addLine(300, { { MAIN_STATION, true }, { INDUSTRY_STOP, true } })
	addLine(301, { { SUBURB, true }, { TOWN_CENTER, true } })   -- reaches line 300 by walking town center -> main station
	addLine(302, { { VILLAGE, true }, { SUBURB, true } })       -- reaches line 301 at the suburb
	local line = core.collectLines(INDUSTRY).lines[1]
	assert(line.line == 300)
	assert(line.residents[0] == 85, tostring(line.residents[0]))
	assert(line.residents[1] == 40, tostring(line.residents[1]))
	assert(line.residents[2] == 10, tostring(line.residents[2]))
	assert(#line.problems == 0, line.problems[1])
end

-- A line that only meets line 300 at the industry's stop is no feeder: nobody transfers there to go to work.
function tests.noFeedersAtIndustryStop()
	reset()
	addStation(MAIN_STATION)
	addStation(SUBURB)
	industryStop()
	addHome(500, 80, MAIN_STATION)
	addHome(501, 40, SUBURB)
	addLine(300, { { MAIN_STATION, true }, { INDUSTRY_STOP, true } })
	addLine(301, { { SUBURB, true }, { INDUSTRY_STOP, true } })
	local check = core.collectLines(INDUSTRY)
	assert(check.lines[1].line == 300 and check.lines[2].line == 301)
	assert(check.lines[1].residents[0] == 80 and check.lines[1].residents[1] == 0, tostring(check.lines[1].residents[1]))
	assert(check.lines[2].residents[0] == 40 and check.lines[2].residents[1] == 0, tostring(check.lines[2].residents[1]))
end

function tests.connectedButNobodyChose()
	reset()
	addStation(MAIN_STATION)
	industryStop()
	addHome(500, 80, MAIN_STATION)
	addLine(300, { { MAIN_STATION, true }, { INDUSTRY_STOP, true } })
	local _, d = snapshot()
	assert(d.title == "Connected, but nobody chose it", d.title)
end

function tests.locationsAddUp()
	reset()
	setComponent(900, "TRANSPORT_VEHICLE", { line = 301 })
	addWorker(101, { target = INDUSTRY, components = { SIM_ENTITY_AT_BUILDING = {} } })
	addWorker(102, { target = INDUSTRY, components = { SIM_ENTITY_AT_TERMINAL = { arrivalTime = now - 500, line = 300 } } })
	addWorker(103, { target = INDUSTRY, components = { SIM_PERSON_AT_VEHICLE = { vehicle = 900 } } })
	addWorker(104, { target = INDUSTRY })
	addWorker(105, { target = HOME, components = { SIM_ENTITY_AT_BUILDING = {} } })
	addWorker(106, { target = SHOP, components = { SIM_ENTITY_AT_BUILDING = {} } })
	addWorker(107, { target = HOME, components = { SIM_ENTITY_AT_TERMINAL = { arrivalTime = now - 9000, line = 300 } } })
	addWorker(108, { target = 999 })
	local s = core.collect(INDUSTRY, deps)
	local sum = s.summary
	assert(sum.WORK.AT == 1 and sum.HOME.AT == 1 and sum.SHOP.AT == 1)
	assert(sum.WORK.WAITING == 1 and sum.WORK.RIDING == 1 and sum.WORK.WALKING == 1)
	assert(sum.HOME.WAITING == 1 and sum.OTHER.WALKING == 1)
	local total = 0
	for __, counts in pairs(sum) do
		for __, n in pairs(counts) do total = total + n end
	end
	assert(total == s.assigned, string.format("%d ~= %d", total, s.assigned))
	-- riding person knows its line through the vehicle
	assert(core.personInfo(103, INDUSTRY, now).line == 301)
	-- longest waits first, also for trips that don't go to work
	assert(s.workers[1] == 107 and s.workers[2] == 102, tostring(s.workers[1]))
	assert(s.lineWaits[300].waiting == 2 and s.lineWaits[300].toWork == 1 and s.lineWaits[300].longest == 9000)
	assert(s.longestWaitToWork.time == 500 and s.longestWaitToWork.line == 300)
end

-- Workers heading to or at work go into toWork, all others into elsewhere.
function tests.workersSplitByPurpose()
	reset()
	addWorker(101, { target = INDUSTRY, components = { SIM_ENTITY_AT_TERMINAL = { arrivalTime = now - 500, line = 300 } } })
	addWorker(102, { target = INDUSTRY, components = { SIM_ENTITY_AT_BUILDING = {} } })
	addWorker(103)                                                -- walking home
	addWorker(104, { target = SHOP, components = { SIM_ENTITY_AT_BUILDING = {} } })
	local s = core.collect(INDUSTRY, deps)
	table.sort(s.toWork)
	table.sort(s.elsewhere)
	assert(table.concat(s.toWork, ",") == "101,102", table.concat(s.toWork, ","))
	assert(table.concat(s.elsewhere, ",") == "103,104", table.concat(s.elsewhere, ","))
	assert(#s.workers == 4)
end

function tests.workersStuckAtStops()
	reset()
	addWorker(101, { target = INDUSTRY, components = { SIM_ENTITY_AT_TERMINAL = { arrivalTime = now - 500, line = 300 } } })
	addWorker(102)
	local d = core.diagnose(core.collect(INDUSTRY, deps), {
		duration = function(t) return t .. " ticks" end,
		lineName = function(l) return "Bus " .. l end,
	})
	-- the title is what the game counts, the waiting workers are the cause
	assert(d.title == "No worker arrived yet" and d.tab == "WORKERS", d.title)
	assert(d.detail:find("None of the 2 workers") and d.detail:find("1 waiting at a stop for 500 ticks%."), d.detail)
end

-- With workers assigned, a problem of a line that can't bring workers is named as the cause, before waiting workers;
-- the problems of a usable line are not.
function tests.lineProblemIsCauseWhenWorkersAssigned()
	reset()
	addStation(TOWN_CENTER)
	addStation(MAIN_STATION)
	industryStop()
	addHome(500, 80, TOWN_CENTER)
	addHome(501, 30, MAIN_STATION)
	addLine(300, { { TOWN_CENTER, false }, { MAIN_STATION, true }, { INDUSTRY_STOP, true } }) -- usable, one problem
	addLine(301, { { TOWN_CENTER, true }, { INDUSTRY_STOP, true } }, {})                      -- no vehicles
	addWorker(101, { target = INDUSTRY, components = { SIM_ENTITY_AT_TERMINAL = { arrivalTime = now - 500, line = 300 } } })
	visitors = { { time = now - 10 } }
	local s = core.collect(INDUSTRY, deps)
	s.lineCheck = core.collectLines(INDUSTRY)
	local d = core.diagnose(s, { lineName = function(l) return "Bus " .. l end })
	assert(d.title == "Not enough workers" and d.tab == "LINES", d.title .. " " .. tostring(d.tab))
	assert(d.detail:find("1 of 10") and d.detail:find("Cause: Bus 301: no vehicles%.$"), d.detail)
end

-- Problems of usable lines alone are no cause: the waiting workers are named instead.
function tests.usableLineProblemsAreNoCause()
	reset()
	addStation(TOWN_CENTER)
	addStation(MAIN_STATION)
	industryStop()
	addHome(500, 80, TOWN_CENTER)
	addHome(501, 30, MAIN_STATION)
	addLine(300, { { TOWN_CENTER, false }, { MAIN_STATION, true }, { INDUSTRY_STOP, true } })
	addWorker(101, { target = INDUSTRY, components = { SIM_ENTITY_AT_TERMINAL = { arrivalTime = now - 500, line = 300 } } })
	visitors = { { time = now - 10 } }
	local s = core.collect(INDUSTRY, deps)
	s.lineCheck = core.collectLines(INDUSTRY)
	assert(#s.lineCheck.lines[1].problems == 1)
	assert(core.lineCause(s.lineCheck, tostring) == nil)
	local d = core.diagnose(s, { duration = function(t) return t .. " ticks" end })
	assert(d.tab == "WORKERS" and d.detail:find("1 waiting at a stop for 500 ticks%."), d.detail)
end

-- A worker waiting at a terminal without a known line still counts as waiting, and the diagnosis doesn't crash.
function tests.waitingWithoutLine()
	reset()
	addWorker(101, { target = INDUSTRY, components = { SIM_ENTITY_AT_TERMINAL = { arrivalTime = now - 700 } } })
	local s = core.collect(INDUSTRY, deps)
	assert(s.summary.WORK.WAITING == 1 and s.longestWaitToWork.time == 700 and s.longestWaitToWork.line == nil)
	assert(next(s.lineWaits) == nil)
	local d = core.diagnose(s, { duration = function(t) return t .. " ticks" end })
	assert(d.tab == "WORKERS" and d.detail:find("The only worker didn't arrive in 2 years%. 1 waiting at a stop for 700 ticks%."), d.detail)
	-- a snapshot without longestWaitToWork names the count only
	s.longestWaitToWork = nil
	d = core.diagnose(s)
	assert(d.detail:find("1 waiting at a stop%.$"), d.detail)
end

function tests.noArrivalYet()
	reset()
	addWorker(101)
	assert(core.diagnose(core.collect(INDUSTRY, deps)).title == "No worker arrived yet")
end

function tests.notEnoughWorkers()
	reset()
	addWorker(101)
	visitors = { { time = now - 10 } }
	local d = core.diagnose(core.collect(INDUSTRY, deps))
	assert(d.title == "Not enough workers" and d.detail:find("1 of 10 needed arrived in 2 years, the last 10 ago"), d.detail)
end

function tests.nearbyLines()
	reset()
	addStation(MAIN_STATION)
	addStation(TOWN_CENTER)
	addStation(SUBURB)
	industryStop()
	walkable[INDUSTRY_STOP] = { [TOWN_CENTER] = 300, [SUBURB] = 120 }
	addLine(300, { { MAIN_STATION, true }, { INDUSTRY_STOP, true } })   -- serves the industry
	addLine(301, { { INDUSTRY_STOP, false, true }, { MAIN_STATION, false } }) -- cargo at the industry stop
	addLine(302, { { TOWN_CENTER, true }, { MAIN_STATION, true } })           -- 300 m walk, passengers
	addLine(303, { { SUBURB, true, true }, { TOWN_CENTER, true } })           -- 120 m walk (closer than via town center), both
	local check = core.collectLines(INDUSTRY)
	assert(#check.lines == 1 and check.lines[1].line == 300)
	local nearby = check.nearby
	assert(#nearby == 3, tostring(#nearby))
	assert(nearby[1].line == 301 and nearby[1].reason == "CARGO" and nearby[1].station == INDUSTRY_STOP)
	assert(nearby[2].line == 303 and nearby[2].reason == "WALK" and nearby[2].distance == 120 and nearby[2].station == SUBURB)
	assert(nearby[3].line == 302 and nearby[3].distance == 300)
end

function tests.severity()
	reset()
	local _, d = snapshot()
	assert(d.severity == "error", d.severity)
	addWorker(101)
	visitors = { { time = now - 10 } }
	assert(core.diagnose(core.collect(INDUSTRY, deps)).severity == "warning")
	productivity.getIndustryProductivity = function() return 2.0 end
	assert(core.diagnose(core.collect(INDUSTRY, deps)).severity == "success")
end

-- Every diagnosis names the details tab that explains it.
function tests.diagnosisTabs()
	local TABS = { ARRIVALS = true, WORKERS = true, LINES = true }
	local cases = {
		{ hasCapacity = false },
		{ hasCapacity = true, boosted = true },
		{ hasCapacity = true, assigned = 0 },
		{ hasCapacity = true, assigned = 0, lineCheck = { industryStations = {}, lines = {}, nearby = {} } },
		{ hasCapacity = true, assigned = 2, counted = 0, capacity = 20, summary = { WORK = { WAITING = 0 } } },
		{ hasCapacity = true, assigned = 2, counted = 1, needed = 10, capacity = 20, summary = { WORK = { WAITING = 0 } } },
		{ hasCapacity = true, assigned = 2, counted = 0, capacity = 20, summary = { WORK = { WAITING = 1 } }, longestWaitToWork = { time = 5, line = 3 } },
	}
	for i, s in ipairs(cases) do
		local d = core.diagnose(s)
		assert(TABS[d.tab], "case " .. i .. ": " .. tostring(d.tab) .. " for " .. d.title)
	end
	assert(core.diagnose(cases[7]).tab == "WORKERS")
	assert(core.diagnose(cases[4]).tab == "LINES")
	-- card look: caution only when the player tried and it doesn't work yet
	local NOTICES = { caution = true, neutral = true, ok = true }
	for i, s in ipairs(cases) do
		assert(NOTICES[core.diagnose(s).notice], "case " .. i .. ": notice " .. tostring(core.diagnose(s).notice))
	end
	assert(core.diagnose(cases[2]).notice == "ok")
	assert(core.diagnose(cases[4]).notice == "neutral") -- no stop: may be a choice
	assert(core.diagnose(cases[7]).notice == "caution") -- workers stuck
end

function tests.brokenApiDegrades()
	reset()
	api.engine.system.simPersonSystem.getSimPersonsForDestination = function() error("boom") end
	local s = core.collect(INDUSTRY, deps)
	api.engine.system.simPersonSystem.getSimPersonsForDestination = function(entity) return destinations[entity] or {} end
	assert(s.assigned == 0)
end

local failed = 0
local names = {}
for name in pairs(tests) do names[#names + 1] = name end
table.sort(names)
for __, name in ipairs(names) do
	local ok, err = pcall(tests[name])
	print((ok and "ok   " or "FAIL ") .. name .. (ok and "" or ": " .. tostring(err)))
	if not ok then failed = failed + 1 end
end
print(string.format("%d tests, %d failed", #names, failed))
os.exit(failed == 0 and 0 or 1)
