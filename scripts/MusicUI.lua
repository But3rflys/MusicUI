local JSON = require('assets.JSON')
local has_chronos, chronos = pcall(require, 'chronos')

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local exp, cos, fmt = math.exp, math.cos, string.format

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function saturate(v) return clamp(v, 0, 1) end
local function lerp(a, b, t) return a + (b - a) * t end

local function approach(current, target, speed, dt)
    return current + (target - current) * (1 - exp(-speed * dt))
end

local function pin(prev, target)
    if prev and abs(target - prev) < 0.55 then return prev end
    return floor(target + 0.5)
end

local function spring(value, vel, target, stiffness, damping, dt)
    vel = vel + ((target - value) * stiffness - vel * damping) * dt
    return value + vel * dt, vel
end

local function ease_out(t)
    t = saturate(t)
    local i = 1 - t
    return 1 - i * i * i
end

local function rgba(r, g, b, a)
    return Color(floor(clamp(r, 0, 255)), floor(clamp(g, 0, 255)),
                 floor(clamp(b, 0, 255)), floor(clamp(a or 255, 0, 255)))
end

local function shade(c, alpha)
    return Color(c.r, c.g, c.b, floor(clamp((c.a or 255) * alpha, 0, 255)))
end

local function fmt_time(seconds)
    if not seconds or seconds < 0 or seconds ~= seconds then seconds = 0 end
    local total = floor(seconds + 0.5)
    return fmt("%d:%02d", floor(total / 60), total % 60)
end

local has_os = type(os) == "table" and type(os.date) == "function"
local clock_cache = { at = -1, hh = "--", mm = "--" }

local function clock_hm(t)
    if has_os and t - clock_cache.at >= 0.25 then
        clock_cache.at = t
        local ok, stamp = pcall(os.date, "*t")
        if ok and type(stamp) == "table" then
            local hh, mm = tonumber(stamp.hour), tonumber(stamp.min)
            if hh and mm then
                clock_cache.hh, clock_cache.mm = fmt("%02d", hh), fmt("%02d", mm)
            end
        end
    end
    return clock_cache.hh, clock_cache.mm
end

local u8 = utf8

local function uclen(s)
    if not s or s == "" then return 0 end
    if u8 then
        local n = u8.len(s)
        if n then return n end
    end
    return #s
end

local function usub(s, count)
    if not s or s == "" or count <= 0 then return "" end
    if u8 then
        local n = u8.len(s)
        if n then
            if count >= n then return s end
            local byte = u8.offset(s, floor(count) + 1)
            return byte and s:sub(1, byte - 1) or s
        end
    end
    return s:sub(1, floor(count))
end

local soft_clock = 0

local function wall_clock()
    if has_chronos and chronos and chronos.nanotime then
        local ok, t = pcall(chronos.nanotime)
        if ok and type(t) == "number" then return t end
    end
    return nil
end

local function now()
    return wall_clock() or soft_clock
end

local SERVER = "127.0.0.1:8770"

local config_dirty = true
local function mark_config() config_dirty = true end

local script_tab = Menu.Create("Scripts", "Scripts", "MusicUI")
script_tab:Icon("\u{f001}")

local tab = script_tab:Create("Main")
tab:Icon("\u{f013}")

local gPlayer = tab:Create("Плеер", Enum.GroupSide.Left)
local gExtra  = tab:Create("Модули", Enum.GroupSide.Right)

local function gear(widget, fallback, name)
    local ok, attached = pcall(widget.Gear, widget, name)
    return (ok and attached) or fallback
end

local M = {}

M.enable = gPlayer:Switch("Включить", true, "\u{f144}")

local view = gear(M.enable, gPlayer, "Внешний вид")
M.style     = view:Combo("Стиль", { "Чёрный", "Размытие" }, 0)
M.scale     = view:Slider("Масштаб", 70, 150, 100, "%d%%")
M.pos_x     = view:Slider("Позиция X", 0, 100, 50, "%d%%")
M.pos_y     = view:Slider("Отступ сверху", 0, 400, 12, "%d px")
M.autohide  = view:Switch("Сворачивать автоматически", true)
M.clock     = view:Switch("Часы, когда нет музыки", true)
M.hide_idle = view:Switch("Скрывать, когда нет трека", true)
M.dash      = view:Switch("Показывать вне игры", true)
M.bounce    = view:Switch("Пружинка раскрытия", true)

M.autohide:ToolTip("Раскрытый плеер сам вернётся в капсулу через ~6 секунд")
M.clock:ToolTip("Без трека/связи с сервером капсула показывает текущее время")
M.dash:ToolTip("Остров будет виден и в главном меню")

M.accent_auto = gPlayer:Switch("Акцент из обложки", true, "\u{f1fc}")
M.accent_auto:ToolTip("Интерфейс красится в доминантный цвет обложки")

local ok_accent, accent = pcall(M.accent_auto.ColorPicker, M.accent_auto,
                                "Свой цвет", Color(122, 190, 255, 255))
M.accent = (ok_accent and accent)
        or gPlayer:ColorPicker("Свой цвет", Color(122, 190, 255, 255))

M.lyrics = gExtra:Switch("Лирика", true, "\u{f036}")
M.lyrics:ToolTip("Не у каждой песни есть текст, а иногда может и не с той песней совпасть")

local lyr = gear(M.lyrics, gExtra, "Лирика")
M.lyr_where = lyr:Combo("Где показывать", { "Отдельная капсула", "Внутри острова" }, 0)
M.lyr_words = lyr:Switch("Подсветка по словам", true)
M.lyr_width = lyr:Slider("Ширина капсулы", 320, 900, 520, "%d px")

M.eq = gExtra:Switch("Эквалайзер", true, "\u{f1de}")

local eqx = gear(M.eq, gExtra, "Эквалайзер")
M.bars     = eqx:Slider("Полосы", 3, 12, 5)
M.sens     = eqx:Slider("Чувствительность", 0.5, 2.0, 1.0, "%.2f×")
M.eq_music = eqx:Switch("Только музыка", true)
M.eq_music:ToolTip("Музыкой считаются плееры и браузеры")

M.eq:SetCallback(mark_config)
M.bars:SetCallback(mark_config)
M.eq_music:SetCallback(mark_config)

M.accent_auto:SetCallback(function(w) M.accent:Visible(not w:Get()) end, true)
M.lyr_where:SetCallback(function(w) M.lyr_width:Visible(w:Get() == 0) end, true)
M.clock:SetCallback(function(w) M.hide_idle:Visible(not w:Get()) end, true)

local C = {}

local function read_menu()
    C.enable        = M.enable:Get()
    C.blur          = M.style:Get() == 1
    C.scale         = M.scale:Get() / 100
    C.pos_x         = M.pos_x:Get()
    C.pos_y         = M.pos_y:Get()
    C.accent_auto   = M.accent_auto:Get()
    C.accent        = M.accent:Get()
    C.autohide      = M.autohide:Get()
    C.hide_idle     = M.hide_idle:Get()
    C.clock         = M.clock:Get()
    C.dashboard     = M.dash:Get()
    C.bounce        = M.bounce:Get()

    C.lyrics      = M.lyrics:Get()
    C.lyr_inside  = M.lyr_where:Get() == 1
    C.lyr_words   = M.lyr_words:Get()
    C.lyr_width   = M.lyr_width:Get()

    C.eq       = M.eq:Get()
    C.bars     = M.bars:Get()
    C.sens     = M.sens:Get()
    C.eq_music = M.eq_music:Get()
end

local FL = Enum.DrawFlags.RoundCornersAll

local fonts = { ready = false }

local function pick_font(weight)
    local flags = Enum.FontCreate.FONTFLAG_ANTIALIAS
    for _, name in ipairs({ "Segoe UI", "Tahoma", "Verdana", "Arial" }) do
        local ok, handle = pcall(Render.LoadFont, name, flags, weight)
        if ok and handle then return handle end
    end
    return nil
end

