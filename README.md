# Worker Diagnostics (Transport Fever 3 mod)

Shows why workers don't reach an industry. A notice in the industry window names the issue;
clicking it opens a window with the arrival log, the current workers and the passenger lines.
Read-only: it sends no commands and changes no game logic.

Get it on [mod.io](https://mod.io/g/transportfever3/m/worker-diagnostics).

> Disclaimer: AI helped develop this mod. It's 2026, and my everyday life doesn't leave room for hours of reading
> documentation.

## How the base game boosts industries
- When a person arrives at the industry and its last trip was by **lines**, the game adds it to the industry's
  **arrival log**. A person is listed once; a new arrival replaces the old entry.
- Entries expire after **2 game years**; the log keeps at most 20.
- The boost is on while the log has `capacity * 0.5` entries. Every base industry has capacity 20, so it needs 10.
- The log doesn't care who works there now. Residents choose their destinations again and again
  (`SimPerson.lastDestinationUpdate`, `baseConfig.simPersonDestinationRecomputationProbability = 1.0`), so the
  arrival log and the current workers (`getSimPersonsForDestination`) are two different lists.
- Industries forbid `WALK` and `DRIVE` for workers (`industryutil.lua`): only arrivals by public transport count,
  residents living next door don't.

## How a stop reaches an industry
- **Covering** (blue highlight when a station is selected): the industry lies, at least partly, in the station's
  catchment circle. `catchmentAreaSystem.getStationCatchables(station, false)` lists these. Covering alone brings
  no workers.
- **Walking reach** (the walk highlight): the station's walking area, `getStation2edgesMap`, reaches the road piece
  at the industry's entrance. The entrance is the construction's frozen node; `streetSystem.getNodeSegments` lists
  the road pieces attached to it. Only then do residents choose the industry as workplace. The walking area
  follows roads and paths and grows with the station range.
- Every industry has its **own road station**. It is inside the industry and always counts as walkable, but it is
  only a stop if a passenger line uses it, so the mod only names it then.
- The game only switches passengers on by default when you add a passenger station to a line
  (`addPassengerByDefault` in `line_util.tl`). Stops at industry or cargo stations may have it off.

## What the mod shows
**Notice in the industry window:** under the section title "Worker Diagnostics", like the game's own notifications in entity windows (no card frame): one sentence with
a coloured icon tile; click it to open the details window. It is tinted yellow only when the player evidently tried
to bring workers and it doesn't work yet (a line that can't bring residents, workers assigned but too few arrive).
Not serving an industry may be a choice, so those states stay neutral (blue tile, no tint); an active boost shows a
green tile.

**Details window:** the status above four tabs. The tab labels carry the key numbers, and the window opens on the
tab that explains the status.

| Tab | Content |
|---|---|
| Arrivals (5/10) | the game's booster bar in its own card (Boosters), last arrival, when the next entry expires, the arrival log (name, home town, arrived, time left) |
| Going to work (10) | who has the industry as workplace now, in two tables: going to or at work, and elsewhere. Home town (locate button jumps to the home), Destination / Status (icon with tooltip, what they are doing), line, time at the stop (orange from 60 days, red from 120). The tab shows how many are going to or at work |
| Lines (4, 1 with problems) | stops within walking reach with distance, stations that only cover the industry; passenger lines as a table (line, vehicles as images like the game's vehicle lists, residents near the stops with the breakdown by transfers in the tooltip, waiting workers, number of problems), up to 3 problems grouped by line below, the rest in a tooltip; other lines nearby with the same column widths (line, vehicles, cargo icons like the game's line overview, where) |
| Help | what the game doesn't tell: observations from play first (marked as such), then the boost, workers changing jobs, walking reach, the industry's own station, passenger loading |

All tables can be sorted by clicking a header.

## Status
Checked in this order; the first that applies is shown.

| Title | Colour | Tab | When |
|---|---|---|---|
| No workplaces | blue | Arrivals | the industry has no worker capacity |
| No issues | green | Arrivals | the boost is active |
| Stops nearby, but out of walking reach | red | Lines | stations cover the industry, but no walking area reaches its entrance (no road or path, or the way is too long) |
| No stop within walking distance | red | Lines | no station covers the industry, or only its own station without a line |
| No passenger line stops near the industry | red | Lines | stops within walking reach, but no line loading passengers uses them |
| No line brings residents here | red | Lines | passenger lines stop there, but none has vehicles, lets passengers off here and loads passengers near homes |
| Connected, but nobody chose it | orange | Lines | a usable line exists, but nobody has the industry as workplace yet (often temporary) |
| No resident works here | red | Lines | fallback when the line check couldn't run |
| No worker arrived yet | orange | by cause | workers are assigned, none arrived in 2 years |
| Not enough workers | orange | by cause | workers are assigned, fewer than needed arrived in 2 years |

The rows from "Stops nearby" to "No resident works here" are checked only while nobody has the industry as workplace.
For the last two, the explanation names the likely cause: first a line problem (Lines tab), then workers waiting
at stops (Going to work tab), else a general note (Arrivals tab). Only lines that can't bring workers count as a
cause; problems of a usable line are listed under Lines but not named.

## Known limits
- "Out of walking reach" can't tell "no road" from "too long": both look the same in the walking area. A path
  search (`api.engine.util.pathfinding.findPathNodeToNode`) returned nothing for station terminal nodes, not even
  between two nodes of the same station.
- Transfers at the industry's own stop don't count: a line that only meets another one there adds no residents.
- Residents near a line's other stops are counted by catchment circle, not by walking reach, so the resident
  numbers in the Lines tab can be too high. They only show the size of the pool.
- Whether a bus can reach the industry's own station isn't checked; the Lines tab mentions it as a possible stop
  whenever no passenger line serves the industry.

## Publish
See the wiki: [Publishing](https://wiki.transportfever3.com/doku.php?id=modding:general:publishing),
[Mod Definition](https://wiki.transportfever3.com/doku.php?id=modding:general:moddefinition).
1. Raise `revision` in `mod.json` (not for the first upload).
2. `./stage.sh <TF3 local folder>` runs the tests (`lua tests/test_core.lua`) and copies `mod.json`, `strings.json`,
   `_metadata/` and `content/` to `<TF3 local folder>/staging_area/<modId>`. The local folder is
   `<Steam>/userdata/<steam id>/3493540/local`.
3. In the game: Mod Hub > My Mods > Worker Diagnostics; set tags, images, visibility and a changelog, then Upload.
4. After the first upload, run `./stage.sh <TF3 local folder>` once more: it copies `_metadata/mod.io_fileid.txt` back into the
   repository. Commit it, so later uploads update the same mod.io entry.

Name and summary come from `_metadata/modinfo.json`, the description from `_metadata/description.html` (English,
then German, then the changelog; mod.io has no per-language descriptions yet). Both overwrite edits made on mod.io.
Add a changelog entry to `description.html` with every new revision. Images are
`_metadata/0.png` (thumbnail), `1.png`, … at 1920×1080.

## Credits and licence
Code under the [MIT licence](LICENSE). The images contain screenshots and UI elements of Transport Fever 3
(© Urban Games), used as permitted by the game's modding guidelines.
