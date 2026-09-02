local JSON = require('assets.JSON')
local has_chronos, chronos = pcall(require, 'chronos')

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local exp, fmt = math.exp, string.format

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function saturate(v) return clamp(v, 0, 1) end
local function lerp(a, b, t) return a + (b - a) * t end

local function approach(current, target, speed, dt)
    return current + (target - current) * (1 - exp(-speed * dt))
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
M.hide_idle = view:Switch("Скрывать, когда нет трека", true)
M.dash      = view:Switch("Показывать вне игры", true)

M.autohide:ToolTip("Раскрытый плеер сам вернётся в капсулу через ~6 секунд")
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
    C.dashboard     = M.dash:Get()

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

local ICON_BOX   = 64
local ICON_SCALE = 1.28

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

local VECTOR_ICON = {
    play = icon_play, pause = icon_pause, prev = icon_prev, next = icon_next,
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

local function control(action, value)
    local path = "/control?action=" .. action
    if value then path = path .. "&value=" .. fmt("%.3f", value) end
    pcall(HTTP.Request, "GET", net.base .. path, {}, function() end)
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
    open = 0, open_vel = 0, open_target = 0,
    swap = 1,
    lyr = 1,
    pulse = 0,
    lyr_h = 0,
    pill_w = 0,
    pill_from = 0,
    bars = {},
    hover = { prev = 0, pause = 0, next = 0, body = 0 },
    ar = 122, ag = 190, ab = 255,
}

local last_touch = 0
local last_click = 0

local function sync_position(value)
    local p = tonumber(value)
    if not p then return end
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

local ART_SIZE = 160

local cover = { track_id = nil, handle = nil, inflight = false, next_try = 0 }

local function cover_reset()
    cover.track_id = nil
    cover.handle   = nil
    cover.inflight = false
    cover.next_try = 0
end

local function cover_build_svg(b64)
    return '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="'
        .. ART_SIZE .. '" height="' .. ART_SIZE
        .. '"><image width="' .. ART_SIZE .. '" height="' .. ART_SIZE
        .. '" preserveAspectRatio="xMidYMid slice" xlink:href="data:image/png;base64,'
        .. b64 .. '"/></svg>'
end

local function cover_update()
    if cover.track_id ~= S.track_id then
        cover_reset()
        cover.track_id = S.track_id
    end
    if cover.handle or type(S.cover) ~= "table" then return end
    if cover.inflight then return end
    if now() < cover.next_try then return end

    cover.inflight = true
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

local function accent_target()
    if C.accent_auto and type(S.cover) == "table" and type(S.cover.colors) == "table" then
        local first = S.cover.colors[1]
        if type(first) == "table" then
            local r, g, b = tonumber(first[1]), tonumber(first[2]), tonumber(first[3])
            if r and g and b then
                local peak = max(r, max(g, b))
                if peak > 0 and peak < 140 then
                    local k = 140 / peak
                    r, g, b = r * k, g * k, b * k
                end
                return r, g, b
            end
        end
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

local function update_anim(dt)
    anim.open, anim.open_vel = spring(anim.open, anim.open_vel, anim.open_target, 210, 22, dt)
    anim.open  = clamp(anim.open, -0.12, 1.14)
    anim.swap  = min(1, anim.swap + dt / 0.34)
    anim.lyr   = min(1, anim.lyr + dt / 0.28)
    anim.pulse = max(0, anim.pulse - dt / 0.45)

    local r, g, b = accent_target()
    anim.ar = approach(anim.ar, r, 6, dt)
    anim.ag = approach(anim.ag, g, 6, dt)
    anim.ab = approach(anim.ab, b, 6, dt)

    update_bars(dt)
end