local function load_fonts()
    if fonts.ready then return end
    fonts.bold    = pick_font(Enum.FontWeight.BOLD)
    fonts.semi    = pick_font(Enum.FontWeight.SEMIBOLD)
    fonts.regular = pick_font(Enum.FontWeight.MEDIUM)
    fonts.ready   = fonts.regular ~= nil
end

local function text(font, size, str, x, y, color)
    if not font or not str or str == "" then return end
    Render.Text(font, size, str, Vec2(x, y), color)
end

local tw_cache, tw_count = {}, 0

local function text_w(font, size, str)
    if not font or not str or str == "" then return 0 end

    local key = fmt("%s|%.2f|%s", tostring(font), size, str)
    local cached = tw_cache[key]
    if cached then return cached end

    local w
    local ok, measured = pcall(Render.TextSize, font, size, str)
    if ok and measured then w = measured.x else w = uclen(str) * size * 0.5 end

    if tw_count >= 800 then tw_cache, tw_count = {}, 0 end
    tw_cache[key], tw_count = w, tw_count + 1
    return w
end

local function text_h(font, size, str)
    if not font then return size * 1.25 end
    local ok, measured = pcall(Render.TextSize, font, size, (str ~= "" and str) or "Ag")
    if ok and measured and measured.y and measured.y > 0 then return measured.y end
    return size * 1.25
end

local function icon_play(cx, cy, s, color)
    Render.FilledTriangle({
        Vec2(cx - s * 0.40, cy - s * 0.58),
        Vec2(cx - s * 0.40, cy + s * 0.58),
        Vec2(cx + s * 0.60, cy),
    }, color)
end

local function icon_pause(cx, cy, s, color)
    local w, h, gap = s * 0.22, s * 0.56, s * 0.18
    Render.FilledRect(Vec2(cx - gap - w, cy - h), Vec2(cx - gap, cy + h), color, w * 0.5, FL)
    Render.FilledRect(Vec2(cx + gap, cy - h), Vec2(cx + gap + w, cy + h), color, w * 0.5, FL)
end

local function icon_next(cx, cy, s, color)
    Render.FilledTriangle({
        Vec2(cx - s * 0.58, cy - s * 0.54),
        Vec2(cx - s * 0.58, cy + s * 0.54),
        Vec2(cx + s * 0.20, cy),
    }, color)
    Render.FilledRect(Vec2(cx + s * 0.28, cy - s * 0.54),
                      Vec2(cx + s * 0.50, cy + s * 0.54), color, s * 0.10, FL)
end

local function icon_prev(cx, cy, s, color)
    Render.FilledTriangle({
        Vec2(cx + s * 0.58, cy - s * 0.54),
        Vec2(cx + s * 0.58, cy + s * 0.54),
        Vec2(cx - s * 0.20, cy),
    }, color)
    Render.FilledRect(Vec2(cx - s * 0.50, cy - s * 0.54),
                      Vec2(cx - s * 0.28, cy + s * 0.54), color, s * 0.10, FL)
end

local function icon_volume(cx, cy, s, color, waves)
    Render.FilledRect(Vec2(cx - s * 0.52, cy - s * 0.14),
                      Vec2(cx - s * 0.26, cy + s * 0.14), color, s * 0.06, FL)
    Render.FilledTriangle({
        Vec2(cx - s * 0.28, cy - s * 0.14),
        Vec2(cx - s * 0.04, cy - s * 0.40),
        Vec2(cx - s * 0.04, cy + s * 0.40),
    }, color)
    Render.FilledTriangle({
        Vec2(cx - s * 0.28, cy - s * 0.14),
        Vec2(cx - s * 0.28, cy + s * 0.14),
        Vec2(cx - s * 0.04, cy + s * 0.40),
    }, color)

    if waves <= 0 then return end
    Render.PushClip(Vec2(cx + s * 0.12, cy - s * 0.40),
                    Vec2(cx + s * 0.62, cy + s * 0.40), true)
    for i = 1, waves do
        Render.Circle(Vec2(cx - s * 0.04, cy), s * (0.06 + 0.16 * i), color, max(1, s * 0.10))
    end
    Render.PopClip()
end

local ICON_BOX   = 64
local ICON_SCALE = 1.28

local VOL_BODY = '<path d="M6 25 L18 25 L30 12 L30 52 L18 39 L6 39 Z"/>'
local VOL_WAVE = {
    '<path d="M38.2 24.6 A11 11 0 0 1 38.2 39.4" fill="none" stroke="#ffffff"'
        .. ' stroke-width="5" stroke-linecap="round"/>',
    '<path d="M44.1 19.3 A19 19 0 0 1 44.1 44.7" fill="none" stroke="#ffffff"'
        .. ' stroke-width="5" stroke-linecap="round"/>',
    '<path d="M50.1 13.9 A27 27 0 0 1 50.1 50.1" fill="none" stroke="#ffffff"'
        .. ' stroke-width="5" stroke-linecap="round"/>',
}

local ICON_ART = {
    play  = '<path d="M15 9 L53 32 L15 55 Z" stroke="#ffffff" stroke-width="9"'
         .. ' stroke-linejoin="round"/>',
    pause = '<rect x="12" y="4" width="14" height="56" rx="7"/>'
         .. '<rect x="38" y="4" width="14" height="56" rx="7"/>',
    prev  = '<path d="M57 8 L20 32 L57 56 Z" stroke="#ffffff" stroke-width="8"'
         .. ' stroke-linejoin="round"/>'
         .. '<rect x="3" y="4" width="8" height="56" rx="4"/>',
    next  = '<path d="M7 8 L44 32 L7 56 Z" stroke="#ffffff" stroke-width="8"'
         .. ' stroke-linejoin="round"/>'
         .. '<rect x="53" y="4" width="8" height="56" rx="4"/>',
    vol0  = VOL_BODY,
    vol1  = VOL_BODY .. VOL_WAVE[1],
    vol2  = VOL_BODY .. VOL_WAVE[1] .. VOL_WAVE[2],
    vol3  = VOL_BODY .. VOL_WAVE[1] .. VOL_WAVE[2] .. VOL_WAVE[3],
}

local icon_tex   = {}
local icon_fails = {}

local function icon_handle(name, size)
    local art = ICON_ART[name]
    if not art then return nil end

    local px  = clamp(floor(size * 2 + 0.5), 32, 256)
    local key = name .. "@" .. px

    local handle = icon_tex[key]
    if handle then return handle end
    if (icon_fails[key] or 0) >= 3 then return nil end

    local svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 '
        .. ICON_BOX .. ' ' .. ICON_BOX .. '" width="' .. ICON_BOX
        .. '" height="' .. ICON_BOX .. '"><g fill="#ffffff">' .. art .. '</g></svg>'

    local ok, h = pcall(Render.LoadSvgString, svg, Vec2(px, px), "dynamic_island_" .. key)
    if ok and type(h) == "number" and h ~= 0 then
        icon_tex[key] = h
        return h
    end
    icon_fails[key] = (icon_fails[key] or 0) + 1
    return nil
end

local function vol_vector(waves)
    return function(cx, cy, s, color) icon_volume(cx, cy, s, color, waves) end
end

local VECTOR_ICON = {
    play = icon_play, pause = icon_pause, prev = icon_prev, next = icon_next,
    vol0 = vol_vector(0), vol1 = vol_vector(1), vol2 = vol_vector(2), vol3 = vol_vector(3),
}

local function draw_glyph(name, cx, cy, s, color)
    local size   = s * ICON_SCALE
    local handle = icon_handle(name, size)
    if handle then
        local ok = pcall(Render.Image, handle,
                         Vec2(cx - size * 0.5, cy - size * 0.5),
                         Vec2(size, size), color)
        if ok then return end
    end
    local vector = VECTOR_ICON[name]
    if vector then vector(cx, cy, s, color) end
end

local net = {
    base   = "http://" .. SERVER,
    online = false,
    fails  = 0,
    note   = "подключение…",
    slots  = {},
}

