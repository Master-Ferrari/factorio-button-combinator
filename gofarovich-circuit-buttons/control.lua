local SP = require("__gglib__.signal_picker")  -- общий пикер из мода-библиотеки gglib
local SB = require("__gglib__.signal_button")  -- слот-кнопка операнда (открывает пикер) из gglib
local CS = require("__gglib__.connection_status")  -- панель «Connected to» из gglib

local NAMES = { ["gofarovich-bc-pulse"] = true, ["gofarovich-bc-switch"] = true }
local GUI_NAME = "gofarovich-bc-btn-gui"
local CLOSE_NAME = "gofarovich-bc-close"
local DESC_BTN = "gofarovich-bc-desc-btn"
local DESC_EDIT_FRAME = "gofarovich-bc-desc-edit"
local DESC_BOX = "gofarovich-bc-desc-box"
local DESC_SAVE = "gofarovich-bc-desc-save"
local DESC_CANCEL = "gofarovich-bc-desc-cancel"
local DESC_EMOJI = "gofarovich-bc-desc-emoji"
-- Pulse-length operand slot: a single slot (signal OR constant), opening our picker
-- — same widget as a condition's right operand.
local DURATION_NAME = "gofarovich-bc-duration"
local BACK_NAME = "gofarovich-bc-back"
-- Левый операнд + компаратор остаются нативными; правый операнд (EN_OP/DIS_OP) — слот,
-- открывающий наш пикер (сигнал ИЛИ константа).
local EN_SIG, EN_CMP, EN_OP = "gofarovich-bc-en-sig", "gofarovich-bc-en-cmp", "gofarovich-bc-en-op"
local DIS_SIG, DIS_CMP, DIS_OP = "gofarovich-bc-dis-sig", "gofarovich-bc-dis-cmp", "gofarovich-bc-dis-op"
local COMPARATORS = { "<", ">", "=", "≥", "≤", "≠" }

-- Подложка условия (как у условий рельса): обычная рамка vs «выполнено». Меняем
-- заливку живьём в on_tick, пока окно открыто.
local FRAME_NORMAL = "decider_combinator_frame"
local FRAME_LIT    = "gofarovich-bc-cond-fulfilled-frame"

local function init_storage()
  storage.buttons = storage.buttons or {}
  storage.pending = storage.pending or {}
  storage.open_gui = storage.open_gui or {}
  storage.auto = storage.auto or {} -- unit_number -> true, for back-signal buttons
  storage.cond_frames = storage.cond_frames or {} -- player.index -> { unit, rows } (живая подсветка)
  storage.undo_stash = storage.undo_stash or {} -- "surface:name:x:y" -> настройки снесённых кнопок (для undo/redo)
end

script.on_init(init_storage)

local function register(entity)
  local data = {
    entity = entity,
    -- default to the green check signal (a fresh table per button, not shared)
    active_signal = { type = "virtual", name = "signal-check" },
    active_count = 1,
    inactive_signal = nil,
    inactive_count = 1,
    -- pulse length in ticks (pulse button): signal-or-constant, like a condition's
    -- right operand. In signal mode the length is read live from the circuit network.
    duration = { use_signal = false, second_signal = nil, constant = 1 },
    state = false,
    auto = false, -- back-signal: drive state from circuit conditions
    enable_cond  = { signal = nil, comparator = "=", use_signal = false, second_signal = nil, constant = 0 },
    disable_cond = { signal = nil, comparator = "=", use_signal = false, second_signal = nil, constant = 0 },
  }
  storage.buttons[entity.unit_number] = data
  return data
end

local function set_auto_tracking(data)
  storage.auto[data.entity.unit_number] = data.auto or nil
end

local function get_data(entity)
  return storage.buttons[entity.unit_number] or register(entity)
end

local DIR = defines.direction

-- Direction encodes (side, on/off) to match data.lua SPRITES:
--   north = front-off   east = front-on   south = back-off   west = back-on
local function is_button_face(entity)
  return entity.direction == DIR.north or entity.direction == DIR.east
end

local function face_dir(front, on)
  if front then return on and DIR.east or DIR.north end
  return on and DIR.west or DIR.south
end

-- Back-signal condition evaluation: read the merged red+green network value for a
-- signal and compare it against a constant.
local RED, GREEN = defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green

local function net_value(entity, signal)
  if not (signal and signal.name) then return 0 end
  local total = 0
  local r = entity.get_circuit_network(RED)
  if r then total = total + r.get_signal(signal) end
  local g = entity.get_circuit_network(GREEN)
  if g then total = total + g.get_signal(signal) end
  return total
end

-- Normalise a duration that may be an old plain-number value (pre-signal-input
-- versions and old blueprints) into the signal-or-constant table form.
local function norm_duration(d)
  if type(d) == "number" then
    return { use_signal = false, second_signal = nil, constant = math.max(1, math.floor(d)) }
  end
  return d or { use_signal = false, second_signal = nil, constant = 1 }
end

-- Effective pulse length in ticks: live network value in signal mode, else the
-- constant. Always at least 1 tick.
local function pulse_duration(data, entity)
  local d = data.duration
  local v
  if d.use_signal and d.second_signal and d.second_signal.name then
    v = net_value(entity, d.second_signal)
  else
    v = d.constant or 1
  end
  return math.max(1, math.floor(v))
end

local CMP = {
  ["<"] = function(a, b) return a < b end,
  [">"] = function(a, b) return a > b end,
  ["="] = function(a, b) return a == b end,
  ["≥"] = function(a, b) return a >= b end,
  ["≤"] = function(a, b) return a <= b end,
  ["≠"] = function(a, b) return a ~= b end,
}

