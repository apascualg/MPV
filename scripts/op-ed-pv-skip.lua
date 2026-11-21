-- ====================================================================
-- OP / ED / PV Skip Script for MPV
-- Soporta modo interactivo con botón visual (estilo streaming) y auto-skip
-- ====================================================================

local opt = require("mp.options")
local assdraw = require("mp.assdraw")

-- --------------------------------------------------------------------
-- Configuración
-- --------------------------------------------------------------------

-- Comportamiento por defecto:
-- "button" = Muestra un botón en pantalla para saltar si el usuario lo desea (Opción B)
-- "auto"   = Salto automático inmediato (comportamiento original)
-- "off"    = Desactivado
local BEHAVIOR = "button"

-- Duración en segundos que el botón permanece en pantalla (0 = todo el capítulo)
local BUTTON_TIMEOUT = 10

-- Teclas de acceso directo para saltar mientras el botón está visible
local BUTTON_KEY = "Tab"        -- Tecla principal (ej. "Tab", "s", "Enter")
local BUTTON_KEY_ALT = "s"      -- Tecla alternativa
local SHOW_KEY_IN_BUTTON = false -- Mostrar [TAB] en la etiqueta del botón

-- Estilo visual del botón (colores en formato ASS &HBBGGRR&)
-- Normal : relleno blanco sólido, sin borde
-- Hover  : borde blanco + relleno gris claro
-- Pulsado: borde blanco + relleno gris medio
local BUTTON_OPACITY       = 1.0         -- Opacidad general del botón (0..1)
local BUTTON_RADIUS        = 6           -- Radio de las esquinas (a escala 1.0)
local BUTTON_BORDER        = 3           -- Grosor del borde blanco en hover/pulsado (a escala 1.0)
local COLOR_NORMAL_FILL    = "&HFFFFFF&" -- Blanco
local COLOR_HOVER_FILL     = "&HE8E8E8&" -- Gris claro
local COLOR_PRESSED_FILL   = "&H8E8E8E&" -- Gris medio
local COLOR_BORDER         = "&HFFFFFF&" -- Borde blanco
local COLOR_TEXT           = "&H000000&" -- Texto negro
local PRESS_FEEDBACK_TIME  = 0.12        -- Segundos que se muestra el estado pulsado si no hay evento "up"

-- Condición estricta: Requiere que se cumplan AMBAS condiciones obligatoriamente:
-- 1. Que el nombre del capítulo coincida con Opening / Ending / Preview
-- 2. Que la duración del capítulo esté entre 88 y 92 segundos (OP/ED)
local REQUIRE_NAME_AND_DURATION = true

-- Atajo para abrir el menú de ajustes OSD (se usa ctrl+y para no pisar subtítulos en 'y'/'Y')
local MENU_KEYBIND = "ctrl+y"

-- Patrones de detección de capítulos (en minúsculas)
local PATTERNS_OP = {
    "op", "opening", " - op", " (opening)", " - opening",
    "intro", "apertura", "opening theme", "オープニング",
    "op song", "op by"
}

local PATTERNS_ED = {
    "ed", "ending", " - ed", " (ending)", "- ending",
    "ending credits", "credits", "cierre", "outro", "créditos", "creditos",
    "ending theme", "エンディング", "edcard", " - ed card",
    "ed+cast", "cast", "ed song"
}

local PATTERNS_PV = {
    "pv", "preview", "next episode preview", "next ep. preview", "nextp ep. preview",
    "next", "next time", "avance", "adelanto", "próximo episodio", "proximo episodio"
}

-- Modos de detección
local MODE_CHAPTER_NAME   = "chapter name"
local MODE_CHAPTER_LENGTH = "chapter length"

-- Estado interno
local CURRENT_MODE = MODE_CHAPTER_NAME
local PREV_CHAPTER = nil
local MENU = false
local SELECTED_MENU_ROW = 1 -- 1: Behavior, 2: Mode, 3: OP/ED threshold, 4: PV threshold
local SELECTED_MENU_COL = 1