local BASE = {
    compact_w = 220, compact_h = 38,  compact_r = 19,
    open_w    = 380, open_h    = 164, open_r    = 28,
    lyr_extra = 34,
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

local function layout(dt)
    local screen = Render.ScreenSize()
    local sy = screen.y / 1080
    local k  = sy * (C.scale or 1)

    local extra = (C.lyr_inside and has_lyrics_line()) and BASE.lyr_extra or 0
    anim.lyr_h = approach(anim.lyr_h, extra, 9, dt)

    local open_h = BASE.open_h + anim.lyr_h
    local w = lerp(BASE.compact_w, BASE.open_w, anim.open) * k
    local h = lerp(BASE.compact_h, open_h, anim.open) * k
    local r = lerp(BASE.compact_r, BASE.open_r, saturate(anim.open)) * k

    local cx = screen.x * (C.pos_x or 50) / 100
    geom.x = clamp(cx - w * 0.5, 4, max(4, screen.x - w - 4))
    geom.y = clamp((C.pos_y or 12) * sy + 2, 2, max(2, screen.y - h - 4))
    geom.w, geom.h, geom.r = w, h, r
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

local function smoothstep(t)
    t = saturate(t)
    return t * t * (3 - 2 * t)
end

local function marquee(id, key, overflow, dt)
    local m = marq[id]
    if not m or m.key ~= key then
        m = { key = key, t0 = now(), off = 0 }
        marq[id] = m
    end

    if overflow <= 0.5 then
        m.off = approach(m.off, 0, 8, dt or 0)
        return m.off
    end
    if not dt or dt <= 0 then return m.off end

    local travel = overflow / max(1, MARQ_SPEED * geom.k)
    local hold   = MARQ_HOLD
    local t      = (now() - m.t0) % ((hold + travel) * 2)

    if t < hold then
        m.off = 0
    elseif t < hold + travel then
        m.off = overflow * smoothstep((t - hold) / travel)
    elseif t < hold * 2 + travel then
        m.off = overflow
    else
        m.off = overflow * (1 - smoothstep((t - hold * 2 - travel) / travel))
    end
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

local hit = { active = false, x = 0, y = 0, w = 0, h = 0, buttons = {}, progress = nil }

local function hit_reset()
    hit.active   = false
    hit.buttons  = {}
    hit.progress = nil
end

local function cursor()
    local ok, cx, cy = pcall(Input.GetCursorPos)
    if ok and cx and cy then return cx, cy end
    return -10000, -10000
end

local function in_rect(mx, my, x, y, w, h)
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local function draw_compact(alpha, dt)
    local k, x, y, w, h = geom.k, geom.x, geom.y, geom.w, geom.h
    local pad   = 4 * k
    local size  = h - pad * 2
    local pulse = 1 + 0.06 * ease_out(anim.pulse)
    local grow  = size * (pulse - 1) * 0.5

    draw_cover(x + pad - grow, y + pad - grow, size * pulse, 10 * k, alpha)

    local eq_w = (C.eq and (C.bars or 0) > 0) and 46 * k or 0
    local eq_h = h * 0.46
    local eq_x = x + w - pad - eq_w
    if eq_w > 0 then
        draw_bars(eq_x, y + (h - eq_h) * 0.5, eq_w, eq_h, alpha)
    end

    local gap = 10 * k
    local tx  = x + pad + size + gap
    local box = eq_x - gap - tx
    if box <= 8 * k then return end

    local tsize = 12.5 * k
    local title = (S.title ~= "" and S.title)
                  or (net.online and "Нет трека" or "Сервер не отвечает")
    local font  = fonts.semi or fonts.regular
    local ty    = y + (h - text_h(font, tsize, title)) * 0.5

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

    local pulse = 1 + 0.06 * ease_out(anim.pulse)
    local cs    = 72 * k
    local grow  = cs * (pulse - 1) * 0.5
    draw_cover(x + pad - grow, y + pad - grow, cs * pulse, 16 * k, alpha)

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
    local done   = (S.duration or 0) > 0 and saturate(S.pos / S.duration) or 0

    Render.FilledRect(Vec2(bar_x1, bar_y), Vec2(bar_x2, bar_y + bar_h),
                      rgba(255, 255, 255, 38 * alpha), bar_h * 0.5, FL)
    if done > 0 then
        Render.FilledRect(Vec2(bar_x1, bar_y), Vec2(bar_x1 + span * done, bar_y + bar_h),
                          accent_color(alpha), bar_h * 0.5, FL)
    end

    hit.progress = { x = bar_x1, y = bar_y - 9 * k, w = span, h = bar_h + 18 * k }
    if in_rect(mx, my, hit.progress.x, hit.progress.y, hit.progress.w, hit.progress.h) then
        Render.FilledCircle(Vec2(bar_x1 + span * done, bar_y + bar_h * 0.5), 5 * k,
                            rgba(255, 255, 255, 238 * alpha))
    end

    local time_y = y + h - 64 * k
    local dim    = rgba(255, 255, 255, 140 * alpha)
    text(fonts.regular, 11 * k, fmt_time(S.pos), bar_x1, time_y, dim)
    local remain = "-" .. fmt_time(max(0, (S.duration or 0) - S.pos))
    text(fonts.regular, 11 * k, remain,
         bar_x2 - text_w(fonts.regular, 11 * k, remain), time_y, dim)

    local cy      = y + h - 27 * k
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
    if anim.alpha <= 0.01 then hit_reset() return end

    local alpha = anim.alpha
    local x, y, w, h, r = geom.x, geom.y, geom.w, geom.h, geom.r

    hit.active   = true
    hit.x, hit.y, hit.w, hit.h = x, y, w, h
    hit.buttons  = {}
    hit.progress = nil

    draw_panel(x, y, w, h, r, alpha)

    local compact_a  = saturate(1 - anim.open * 2.2)
    local expanded_a = saturate((anim.open - 0.45) / 0.55)

    Render.PushClip(Vec2(x, y), Vec2(x + w, y + h), true)
    if compact_a  > 0.01 then draw_compact(alpha * compact_a, dt) end
    if expanded_a > 0.01 then draw_expanded(alpha * expanded_a, dt) end
    Render.PopClip()

    if expanded_a < 0.6 then
        hit.buttons  = {}
        hit.progress = nil
    end

    if C.lyrics and not C.lyr_inside then draw_lyrics_pill(alpha, dt) end
end

local function want_alpha(visible)
    if not visible or not net.online then return 0 end
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

    local p = hit.progress
    if p and in_rect(mx, my, p.x, p.y, p.w, p.h) and (S.duration or 0) > 0 then
        local target = saturate((mx - p.x) / max(1, p.w)) * S.duration
        S.pos, S.pos_target = target, target
        control("seek", target)
        return
    end

    anim.open_target = (anim.open_target > 0.5) and 0 or 1
end

local function on_key(data)
    if not C.enable or not data then return end
    if data.key ~= Enum.ButtonCode.KEY_MOUSE1 then return end

    local mx, my = cursor()
    if cursor_in_menu(mx, my) or not over_island(mx, my) then
        mouse_down = false
        return
    end

    if data.event == Enum.EKeyEvent.EKeyEvent_KEY_DOWN then
        mouse_down = true
        last_click = now()
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
    hit_reset()
end

return island