local function eval_cond(entity, cond)
  if not (cond and cond.signal and cond.signal.name) then return false end
  local f = CMP[cond.comparator or "="]
  if not f then return false end
  local left = net_value(entity, cond.signal)
  -- right operand: signal value in signal mode, else the constant
  local right
  if cond.use_signal and cond.second_signal and cond.second_signal.name then
    right = net_value(entity, cond.second_signal)
  else
    right = cond.constant or 0
  end
  return f(left, right)
end

-- A back-signal button is locked to manual input while a condition is currently met.
local function is_locked(data)
  if not data.auto then return false end
  return eval_cond(data.entity, data.enable_cond) or eval_cond(data.entity, data.disable_cond)
end

-- SignalID leaves `type` out for plain items, so a missing type means "item",
-- never "virtual" -- defaulting it the other way makes set_slot reject every item
-- signal outright ("Unknown virtual-signal name: gun-turret").
local function signal_type(signal)
  return signal.type or "item"
end

local function signal_value(signal)
  return { type = signal_type(signal), name = signal.name, quality = signal.quality or "normal" }
end

-- Blueprint parametrisation ("parameter-0" & co) is the engine's job, and the
-- engine only rewrites fields it knows: for a constant combinator, its filters.
-- Every signal a player picks here lives in our own storage and rides blueprints
-- inside the `cb` tag, which the engine never looks at -- so none of these signals
-- ever reached the parameter dialog.
--
-- Fix: while a blueprint is being taken, copy each picked signal into an extra
-- combinator section of the BLUEPRINT ENTITY (see mirror_into). Those sections
-- exist in blueprint data only; on_built reads the substituted signals out of them
-- and strips them off the real entity before the tick ends, so a live button still
-- has exactly one section and never emits anything extra.
--
-- One section per signal, deliberately: a section cannot hold the same signal
-- twice, and two pickers may well point at the same one.
local MIRROR_SLOTS = {
  -- The filter's count carries which picker it belongs to, so the read side does
  -- not depend on section order surviving the round trip. Append, never reshuffle.
  { get = function(d) return d.active_signal end,
    set = function(d, signal) d.active_signal = signal end },
  { get = function(d) return d.inactive_signal end,
    set = function(d, signal) d.inactive_signal = signal end },
  { get = function(d) return d.enable_cond and d.enable_cond.signal end,
    set = function(d, signal) d.enable_cond.signal = signal end },
  { get = function(d) return d.enable_cond and d.enable_cond.use_signal and d.enable_cond.second_signal or nil end,
    set = function(d, signal) d.enable_cond.second_signal = signal end },
  { get = function(d) return d.disable_cond and d.disable_cond.signal end,
    set = function(d, signal) d.disable_cond.signal = signal end },
  { get = function(d) return d.disable_cond and d.disable_cond.use_signal and d.disable_cond.second_signal or nil end,
    set = function(d, signal) d.disable_cond.second_signal = signal end },
}

local function set_output(data)
  local cb = data.entity.get_or_create_control_behavior()
  local section = cb.get_section(1) or cb.add_section()
  local signal = data.state and data.active_signal or data.inactive_signal
  local count = data.state and (data.active_count or 1) or (data.inactive_count or 1)
  if signal and signal.name then
    section.set_slot(1, {
      value = signal_value(signal),
      min = count, -- constant-combinator outputs this count
    })
  else
    section.clear_slot(1)
  end
end

-- Rotate the entity so its static sprite reflects the current (side, state).
local function apply_visual(data)
  local entity = data.entity
  entity.direction = face_dir(is_button_face(entity), data.state)
end

-- After a mod update, re-sync each button's facing to its stored state
-- (the direction<->state encoding may have changed).
script.on_configuration_changed(function()
  init_storage()
  storage.auto = {}
  for unit_number, data in pairs(storage.buttons) do
    if data.entity and data.entity.valid then
      -- back-fill fields added in newer versions
      data.active_count = data.active_count or 1
      data.inactive_count = data.inactive_count or 1
      data.enable_cond = data.enable_cond or { signal = nil, comparator = "=", use_signal = false, second_signal = nil, constant = 0 }
      data.disable_cond = data.disable_cond or { signal = nil, comparator = "=", use_signal = false, second_signal = nil, constant = 0 }
      data.duration = norm_duration(data.duration)
      data.auto = data.auto or false
      if data.auto then storage.auto[unit_number] = true end
      apply_visual(data)
    else
      storage.buttons[unit_number] = nil
    end
  end
end)

local function set_state(data, state, sound)
  if data.state == state then return end
  data.state = state
  apply_visual(data)
  set_output(data)
  if sound then
    data.entity.surface.play_sound{ path = sound, position = data.entity.position }
  end
end

-- Arm the auto-release `ticks` from now. off_tick tracks the latest scheduled end,
-- so releases queued by an earlier press are ignored when a re-press extends it.
local function schedule_release(data, ticks)
  local off = game.tick + math.max(1, math.floor(ticks or 1))
  data.off_tick = off
  storage.pending[off] = storage.pending[off] or {}
  table.insert(storage.pending[off], data.entity.unit_number)
end

-- Click emits the active signal for `duration` ticks, then auto-releases.
-- (Mouse-up is not exposed by the Factorio API, so a true "hold while pressed"
-- is impossible; a self-extinguishing timed pulse is the practical equivalent.)
-- Re-pressing during a pulse restarts it.
local function press_pulse(data)
  schedule_release(data, pulse_duration(data, data.entity))
  set_state(data, true, "gofarovich-bc-press")
end

local function press_switch(data)
  set_state(data, not data.state, data.state and "gofarovich-bc-release" or "gofarovich-bc-press")
end