local function slot(name)
    local s = net.slots[name]
    if not s then
        s = { inflight = false, sent = 0, next_at = 0 }
        net.slots[name] = s
    end
    return s
end

local function net_fail(note)
    net.fails = net.fails + 1
    net.online = false
    net.note = note or "нет связи"
end

local function backoff()
    return min(5.0, 0.35 * (2 ^ min(net.fails, 5)))
end

local function fetch(name, path, interval, handler)
    local s = slot(name)
    local t = now()

    if s.inflight then
        if t - s.sent < 5.0 then return end
        s.inflight = false
        net_fail("нет ответа")
    end
    if t < s.next_at then return end

    s.inflight = true
    s.sent     = t
    s.next_at  = t + interval

    local ok, started = pcall(HTTP.Request, "GET", net.base .. path, {}, function(res)
        s.inflight = false
        local body = res and res.response
        local code = (res and res.code) or 0
        if type(body) ~= "string" or body == "" or (code ~= 0 and code ~= 200) then
            net_fail((res and res.error_message) or "сервер не отвечает")
            s.next_at = now() + backoff()
            return
        end
        local parsed, data = pcall(JSON.decode, JSON, body)
        if not parsed or type(data) ~= "table" then
            net_fail("битый ответ")
            s.next_at = now() + backoff()
            return
        end
        net.fails  = 0
        net.online = true
        net.note   = nil
        handler(data)
    end)

    if not ok or started == false then
        s.inflight = false
        s.next_at  = t + 2.0
        net_fail("HTTP недоступен")
    end
end

local function control(action, value, quiet)
    local path = "/control?action=" .. action
    if value then path = path .. "&value=" .. fmt("%.3f", value) end
    pcall(HTTP.Request, "GET", net.base .. path, {}, function() end)
    if quiet then return end
    slot("tick").next_at  = 0
    slot("state").next_at = 0
end

local function push_config()
    local s = slot("config")
    if s.inflight or now() < s.next_at then return end
    config_dirty = false
    fetch("config", fmt("/config?bands=%d&music_only=%d&equalizer=%d",
                        C.bars or 4, C.eq_music and 1 or 0, C.eq and 1 or 0),
          0.25, function() end)
end

local S = {
    v_tick  = -1,
    v_state = -2,
    ok = false,
    playing = false,
    pos = 0,
    pos_target = 0,
    duration = 0,
    track_id = nil,
    title = "",
    artist = "",
    cover = nil,
    bands = {},
    band_source = "idle",
    source_app = nil,
    backend = "?",
    line_index = -1,
    lyrics = { state = "idle", mode = nil, count = 0, window = {} },
}

local prev = { title = "", artist = "", line = nil }

local anim = {
    alpha = 0,
    open = 0, open_vel = 0, open_target = 0, fill = 0,
    swap = 1,
    lyr = 1,
    pulse = 0,
    lyr_h = 0,
    clock = 1,
    pill_w = 0,
    pill_from = 0,
    bars = {},
    hover = { prev = 0, pause = 0, next = 0, body = 0, vol = 0 },
    ar = 122, ag = 190, ab = 255,
}

local last_touch = 0
local last_click = 0

local vol = {
    app = nil,
    level = nil,
    open = 0,
    drag = false,
    pin = 0,
    touch = 0,
    sent = -1,
    sent_at = 0,
    cx = 0, cy = 0, ir = 0, is = 0,
    tx = 0, tw = 0, ty = 0,
}

local seek = {
    drag = false,
    at = 0,
    hold = 0,
}

local function vol_send(level, force)
    local t = now()
    if force then
        if abs(level - vol.sent) < 0.001 then return end
    elseif abs(level - vol.sent) < 0.004 or t - vol.sent_at < 0.05 then
        return
    end
    vol.sent, vol.sent_at = level, t
    control("volume", level, true)
end

local function vol_icon_name(level)
    if level <= 0.005 then return "vol0" end
    if level < 0.34 then return "vol1" end
    if level < 0.68 then return "vol2" end
    return "vol3"
end

local function sync_position(value)
    local p = tonumber(value)
    if not p then return end
    if seek.drag then return end
    if now() < seek.hold then
        if abs(p - seek.at) > 2.5 then return end
        seek.hold = 0
    end
    S.pos_target = p
    if abs(p - S.pos) > 1.0 then S.pos = p end
end

local function advance_position(dt)
    if S.playing then
        S.pos = S.pos + dt
        S.pos_target = S.pos_target + dt
    end
    S.pos = S.pos + (S.pos_target - S.pos) * min(1, 3 * dt)
    if S.duration > 0 then S.pos = clamp(S.pos, 0, S.duration) end
end

local function line_at(index)
    local window = S.lyrics.window
    for i = 1, #window do
        local line = window[i]
        if line and line.i == index then return line end
    end
    return nil
end

local last_line_at = 0

local function set_line(index)
    index = tonumber(index) or -1
    if index == S.line_index then return end
    if index == S.line_index - 1 and now() - last_line_at < 1.0 then return end
    prev.line = line_at(S.line_index)
    S.line_index = index
    anim.lyr = 0
    anim.pill_from = anim.pill_w
    last_line_at = now()
end

local ART_SIZE = 256

local cover = { track_id = nil, handle = nil, inflight = false, next_try = 0, sent = 0 }

local function cover_reset()
    cover.track_id = nil
    cover.handle   = nil
    cover.inflight = false
    cover.next_try = 0
    cover.sent     = 0
end

local function cover_build_svg(b64)
    local mime = (b64:sub(1, 4) == "/9j/") and "image/jpeg" or "image/png"
    return '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="'
        .. ART_SIZE .. '" height="' .. ART_SIZE
        .. '"><image width="' .. ART_SIZE .. '" height="' .. ART_SIZE
        .. '" preserveAspectRatio="xMidYMid slice" xlink:href="data:' .. mime .. ';base64,'
        .. b64 .. '"/></svg>'
end

local function cover_update()
    if cover.track_id ~= S.track_id then
        cover_reset()
        cover.track_id = S.track_id
    end
    if cover.handle or type(S.cover) ~= "table" then return end
    if cover.inflight then
        if now() - cover.sent < 5.0 then return end
        cover.inflight = false
    end
    if now() < cover.next_try then return end

    cover.inflight = true
    cover.sent     = now()
    cover.next_try = now() + 1.0

    local want_track = S.track_id
    local ok = pcall(HTTP.Request, "GET", net.base .. "/art", {}, function(res)
        cover.inflight = false
        if cover.track_id ~= want_track then return end

        local body = res and res.response
        if type(body) ~= "string" or body == "" then return end

        local svg = cover_build_svg(body)
        local sok, handle = pcall(Render.LoadSvgString, svg, Vec2(ART_SIZE, ART_SIZE),
                                  "dynamic_island_cover_" .. tostring(want_track))
        if sok and type(handle) == "number" and handle ~= 0 then
            cover.handle = handle
        end
    end)
    if not ok then
        cover.inflight = false
    end
end

local auto_r, auto_g, auto_b

local function accent_target()
    if C.accent_auto then
        if type(S.cover) == "table" and type(S.cover.colors) == "table" then
            local first = S.cover.colors[1]
            if type(first) == "table" then
                local r, g, b = tonumber(first[1]), tonumber(first[2]), tonumber(first[3])
                if r and g and b then
                    local peak = max(r, max(g, b))
                    if peak > 0 and peak < 140 then
                        local k = 140 / peak
                        r, g, b = r * k, g * k, b * k
                    end
                    auto_r, auto_g, auto_b = r, g, b
                    return r, g, b
                end
            end
        end
        if auto_r then return auto_r, auto_g, auto_b end
    end
    local pick = C.accent
    if pick then return pick.r, pick.g, pick.b end
    return 122, 190, 255
end

local function accent_color(alpha)
    return rgba(anim.ar, anim.ag, anim.ab, 255 * (alpha or 1))
end

