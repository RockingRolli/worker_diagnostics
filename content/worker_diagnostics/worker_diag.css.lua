local color_util = require "::/gui/main/color_util.tl"
local ssu = require "::/gui/main/stylesheetutil.lua"

-- Worker Diagnostics. Windows are matched by class (Window!...), like the game's centered dialogs
-- (popover_react_util.css.lua); an id selector with dots doesn't match.
-- Wrapping texts need a fixed width, like the game's info hint (content_card.css.lua).
-- builtin.Component is a recipe, so its selector is R::Component (or class only); "Component!..." never matches.
local WINDOW_TEXT_WIDTH = 800
local NOTICE_TEXT_WIDTH = 350 -- as the game's notifications in entity windows
local TAB_HEIGHT = 580

-- The data of a game resource, or nil if it is missing (e.g. moved in a game update): the rules that need it are
-- skipped, so the rest of the style still loads.
local function gres(path)
	local ok, value = pcall(function() return api.gui.genericRep.get(api.gui.genericRep.find(path)).data end)
	if not ok then
		pcall(function() print("[WorkerDiag] style resource missing: " .. path) end)
		return nil
	end
	return value
end

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	local colorDefault = gres("::/gui/main/default_colors.gres")
	local colorNotification = gres("::/game_mechanics/notifications/gui/notification_colors.gres")
	local transparency = gres("::/gui/main/transparency.gres")
	local colorGameplay = gres("::/gui/entity_window/gameplay_colors.gres")

	-- details window: centered, wide enough for the tables without shortening texts
	a("Window!worker-diag-window", {
		size = { 900, -1 },
		anchorPoint = { 0.5, 0.5 },
		gravity = { 0.5, 0.5 },
	})
	a("BoxLayout!worker-diag-window-body", {
		outerSpacing = { 8, 8 },
		innerSpacing = { 0, 10 },
	})
	-- fixed size: the scroll bar stays inside the window, and the window keeps its height when switching tabs
	a("ScrollArea!worker-diag-scroll", {
		size = { 870, TAB_HEIGHT },
		minSize = { 870, TAB_HEIGHT },
		maxSize = { 870, TAB_HEIGHT },
	})
	a("BoxLayout!worker-diag-body", {
		outerSpacing = { 0, 8 },
		innerSpacing = { 0, 8 },
	})
	a("!worker-diag-card-body > BoxLayout", {
		innerSpacing = { 0, 6 },
	})
	-- problems below the passenger lines table: line name, then its problems indented
	a("TextView!worker-diag-problem-line", {
		margin = { 6, 0, 0, 0 },
	})
	a("R::Component!worker-diag-problem-row", {
		padding = { 0, 0, 0, 16 },
	})
	a("TextView!worker-diag-problem-more", {
		margin = { 4, 0, 0, 16 },
	})
	a("TextView!worker-diag-note", {
		textAutoWrap = true,
		size = { WINDOW_TEXT_WIDTH, -1 },
		maxSize = { WINDOW_TEXT_WIDTH, -1 },
	})
	a("TextView!worker-diag-help", {
		textAutoWrap = true,
		size = { WINDOW_TEXT_WIDTH, -1 },
		maxSize = { WINDOW_TEXT_WIDTH, -1 },
	})
	a("TextView!worker-diag-problem", {
		textAutoWrap = true,
		maxSize = { WINDOW_TEXT_WIDTH - 30, -1 },
	})

	-- the game's workplaces booster row stretches its bar to the row height; keep it as slim as in the entity window
	a("!booster-widget!worker-diag-booster R::ProgressDisplay", {
		size = { -1, 20 },
		maxSize = { -1, 20 },
		gravity = { -1, 0.5 },
		padding = { 0, 12, 0, 12 }, -- same gap on both sides (the game only pads the right side by 8)
	})
	a("!booster-widget!worker-diag-booster R::ProgressDisplay ProgressBar", {
		maxSize = { -1, 20 },
	})
	-- bar colours as in the entity window: blue, green with an active boost. The game only sets blue for
	-- R::EntityWindowContent (entity_window.css.lua); elsewhere the bar falls back to a pale grey.
	if colorDefault then
		a("R::Component!worker-diag-booster R::WorkplacesBoosterProgressBar R::ProgressDisplay ProgressBar", {
			color = colorDefault.AccentLight,
			backgroundColor1 = colorDefault.Invisible,
		})
	end
	if colorGameplay then
		a("R::Component!worker-diag-booster !boosted R::WorkplacesBoosterProgressBar R::ProgressDisplay ProgressBar", {
			color = colorGameplay.IndustryBoost,
		})
	end

	a("ImageView!worker-diag-icon", {
		size = { 20, 20 },
		margin = { 0, 6, 0, 0 },
	})
	a("R::Component!worker-diag-icon", {
		size = { 20, 20 },
		margin = { 0, 6, 0, 0 },
	})

	-- status box: no background, only the icon and the title carry the severity colour
	local severityColors = colorDefault and {
		error = colorDefault.Error,
		warning = colorDefault.Warning,
		success = colorDefault.Positive,
		info = colorDefault.Info,
	} or {}
	for severity, color in pairs(severityColors) do
		a("R::Component!worker-diag-status!worker-diag-sev-" .. severity .. " ImageView!worker-diag-status-icon", {
			color = color,
		})
	end
	a("R::Component!worker-diag-status", {
		padding = { 8, 10, 8, 10 },
	})
	a("BoxLayout!worker-diag-status-row", {
		innerSpacing = { 10, 0 },
	})
	a("BoxLayout!worker-diag-status-body", {
		innerSpacing = { 0, 0 },
	})
	a("ImageView!worker-diag-status-icon", {
		size = { 24, 24 },
		gravity = { -1, 0.5 }, -- centred next to title and explanation
	})
	a("R::Component!worker-diag-in-window TextView!worker-diag-status-text", {
		textAutoWrap = true,
		size = { WINDOW_TEXT_WIDTH, -1 },
		maxSize = { WINDOW_TEXT_WIDTH, -1 },
	})

	-- card in the industry window: a notice built like the game's notifications in entity windows
	-- (notifications.css.lua, R::NotificationWidgetEntry; those rules are bound to that recipe, so they are repeated here)
	-- section title like ContentCard's (content_card.css.lua binds these rules to R::ContentCard)
	a("TextView!worker-diag-title", {
		padding = { 0, 0, 0, 0 },
		margin = { 4, 4, 4, 4 },
	})
	a("ImageView!worker-diag-title-decor", {
		margin = { 0, 3, 0, 1 },
		gravity = { -1.0, 0.5 },
	})
	a("BoxLayout!worker-diag-card", {
		outerSpacing = { 0, 0 },
		innerSpacing = { 0, 0 },
	})
	a("R::Component!worker-diag-notice", {
		backgroundImage1 = {
			fileName = "::/gui/entity_window/design/card_surface.tga",
			horizontal = { 0, 6, 26, 32 },
			vertical = { 0, 6, 26, 32 },
		},
		backgroundColor1 = colorDefault and colorDefault.Invisible, -- nil leaves the key out
		gravity = { -1, 0 }, -- full width, like the cards around it
	})
	if colorNotification and transparency then
		a("R::Component!worker-diag-notice!worker-diag-notice-caution", {
			backgroundColor1 = color_util.withTransparencyRaw(colorNotification.Caution, transparency.High),
		})
	end
	a("R::Component!worker-diag-notice Button", {
		gravity = { -1, 0 },
		padding = { 8, 10, 8, 10 },
	})
	a("R::Component!worker-diag-notice Button::Layout > BoxLayout", {
		innerSpacing = { 10, 0 },
	})
	a("R::Component!worker-diag-notice TextView!worker-diag-notice-text", {
		size = { NOTICE_TEXT_WIDTH, -1 },
		maxSize = { NOTICE_TEXT_WIDTH, -1 },
		textAutoWrap = true,
		margin = { 2, 0, 2, 0 },
		gravity = { -1, 0.5 },
	})
	a("R::Component!worker-diag-notice R::NotificationSimpleIcon ImageView!icon-size", {
		size = { 32, 32 },
	})

	return result
end