-- Заливка панели условия: обычная / «выполнено». Смена named-style сбрасывает
-- свойства стиля — переустанавливаем растяжку и паддинг.
local function apply_cond_frame(panel, lit)
  panel.style = lit and FRAME_LIT or FRAME_NORMAL
  panel.style.horizontally_stretchable = true
  -- максимально компактная рамка условия: без внутренних отступов и зазоров.
  -- свойства переустанавливаем здесь, т.к. смена стиля при подсветке их сбрасывает.
  panel.style.padding = 0
  panel.style.bottom_margin = 0
end

-- Живая подсветка панелей условий у открытых окон: активная подложка, пока условие
-- выполняется (как у условий рельса).
local function update_cond_frames()
  for pi, st in pairs(storage.cond_frames) do
    local data = storage.buttons[st.unit]
    if data and data.entity.valid and data.auto then
      for _, r in ipairs(st.rows) do
        if r.panel and r.panel.valid then
          local cond = (r.which == "enable") and data.enable_cond or data.disable_cond
          local lit = eval_cond(data.entity, cond)
          if lit ~= r.lit then
            apply_cond_frame(r.panel, lit)
            r.lit = lit
          end
        end
      end
    else
      storage.cond_frames[pi] = nil
    end
  end
end

script.on_event(defines.events.on_tick, function(event)
  -- scheduled pulse auto-releases
  local list = storage.pending[event.tick]
  if list then
    storage.pending[event.tick] = nil
    for _, unit_number in pairs(list) do
      local data = storage.buttons[unit_number]
      -- Only release if this is the latest scheduled end (re-press extends off_tick).
      if data and data.entity.valid and data.off_tick and event.tick >= data.off_tick then
        data.off_tick = nil
        set_state(data, false, "gofarovich-bc-release")
      end
    end
  end

  -- back-signal: drive state from circuit conditions (silent)
  for unit_number in pairs(storage.auto) do
    local data = storage.buttons[unit_number]
    if data and data.entity.valid and data.auto then
      local e = eval_cond(data.entity, data.enable_cond)
      local d = eval_cond(data.entity, data.disable_cond)
      -- both met -> locked, no change; otherwise the matching condition drives it
      -- (same press/release sound as a manual interaction)
      if e and not d then
        set_state(data, true, "gofarovich-bc-press")
      elseif d and not e then
        set_state(data, false, "gofarovich-bc-release")
      end
    else
      storage.auto[unit_number] = nil
    end
  end

  -- Закрываем окно, если игрок отошёл от кнопки слишком далеко (как ванильные окна).
  for player_index, unit_number in pairs(storage.open_gui) do
    local player = game.get_player(player_index)
    local data = storage.buttons[unit_number]
    if not (player and data and data.entity.valid) then
      if player then player.opened = nil end
    else
      local p, e = player.position, data.entity.position
      local dx, dy = p.x - e.x, p.y - e.y
      local max = player.reach_distance + 4
      if player.surface ~= data.entity.surface or (dx * dx + dy * dy) > max * max then
        player.opened = nil -- триггерит on_gui_closed → окно уничтожается
      end
    end
  end

  update_cond_frames()
end)

local function cmp_index(comparator)
  for i, c in ipairs(COMPARATORS) do
    if c == comparator then return i end
  end
  return 3 -- "="
end

-- Правый операнд = ОДИН слот (сигнал со значком качества ИЛИ константа-число),
-- собранный gglib-кнопкой signal_button. Клик по ней (через SB.on_click) открывает
-- наш пикер; результат приходит в SP.set_on_pick по `target`.
--   cond  — таблица { use_signal, second_signal, constant } (условие или data.duration).
--   target — что вернётся в on_pick ({ unit, cond = "enable"|"disable"|"duration" }).
--   extra — доп. опции пикера (allow_constant / allow_wildcards / constant_only).
local function add_operand_slot(row, op_name, cond, target, extra)
  local opts = {
    target = target,
    name = op_name,
    size = 40,
    value = { use_signal = cond.use_signal, signal = cond.second_signal, constant = cond.constant },
  }
  if extra then for k, v in pairs(extra) do opts[k] = v end end
  return SB.build(row, opts)
end

-- One condition as its own panel: [label] over [signal] [comparator] [right operand slot].
-- Подложка — как у условий рельса (decider_combinator_frame), активная при выполнении.
local function add_condition_row(parent, label_key, sig_name, cmp_name, op_name, cond, lit, target)
  local panel = parent.add{ type = "frame", style = FRAME_NORMAL, direction = "vertical" }
  apply_cond_frame(panel, lit)
  local row = panel.add{ type = "flow", direction = "horizontal" }
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 6
  row.style.horizontally_stretchable = true
  local cap = row.add{ type = "label", style = "caption_label", caption = { label_key } }
  cap.style.left_margin = 4
  -- название слева, условие притянуто к правому краю
  local filler = row.add{ type = "empty-widget" }
  filler.style.horizontally_stretchable = true
  row.add{ type = "choose-elem-button", name = sig_name, elem_type = "signal", signal = cond.signal }
  local dd = row.add{ type = "drop-down", name = cmp_name, items = COMPARATORS, selected_index = cmp_index(cond.comparator) }
  dd.style.width = 52
  add_operand_slot(row, op_name, cond, target, { allow_constant = true, allow_wildcards = false })
  return panel
end

-- Rich-text tag for inserting a signal/icon into the description text.
local function signal_richtext(sig)
  if not (sig and sig.name) then return "" end
  local t = sig.type or "item"
  if t == "virtual" then return "[virtual-signal=" .. sig.name .. "]" end
  return "[" .. t .. "=" .. sig.name .. "]"
end