local function apply_tick(d)
    S.ok      = d.ok == true
    S.playing = d.playing == true
    sync_position(d.pos)
    if type(d.bands) == "table" then S.bands = d.bands end
    if type(d.band_source) == "string" then S.band_source = d.band_source end
    if type(d.v) == "number" then S.v_tick = d.v end
    set_line(d.line)
end

local function apply_state(d)
    if type(d.v) == "number" then
        S.v_state = d.v
        S.v_tick  = max(S.v_tick, d.v)
    end
    S.ok      = d.ok == true
    S.playing = d.playing == true
    sync_position(d.pos)

    if type(d.bands) == "table" then S.bands = d.bands end
    if type(d.band_source) == "string" then S.band_source = d.band_source end
    S.source_app = d.source_app
    S.backend    = d.player_backend or "?"

    local track = (type(d.track) == "table") and d.track or nil
    local id    = track and track.track_id or nil

    if id ~= S.track_id then
        prev.title, prev.artist = S.title, S.artist
        prev.line   = nil
        anim.swap   = 0
        anim.pulse  = 1
        S.track_id  = id
        S.line_index = -1
        cover_reset()
    end

    if track then
        S.title    = tostring(track.title or "")
        S.artist   = tostring(track.artist or "")
        S.duration = tonumber(track.duration) or 0
    else
        S.title, S.artist, S.duration = "", "", 0
    end

    S.cover = (type(d.cover) == "table") and d.cover or nil

    local mix = (type(d.volume) == "table") and d.volume or nil
    vol.app = mix and mix.app or nil
    if not vol.drag and now() - vol.sent_at > 0.6 then
        local level = mix and tonumber(mix.level) or nil
        vol.level = level and saturate(level) or nil
    end

    local ly = (type(d.lyrics) == "table") and d.lyrics or nil
    if ly then
        S.lyrics.state  = tostring(ly.state or "idle")
        S.lyrics.mode   = ly.mode
        S.lyrics.count  = tonumber(ly.count) or 0
        S.lyrics.window = (type(ly.window) == "table") and ly.window or {}
        set_line(ly.line)
    else
        S.lyrics.state, S.lyrics.count, S.lyrics.window = "idle", 0, {}
    end
end

