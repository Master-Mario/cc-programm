-- ============================================================
--  FabrikOS :: Energie-Monitor v1.0
--  Kompatibel mit: Mekanism, Refined Storage, AE2, Create
--  Peripherie: Energy Cell, Induction Matrix, Accumulator
-- ============================================================

-- ┌─────────────────────────────────────────────────────────┐
-- │  KONFIGURATION                                          │
-- └─────────────────────────────────────────────────────────┘

local CONFIG = {
    monitor_side    = "left",        -- Seite des Monitors
    refresh_rate    = 1,            -- Sekunden zwischen Updates
    history_size    = 60,           -- Datenpunkte für Graph (= 60s)
    warn_threshold  = 0.25,         -- Warnung unter 25% Kapazität
    crit_threshold  = 0.10,         -- Kritisch unter 10% Kapazität
    redstone_alarm  = "back",       -- Redstone-Ausgang für Alarm (nil = deaktiviert)

    -- Bekannte Peripherie-Namen (nil = auto-detect)
    energy_periph   = nil,

    -- Einheit (auto, FE, RF, J, EU)
    unit            = "auto",
}

-- ┌─────────────────────────────────────────────────────────┐
--  FARBEN & THEME
-- └─────────────────────────────────────────────────────────┘

local C = {
    bg          = colors.black,
    panel       = colors.gray,
    border      = colors.lightGray,
    text        = colors.white,
    muted       = colors.lightGray,
    accent      = colors.cyan,
    ok          = colors.lime,
    warn        = colors.yellow,
    crit        = colors.red,
    bar_full    = colors.cyan,
    bar_warn    = colors.yellow,
    bar_crit    = colors.red,
    bar_empty   = colors.gray,
    graph_line  = colors.cyan,
    graph_bg    = colors.gray,
    title_bg    = colors.blue,
    title_text  = colors.white,
}

-- ┌─────────────────────────────────────────────────────────┐
--  STATE
-- └─────────────────────────────────────────────────────────┘

local state = {
    energy       = 0,
    max_energy   = 0,
    input_rate   = 0,   -- FE/t eingehend
    output_rate  = 0,   -- FE/t ausgehend
    net_rate     = 0,   -- Differenz (positiv = aufladen)
    percent      = 0,
    eta_seconds  = nil, -- nil wenn stabil oder voll
    history      = {},  -- Ringpuffer für Graphen
    history_idx  = 1,
    periph_name  = "?",
    periph_type  = "unknown",
    alarm_active = false,
    tick         = 0,
    unit_label   = "FE",
}

-- ┌─────────────────────────────────────────────────────────┐
--  HILFSFUNKTIONEN
-- └─────────────────────────────────────────────────────────┘

-- Zahlen lesbar formatieren: 1234567 → "1.23M"
local function fmt_num(n, unit)
    local u = unit or ""
    if n == nil then return "N/A" end
    local abs = math.abs(n)
    if abs >= 1e9 then
        return string.format("%.2fG%s", n / 1e9, u)
    elseif abs >= 1e6 then
        return string.format("%.2fM%s", n / 1e6, u)
    elseif abs >= 1e3 then
        return string.format("%.1fk%s", n / 1e3, u)
    else
        return string.format("%d%s", math.floor(n), u)
    end
end

-- Sekunden → "1h 23m 45s"
local function fmt_time(s)
    if s == nil or s < 0 then return "∞" end
    if s > 86400 then return ">1d" end
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local sec = math.floor(s % 60)
    if h > 0 then
        return string.format("%dh %dm", h, m)
    elseif m > 0 then
        return string.format("%dm %ds", m, sec)
    else
        return string.format("%ds", sec)
    end
end

-- Fortschrittsbalken zeichnen
local function draw_bar(mon, x, y, w, percent, col_fill, col_empty)
    local filled = math.floor(w * percent)
    mon.setCursorPos(x, y)
    mon.setBackgroundColor(col_fill)
    mon.write(string.rep(" ", filled))
    if filled < w then
        mon.setBackgroundColor(col_empty)
        mon.write(string.rep(" ", w - filled))
    end
    mon.setBackgroundColor(C.bg)