local function open_gui(player, data)
  local old = player.gui.screen[GUI_NAME]
  if old then old.destroy() end

  local frame = player.gui.screen.add{
    type = "frame",
    name = GUI_NAME,
    direction = "vertical",
  }
  frame.auto_center = true

  -- Canonical titlebar: title + draggable filler + close button
  local titlebar = frame.add{ type = "flow", direction = "horizontal" }
  titlebar.drag_target = frame
  titlebar.add{
    type = "label",
    style = "frame_title",
    caption = { "entity-name." .. data.entity.name },
    ignored_by_interaction = true,
  }
  local filler = titlebar.add{ type = "empty-widget", style = "draggable_space_header" }
  filler.style.height = 24
  filler.style.horizontally_stretchable = true
  filler.style.right_margin = 4
  filler.drag_target = frame
  titlebar.add{
    type = "sprite-button",
    name = CLOSE_NAME,
    style = "frame_action_button",
    sprite = "utility/close",
    hovered_sprite = "utility/close_black",
    clicked_sprite = "utility/close",
    tooltip = { "gui.close" },
  }

  -- Content frame, vanilla entity-GUI style
  local content = frame.add{
    type = "frame",
    style = "entity_frame",
    direction = "vertical",
  }

  -- "Connected to" at the top of the content frame, hugging its top & side edges
  -- (negative margins cancel the entity_frame's inner padding; only a bottom gap remains).
  local cs_bar = CS.add(content, data.entity, {
    mode  = "single",
    red   = defines.wire_connector_id.combinator_input_red,
    green = defines.wire_connector_id.combinator_input_green,
  })
  cs_bar.style.top_margin = -12
  cs_bar.style.left_margin = -12
  cs_bar.style.right_margin = -12
  cs_bar.style.bottom_margin = 8

  -- Status line (lamp + "Working"), like vanilla machine windows
  local status = content.add{ type = "flow", direction = "horizontal" }
  status.style.vertical_align = "center"
  local lamp = status.add{ type = "sprite", sprite = "utility/status_working" }
  lamp.style.size = 16
  lamp.style.right_margin = 4
  status.add{ type = "label", caption = { "entity-status.working" } }

  -- Live entity preview, like vanilla entity windows
  local preview_frame = content.add{ type = "frame", style = "deep_frame_in_shallow_frame" }
  preview_frame.style.top_margin = 4
  local preview = preview_frame.add{ type = "entity-preview" }
  preview.style.horizontally_stretchable = true
  preview.style.height = 120
  preview.entity = data.entity

  content.add{ type = "line" }.style.margin = 4

  -- Signals
  local tbl = content.add{ type = "table", name = "tbl", column_count = 2 }
  tbl.style.horizontally_stretchable = true
  -- Подписи слева тянутся, прижимая инпуты ко второму столбцу — к правому краю.
  -- active/idle outputs: a signal AND a count (e.g. send -60 tanks while pressed),
  -- via gglib's with_count picker. Result comes back through SP.set_on_pick by target.slot.
  tbl.add{ type = "label", caption = { "gofarovich-bc-gui.active-signal" } }.style.horizontally_stretchable = true
  SB.build(tbl, {
    target = { unit = data.entity.unit_number, slot = "active" },
    value = { use_signal = true, signal = data.active_signal, count = data.active_count or 1 },
    with_count = true,
  })
  tbl.add{ type = "label", caption = { "gofarovich-bc-gui.inactive-signal" } }.style.horizontally_stretchable = true
  SB.build(tbl, {
    target = { unit = data.entity.unit_number, slot = "inactive" },
    value = { use_signal = true, signal = data.inactive_signal, count = data.inactive_count or 1 },
    with_count = true,
  })

  if data.entity.name == "gofarovich-bc-pulse" then
    tbl.add{ type = "label", caption = { "gofarovich-bc-gui.duration" }, tooltip = { "gofarovich-bc-gui.duration-tt" } }.style.horizontally_stretchable = true
    data.duration = norm_duration(data.duration)
    add_operand_slot(tbl, DURATION_NAME, data.duration,
      { unit = data.entity.unit_number, cond = "duration" }, { constant_only = true })
  end

  content.add{ type = "line" }.style.margin = 4

  -- Back-signal: drive the button's state from circuit conditions. Тултип — на
  -- значке (?) справа от подписи, а не на самой подписи/чекбоксе.
  local back_flow = content.add{ type = "flow", direction = "horizontal" }
  back_flow.style.vertical_align = "center"
  back_flow.add{
    type = "checkbox",
    name = BACK_NAME,
    caption = { "gofarovich-bc-gui.back-signal" },
    state = data.auto,
  }
  local help = back_flow.add{
    type = "sprite", sprite = "info", tooltip = { "gofarovich-bc-gui.back-signal-tt" },
  }
  help.style.size = 16
  help.style.left_margin = 4
  storage.cond_frames[player.index] = nil
  if data.auto then
    -- Common panel that holds each condition in its own sub-panel.
    local conds = content.add{ type = "frame", style = "deep_frame_in_shallow_frame", direction = "vertical" }
    conds.style.top_margin = 4
    conds.style.padding = 0
    conds.style.horizontally_stretchable = true
    local en_panel = add_condition_row(conds, "gofarovich-bc-gui.enable-cond", EN_SIG, EN_CMP, EN_OP,
      data.enable_cond, eval_cond(data.entity, data.enable_cond),
      { unit = data.entity.unit_number, cond = "enable" })
    local dis_panel = add_condition_row(conds, "gofarovich-bc-gui.disable-cond", DIS_SIG, DIS_CMP, DIS_OP,
      data.disable_cond, eval_cond(data.entity, data.disable_cond),
      { unit = data.entity.unit_number, cond = "disable" })
    storage.cond_frames[player.index] = { unit = data.entity.unit_number, rows = {
      { panel = en_panel, which = "enable", lit = false },
      { panel = dis_panel, which = "disable", lit = false },
    } }
  end

  -- Description at the bottom, under a separator. When set: a "Description" header
  -- with a pencil-edit button, and the text shown below it (like vanilla).
  -- разделитель над описанием скрываем, когда раскрыты условия фидбека
  if not data.auto then
    content.add{ type = "line" }.style.margin = 4
  end
  local desc = data.entity.combinator_description
  if desc and desc ~= "" then
    local head = content.add{ type = "flow", direction = "horizontal" }
    head.style.vertical_align = "center"
    head.add{ type = "label", style = "caption_label", caption = { "gofarovich-bc-gui.description" } }
    local pencil = head.add{
      type = "sprite-button", name = DESC_BTN, style = "mini_button",
      sprite = "utility/rename_icon", tooltip = { "gofarovich-bc-gui.edit-description" },
    }
    pencil.style.left_margin = 4
    local text = content.add{ type = "label", caption = desc }
    text.style.single_line = false
    text.style.maximal_width = 280
    text.style.top_margin = 2
  else
    content.add{ type = "button", name = DESC_BTN, caption = { "gofarovich-bc-gui.add-description" } }
  end

  storage.open_gui[player.index] = data.entity.unit_number
  player.opened = frame
end

-- Результат пикера → правый операнд условия (target.cond = "enable"|"disable").
SP.set_on_pick(function(player, target, result, changed)
  local data = storage.buttons[target.unit]
  if not (data and data.entity.valid) then return end
  -- active/idle output slots: signal + count
  if target.slot then
    if changed then
      local sig = result and result.signal
      local count = math.floor((result and result.count) or 1)
      if target.slot == "active" then
        data.active_signal = sig
        data.active_count = count
      else
        data.inactive_signal = sig
        data.inactive_count = count
      end
      set_output(data)
    end
    open_gui(player, data)
    return
  end
  if changed and target.cond == "duration" then
    -- только число: константа → длина импульса (минимум 1 тик)
    local n = (result and result.constant) or 1
    data.duration = { use_signal = false, second_signal = nil, constant = math.max(1, math.floor(n)) }
    open_gui(player, data)
    return
  end
  if changed then
    local cond = (target.cond == "enable") and data.enable_cond or data.disable_cond
    if result and result.constant ~= nil then
      cond.use_signal = false
      cond.constant = math.floor(result.constant)
    elseif result and result.signal then
      cond.use_signal = true
      cond.second_signal = result.signal
    else  -- очистить → константа 0
      cond.use_signal = false
      cond.constant = 0
    end
  end
  open_gui(player, data)  -- переоткрыть окно кнопки (и после выбора, и после cancel)
end)

-- Separate "Edit description" dialog, opened from the description button.
local function open_desc_editor(player, data)
  local old = player.gui.screen[DESC_EDIT_FRAME]
  if old then old.destroy() end

  local frame = player.gui.screen.add{ type = "frame", name = DESC_EDIT_FRAME, direction = "vertical" }
  frame.auto_center = true

  local titlebar = frame.add{ type = "flow", direction = "horizontal" }
  titlebar.drag_target = frame
  titlebar.add{ type = "label", style = "frame_title", caption = { "gofarovich-bc-gui.edit-description" }, ignored_by_interaction = true }
  local filler = titlebar.add{ type = "empty-widget", style = "draggable_space_header" }
  filler.style.height = 24
  filler.style.horizontally_stretchable = true
  filler.style.right_margin = 4
  filler.drag_target = frame
  titlebar.add{
    type = "sprite-button", name = DESC_CANCEL, style = "frame_action_button",
    sprite = "utility/close", hovered_sprite = "utility/close_black", clicked_sprite = "utility/close",
    tooltip = { "gui.close" },
  }

  local body = frame.add{ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" }
  local box = body.add{ type = "text-box", name = DESC_BOX, text = data.entity.combinator_description or "" }
  box.style.width = 400
  box.style.height = 150
  box.focus()

  local bottom = frame.add{ type = "flow", direction = "horizontal" }
  bottom.style.top_margin = 8
  bottom.style.vertical_align = "center"
  -- signal/icon picker: inserts a rich-text tag into the description
  local emoji_label = bottom.add{ type = "label", caption = { "gofarovich-bc-gui.insert-icon" } }
  emoji_label.style.right_margin = 6
  bottom.add{
    type = "choose-elem-button", name = DESC_EMOJI, elem_type = "signal",
    tooltip = { "gofarovich-bc-gui.insert-icon-tt" },
  }
  local b_filler = bottom.add{ type = "empty-widget" }
  b_filler.style.horizontally_stretchable = true
  bottom.add{ type = "button", name = DESC_SAVE, style = "confirm_button", caption = { "gofarovich-bc-gui.save-description" } }
  -- NB: do NOT set player.opened here; that would fire the main window's
  -- on_gui_closed and wipe storage.open_gui, breaking Save/Cancel.
end

script.on_event(defines.events.on_gui_opened, function(event)
  if event.gui_type ~= defines.gui_type.entity then return end
  local entity = event.entity
  if not (entity and entity.valid) then return end
  -- A ghost keeps its real name in ghost_name, so the check below never matched it
  -- and the player got the raw constant-combinator window. Nothing there is ours to
  -- show (least of all the blueprint mirror sections), so just close it.
  if entity.name == "entity-ghost" and NAMES[entity.ghost_name] then
    game.get_player(event.player_index).opened = nil
    return
  end
  if not NAMES[entity.name] then return end
  local player = game.get_player(event.player_index)
  player.opened = nil
  local data = get_data(entity)
  if is_button_face(entity) then
    if is_locked(data) then
      -- a condition is currently driving the button; reject manual input
      entity.surface.play_sound{ path = "gofarovich-bc-locked", position = entity.position }
    elseif entity.name == "gofarovich-bc-pulse" then
      press_pulse(data)
    else
      press_switch(data)
    end
  else
    open_gui(player, data)
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  if SP.on_closed(event) then return end
  local element = event.element
  if not (element and element.valid) or element.name ~= GUI_NAME then return end
  -- Opening the picker sets player.opened = picker, which fires this for the button
  -- window. Keep the window alive behind the picker (like the native signal fields).
  if SP.is_open(game.get_player(event.player_index)) then return end
  storage.open_gui[event.player_index] = nil
  storage.cond_frames[event.player_index] = nil
  local edit = game.get_player(event.player_index).gui.screen[DESC_EDIT_FRAME]
  if edit then edit.destroy() end
  element.destroy()
end)

local function get_open_data(event)
  local unit_number = storage.open_gui[event.player_index]
  local data = unit_number and storage.buttons[unit_number]
  if data and data.entity.valid then return data end
end

local function find_desc_box(el)
  if el.name == DESC_BOX then return el end
  for _, c in pairs(el.children) do
    local found = find_desc_box(c)
    if found then return found end
  end
end

local function refocus_main(player)
  local main = player.gui.screen[GUI_NAME]
  if main then player.opened = main end
end

script.on_event(defines.events.on_gui_click, function(event)
  if SP.on_click(event) then return end
  if SB.on_click(event) then return end  -- слот операнда → gglib откроет пикер
  local name = event.element.name
  local player = game.get_player(event.player_index)
  if name == CLOSE_NAME then
    local edit = player.gui.screen[DESC_EDIT_FRAME]
    if edit then edit.destroy() end
    local frame = player.gui.screen[GUI_NAME]
    if frame then frame.destroy() end
    storage.open_gui[event.player_index] = nil
    storage.cond_frames[event.player_index] = nil
    return
  end
  local data = get_open_data(event)
  if not data then return end
  if name == DESC_BTN then
    open_desc_editor(player, data)
  elseif name == DESC_SAVE then
    local edit = player.gui.screen[DESC_EDIT_FRAME]
    if edit then
      local box = find_desc_box(edit)
      if box then data.entity.combinator_description = box.text end
      edit.destroy()
    end
    open_gui(player, data) -- rebuild main with the updated description button
  elseif name == DESC_CANCEL then
    local edit = player.gui.screen[DESC_EDIT_FRAME]
    if edit then edit.destroy() end
    refocus_main(player)
  end
  -- Слоты операндов (EN_OP/DIS_OP/DURATION_NAME) открывают пикер через SB.on_click выше.
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
  local name = event.element.name
  local data = get_open_data(event)
  if not data then return end
  if name == EN_SIG then
    data.enable_cond.signal = event.element.elem_value
  elseif name == DIS_SIG then
    data.disable_cond.signal = event.element.elem_value
  elseif name == DESC_EMOJI then
    -- insert the picked signal as a rich-text icon into the description text
    local edit = game.get_player(event.player_index).gui.screen[DESC_EDIT_FRAME]
    local box = edit and find_desc_box(edit)
    if box then box.text = box.text .. signal_richtext(event.element.elem_value) end
    event.element.elem_value = nil -- reset the picker
  end
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(event)
  local name = event.element.name
  if name ~= EN_CMP and name ~= DIS_CMP then return end
  local data = get_open_data(event)
  if not data then return end
  local cmp = COMPARATORS[event.element.selected_index]
  if name == EN_CMP then data.enable_cond.comparator = cmp
  else data.disable_cond.comparator = cmp end
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
  if event.element.name ~= BACK_NAME then return end
  local data = get_open_data(event)
  if not data then return end
  data.auto = event.element.state
  set_auto_tracking(data)
  -- rebuild the window to show/hide the condition rows
  local player = game.get_player(event.player_index)
  open_gui(player, data)
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
  SP.on_text(event)  -- поиск/поле константы пикера
end)

-- Ползунок константы в пикере (у мода нет других слайдеров).
script.on_event(defines.events.on_gui_value_changed, function(event)
  SP.on_value(event)
end)

script.on_event(defines.events.on_player_rotated_entity, function(event)
  local entity = event.entity
  if not NAMES[entity.name] then return end
  -- R flips side (front<->back) but keeps the on/off state.
  local data = storage.buttons[entity.unit_number]
  local on = (data and data.state) or false
  local was_front = event.previous_direction == DIR.north or event.previous_direction == DIR.east
  entity.direction = face_dir(not was_front, on)
end)

script.on_event(defines.events.on_entity_settings_pasted, function(event)
  local src, dst = event.source, event.destination
  if not (NAMES[src.name] and src.name == dst.name) then return end
  local src_data = get_data(src)
  local dst_data = get_data(dst)
  local function copy_cond(c)
    return { signal = c.signal, comparator = c.comparator, use_signal = c.use_signal, second_signal = c.second_signal, constant = c.constant }
  end
  dst_data.active_signal = src_data.active_signal
  dst_data.active_count = src_data.active_count or 1
  dst_data.inactive_signal = src_data.inactive_signal
  dst_data.inactive_count = src_data.inactive_count or 1
  local sd = norm_duration(src_data.duration)
  dst_data.duration = { use_signal = false, second_signal = sd.second_signal, constant = sd.constant }
  dst_data.auto = src_data.auto
  dst_data.enable_cond = copy_cond(src_data.enable_cond)
  dst_data.disable_cond = copy_cond(src_data.disable_cond)
  set_auto_tracking(dst_data)
  dst.combinator_description = src.combinator_description
  set_output(dst_data)
end)

local filters = {
  { filter = "name", name = "gofarovich-bc-pulse" },
  { filter = "name", name = "gofarovich-bc-switch" },
}

-- Настройки кнопки <-> таблица-тег "cb". Один формат на все каналы переноса:
-- блюпринты, undo/redo и призраки после смерти — всё едет через теги призрака
-- и возвращается в on_built.
local function tag_data(data, desc)
  -- Which way the button faces. direction alone cannot be trusted on the way back:
  -- it encodes (side, on/off) together, so rotating a blueprint rewrites both.
  local front
  if data.entity and data.entity.valid then front = is_button_face(data.entity) end
  return {
    front = front,
    active = data.active_signal,
    active_count = data.active_count,
    inactive = data.inactive_signal,
    inactive_count = data.inactive_count,
    duration = data.duration,
    state = data.state,
    -- Ticks left of a running pulse. A timer button copied / blueprinted / undone
    -- while lit used to come back lit with nothing scheduled to switch it off, so
    -- it stayed on forever. Carry the leftover and restart the countdown on build.
    remaining = (data.off_tick and data.off_tick > game.tick) and (data.off_tick - game.tick) or nil,
    desc = desc,
    auto = data.auto,
    enable_cond = data.enable_cond,
    disable_cond = data.disable_cond,
  }
end

local function apply_tags(data, t, entity)
  data.active_signal = t.active
  data.active_count = t.active_count or 1
  data.inactive_signal = t.inactive
  data.inactive_count = t.inactive_count or 1
  if t.duration then data.duration = norm_duration(t.duration) end
  data.state = t.state or false
  if t.desc and t.desc ~= "" then entity.combinator_description = t.desc end
  data.auto = t.auto or false
  if t.enable_cond then data.enable_cond = t.enable_cond end
  if t.disable_cond then data.disable_cond = t.disable_cond end
  set_auto_tracking(data)
  -- Restart the pulse countdown from whatever was left when the button was copied
  -- (older tags have no `remaining` — fall back to a full-length pulse).
  data.off_tick = nil
  if data.state and entity.name == "gofarovich-bc-pulse" then
    schedule_release(data, t.remaining or pulse_duration(data, entity))
  end
  -- All four directions are spoken for by (side, on/off), so a rotated blueprint
  -- landed the button on its terminal side or with its state flipped. Both halves
  -- come from our own data instead; how the blueprint was turned is ignored.
  -- (Tags written before `front` existed fall back to the placed direction.)
  local front = t.front
  if front == nil then front = is_button_face(entity) end
  entity.direction = face_dir(front, data.state)
end

-- Pull the mirror sections off a freshly built entity. Everything past section 1
-- is ours: one filter each, whose count says which picker it belongs to and whose
-- signal the engine has already substituted parameters into.
local function read_mirror(entity)
  local cb = entity.get_control_behavior()
  if not cb then return nil end
  local sections = cb.sections
  local captured
  for index = 2, #sections do
    local slot = sections[index].get_slot(1)
    local value = slot and slot.value
    local which = slot and slot.min
    if value and value.name and which and which >= 1 and which <= #MIRROR_SLOTS then
      captured = captured or {}
      captured[which] = { type = value.type or "item", name = value.name, quality = value.quality }
    end
  end
  return captured
end

local function apply_mirror(data, captured)
  for index, slot in ipairs(MIRROR_SLOTS) do
    local signal = captured[index]
    if signal then slot.set(data, signal) end
  end
end

-- A real button owns exactly one section. Anything above it arrived from a
-- blueprint and has to go before it can put a signal on the wire.
local function strip_mirror(entity)
  local cb = entity.get_control_behavior()
  if not cb then return end
  for index = #cb.sections, 2, -1 do
    cb.remove_section(index)
  end
end

-- Fallback for blueprints taken before the mirror existed: back then the only
-- field the engine could substitute was the output filter in slot 1 of section 1.
local function built_slot(entity)
  local cb = entity.get_control_behavior()
  local section = cb and cb.get_section(1)
  local slot = section and section.get_slot(1)
  local value = slot and slot.value
  if value and value.name then
    return { type = value.type or "virtual", name = value.name, quality = value.quality }, slot.min
  end
end

local function on_built(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local data = register(entity)
  -- Restore mod data from blueprint tags (see on_player_setup_blueprint).
  local t = event.tags and event.tags.cb
  if t then
    -- Read what the engine actually built before the tag puts our raw copy back,
    -- then get the mirror off the entity in the same handler -- no tick passes
    -- with those sections live, so nothing of theirs reaches the network.
    local captured = read_mirror(entity)
    local signal, count = built_slot(entity)
    strip_mirror(entity)
    apply_tags(data, t, entity)
    if captured then
      apply_mirror(data, captured)
    elseif signal then
      -- pre-mirror blueprint: slot 1 held whichever half was live when it was
      -- taken, so the substituted signal belongs to the state it comes back in.
      if data.state then
        data.active_signal = signal
        data.active_count = count or data.active_count
      else
        data.inactive_signal = signal
        data.inactive_count = count or data.inactive_count
      end
    end
  end
  -- Keep the side the entity was placed/blueprinted with (Q-pipette, paste and
  -- blueprints carry a direction); only re-derive the on/off half from our state.
  entity.direction = face_dir(is_button_face(entity), data.state)
  set_output(data)
end

script.on_event(defines.events.on_built_entity, on_built, filters)
script.on_event(defines.events.on_robot_built_entity, on_built, filters)
script.on_event(defines.events.script_raised_built, on_built, filters)
script.on_event(defines.events.script_raised_revive, on_built, filters)

-- The signal/duration/state data lives in our storage, not on the entity, so it is
-- not blueprinted by default. Stash it into blueprint tags here; on_built reads
-- it back. (combinator_description is included too, to be safe.)
local function blueprint_stack(player)
  local bp = player.blueprint_to_setup
  if bp and bp.valid_for_read then return bp end
  bp = player.cursor_stack
  if bp and bp.valid_for_read and bp.is_blueprint then return bp end
  return nil
end

-- Append one section per picked signal to a blueprint entity, so the parameter
-- dialog can see them and substitute into them. Section 1 stays the button's real
-- output; the extras start at 2 and carry their picker index in the filter count.
-- No `group` is set on purpose: a named section is a logistic group, i.e. a global
-- the player would find in their own list.
local function mirror_into(ent, data)
  local behavior = ent.control_behavior or {}
  local wrapper = behavior.sections or {}
  local list = wrapper.sections or {}
  -- Guarantee the output section exists, so the mirror never lands on index 1.
  if #list == 0 then list[1] = { index = 1 } end
  for which, slot in ipairs(MIRROR_SLOTS) do
    local signal = slot.get(data)
    if signal and signal.name then
      list[#list + 1] = {
        index = #list + 1,
        filters = { {
          index = 1,
          type = signal_type(signal),
          name = signal.name,
          quality = signal.quality or "normal",
          comparator = "=",
          count = which, -- which picker this section stands for
        } },
      }
    end
  end
  wrapper.sections = list
  behavior.sections = wrapper
  ent.control_behavior = behavior
end

script.on_event(defines.events.on_player_setup_blueprint, function(event)
  local player = game.get_player(event.player_index)
  local bp = blueprint_stack(player)
  if not bp then return end
  local entities = bp.get_blueprint_entities()
  if not entities then return end
  local mapping = event.mapping.get()
  local touched = false
  for _, ent in pairs(entities) do
    local real = mapping[ent.entity_number]
    if real and real.valid and NAMES[real.name] then
      local data = storage.buttons[real.unit_number]
      if data then
        -- tags go in the same write: set_blueprint_entities replaces the lot
        ent.tags = ent.tags or {}
        ent.tags.cb = tag_data(data, real.combinator_description)
        mirror_into(ent, data)
        touched = true
      end
    end
  end
  if touched then bp.set_blueprint_entities(entities) end
end)

-- Undo/redo и восстановление после смерти. Движковый undo-стек сам не носит
-- данные мода: Ctrl+Z после сноса ставил призрака без тегов, и on_built
-- регистрировал кнопку с дефолтами. Поэтому при удалении настройки прячутся в
-- storage.undo_stash по ключу (поверхность, имя, позиция), а когда undo/redo
-- (или смерть) создаёт там призрака — стэш пишется в его теги и штатно
-- возвращается в on_built при оживлении.
local function stash_key(surface_index, name, pos)
  return string.format("%d:%s:%.2f:%.2f", surface_index, name, pos.x, pos.y)
end

local STASH_LIMIT = 200 -- ограничитель, чтобы никогда-не-отменённые сносы не копились в сейве

local function stash_settings(entity, data)
  local stash = storage.undo_stash
  stash[stash_key(entity.surface.index, entity.name, entity.position)] =
    { tick = game.tick, cb = tag_data(data, entity.combinator_description) }
  local count, oldest_key, oldest_tick = 0, nil, math.huge
  for k, v in pairs(stash) do
    count = count + 1
    if v.tick < oldest_tick then oldest_key, oldest_tick = k, v.tick end
  end
  if count > STASH_LIMIT then stash[oldest_key] = nil end
end

local function on_removed(event)
  local entity = event.entity
  if not (entity and NAMES[entity.name]) then return end
  local data = storage.buttons[entity.unit_number]
  if data then
    stash_settings(entity, data)
    storage.buttons[entity.unit_number] = nil
    storage.auto[entity.unit_number] = nil
  end
end

script.on_event(defines.events.on_player_mined_entity, on_removed, filters)
script.on_event(defines.events.on_robot_mined_entity, on_removed, filters)
script.on_event(defines.events.on_entity_died, on_removed, filters)
script.on_event(defines.events.script_raised_destroy, on_removed, filters)

local function restore_from_stash(surface_index, name, pos)
  local saved = storage.undo_stash[stash_key(surface_index, name, pos)]
  if not saved then return end
  local surface = game.get_surface(surface_index)
  if not surface then return end
  -- обычный случай: undo поставил призрака — теги доедут до on_built при оживлении
  local ghost = surface.find_entities_filtered{ ghost_name = name, position = pos, limit = 1 }[1]
  if ghost then
    local tags = ghost.tags or {}
    tags.cb = saved.cb
    ghost.tags = tags
    return
  end
  -- мгновенная постройка (редактор/чит-режим): сущность уже реальная и on_built
  -- успел зарегистрировать её с дефолтами — накатываем сохранённое поверх
  local real = surface.find_entities_filtered{ name = name, position = pos, limit = 1 }[1]
  if real then
    local data = get_data(real)
    apply_tags(data, saved.cb, real)
    real.direction = face_dir(is_button_face(real), data.state)
    set_output(data)
  end
end

local function on_undo_redo(event)
  for _, action in pairs(event.actions) do
    local target = action.target
    if target and NAMES[target.name]
      and (action.type == "removed-entity" or action.type == "built-entity") then
      restore_from_stash(action.surface_index, target.name, target.position)
    end
  end
end

script.on_event(defines.events.on_undo_applied, on_undo_redo)
script.on_event(defines.events.on_redo_applied, on_undo_redo)

-- Смерть кнопки: on_entity_died (on_removed выше) уже спрятал настройки в стэш,
-- здесь вешаем их на созданного движком призрака — боты отстроят кнопку как была.
script.on_event(defines.events.on_post_entity_died, function(event)
  if not (event.ghost and event.prototype and NAMES[event.prototype.name]) then return end
  local saved = storage.undo_stash[stash_key(event.surface_index, event.prototype.name, event.position)]
  if saved then event.ghost.tags = { cb = saved.cb } end
end)