local function lyrics_window_stale()
    if S.lyrics.count <= 0 or S.line_index < 0 then return false end
    local window = S.lyrics.window
    if #window == 0 then return true end
    local first, last = window[1].i, window[#window].i
    if not first or not last then return true end
    return S.line_index >= last - 1 or S.line_index < first
end

local function net_pump()
    fetch("tick", "/tick", 1 / 15, apply_tick)

    if S.v_tick ~= S.v_state or lyrics_window_stale() then
        local s, t = slot("state"), now()
        if s.next_at > t + 1.0 then s.next_at = t + 0.05 end
        fetch("state", "/state", 1.0, apply_state)
    else
        fetch("state", "/state", 5.0, apply_state)
    end

    if config_dirty then push_config() end
end

local function update_bars(dt)
    local n     = C.bars or 4
    local src   = S.bands or {}
    local quiet = (not C.eq) or (S.ok and not S.playing)
    for i = 1, n do
        local target = quiet and 0 or saturate((tonumber(src[i]) or 0) * (C.sens or 1))
        local current = anim.bars[i] or 0
        anim.bars[i] = approach(current, target, target > current and 34 or 9, dt)
    end
    for i = n + 1, 12 do anim.bars[i] = nil end
end

local SPRING_SOFT_K, SPRING_SOFT_C = 320, 24
local SPRING_FIRM_K, SPRING_FIRM_C = 380, 40

local function update_anim(dt)
    local sk, sc = SPRING_FIRM_K, SPRING_FIRM_C
    if C.bounce then sk, sc = SPRING_SOFT_K, SPRING_SOFT_C end

    anim.open, anim.open_vel = spring(anim.open, anim.open_vel, anim.open_target,
                                     sk, sc, min(dt, 0.05))
    anim.open  = clamp(anim.open, -0.12, 1.14)

    local reach = saturate(anim.open)
    anim.fill = (anim.open_target > 0.5) and max(anim.fill, reach) or min(anim.fill, reach)
    anim.swap  = min(1, anim.swap + dt / 0.34)
    anim.lyr   = min(1, anim.lyr + dt / 0.28)
    anim.pulse = max(0, anim.pulse - dt / 0.45)

    local r, g, b = accent_target()
    anim.ar = approach(anim.ar, r, 6, dt)
    anim.ag = approach(anim.ag, g, 6, dt)
    anim.ab = approach(anim.ab, b, 6, dt)

    update_bars(dt)

    if anim.fill < 0.37 then
        vol.open = approach(vol.open, 0, 16, dt)
        vol.drag = false
        vol.pin  = 0
    end
end

local BASE = {
    compact_w = 220, compact_h = 38,  compact_r = 19,
    open_w    = 380, open_h    = 164, open_r    = 28,
    lyr_extra = 34,
    clock_w   = 96,
}

local geom = { x = 0, y = 0, w = 0, h = 0, r = 0, k = 1, sy = 1, open_h = BASE.open_h }

local function current_line()
    local line = line_at(S.line_index)
    if not line then return nil end
    if S.lyrics.count > 0 and S.line_index >= S.lyrics.count - 1 then
        local fin = tonumber(line["end"])
        if fin and S.pos > fin + 1.0 then return nil end
    end
    return line
end

local function has_lyrics_line()
    if not C.lyrics or S.lyrics.count <= 0 then return false end
    return current_line() ~= nil
end

local function clock_mode()
    if not C.clock then return false end
    return (not net.online) or S.title == ""
end

local function layout(dt)
    local screen = Render.ScreenSize()
    local sy = screen.y / 1080
    local k  = sy * (C.scale or 1)

    local idle   = clock_mode()
    local goal   = idle and 1 or 0
    local want_w = idle and BASE.clock_w or BASE.compact_w
    anim.clock     = approach(anim.clock, goal, 9, dt)
    anim.compact_w = approach(anim.compact_w or want_w, want_w, 11, dt)
    if abs(anim.clock - goal) < 0.004 then anim.clock = goal end
    if abs(anim.compact_w - want_w) < 0.25 then anim.compact_w = want_w end

    local extra = (C.lyr_inside and has_lyrics_line()) and BASE.lyr_extra or 0
    anim.lyr_h = approach(anim.lyr_h, extra, 9, dt)

    local open_h = BASE.open_h + anim.lyr_h
    local w = lerp(anim.compact_w, BASE.open_w, anim.fill) * k
    local h = lerp(BASE.compact_h, open_h, anim.fill) * k
    local bw = lerp(anim.compact_w, BASE.open_w, anim.open) * k
    local bh = lerp(BASE.compact_h, open_h, anim.open) * k

    local cx = screen.x * (C.pos_x or 50) / 100
    geom.x = pin(geom.x, clamp(cx - w * 0.5, 4, max(4, screen.x - w - 4)))
    geom.y = pin(geom.y, clamp((C.pos_y or 12) * sy + 2, 2, max(2, screen.y - h - 4)))
    geom.w = pin(geom.w, w)
    geom.h = pin(geom.h, h)
    geom.r = lerp(BASE.compact_r, BASE.open_r, anim.fill) * k
    geom.bx = clamp(cx - bw * 0.5, 4, max(4, screen.x - bw - 4))
    geom.by = geom.y
    geom.bw, geom.bh = bw, bh
    geom.br = lerp(BASE.compact_r, BASE.open_r, saturate(anim.open)) * k
    geom.cov_p = lerp(4, 16, anim.fill) * k
    geom.cov_s = lerp(BASE.compact_h - 8, 72, anim.fill) * k
    geom.cov_r = lerp(10, 16, anim.fill) * k
    geom.k, geom.sy = k, sy
    geom.screen = screen
    geom.open_h = open_h
end

local function draw_panel(x, y, w, h, r, alpha)
    local a, b = Vec2(x, y), Vec2(x + w, y + h)

    if C.blur then
        local blurred = pcall(Render.Blur, a, b, 1, alpha, r, FL)
        Render.FilledRect(a, b, rgba(14, 14, 18, (blurred and 150 or 235) * alpha), r, FL)
    else
        Render.FilledRect(a, b, rgba(10, 10, 12, 238 * alpha), r, FL)
    end

    Render.Gradient(a, b,
        rgba(anim.ar, anim.ag, anim.ab, 30 * alpha),
        rgba(anim.ar, anim.ag, anim.ab, 30 * alpha),
        rgba(anim.ar, anim.ag, anim.ab, 0),
        rgba(anim.ar, anim.ag, anim.ab, 0), r, FL)
end

local function draw_cover(x, y, size, rounding, alpha)
    local a, b = Vec2(x, y), Vec2(x + size, y + size)

    if cover.handle then
        local ok = pcall(Render.Image, cover.handle, a, Vec2(size, size),
                         rgba(255, 255, 255, 255 * alpha), rounding, FL)
        if ok then
            Render.OutlineGradient(a, b,
                rgba(255, 255, 255, 40 * alpha), rgba(255, 255, 255, 40 * alpha),
                rgba(255, 255, 255, 12 * alpha), rgba(255, 255, 255, 12 * alpha),
                rounding, FL, 1)
            return
        end
    end

    Render.Gradient(a, b,
        rgba(anim.ar, anim.ag, anim.ab, 215 * alpha),
        rgba(anim.ar * 0.78, anim.ag * 0.78, anim.ab * 0.78, 215 * alpha),
        rgba(anim.ar * 0.42, anim.ag * 0.42, anim.ab * 0.42, 215 * alpha),
        rgba(anim.ar * 0.42, anim.ag * 0.42, anim.ab * 0.42, 215 * alpha),
        rounding, FL)

    local center = Vec2(x + size * 0.5, y + size * 0.5)
    Render.Circle(center, size * 0.30, rgba(255, 255, 255, 46 * alpha), max(1, size * 0.045))
    Render.FilledCircle(center, size * 0.09, rgba(255, 255, 255, 70 * alpha))
end

local function draw_bars(x, y, w, h, alpha)
    local n = C.bars or 4
    if n <= 0 or not C.eq then return end
    local pitch = w / n
    local bw    = max(2, pitch * 0.56)
    local off   = (pitch - bw) * 0.5
    local cy    = y + h * 0.5
    local color = accent_color(alpha * 0.95)
    for i = 1, n do
        local level = saturate(anim.bars[i] or 0)
        local bh    = max(bw, h * level)
        local bx    = x + (i - 1) * pitch + off
        Render.FilledRect(Vec2(bx, cy - bh * 0.5), Vec2(bx + bw, cy + bh * 0.5),
                          color, bw * 0.5, FL)
    end
end

local marq = {}

local MARQ_SPEED = 34
local MARQ_HOLD  = 1.15
local MARQ_EASE  = 0.14
local MARQ_MIN   = 5

local function ramp(t, ease)
    t = saturate(t)
    local e = clamp(ease, 0.02, 0.5)
    local span = 1 - e
    if t < e then return t * t / (2 * e * span) end
    if t > 1 - e then
        local rest = 1 - t
        return 1 - rest * rest / (2 * e * span)
    end
    return (t - e * 0.5) / span
end

local function marquee(id, key, overflow, dt)
    local over = max(overflow, 0)
    local m = marq[id]
    if not m or m.key ~= key then
        m = { key = key, phase = 0, off = 0, over = over, raw = over, calm = 0 }
        marq[id] = m
    end
    if not dt or dt <= 0 then return m.off end

    local step = abs(over - m.raw)
    m.raw  = over
    m.over = approach(m.over, over, 9, dt)
    if abs(m.over - over) < 0.2 then m.over = over end

    local live = over > MARQ_MIN * geom.k and step < 1.6
    m.calm = approach(m.calm, live and 1 or 0, live and 4 or 12, dt)
    if m.calm < 0.02 then m.phase = 0 end

    local goal = 0
    if m.over > 0.5 then
        local travel = m.over / max(1, MARQ_SPEED * geom.k)
        local period = (MARQ_HOLD + travel) * 2
        local ease   = clamp(MARQ_EASE / max(travel, 0.05), 0.03, 0.2)

        m.phase = (m.phase + dt * m.calm / period) % 1

        local t = m.phase * period
        if t < MARQ_HOLD then
            goal = 0
        elseif t < MARQ_HOLD + travel then
            goal = m.over * ramp((t - MARQ_HOLD) / travel, ease)
        elseif t < MARQ_HOLD * 2 + travel then
            goal = m.over
        else
            goal = m.over * (1 - ramp((t - MARQ_HOLD * 2 - travel) / travel, ease))
        end
        goal = min(goal * m.calm, over)
    end

    m.off = approach(m.off, goal, 16, dt)
    if abs(m.off - goal) < 0.12 then m.off = goal end
    return m.off
end

local function marq_slot(prefix, line)
    local i = line and tonumber(line.i) or 0
    return prefix .. "_" .. tostring(i % 3)
end

local EDGE_SLICES = 6

local function paint_faded(x, w, left, right, paint)
    local l = min(left, w * 0.45)
    local r = min(right, w * 0.45)

    if w - l - r > 0.5 then
        paint(x + l, x + w - r, 1)
    end

    for i = 1, EDGE_SLICES do
        local t0, t1 = (i - 1) / EDGE_SLICES, i / EDGE_SLICES
        local k = (t0 + t1) * 0.5
        if l > 0.25 then paint(x + l * t0, x + l * t1, k) end
        if r > 0.25 then paint(x + w - r * t1, x + w - r * t0, k) end
    end
end

local function edge_fades(box_w, off, over)
    local edge = min(16 * geom.k, box_w * 0.35)
    if edge <= 0.5 then return 0, 0 end
    return edge * saturate(off / edge), edge * saturate((over - off) / edge)
end

local function draw_scroll_text(id, font, size, str, x, y, box_w, color, alpha, dt)
    if not str or str == "" then return end
    local width = text_w(font, size, str)
    local over  = width - box_w
    local off   = marquee(id, str, over, dt)
    local top   = y - size * 0.3
    local hgt   = size * 1.8

    local function paint(x0, x1, k)
        if x1 - x0 <= 0.25 then return end
        Render.PushClip(Vec2(x0, top), Vec2(x1, top + hgt), true)
        text(font, size, str, x - off, y, shade(color, k))
        Render.PopClip()
    end

    if over > 0 then
        local l, r = edge_fades(box_w, off, over)
        paint_faded(x, box_w, l, r, paint)
    else
        paint(x, x + box_w, 1)
    end
end

local function line_text(line)
    if not line then return "" end
    local words = line.words
    if type(words) == "table" and #words > 0 then
        local parts = {}
        for i = 1, #words do parts[i] = tostring(words[i][3] or "") end
        return table.concat(parts, " ")
    end
    return tostring(line.text or "")
end

local function revealed_chars(line, pos)
    local words = line and line.words
    if type(words) ~= "table" or #words == 0 then return nil end

    local count = 0
    for i = 1, #words do
        local w = words[i]
        local from, to = tonumber(w[1]) or 0, tonumber(w[2]) or 0
        local len = uclen(tostring(w[3] or ""))
        if pos >= to then
            count = count + len
            if i < #words then count = count + 1 end
        elseif pos <= from then
            return count
        else
            local t = (to > from) and saturate((pos - from) / (to - from)) or 1
            return count + len * t
        end
    end
    return count
end

local function revealed_width(font, size, str, chars)
    local whole = floor(chars)
    local frac  = chars - whole
    local left  = text_w(font, size, usub(str, whole))
    if frac <= 0.001 then return left end
    return lerp(left, text_w(font, size, usub(str, whole + 1)), frac)
end

local function draw_lyrics_line(id, line, x, y, box_w, size, alpha, dt, fade)
    if not line or fade <= 0.01 then return end
    local str = line_text(line)
    if str == "" then return end

    local font  = fonts.semi or fonts.regular
    local width = text_w(font, size, str)
    local over  = width - box_w
    local off   = marquee(id, str, over, dt)
    local top   = y - size * 0.35
    local hgt   = size * 1.9
    local chars  = C.lyr_words and revealed_chars(line, S.pos) or nil
    local reveal = chars and revealed_width(font, size, str, chars) or 0

    local function paint(x0, x1, k)
        if x1 - x0 <= 0.25 then return end
        Render.PushClip(Vec2(x0, top), Vec2(x1, top + hgt), true)
        if chars then
            text(font, size, str, x - off, y, rgba(255, 255, 255, 112 * alpha * fade * k))
            if reveal > 0.5 then
                Render.PushClip(Vec2(x - off, top), Vec2(x - off + reveal, top + hgt), true)
                text(font, size, str, x - off, y, rgba(255, 255, 255, 240 * alpha * fade * k))
                Render.PopClip()
            end
        else
            text(font, size, str, x - off, y, rgba(255, 255, 255, 240 * alpha * fade * k))
        end
        Render.PopClip()
    end

    if over > 0 then
        local l, r = edge_fades(box_w, off, over)
        paint_faded(x, box_w, l, r, paint)
    else
        paint(x, x + box_w, 1)
    end
end

local function line_box(font, size, line, limit)
    return clamp(text_w(font, size, line_text(line)), 20 * geom.k, limit)
end

local function draw_lyrics_pill(alpha, dt)
    local line = current_line()
    if not line then
        anim.pill_w = 0
        anim.pill_from = 0
        return
    end
    if line_text(line) == "" then return end

    local k     = geom.k
    local size  = 14 * k
    local font  = fonts.semi or fonts.regular
    local pad   = 14 * k
    local maxw  = (C.lyr_width or 520) * geom.sy
    local limit = max(20 * k, maxw - pad * 2)

    local t   = ease_out(anim.lyr)
    local box = line_box(font, size, line, limit)

    anim.pill_w = lerp(anim.pill_from, box, t)

    local inner = anim.pill_w
    local w   = inner + pad * 2
    local h   = 30 * k
    local x   = clamp(geom.x + geom.w * 0.5 - w * 0.5, 4, max(4, geom.screen.x - w - 4))
    local y   = geom.y + geom.h + 8 * k
    local ty  = y + (h - size * 1.25) * 0.5

    draw_panel(x, y, w, h, h * 0.5, alpha * (0.4 + 0.6 * t))

    Render.PushClip(Vec2(x, y), Vec2(x + w, y + h), true)
    if prev.line and t < 1 then
        draw_lyrics_line(marq_slot("pill", prev.line), prev.line,
                         x + pad, ty - size * 0.8 * t, inner, size, alpha, 0, 1 - t)
    end
    draw_lyrics_line(marq_slot("pill", line), line,
                     x + pad, ty + size * 0.8 * (1 - t), inner, size, alpha, dt, t)
    Render.PopClip()
end

local hit = { active = false, x = 0, y = 0, w = 0, h = 0, buttons = {},
              progress = nil, volume = nil, vol_icon = nil }

local function hit_reset()
    hit.active   = false
    hit.buttons  = {}
    hit.progress = nil
    hit.volume   = nil
    hit.vol_icon = nil
end

local function cursor()
    local ok, cx, cy = pcall(Input.GetCursorPos)
    if ok and cx and cy then return cx, cy end
    return -10000, -10000
end

local function in_rect(mx, my, x, y, w, h)
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local function draw_track(x1, x2, top, h, level, alpha)
    Render.FilledRect(Vec2(x1, top), Vec2(x2, top + h),
                      rgba(255, 255, 255, 38 * alpha), h * 0.5, FL)
    if level > 0 then
        Render.FilledRect(Vec2(x1, top), Vec2(x1 + (x2 - x1) * level, top + h),
                          accent_color(alpha), h * 0.5, FL)
    end
end

local function vol_update(mx, my, x1, x2, ty, cy, dt)
    local k  = geom.k
    local ir = 20 * k
    local cx = x2 - ir
    local tw = max(40 * k, x2 - x1)

    vol.cx, vol.cy, vol.ir, vol.is = cx, cy, ir, 19 * k
    vol.tx, vol.tw, vol.ty = x1, tw, ty

    local over_icon = in_rect(mx, my, cx - ir, cy - ir, ir * 2, ir * 2)
    local over_all  = in_rect(mx, my, x1 - 6 * k, ty - 9 * k,
                              (cx + ir) - (x1 - 6 * k), (cy + ir) - (ty - 9 * k))

    local want = (vol.drag or now() < vol.pin or over_icon
                  or (vol.open > 0.25 and over_all)) and 1 or 0
    if seek.drag then want = 0 end
    if want > 0 then vol.touch = now() end
    if want == 0 and now() - vol.touch < 0.3 then want = 1 end

    vol.open = approach(vol.open, want, 16, dt)
    anim.hover.vol = approach(anim.hover.vol or 0,
                              (over_icon or vol.drag) and 1 or 0, 14, dt)

    if vol.drag then
        last_touch = now()
        vol.level = saturate((mx - x1) / max(1, tw))
        vol_send(vol.level, false)
    end

    local t = ease_out(vol.open)
    hit.vol_icon = { x = cx - ir, y = cy - ir, w = ir * 2, h = ir * 2 }
    hit.volume   = (t > 0.85) and { x = x1, y = ty - 6 * k, w = tw, h = 17 * k } or nil
    return t
end

local function draw_volume(alpha, t)
    local k     = geom.k
    local level = saturate(vol.level or 0)

    if t > 0.01 then
        local bh  = 5 * k
        local x2  = vol.tx + vol.tw
        local x1  = x2 - vol.tw * t

        draw_track(x1, x2, vol.ty, bh, level, alpha * t)
        Render.FilledCircle(Vec2(x1 + (x2 - x1) * level, vol.ty + bh * 0.5), 5 * k,
                            rgba(255, 255, 255, 238 * alpha * t))
    end

    local hv = anim.hover.vol or 0
    if hv > 0.01 then
        Render.FilledCircle(Vec2(vol.cx, vol.cy), vol.ir * (0.74 + 0.10 * hv),
                            rgba(255, 255, 255, 22 * hv * alpha))
    end

    local name = vol_icon_name(level)
    if t < 0.99 then
        draw_glyph(name, vol.cx, vol.cy, vol.is,
                   rgba(255, 255, 255, (214 + 41 * hv) * alpha * (1 - t)))
    end
    if t > 0.01 then
        draw_glyph(name, vol.cx, vol.cy, vol.is, accent_color(alpha * t))
    end
end

local function draw_clock(alpha)
    local font = fonts.semi or fonts.regular
    local size = 15 * geom.k
    local hh, mm = clock_hm(now())

    local wh, wc, wm = text_w(font, size, hh), text_w(font, size, ":"),
                       text_w(font, size, mm)
    local pill = BASE.compact_h * geom.k
    local tx = floor(geom.x + (geom.w - (wh + wc + wm)) * 0.5 + 0.5)
    local ty = floor(geom.y + (pill - text_h(font, size, "00")) * 0.5 + 0.5)

    local main = rgba(255, 255, 255, 234 * alpha)
    local beat = 0.55 + 0.45 * (0.5 + 0.5 * cos(now() * 6.2832))

    text(font, size, hh, tx, ty, main)
    text(font, size, ":", floor(tx + wh + 0.5), ty,
         rgba(255, 255, 255, 234 * alpha * beat))
    text(font, size, mm, floor(tx + wh + wc + 0.5), ty, main)
end

local function draw_compact(alpha, dt)
    local k, x, y = geom.k, geom.x, geom.y

    local clock_a = saturate((anim.clock - 0.35) / 0.65)
    local music_a = saturate(1 - anim.clock * 1.8)

    if clock_a > 0.01 then draw_clock(alpha * clock_a) end

    alpha = alpha * music_a
    if alpha <= 0.01 then return end

    local pad  = geom.cov_p
    local size = geom.cov_s
    local cw   = anim.compact_w * k

    local eq_w = (C.eq and (C.bars or 0) > 0) and 46 * k or 0
    local eq_h = BASE.compact_h * k * 0.46
    local eq_x = x + cw - 4 * k - eq_w
    if eq_w > 0 then
        draw_bars(eq_x, y + pad + (size - eq_h) * 0.5, eq_w, eq_h, alpha)
    end

    local gap = 10 * k
    local tx  = x + pad + size + gap
    local box = eq_x - gap - tx
    if box <= 8 * k then return end

    local tsize = 12.5 * k
    local title = (S.title ~= "" and S.title)
                  or (net.online and "Нет трека" or "Сервер не отвечает")
    local font  = fonts.semi or fonts.regular
    local ty    = y + pad + (size - text_h(font, tsize, title)) * 0.5

    local t     = ease_out(anim.swap)
    local slide = 10 * k

    if t < 1 and prev.title and prev.title ~= "" then
        draw_scroll_text("c_old", font, tsize, prev.title, tx, ty - slide * t,
                         box, rgba(255, 255, 255, 228 * alpha * (1 - t)), alpha, dt)
    end
    draw_scroll_text("c_new", font, tsize, title, tx, ty + slide * (1 - t),
                     box, rgba(255, 255, 255, 235 * alpha * t), alpha, dt)
end

local function draw_expanded(alpha, dt)
    local k, x, y, w, h = geom.k, geom.x, geom.y, geom.w, geom.h
    local mx, my = cursor()

    local pad   = 16 * k
    local right = x + w - pad
    local tx    = x + 102 * k
    local box   = max(20 * k, right - tx - 52 * k)

    local t     = ease_out(anim.swap)
    local slide = 14 * k
    local title_y, artist_y = y + 22 * k, y + 45 * k

    local title  = (S.title ~= "" and S.title)
                   or (net.online and "Нет трека" or "Сервер не отвечает")
    local artist = (S.artist ~= "" and S.artist)
                   or (S.backend == "mediakeys" and "управление медиаклавишами" or "")

    Render.PushClip(Vec2(tx, y + 8 * k), Vec2(tx + box, y + 62 * k), true)
    if t < 1 then
        draw_scroll_text("t_old", fonts.bold, 16 * k, prev.title, tx, title_y - slide * t,
                         box, rgba(255, 255, 255, 235 * alpha * (1 - t)), alpha, dt)
        draw_scroll_text("a_old", fonts.regular, 13 * k, prev.artist, tx, artist_y - slide * t,
                         box, rgba(255, 255, 255, 150 * alpha * (1 - t)), alpha, dt)
    end
    draw_scroll_text("t_new", fonts.bold, 16 * k, title, tx, title_y + slide * (1 - t),
                     box, rgba(255, 255, 255, 242 * alpha * t), alpha, dt)
    draw_scroll_text("a_new", fonts.regular, 13 * k, artist, tx, artist_y + slide * (1 - t),
                     box, rgba(255, 255, 255, 155 * alpha * t), alpha, dt)
    Render.PopClip()

    draw_bars(right - 42 * k, y + 24 * k, 42 * k, 18 * k, alpha * 0.9)

    if C.lyrics and C.lyr_inside and anim.lyr_h > 1 then
        local size = 13 * k
        local lx, lw = tx, right - tx
        local ly = y + 68 * k
        local lt = ease_out(anim.lyr)
        local cur, nxt = current_line(), line_at(S.line_index + 1)
        Render.PushClip(Vec2(lx, ly - 2 * k), Vec2(lx + lw, ly + anim.lyr_h * k + 2 * k), true)
        if prev.line and lt < 1 then
            draw_lyrics_line(marq_slot("in", prev.line), prev.line, lx, ly - size * 0.9 * lt,
                             lw, size, alpha, dt, 1 - lt)
        end
        draw_lyrics_line(marq_slot("in", cur), cur, lx, ly + size * 0.9 * (1 - lt),
                         lw, size, alpha, dt, lt)
        draw_lyrics_line(marq_slot("in", nxt), nxt, lx, ly + size * 1.55,
                         lw, size, alpha * 0.6, dt, lt)
        Render.PopClip()
    end

    local bar_h  = 5 * k
    local bar_y  = y + h - 74 * k
    local bar_x2 = right
    local bar_x1 = x + pad
    local span   = max(1, bar_x2 - bar_x1)
    local length = S.duration or 0

    if seek.drag then
        if length > 0 then seek.at = saturate((mx - bar_x1) / span) * length end
        last_touch = now()
    end

    local shown = seek.drag and seek.at or S.pos
    local done  = length > 0 and saturate(shown / length) or 0

    draw_track(bar_x1, bar_x2, bar_y, bar_h, done, alpha)

    hit.progress = { x = bar_x1, y = bar_y - 9 * k, w = span, h = bar_h + 18 * k }
    local over_bar = in_rect(mx, my, hit.progress.x, hit.progress.y,
                             hit.progress.w, hit.progress.h)
    if seek.drag or over_bar then
        Render.FilledCircle(Vec2(bar_x1 + span * done, bar_y + bar_h * 0.5),
                            (seek.drag and 6.5 or 5) * k,
                            rgba(255, 255, 255, 238 * alpha))
    end

    local btn_cy = y + h - 27 * k
    local time_y = y + h - 64 * k
    local vol_on = vol.app ~= nil and vol.level ~= nil
    local vol_t  = vol_on and vol_update(mx, my, bar_x1, bar_x2,
                                         y + h - 60 * k, btn_cy, dt) or 0

    local time_a = alpha * (1 - vol_t)
    if time_a > 0.01 then
        local dim = rgba(255, 255, 255, 140 * time_a)
        text(fonts.regular, 11 * k, fmt_time(shown), bar_x1, time_y, dim)
        local remain = "-" .. fmt_time(max(0, length - shown))
        text(fonts.regular, 11 * k, remain,
             bar_x2 - text_w(fonts.regular, 11 * k, remain), time_y, dim)
    end

    if vol_on then draw_volume(alpha, vol_t) end

    local cy      = btn_cy
    local center  = x + w * 0.5
    local spacing = 58 * k
    local radius  = 20 * k
    local buttons = {
        { id = "prev",  cx = center - spacing, size = 13 * k },
        { id = "pause", cx = center,           size = 16 * k },
        { id = "next",  cx = center + spacing, size = 13 * k },
    }

    for i = 1, #buttons do
        local b       = buttons[i]
        local hovered = in_rect(mx, my, b.cx - radius, cy - radius, radius * 2, radius * 2)
        anim.hover[b.id] = approach(anim.hover[b.id] or 0, hovered and 1 or 0, 14, dt)
        local hv = anim.hover[b.id]

        if hv > 0.01 then
            Render.FilledCircle(Vec2(b.cx, cy), radius * (0.74 + 0.10 * hv),
                                rgba(255, 255, 255, 22 * hv * alpha))
        end

        local tint = rgba(255, 255, 255, (214 + 41 * hv) * alpha)
        if b.id == "pause" then
            local want = S.playing and 1 or 0
            anim.play  = approach(anim.play or want, want, 12, dt)
            if anim.play < 0.99 then
                draw_glyph("play", b.cx, cy, b.size, shade(tint, 1 - anim.play))
            end
            if anim.play > 0.01 then
                draw_glyph("pause", b.cx, cy, b.size, shade(tint, anim.play))
            end
        else
            draw_glyph(b.id, b.cx, cy, b.size, tint)
        end

        hit.buttons[#hit.buttons + 1] = {
            id = b.id, x = b.cx - radius, y = cy - radius, w = radius * 2, h = radius * 2,
        }
    end
end

local function draw(dt)
    if anim.alpha <= 0.01 then
        seek.drag = false
        hit_reset()
        return
    end

    local alpha = anim.alpha
    local x, y, w, h = geom.x, geom.y, geom.w, geom.h

    hit.active   = true
    hit.x, hit.y, hit.w, hit.h = x, y, w, h
    hit.buttons  = {}
    hit.progress = nil
    hit.volume   = nil
    hit.vol_icon = nil

    draw_panel(geom.bx, geom.by, geom.bw, geom.bh, geom.br, alpha)

    local compact_a  = saturate(1.06 - anim.fill * 2.8)
    local expanded_a = saturate((anim.fill - 0.36) / 0.44)

    local cover_a = alpha * saturate(max(saturate(1 - anim.clock * 1.8), expanded_a))

    Render.PushClip(Vec2(x, y), Vec2(x + w, y + h), true)
    if cover_a > 0.01 then
        local pulse = 1 + 0.06 * ease_out(anim.pulse)
        local cs    = geom.cov_s
        local grow  = cs * (pulse - 1) * 0.5
        draw_cover(x + geom.cov_p - grow, y + geom.cov_p - grow, cs * pulse, geom.cov_r, cover_a)
    end
    if compact_a  > 0.01 then draw_compact(alpha * compact_a, dt) end
    if expanded_a > 0.01 then draw_expanded(alpha * expanded_a, dt) end
    Render.PopClip()

    if expanded_a < 0.6 then
        hit.buttons  = {}
        hit.progress = nil
        hit.volume   = nil
        hit.vol_icon = nil
    end

    if C.lyrics and not C.lyr_inside then
        local la = alpha * (1 - anim.clock)
        if la > 0.01 then draw_lyrics_pill(la, dt) end
    end
end

local function want_alpha(visible)
    if not visible then return 0 end
    if C.clock then return 1 end
    if not net.online then return 0 end
    if C.hide_idle and not S.ok and S.backend ~= "mediakeys" then return 0 end
    return 1
end

local function update_open(dt)
    if anim.open_target < 0.5 or not C.autohide then return end
    local mx, my = cursor()
    if hit.active and in_rect(mx, my, hit.x - 6, hit.y - 6, hit.w + 12, hit.h + 12) then
        last_touch = now()
    end
    if now() - last_touch > 6.0 then anim.open_target = 0 end
end

local mouse_down = false

local function cursor_in_menu(mx, my)
    local opened = false
    if not pcall(function() opened = Menu.Opened() end) or not opened then return false end
    local okp, pos  = pcall(Menu.Pos)
    local oks, size = pcall(Menu.Size)
    if not (okp and oks and pos and size) then return false end
    return in_rect(mx, my, pos.x, pos.y, size.x, size.y)
end

local function over_island(mx, my)
    if not hit.active or anim.alpha < 0.35 then return false end
    return in_rect(mx, my, hit.x - 4, hit.y - 4, hit.w + 8, hit.h + 8)
end

local function click(mx, my)
    last_touch = now()

    for i = 1, #hit.buttons do
        local b = hit.buttons[i]
        if in_rect(mx, my, b.x, b.y, b.w, b.h) then
            if b.id == "pause" then
                S.playing = not S.playing
                control("play_pause")
            elseif b.id == "next" then
                control("next")
            else
                control("prev")
            end
            return
        end
    end

    local vi = hit.vol_icon
    if vi and in_rect(mx, my, vi.x, vi.y, vi.w, vi.h) then
        vol.pin = (now() < vol.pin) and 0 or (now() + 4.0)
        return
    end

    local vt = hit.volume
    if vt and in_rect(mx, my, vt.x, vt.y, vt.w, vt.h) then
        vol.pin   = now() + 4.0
        vol.level = saturate((mx - vt.x) / max(1, vt.w))
        vol_send(vol.level, true)
        return
    end

    local p = hit.progress
    if p and in_rect(mx, my, p.x, p.y, p.w, p.h) and (S.duration or 0) > 0 then
        local target = saturate((mx - p.x) / max(1, p.w)) * S.duration
        S.pos, S.pos_target = target, target
        seek.at, seek.hold = target, now() + 1.5
        control("seek", target)
        return
    end

    anim.open_target = (anim.open_target > 0.5) and 0 or 1
end

local function on_key(data)
    if not C.enable or not data then return end
    if data.key ~= Enum.ButtonCode.KEY_MOUSE1 then return end

    local mx, my = cursor()

    if vol.drag and data.event == Enum.EKeyEvent.EKeyEvent_KEY_UP then
        vol_send(saturate(vol.level or 0), true)
        vol.drag   = false
        vol.pin    = now() + 1.5
        mouse_down = false
        last_click = now()
        return false
    end

    if seek.drag and data.event == Enum.EKeyEvent.EKeyEvent_KEY_UP then
        local target = seek.at
        seek.drag  = false
        seek.hold  = now() + 1.5
        S.pos, S.pos_target = target, target
        control("seek", target)
        last_touch = now()
        mouse_down = false
        last_click = now()
        return false
    end

    if cursor_in_menu(mx, my) or not over_island(mx, my) then
        mouse_down = false
        return
    end

    if data.event == Enum.EKeyEvent.EKeyEvent_KEY_DOWN then
        mouse_down = true
        last_click = now()
        local vt = hit.volume
        if vt and in_rect(mx, my, vt.x, vt.y, vt.w, vt.h) then
            vol.drag  = true
            vol.pin   = now() + 4.0
            vol.level = saturate((mx - vt.x) / max(1, vt.w))
            vol_send(vol.level, true)
            return false
        end

        local pr = hit.progress
        if pr and in_rect(mx, my, pr.x, pr.y, pr.w, pr.h) and (S.duration or 0) > 0 then
            seek.drag  = true
            seek.at    = saturate((mx - pr.x) / max(1, pr.w)) * S.duration
            last_touch = now()
        end
        return false
    elseif data.event == Enum.EKeyEvent.EKeyEvent_KEY_UP then
        if mouse_down then click(mx, my) end
        mouse_down = false
        last_click = now()
        return false
    end
end

local function on_orders()
    if not C.enable or not hit.active then return end
    if now() - last_click < 0.3 then return false end
    local mx, my = cursor()
    if over_island(mx, my) and not cursor_in_menu(mx, my) then return false end
end

local island = {}

function island.OnScriptsLoaded()
    load_fonts()
    read_menu()
    config_dirty = true
end

local last_tick = nil

function island.OnFrame()
    local dt
    local tick = wall_clock()
    if tick then
        dt = last_tick and (tick - last_tick) or 1 / 144
        last_tick = tick
    end
    if not dt or dt <= 0 then
        local ok, engine_dt = pcall(GlobalVars.GetAbsFrameTime)
        dt = (ok and type(engine_dt) == "number" and engine_dt > 0) and engine_dt or 1 / 144
    end
    dt = clamp(dt, 1 / 1000, 0.1)
    soft_clock = soft_clock + dt

    read_menu()

    if not C.enable then
        anim.alpha = 0
        hit_reset()
        return
    end

    load_fonts()

    local in_game = false
    pcall(function() in_game = Engine.IsInGame() end)
    local visible = in_game or C.dashboard

    if visible then net_pump() end

    advance_position(dt)
    cover_update()
    update_anim(dt)

    local target = want_alpha(visible)
    anim.alpha = approach(anim.alpha, target, 10, dt)
    if target <= 0 then
        anim.open_target = 0
        if anim.alpha < 0.02 then
            hit_reset()
            return
        end
    end

    update_open(dt)
    layout(dt)
    draw(dt)
end

island.OnKeyEvent          = on_key
island.OnPrepareUnitOrders = on_orders

function island.OnGameEnd()
    anim.open_target = 0
    anim.open, anim.open_vel = 0, 0
    mouse_down = false
    vol.drag, vol.open, vol.pin = false, 0, 0
    seek.drag, seek.hold = false, 0
    hit_reset()
end

return island