end

-- Text zentriert auf Monitor schreiben
local function center_text(mon, y, text, fg, bg)
    local w, _ = mon.getSize()
    local x = math.floor((w - #text) / 2) + 1
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x, y)
    mon.write(text)
end

-- Linie zeichnen
local function hline(mon, y, char, fg, bg)
    local w, _ = mon.getSize()
    mon.setCursorPos(1, y)
    if fg then mon.setTextColor(fg) end
    if bg then mon.setBackgroundColor(bg) end
    mon.write(string.rep(char or "─", w))
end

-- Graphen zeichnen (Mini-Sparkline)
local function draw_graph(mon, x, y, w, h, data, max_val)
    if #data == 0 then return end

    -- Hintergrund
    for row = y, y + h - 1 do
        mon.setCursorPos(x, row)
        mon.setBackgroundColor(C.graph_bg)
        mon.write(string.rep(" ", w))
    end

    -- Werte normalisieren
    local effective_max = max_val
    if effective_max == nil or effective_max == 0 then
        effective_max = 1
        for _, v in ipairs(data) do
            if v > effective_max then effective_max = v end
        end
    end

    -- Bars zeichnen (von rechts nach links, neueste Daten rechts)
    local num = math.min(#data, w)
    for i = 1, num do
        local val = data[#data - num + i]
        if val == nil then val = 0 end
        local norm = val / effective_max
        local bar_h = math.floor(norm * h)
        if bar_h < 0 then bar_h = 0 end
        if bar_h > h then bar_h = h end

        local col = C.bar_full
        if norm < CONFIG.crit_threshold then
            col = C.bar_crit
        elseif norm < CONFIG.warn_threshold then
            col = C.bar_warn
        end

        -- Spalte von unten auffüllen
        for row = 0, bar_h - 1 do
            mon.setCursorPos(x + i - 1, y + h - 1 - row)
            mon.setBackgroundColor(col)
            mon.write(" ")
        end
    end
    mon.setBackgroundColor(C.bg)
end

-- ┌─────────────────────────────────────────────────────────┐
--  PERIPHERIE-ERKENNUNG
-- └─────────────────────────────────────────────────────────┘

-- Gibt zurück: { energy, maxEnergy, input, output } oder nil
local function read_mekanism(p)
    -- Mekanism Induction Matrix / Energy Cube
    local ok, e = pcall(function() return p.getEnergy() end)
    if not ok then return nil end
    local ok2, me = pcall(function() return p.getMaxEnergy() end)
    if not ok2 then return nil end
    local inp = 0
    local out = 0
    pcall(function() inp = p.getLastInput() end)
    pcall(function() out = p.getLastOutput() end)
    return { energy = e, max_energy = me, input = inp, output = out, unit = "J" }
end

local function read_fe_generic(p)
    -- Funktioniert für: Refined Storage Controller,
    -- Thermal Expansion Cells, Powah, most FE tiles
    local ok, e = pcall(function() return p.getEnergyStored() end)
    if not ok then return nil end
    local ok2, me = pcall(function() return p.getMaxEnergyStored() end)
    if not ok2 then return nil end
    -- Input/Output optional
    local inp, out = 0, 0
    pcall(function() inp = p.getEnergyInput() end)
    pcall(function() out = p.getEnergyOutput() end)
    return { energy = e, max_energy = me, input = inp, output = out, unit = "FE" }
end

local function read_create_accumulator(p)
    -- Create: Energized Andesite Accumulator
    local ok, info = pcall(function() return p.getAccumulatorInfo() end)
    if ok and info then
        return {
            energy     = info.energy or 0,
            max_energy = info.capacity or 1,
            input      = info.flowIn or 0,
            output     = info.flowOut or 0,
            unit       = "FE"
        }
    end
    return nil
end

local READERS = {
    { name = "Mekanism",    fn = read_mekanism },
    { name = "FE-Generic",  fn = read_fe_generic },
    { name = "Create",      fn = read_create_accumulator },
}

local function detect_and_read()
    local candidates = {}

    if CONFIG.energy_periph then
        -- Fixe Peripherie konfiguriert
        local p = peripheral.wrap(CONFIG.energy_periph)
        if p then
            candidates = {{ name = CONFIG.energy_periph, p = p }}
        end
    else
        -- Auto-detect: alle Peripherie durchsuchen
        for _, side in ipairs(peripheral.getNames()) do
            if side ~= CONFIG.monitor_side then
                local p = peripheral.wrap(side)
                if p then
                    table.insert(candidates, { name = side, p = p })
                end
            end
        end
    end

    for _, cand in ipairs(candidates) do
        for _, reader in ipairs(READERS) do
            local data = reader.fn(cand.p)
            if data then
                data.periph_name = cand.name
                data.periph_type = reader.name
                return data
            end
        end
    end
    return nil
end

-- ┌─────────────────────────────────────────────────────────┐
--  DATEN AKTUALISIEREN
-- └─────────────────────────────────────────────────────────┘

local prev_energy = nil
local prev_time   = nil

local function update_state()
    state.tick = state.tick + 1
    local data = detect_and_read()

    if data then
        local now = os.clock()

        -- Rate berechnen über Zeitdelta (genauer als Periph-Werte)
        if prev_energy ~= nil and prev_time ~= nil then
            local dt = now - prev_time
            if dt > 0.05 then
                local delta = data.energy - prev_energy
                -- FE/s → FE/t (20 ticks/s)
                local rate = delta / dt
                state.net_rate    = rate
                state.input_rate  = data.input  ~= 0 and data.input  or math.max(0,  rate)
                state.output_rate = data.output ~= 0 and data.output or math.max(0, -rate)
            end
        end

        prev_energy = data.energy
        prev_time   = os.clock()

        state.energy      = data.energy
        state.max_energy  = math.max(data.max_energy, 1)
        state.percent     = data.energy / state.max_energy
        state.periph_name = data.periph_name
        state.periph_type = data.periph_type
        if CONFIG.unit == "auto" then
            state.unit_label = data.unit or "FE"
        else
            state.unit_label = CONFIG.unit
        end

        -- ETA berechnen
        if state.net_rate < -100 then
            -- Entladen: Zeit bis leer
            state.eta_seconds = state.energy / math.abs(state.net_rate)
        elseif state.net_rate > 100 and state.percent < 0.9999 then
            -- Laden: Zeit bis voll
            state.eta_seconds = (state.max_energy - state.energy) / state.net_rate
        else
            state.eta_seconds = nil
        end

        -- History Ringpuffer
        state.history[state.history_idx] = state.percent
        state.history_idx = (state.history_idx % CONFIG.history_size) + 1
        -- Sicherstellen dass Array korrekte Größe hat
        if #state.history > CONFIG.history_size then
            table.remove(state.history, 1)
        end

        -- Alarm
        state.alarm_active = state.percent < CONFIG.crit_threshold
        if CONFIG.redstone_alarm then
            rs.setOutput(CONFIG.redstone_alarm, state.alarm_active)
        end
    end
end

-- History-Array als geordnete Liste (ältestes zuerst) zurückgeben
local function get_ordered_history()
    local result = {}
    local size = #state.history
    if size == 0 then return result end
    local start = state.history_idx
    for i = 0, size - 1 do
        local idx = ((start + i - 1) % size) + 1
        if state.history[idx] then
            table.insert(result, state.history[idx])
        end
    end
    return result
end

-- ┌─────────────────────────────────────────────────────────┐
--  RENDERING
-- └─────────────────────────────────────────────────────────┘

local function render(mon)
    local w, h = mon.getSize()

    -- Bildschirm leeren
    mon.setBackgroundColor(C.bg)
    mon.clear()

    -- ── Titelzeile ───────────────────────────────────────────
    mon.setCursorPos(1, 1)
    mon.setBackgroundColor(C.title_bg)
    mon.setTextColor(C.title_text)
    mon.write(string.rep(" ", w))
    local title = " ⚡ Energie-Monitor"
    mon.setCursorPos(1, 1)
    mon.write(title)
    -- Periph-Info rechts in Titelzeile
    local pinfo = state.periph_name .. " "
    mon.setCursorPos(w - #pinfo, 1)
    mon.write(pinfo)

    mon.setBackgroundColor(C.bg)
    mon.setTextColor(C.text)

    -- ── Status-Farbe bestimmen ───────────────────────────────
    local status_col = C.ok
    local status_text = "OK"
    if state.percent < CONFIG.crit_threshold then
        status_col = C.crit
        status_text = "KRITISCH"
    elseif state.percent < CONFIG.warn_threshold then
        status_col = C.warn
        status_text = "WARNUNG"
    end

    -- ── Energie-Wert ─────────────────────────────────────────
    local row = 3
    local pct_str = string.format("%.1f%%", state.percent * 100)
    local energy_str = fmt_num(state.energy, state.unit_label)
    local max_str    = fmt_num(state.max_energy, state.unit_label)

    mon.setCursorPos(2, row)
    mon.setTextColor(status_col)
    mon.write(pct_str)
    mon.setTextColor(C.muted)
    mon.write("  " .. energy_str .. " / " .. max_str)

    -- Status-Badge rechts
    mon.setBackgroundColor(status_col)
    mon.setTextColor(colors.black)
    mon.setCursorPos(w - #status_text - 1, row)
    mon.write(" " .. status_text .. " ")
    mon.setBackgroundColor(C.bg)
    mon.setTextColor(C.text)

    -- ── Fortschrittsbalken ───────────────────────────────────
    row = row + 1
    local bar_w = w - 2
    local bar_col = C.bar_full
    if state.percent < CONFIG.crit_threshold then
        bar_col = C.bar_crit
    elseif state.percent < CONFIG.warn_threshold then
        bar_col = C.bar_warn
    end
    draw_bar(mon, 2, row, bar_w, state.percent, bar_col, C.bar_empty)

    -- ── Raten ────────────────────────────────────────────────
    row = row + 2
    mon.setTextColor(C.muted)
    mon.setCursorPos(2, row)
    mon.write("Eingang:")
    mon.setTextColor(C.ok)
    mon.write(" +" .. fmt_num(state.input_rate, state.unit_label .. "/t"))

    mon.setTextColor(C.muted)
    local out_str = "  Ausgang: "
    mon.setCursorPos(2 + 10 + #fmt_num(state.input_rate, state.unit_label .. "/t") + 1, row)
    mon.write("Ausgang:")
    mon.setTextColor(C.crit)
    mon.write(" -" .. fmt_num(state.output_rate, state.unit_label .. "/t"))

    row = row + 1
    mon.setTextColor(C.muted)
    mon.setCursorPos(2, row)
    mon.write("Netto:  ")
    if state.net_rate >= 0 then
        mon.setTextColor(C.ok)
        mon.write("+" .. fmt_num(state.net_rate, state.unit_label .. "/s"))
    else
        mon.setTextColor(C.crit)
        mon.write(fmt_num(state.net_rate, state.unit_label .. "/s"))
    end

    -- ETA
    if state.eta_seconds ~= nil then
        mon.setTextColor(C.muted)
        if state.net_rate < 0 then
            mon.setCursorPos(math.floor(w / 2), row)
            mon.write("Leer in: ")
            mon.setTextColor(C.warn)
        else
            mon.setCursorPos(math.floor(w / 2), row)
            mon.write("Voll in: ")
            mon.setTextColor(C.accent)
        end
        mon.write(fmt_time(state.eta_seconds))
    end

    mon.setTextColor(C.text)
    mon.setBackgroundColor(C.bg)

    -- ── Trennlinie ───────────────────────────────────────────
    row = row + 1
    hline(mon, row, "─", C.border, C.bg)

    -- ── Verlaufs-Graph ───────────────────────────────────────
    row = row + 1
    local graph_h = h - row - 1
    if graph_h > 2 then
        mon.setCursorPos(2, row)
        mon.setTextColor(C.muted)
        mon.write("Verlauf (" .. CONFIG.history_size .. "s)")

        local history = get_ordered_history()
        -- Graph zeigt percent-Werte (0.0 - 1.0)
        -- max_val = 1.0 (100%)
        draw_graph(mon, 1, row + 1, w, graph_h, history, 1.0)

        -- Y-Achse Beschriftungen (rechter Rand, auf Graph-Hintergrund)
        mon.setTextColor(C.muted)
        mon.setBackgroundColor(C.graph_bg)
        mon.setCursorPos(w - 3, row + 1)
        mon.write("100")
        mon.setCursorPos(w - 1, row + math.floor(graph_h / 2))
        mon.write("50")
        mon.setCursorPos(w - 1, row + graph_h - 1)
        mon.write(" 0")
    end

    -- ── Statuszeile unten ────────────────────────────────────
    mon.setCursorPos(1, h)
    mon.setBackgroundColor(C.panel)
    mon.setTextColor(C.muted)
    local footer = string.format(" %s | Tick #%d | %.0fs Daten",
        state.periph_type, state.tick, #state.history)
    mon.write(footer .. string.rep(" ", math.max(0, w - #footer)))

    mon.setBackgroundColor(C.bg)
    mon.setTextColor(C.text)
end

-- ┌─────────────────────────────────────────────────────────┐
--  STARTUP & MAIN LOOP
-- └─────────────────────────────────────────────────────────┘

local function init_monitor()
    local mon = peripheral.wrap(CONFIG.monitor_side)
    if not mon then
        -- Fallback: ersten Monitor finden
        for _, side in ipairs(peripheral.getNames()) do
            local p = peripheral.wrap(side)
            if p and peripheral.getType(side) == "monitor" then
                mon = p
                CONFIG.monitor_side = side
                break
            end
        end
    end
    if not mon then
        print("[FabrikOS] FEHLER: Kein Monitor gefunden!")
        print("  Setze monitor_side in CONFIG.")
        return nil
    end
    mon.setTextScale(0.5)
    return mon
end

local function main()
    print("[FabrikOS] Energie-Monitor gestartet.")
    print("  Monitor-Seite: " .. CONFIG.monitor_side)

    local mon = init_monitor()
    if not mon then return end

    -- History vorinitialisieren
    for i = 1, CONFIG.history_size do
        state.history[i] = 0
    end

    -- Erster Read zum Testen
    local test = detect_and_read()
    if test then
        print("  Peripherie gefunden: " .. test.periph_name ..
              " (" .. test.periph_type .. ")")
    else
        print("  WARNUNG: Keine Energie-Peripherie gefunden.")
        print("  Unterstützt: Mekanism, FE-Blocks, Create")
    end

    print("  Refresh: alle " .. CONFIG.refresh_rate .. "s")
    print("  Drücke Q zum Beenden.")

    -- Haupt-Loop
    local running = true
    parallel.waitForAny(
        -- Update + Render Loop
        function()
            while running do
                update_state()
                render(mon)
                sleep(CONFIG.refresh_rate)
            end
        end,
        -- Key-Handler (Q = Beenden)
        function()
            while true do
                local _, key = os.pullEvent("key")
                if key == keys.q then
                    running = false
                    -- Monitor leeren beim Beenden
                    mon.setBackgroundColor(colors.black)
                    mon.clear()
                    mon.setCursorPos(1, 1)
                    mon.setTextColor(colors.white)
                    mon.write("Monitor gestoppt.")
                    print("[FabrikOS] Energie-Monitor beendet.")
                    return
                end
            end
        end
    )
end

-- Starten
main()