local OP_ED_THRESHOLD = {
    from = { selected = false, value = 70 },
    to   = { selected = false, value = 120 },
}
local PV_THRESHOLD = {
    from = { selected = false, value = 14 },
    to   = { selected = false, value = 26 },
}

-- Estado del botón en pantalla
local overlay = mp.create_osd_overlay("ass-events")
local button_visible = false
local is_hovered = false
local is_pressed = false        -- true mientras se mantiene pulsado (ratón o tecla)
local current_chapter_index = nil
local current_label = "Saltar Intro"
local button_timer = nil
local screen_w, screen_h = 1280, 720

-- Animación de desvanecimiento (fade out)
local FADE_OUT_DURATION = 0.6   -- segundos que tarda en desaparecer
local fade_opacity = 1.0        -- multiplicador de opacidad (1 = visible, 0 = invisible)
local fade_timer = nil
local fading_out = false

-- Convierte una opacidad (0..1) a un valor alfa ASS (&H00& opaco, &HFF& transparente)
local function opacity_to_ass_alpha(opacity)
    local a = math.floor(255 - 255 * math.max(0, math.min(1, opacity)) + 0.5)
    return string.format("&H%02X&", a)
end

-- ====================================================================
-- Lógica del Botón en Pantalla (OSD ASS)
-- ====================================================================

local function get_button_layout()
    local scale = 1.0
    if screen_h < 500 then
        scale = 0.8
    elseif screen_h >= 1440 and screen_h < 2160 then
        scale = 1.25
    elseif screen_h >= 2160 then
        scale = 1.6
    end

    local bh = math.floor(44 * scale)
    local font_size = math.floor(16 * scale)
    local margin_x = math.floor(40 * scale)
    local margin_y = math.floor(80 * scale) -- Margen inferior (por encima de la barra uosc)

    local display_text = current_label
    if SHOW_KEY_IN_BUTTON and BUTTON_KEY and BUTTON_KEY ~= "" then
        display_text = display_text .. " [" .. BUTTON_KEY:upper() .. "]"
    end

    -- Cálculo de ancho proporcional para que el texto nunca desborde la caja
    local char_w = 10.5 * scale
    local padding_x = 48 * scale
    local bw = math.max(math.floor(180 * scale), math.floor(#display_text * char_w + padding_x))

    local bx = screen_w - bw - margin_x
    local by = screen_h - bh - margin_y

    return bx, by, bw, bh, font_size, display_text, scale
end

local function round(n)
    return math.floor(n + 0.5)
end

-- Genera el trazado ASS de un rectángulo con esquinas redondeadas
local function rounded_rect_path(x, y, w, h, r)
    r = math.max(0, math.min(r, w / 2, h / 2))
    local c = 0.5522847498 * r
    local x0, x1, x2, x3 = x, x + r, x + w - r, x + w
    local y0, y1, y2, y3 = y, y + r, y + h - r, y + h
    local pts = {
        "m", x1, y0,
        "l", x2, y0,
        "b", x2 + c, y0, x3, y1 - c, x3, y1,
        "l", x3, y2,
        "b", x3, y2 + c, x2 + c, y3, x2, y3,
        "l", x1, y3,
        "b", x1 - c, y3, x0, y2 + c, x0, y2,
        "l", x0, y1,
        "b", x0, y1 - c, x1 - c, y0, x1, y0,
    }
    for i, v in ipairs(pts) do
        if type(v) == "number" then pts[i] = tostring(round(v)) end
    end
    return table.concat(pts, " ")
end

local function render_button()
    if not button_visible or not overlay then return end

    local bx, by, bw, bh, font_size, display_text, scale = get_button_layout()

    overlay.res_x = screen_w
    overlay.res_y = screen_h

    local radius = math.max(1, round(BUTTON_RADIUS * scale))
    local border = math.max(1, round(BUTTON_BORDER * scale))
    local alpha      = opacity_to_ass_alpha(BUTTON_OPACITY * fade_opacity)
    local text_alpha = opacity_to_ass_alpha(fade_opacity)

    local ass = assdraw.ass_new()

    -- Evento 1: Fondo del botón
    ass:new_event()
    ass:an(7)
    ass:pos(0, 0)

    if is_pressed or is_hovered then
        -- Hover / Pulsado: relleno gris con borde blanco.
        -- El relleno se encoge 'border' px por cada lado y el borde ASS (\bord) crece
        -- hacia fuera, de modo que el tamaño exterior del botón es idéntico al normal
        -- y la esquina exterior conserva el mismo radio.
        local fill = is_pressed and COLOR_PRESSED_FILL or COLOR_HOVER_FILL
        ass:append(string.format(
            "{\\p1\\blur0\\shad0\\bord%d\\c%s\\1a%s\\3c%s\\3a%s}",
            border, fill, alpha, COLOR_BORDER, alpha
        ))
        ass:append(rounded_rect_path(
            bx + border, by + border,
            bw - 2 * border, bh - 2 * border,
            math.max(0, radius - border)
        ))
    else
        -- Normal: relleno blanco sólido sin borde
        ass:append(string.format(
            "{\\p1\\blur0\\shad0\\bord0\\c%s\\1a%s}",
            COLOR_NORMAL_FILL, alpha
        ))
        ass:append(rounded_rect_path(bx, by, bw, bh, radius))
    end
    ass:append("{\\p0}")

    -- Evento 2: Texto centrado dentro del botón con tipografía Inter en negro
    ass:new_event()
    ass:an(5)
    local cx = math.floor(bx + bw / 2)
    local cy = math.floor(by + bh / 2)
    ass:pos(cx, cy)
    ass:append(string.format(
        "{\\fnInter\\fs%d\\b1\\c%s\\1a%s\\bord0\\shad0}%s",
        font_size, COLOR_TEXT, text_alpha, display_text
    ))

    overlay.data = ass.text
    overlay:update()
end

-- Segundos antes del final del vídeo a los que se salta cuando el segmento es el último capítulo
local END_SEEK_OFFSET = 5

local function seek_to_end_of_file()
    local file_duration = mp.get_property_number("duration")
    if not file_duration or file_duration <= 0 then return end
    local target = math.max(0, file_duration - END_SEEK_OFFSET)
    local position = mp.get_property_number("time-pos") or 0
    if position < target then
        mp.commandv("seek", tostring(target), "absolute", "exact")
    end
end

local function execute_seek(chapter_index)
    local chapters = mp.get_property_number("chapter-list/count")
    if not chapters then return end

    local to_chapter = chapter_index + 1

    if chapter_index >= chapters - 1 or to_chapter >= chapters then
        -- No quedan más capítulos: saltar a los últimos 5 segundos del vídeo
        seek_to_end_of_file()
    else
        local chapter_start = mp.get_property_number("chapter-list/" .. to_chapter .. "/time")
        local file_duration = mp.get_property_number("duration")

        if chapter_start and file_duration and chapter_start >= file_duration then
            -- El siguiente capítulo empieza más allá del final del archivo
            seek_to_end_of_file()
        else
            mp.set_property_number("chapter", to_chapter)
        end
    end
end

local function stop_fade()
    if fade_timer then
        fade_timer:kill()
        fade_timer = nil
    end
    fading_out = false
    fade_opacity = 1.0
end

-- Oculta el botón de forma inmediata (usado al pulsar, al cambiar de archivo, etc.)
local function hide_skip_button()
    if not button_visible then return end
    button_visible = false
    is_hovered = false
    is_pressed = false
    current_chapter_index = nil

    if button_timer then
        button_timer:kill()
        button_timer = nil
    end
    stop_fade()

    mp.remove_key_binding("op-ed-skip-click")
    if BUTTON_KEY and BUTTON_KEY ~= "" then
        mp.remove_key_binding("op-ed-skip-key")
    end
    if BUTTON_KEY_ALT and BUTTON_KEY_ALT ~= "" then
        mp.remove_key_binding("op-ed-skip-key-alt")
    end

    if overlay then
        overlay:remove()
    end
end

-- Oculta el botón con un desvanecimiento suave (fade out)
local function fade_out_skip_button()
    if not button_visible or fading_out then return end

    if not FADE_OUT_DURATION or FADE_OUT_DURATION <= 0 then
        hide_skip_button()
        return
    end

    if button_timer then
        button_timer:kill()
        button_timer = nil
    end

    fading_out = true
    local start_time = mp.get_time()

    fade_timer = mp.add_periodic_timer(1 / 60, function()
        local t = (mp.get_time() - start_time) / FADE_OUT_DURATION
        if t >= 1 then
            hide_skip_button()
            return
        end
        -- Curva ease-in-out (smoothstep) para un desvanecimiento natural
        local eased = t * t * (3 - 2 * t)
        fade_opacity = 1 - eased
        render_button()
    end)
end

local function trigger_skip()
    if not button_visible or current_chapter_index == nil then return end
    -- Durante el fade out solo se permite saltar si seguimos en el mismo capítulo
    if fading_out and mp.get_property_number("chapter") ~= current_chapter_index then return end
    local ch = current_chapter_index
    hide_skip_button()
    execute_seek(ch)
end

-- Crea un manejador de pulsación con estados down/up (binding "complex"):
--  * down : muestra el estado pulsado (gris medio)
--  * up   : ejecuta el salto (si es ratón, solo si se suelta encima del botón)
--  * press: (sin down/up separados) muestra el estado pulsado un instante y salta
local function make_press_handler(require_hover)
    return function(e)
        if not button_visible then return end
        local ev = e and e.event or "press"

        if ev == "down" then
            is_pressed = true
            render_button()
        elseif ev == "up" then
            if is_pressed and (not require_hover or is_hovered) then
                trigger_skip()
            else
                is_pressed = false
                render_button()
            end
        elseif ev == "press" then
            is_pressed = true
            render_button()
            mp.add_timeout(PRESS_FEEDBACK_TIME, function()
                if button_visible and is_pressed then
                    trigger_skip()
                end
            end)
        end
    end
end

local mouse_press_handler = make_press_handler(true)
local key_press_handler = make_press_handler(false)

local function on_mouse_move(_, mouse)
    if not button_visible or not mouse or not mouse.hover then
        if is_hovered then
            is_hovered = false
            is_pressed = false
            mp.remove_key_binding("op-ed-skip-click")
            render_button()
        end
        return
    end

    local bx, by, bw, bh = get_button_layout()
    local inside = (mouse.x >= bx and mouse.x <= bx + bw and mouse.y >= by and mouse.y <= by + bh)

    if inside ~= is_hovered then
        is_hovered = inside
        if is_hovered then
            mp.add_forced_key_binding("MBTN_LEFT", "op-ed-skip-click", mouse_press_handler, { complex = true })
        else
            -- Si se sale del botón con el ratón pulsado, se cancela la pulsación
            is_pressed = false
            mp.remove_key_binding("op-ed-skip-click")
        end
        render_button()
    end
end

local function show_skip_button(chapter_idx, label)
    if button_visible then
        hide_skip_button()
    end

    current_chapter_index = chapter_idx
    current_label = label or "Saltar Intro"
    button_visible = true
    is_hovered = false
    is_pressed = false
    stop_fade()

    local ow, oh = mp.get_osd_size()
    if ow and oh and ow > 0 and oh > 0 then
        screen_w = ow
        screen_h = oh
    end

    render_button()

    -- Asignar atajos de teclado mientras el botón está visible
    if BUTTON_KEY and BUTTON_KEY ~= "" then
        mp.add_forced_key_binding(BUTTON_KEY, "op-ed-skip-key", key_press_handler, { complex = true })
    end
    if BUTTON_KEY_ALT and BUTTON_KEY_ALT ~= "" and BUTTON_KEY_ALT ~= BUTTON_KEY then
        mp.add_forced_key_binding(BUTTON_KEY_ALT, "op-ed-skip-key-alt", key_press_handler, { complex = true })
    end

    -- Temporizador para ocultar el botón si el usuario decide no saltar
    if BUTTON_TIMEOUT and BUTTON_TIMEOUT > 0 then
        button_timer = mp.add_timeout(BUTTON_TIMEOUT, function()
            fade_out_skip_button()
        end)
    end
end

-- Observar cambios de resolución / dimensiones de ventana
mp.observe_property("osd-dimensions", "native", function(_, dims)
    if dims and dims.w and dims.h and dims.w > 0 and dims.h > 0 then
        screen_w = dims.w
        screen_h = dims.h
        if button_visible then
            render_button()
        end
    end
end)

-- Observar movimiento del ratón
mp.observe_property("mouse-pos", "native", on_mouse_move)

-- ====================================================================
-- Detección de Capítulos (OP / ED / PV)
-- ====================================================================

local function starts_with(str, start)
    return str:sub(1, #start) == start
end

local function ends_with(str, ending)
    return ending == "" or str:sub(-#ending) == ending
end

local function match_chapter(chapter_index)
    local raw_title = mp.get_property("chapter-list/" .. chapter_index .. "/title")
    if not raw_title then return false, nil, nil end
    local title = raw_title:lower():match("^%s*(.-)%s*$") -- limpiar espacios

    local function check_list(list)
        for _, pattern in ipairs(list) do
            if title == pattern then return true end
            if starts_with(title, pattern) then return true end
            if ends_with(title, pattern) then return true end
        end
        return false
    end

    if check_list(PATTERNS_OP) then
        return true, "OP", "Saltar Opening"
    elseif check_list(PATTERNS_ED) then
        return true, "ED", "Saltar Ending"
    elseif check_list(PATTERNS_PV) then
        return true, "PV", "Saltar Avance"
    end

    return false, nil, nil
end

local function get_chapter_length(chapter_index)
    local current_chapter_start = mp.get_property_number("chapter-list/" .. chapter_index .. "/time")
    if not current_chapter_start then return 0 end

    local chapter_count = mp.get_property_number("chapter-list/count")
    local last_chapter_index = (chapter_count or 1) - 1

    if chapter_index >= last_chapter_index then
        local file_duration = mp.get_property_number("duration") or 0
        return math.max(0, file_duration - current_chapter_start)
    else
        local next_chapter_start = mp.get_property_number("chapter-list/" .. chapter_index + 1 .. "/time") or 0
        return math.max(0, next_chapter_start - current_chapter_start)
    end
end

local function handle_chapter_entered(chapter_index)
    if BEHAVIOR == "off"
    or chapter_index == nil
    or chapter_index < 0
    then
        return
    end

    local is_match = false
    local seg_type = nil
    local seg_label = nil

    local name_match, matched_type, matched_label = match_chapter(chapter_index)
    local chapter_length = get_chapter_length(chapter_index)

    if REQUIRE_NAME_AND_DURATION then
        -- CONDICIÓN OBLIGATORIA: Deben cumplirse AMBAS:
        -- 1. Que coincida el nombre del capítulo (Opening / Ending / Preview)
        -- 2. Que la duración esté en el rango de 88 a 92 segundos (o 14-26s para Preview)
        if name_match then
            if (matched_type == "OP" or matched_type == "ED")
               and chapter_length >= OP_ED_THRESHOLD.from.value
               and chapter_length <= OP_ED_THRESHOLD.to.value
            then
                is_match = true
                seg_type = matched_type
                seg_label = matched_label
            elseif matched_type == "PV"
               and chapter_length >= PV_THRESHOLD.from.value
               and chapter_length <= PV_THRESHOLD.to.value
            then
                is_match = true
                seg_type = matched_type
                seg_label = matched_label
            end
        end
    else
        -- Modo permisivo (solo nombre o solo duración)
        if CURRENT_MODE == MODE_CHAPTER_NAME then
            is_match, seg_type, seg_label = name_match, matched_type, matched_label
        elseif CURRENT_MODE == MODE_CHAPTER_LENGTH then
            local chapter_count = mp.get_property_number("chapter-list/count")
            local last_chapter_index = (chapter_count or 1) - 1

            if (chapter_index <= 2 or chapter_index >= last_chapter_index - 2)
               and chapter_length >= OP_ED_THRESHOLD.from.value
               and chapter_length <= OP_ED_THRESHOLD.to.value
            then
                if chapter_index <= 2 then
                    is_match = true
                    seg_type = "OP"
                    seg_label = "Saltar Opening"
                else
                    is_match = true
                    seg_type = "ED"
                    seg_label = "Saltar Ending"
                end
            elseif chapter_index == last_chapter_index
               and chapter_length >= PV_THRESHOLD.from.value
               and chapter_length <= PV_THRESHOLD.to.value
            then
                is_match = true
                seg_type = "PV"
                seg_label = "Saltar Avance"
            end
        end
    end

    if is_match then
        if BEHAVIOR == "auto" then
            execute_seek(chapter_index)
        else -- BEHAVIOR == "button"
            show_skip_button(chapter_index, seg_label)
        end
    end

    PREV_CHAPTER = chapter_index
end

mp.observe_property("chapter", "number", function(_, chapter_index)
    -- Si el capítulo termina con el botón aún visible, desvanecerlo suavemente
    fade_out_skip_button()
    handle_chapter_entered(chapter_index)
end)

mp.observe_property("path", "none", function()
    hide_skip_button()
    PREV_CHAPTER = nil
end)

-- Detectar si los capítulos tienen nombres propios o solo números (Chapter 01...)
mp.observe_property("chapters", "number", function(_, chapter_count)
    if chapter_count == nil or chapter_count == 0 then return end

    local named_chapters = false
    for chapter_index = 0, chapter_count - 1 do
        local title = mp.get_property("chapter-list/" .. chapter_index .. "/title")
        if title and not starts_with(title, "Chapter ") and not starts_with(title, "chapter ") then
            named_chapters = true
            break
        end
    end

    if named_chapters and CURRENT_MODE ~= MODE_CHAPTER_NAME then
        CURRENT_MODE = MODE_CHAPTER_NAME
    elseif not named_chapters and CURRENT_MODE ~= MODE_CHAPTER_LENGTH then
        CURRENT_MODE = MODE_CHAPTER_LENGTH
    end
end)

-- ====================================================================
-- Menú OSD de Ajustes (Ctrl + Y)
-- ====================================================================

local function increment_from(t)
    if t.from.value == t.to.value - 1 then return end
    t.from.value = t.from.value + 1
end

local function decrement_from(t)
    if t.from.value == 0 then return end
    t.from.value = t.from.value - 1
end

local function increment_to(t)
    t.to.value = t.to.value + 1
end

local function decrement_to(t)
    if t.to.value == 0 or t.from.value == t.to.value - 1 then return end
    t.to.value = t.to.value - 1
end

function OP_ED_THRESHOLD.from:increment() increment_from(OP_ED_THRESHOLD) end
function OP_ED_THRESHOLD.from:decrement() decrement_from(OP_ED_THRESHOLD) end
function OP_ED_THRESHOLD.to:increment() increment_to(OP_ED_THRESHOLD) end
function OP_ED_THRESHOLD.to:decrement() decrement_to(OP_ED_THRESHOLD) end
function PV_THRESHOLD.from:increment() increment_from(PV_THRESHOLD) end
function PV_THRESHOLD.from:decrement() decrement_from(PV_THRESHOLD) end
function PV_THRESHOLD.to:increment() increment_to(PV_THRESHOLD) end
function PV_THRESHOLD.to:decrement() decrement_to(PV_THRESHOLD) end

local function draw_menu()
    local menu = {
        { name = "Ajustes Skip OP/ED/PV", items = {} }
    }

    -- Item 1: Comportamiento
    local behavior_str = "- Modo: "
    if BEHAVIOR == "button" then
        behavior_str = behavior_str .. "{\\b1}[Botón visual]{\\b0} | Auto | Desactivado"
    elseif BEHAVIOR == "auto" then
        behavior_str = behavior_str .. "Botón | {\\b1}[Auto-skip]{\\b0} | Desactivado"
    else
        behavior_str = behavior_str .. "Botón | Auto | {\\b1}[Desactivado]{\\b0}"
    end
    table.insert(menu[1].items, behavior_str)

    local function bool_to_int(b) return b and 1 or 0 end
    if REQUIRE_NAME_AND_DURATION then
        table.insert(menu[1].items, "- Requisito: {\\b1}Nombre + Duración (ambas){\\b0}")
        table.insert(menu, { name = "Umbrales de duración", items = {
            string.format(
                "- OP/ED: {\\b%i}%i{\\b0}-{\\b%i}%i{\\b0} seg",
                bool_to_int(OP_ED_THRESHOLD.from.selected), OP_ED_THRESHOLD.from.value,
                bool_to_int(OP_ED_THRESHOLD.to.selected), OP_ED_THRESHOLD.to.value
            ),
            string.format(
                "- PV: {\\b%i}%i{\\b0}-{\\b%i}%i{\\b0} seg",
                bool_to_int(PV_THRESHOLD.from.selected), PV_THRESHOLD.from.value,
                bool_to_int(PV_THRESHOLD.to.selected), PV_THRESHOLD.to.value
            )
        }})
    elseif CURRENT_MODE == MODE_CHAPTER_NAME then
        table.insert(menu[1].items, "- Detección: {\\b1}Nombre capítulo{\\b0} | Duración")
    else
        table.insert(menu[1].items, "- Detección: Nombre capítulo | {\\b1}Duración{\\b0}")

        table.insert(menu, { name = "Umbrales de duración", items = {
            string.format(
                "- OP/ED: {\\b%i}%i{\\b0}-{\\b%i}%i{\\b0} seg",
                bool_to_int(OP_ED_THRESHOLD.from.selected), OP_ED_THRESHOLD.from.value,
                bool_to_int(OP_ED_THRESHOLD.to.selected), OP_ED_THRESHOLD.to.value
            ),
            string.format(
                "- PV: {\\b%i}%i{\\b0}-{\\b%i}%i{\\b0} seg",
                bool_to_int(PV_THRESHOLD.from.selected), PV_THRESHOLD.from.value,
                bool_to_int(PV_THRESHOLD.to.selected), PV_THRESHOLD.to.value
            )
        }})
    end

    local ass = ""
    local row_offset = 0
    for _, section in ipairs(menu) do
        ass = ass .. "{\\b1}" .. section.name .. "{\\b0}\\N"
        for i, item in ipairs(section.items) do
            if row_offset + i == SELECTED_MENU_ROW then
                ass = ass .. "{\\c&H46CFFF&}" .. item .. "{\\c&HFFFFFF&}\\N"
            else
                ass = ass .. item .. "\\N"
            end
        end
        row_offset = row_offset + #section.items
    end

    mp.set_osd_ass(0, 0, ass)
end

local function hide_menu()
    MENU = false
    mp.set_osd_ass(0, 0, "")
    mp.remove_key_binding("op-ed-pv-skip-menu-up")
    mp.remove_key_binding("op-ed-pv-skip-menu-down")
    mp.remove_key_binding("op-ed-pv-skip-menu-left")
    mp.remove_key_binding("op-ed-pv-skip-menu-right")
    mp.remove_key_binding("op-ed-pv-skip-menu-esc")
end

mp.add_key_binding(MENU_KEYBIND, 'op-ed-pv-skip-settings', function()
    if not MENU then
        MENU = true
        draw_menu()

        mp.add_forced_key_binding("UP", "op-ed-pv-skip-menu-up", function()
            if SELECTED_MENU_ROW <= 1 then return
            elseif SELECTED_MENU_ROW == 3 and SELECTED_MENU_COL == 2 then OP_ED_THRESHOLD.from.increment()
            elseif SELECTED_MENU_ROW == 3 and SELECTED_MENU_COL == 3 then OP_ED_THRESHOLD.to.increment()
            elseif SELECTED_MENU_ROW == 4 and SELECTED_MENU_COL == 2 then PV_THRESHOLD.from.increment()
            elseif SELECTED_MENU_ROW == 4 and SELECTED_MENU_COL == 3 then PV_THRESHOLD.to.increment()
            else SELECTED_MENU_ROW = SELECTED_MENU_ROW - 1 end
            draw_menu()
        end, {repeatable=true})

        mp.add_forced_key_binding("DOWN", "op-ed-pv-skip-menu-down", function()
            if not REQUIRE_NAME_AND_DURATION and CURRENT_MODE == MODE_CHAPTER_NAME and SELECTED_MENU_ROW >= 2 then return
            elseif SELECTED_MENU_ROW == 3 and SELECTED_MENU_COL == 2 then OP_ED_THRESHOLD.from.decrement()
            elseif SELECTED_MENU_ROW == 3 and SELECTED_MENU_COL == 3 then OP_ED_THRESHOLD.to.decrement()
            elseif SELECTED_MENU_ROW == 4 and SELECTED_MENU_COL == 2 then PV_THRESHOLD.from.decrement()
            elseif SELECTED_MENU_ROW == 4 and SELECTED_MENU_COL == 3 then PV_THRESHOLD.to.decrement()
            elseif SELECTED_MENU_ROW >= 4 then return
            else SELECTED_MENU_ROW = SELECTED_MENU_ROW + 1 end
            draw_menu()
        end, {repeatable=true})

        mp.add_forced_key_binding("LEFT", "op-ed-pv-skip-menu-left", function()
            if SELECTED_MENU_ROW == 1 then
                if BEHAVIOR == "off" then BEHAVIOR = "auto"
                elseif BEHAVIOR == "auto" then BEHAVIOR = "button" end
            elseif SELECTED_MENU_ROW == 2 then
                CURRENT_MODE = MODE_CHAPTER_NAME
            elseif SELECTED_MENU_ROW == 3 and SELECTED_MENU_COL == 2 then
                OP_ED_THRESHOLD.from.selected = false; SELECTED_MENU_COL = 1
            elseif SELECTED_MENU_ROW == 3 and SELECTED_MENU_COL == 3 then
                OP_ED_THRESHOLD.from.selected = true; OP_ED_THRESHOLD.to.selected = false; SELECTED_MENU_COL = 2
            elseif SELECTED_MENU_ROW == 4 and SELECTED_MENU_COL == 2 then
                PV_THRESHOLD.from.selected = false; SELECTED_MENU_COL = 1
            elseif SELECTED_MENU_ROW == 4 and SELECTED_MENU_COL == 3 then
                PV_THRESHOLD.from.selected = true; PV_THRESHOLD.to.selected = false; SELECTED_MENU_COL = 2
            end
            draw_menu()
        end)

        mp.add_forced_key_binding("RIGHT", "op-ed-pv-skip-menu-right", function()
            if SELECTED_MENU_ROW == 1 then
                if BEHAVIOR == "button" then BEHAVIOR = "auto"
                elseif BEHAVIOR == "auto" then BEHAVIOR = "off" end
            elseif SELECTED_MENU_ROW == 2 then
                CURRENT_MODE = MODE_CHAPTER_LENGTH
            elseif SELECTED_MENU_ROW == 3 and SELECTED_MENU_COL == 1 then
                OP_ED_THRESHOLD.from.selected = true; SELECTED_MENU_COL = 2
            elseif SELECTED_MENU_ROW == 3 and SELECTED_MENU_COL == 2 then
                OP_ED_THRESHOLD.from.selected = false; OP_ED_THRESHOLD.to.selected = true; SELECTED_MENU_COL = 3
            elseif SELECTED_MENU_ROW == 4 and SELECTED_MENU_COL == 1 then
                PV_THRESHOLD.from.selected = true; SELECTED_MENU_COL = 2
            elseif SELECTED_MENU_ROW == 4 and SELECTED_MENU_COL == 2 then
                PV_THRESHOLD.from.selected = false; PV_THRESHOLD.to.selected = true; SELECTED_MENU_COL = 3
            end
            draw_menu()
        end)

        mp.add_forced_key_binding("ESC", "op-ed-pv-skip-menu-esc", function()
            hide_menu()
        end)
    else
        hide_menu()
    end
end)
