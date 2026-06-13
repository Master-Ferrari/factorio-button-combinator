local NAMES = { ["gofarovich-bc-pulse"] = true, ["gofarovich-bc-switch"] = true }
local GUI_NAME = "gofarovich-bc-btn-gui"
local CLOSE_NAME = "gofarovich-bc-close"
local DESC_BTN = "gofarovich-bc-desc-btn"
local DESC_EDIT_FRAME = "gofarovich-bc-desc-edit"
local DESC_BOX = "gofarovich-bc-desc-box"
local DESC_SAVE = "gofarovich-bc-desc-save"
local DESC_CANCEL = "gofarovich-bc-desc-cancel"
local DESC_EMOJI = "gofarovich-bc-desc-emoji"
local DURATION_NAME = "gofarovich-bc-duration"
local BACK_NAME = "gofarovich-bc-back"
local EN_SIG, EN_CMP, EN_TOG, EN_SIG2, EN_CONST = "gofarovich-bc-en-sig", "gofarovich-bc-en-cmp", "gofarovich-bc-en-tog", "gofarovich-bc-en-sig2", "gofarovich-bc-en-const"
local DIS_SIG, DIS_CMP, DIS_TOG, DIS_SIG2, DIS_CONST = "gofarovich-bc-dis-sig", "gofarovich-bc-dis-cmp", "gofarovich-bc-dis-tog", "gofarovich-bc-dis-sig2", "gofarovich-bc-dis-const"
local COMPARATORS = { "<", ">", "=", "≥", "≤", "≠" }

local function init_storage()
  storage.buttons = storage.buttons or {}
  storage.pending = storage.pending or {}
  storage.open_gui = storage.open_gui or {}
  storage.auto = storage.auto or {} -- unit_number -> true, for back-signal buttons
end

script.on_init(init_storage)

local function register(entity)
  local data = {
    entity = entity,
    -- default to the green check signal (a fresh table per button, not shared)
    active_signal = { type = "virtual", name = "signal-check" },
    inactive_signal = nil,
    duration = 1, -- pulse length in ticks (pulse button)
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

local function set_output(data)
  local cb = data.entity.get_or_create_control_behavior()
  local section = cb.get_section(1) or cb.add_section()
  local signal = data.state and data.active_signal or data.inactive_signal
  if signal and signal.name then
    section.set_slot(1, {
      value = { type = signal.type or "virtual", name = signal.name, quality = "normal" },
      min = 1, -- constant-combinator outputs this count
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
      data.enable_cond = data.enable_cond or { signal = nil, comparator = "=", use_signal = false, second_signal = nil, constant = 0 }
      data.disable_cond = data.disable_cond or { signal = nil, comparator = "=", use_signal = false, second_signal = nil, constant = 0 }
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

-- Click emits the active signal for `duration` ticks, then auto-releases.
-- (Mouse-up is not exposed by the Factorio API, so a true "hold while pressed"
-- is impossible; a self-extinguishing timed pulse is the practical equivalent.)
-- Re-pressing during a pulse extends it: off_tick tracks the latest end so older
-- scheduled releases are ignored.
local function press_pulse(data)
  local off = game.tick + math.max(1, data.duration or 1)
  data.off_tick = off
  set_state(data, true, "gofarovich-bc-press")
  storage.pending[off] = storage.pending[off] or {}
  table.insert(storage.pending[off], data.entity.unit_number)
end

local function press_switch(data)
  set_state(data, not data.state, data.state and "gofarovich-bc-release" or "gofarovich-bc-press")
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
end)

-- "Connected to: <red id> <green id>" line; placed on a dark subheader bar.
local function add_connection_status(parent, entity)
  local bar = parent.add{ type = "frame", style = "subheader_frame" }
  bar.style.horizontally_stretchable = true
  local flow = bar.add{ type = "flow", direction = "horizontal" }
  flow.style.vertical_align = "center"
  flow.add{ type = "label", style = "subheader_label", caption = { "gofarovich-bc-gui.connected-to" } }
  local r = entity.get_circuit_network(RED)
  local g = entity.get_circuit_network(GREEN)
  if not r and not g then
    flow.add{ type = "label", style = "subheader_label", caption = { "gofarovich-bc-gui.not-connected" } }
  else
    if r then flow.add{ type = "label", style = "subheader_label", caption = "[color=255,90,90]" .. r.network_id .. "[/color]" } end
    if g then flow.add{ type = "label", style = "subheader_label", caption = "[color=90,255,90]" .. g.network_id .. "[/color]" } end
  end
end

local function cmp_index(comparator)
  for i, c in ipairs(COMPARATORS) do
    if c == comparator then return i end
  end
  return 3 -- "="
end

-- One condition row: [label] [signal] [comparator] [toggle] [number OR signal].
-- The right operand is a SINGLE slot: a constant field or a signal picker; the
-- small toggle button switches between the two (one is shown at a time).
local function add_condition_row(parent, label_key, sig_name, cmp_name, tog_name, sig2_name, const_name, cond)
  parent.add{ type = "label", caption = { label_key } }
  local row = parent.add{ type = "flow", direction = "horizontal" }
  row.style.vertical_align = "center"
  row.add{ type = "choose-elem-button", name = sig_name, elem_type = "signal", signal = cond.signal }
  local dd = row.add{ type = "drop-down", name = cmp_name, items = COMPARATORS, selected_index = cmp_index(cond.comparator) }
  dd.style.width = 52
  local tog = row.add{
    type = "sprite-button", name = tog_name, style = "tool_button",
    sprite = "utility/change_recipe", tooltip = { "gofarovich-bc-gui.operand-toggle-tt" },
  }
  tog.style.size = 28
  if cond.use_signal then
    row.add{ type = "choose-elem-button", name = sig2_name, elem_type = "signal", signal = cond.second_signal }
  else
    local c = row.add{
      type = "textfield", name = const_name,
      numeric = true, allow_decimal = false, allow_negative = true,
      text = tostring(cond.constant or 0),
    }
    c.style.width = 70
  end
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

  -- "Connected to" on its own dark subheader bar, under the titlebar
  add_connection_status(frame, data.entity)

  -- Content frame, vanilla entity-GUI style
  local content = frame.add{
    type = "frame",
    style = "entity_frame",
    direction = "vertical",
  }

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
  tbl.add{ type = "label", caption = { "gofarovich-bc-gui.active-signal" } }
  tbl.add{ type = "choose-elem-button", name = "gofarovich-bc-active-signal", elem_type = "signal", signal = data.active_signal }
  tbl.add{ type = "label", caption = { "gofarovich-bc-gui.inactive-signal" } }
  tbl.add{ type = "choose-elem-button", name = "gofarovich-bc-inactive-signal", elem_type = "signal", signal = data.inactive_signal }

  if data.entity.name == "gofarovich-bc-pulse" then
    tbl.add{ type = "label", caption = { "gofarovich-bc-gui.duration" }, tooltip = { "gofarovich-bc-gui.duration-tt" } }
    local dur = tbl.add{
      type = "textfield",
      name = DURATION_NAME,
      numeric = true,
      allow_decimal = false,
      allow_negative = false,
      text = tostring(data.duration or 1),
    }
    dur.style.width = 60
  end

  content.add{ type = "line" }.style.margin = 4

  -- Back-signal: drive the button's state from circuit conditions
  content.add{
    type = "checkbox",
    name = BACK_NAME,
    caption = { "gofarovich-bc-gui.back-signal" },
    tooltip = { "gofarovich-bc-gui.back-signal-tt" },
    state = data.auto,
  }
  if data.auto then
    local conds = content.add{ type = "table", column_count = 2 }
    conds.style.top_margin = 4
    add_condition_row(conds, "gofarovich-bc-gui.enable-cond", EN_SIG, EN_CMP, EN_TOG, EN_SIG2, EN_CONST, data.enable_cond)
    add_condition_row(conds, "gofarovich-bc-gui.disable-cond", DIS_SIG, DIS_CMP, DIS_TOG, DIS_SIG2, DIS_CONST, data.disable_cond)
  end

  -- Description at the bottom, under a separator. When set: a "Description" header
  -- with a pencil-edit button, and the text shown below it (like vanilla).
  content.add{ type = "line" }.style.margin = 4
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
  if not (entity and entity.valid and NAMES[entity.name]) then return end
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
  local element = event.element
  if not (element and element.valid) or element.name ~= GUI_NAME then return end
  storage.open_gui[event.player_index] = nil
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
  local name = event.element.name
  local player = game.get_player(event.player_index)
  if name == CLOSE_NAME then
    local edit = player.gui.screen[DESC_EDIT_FRAME]
    if edit then edit.destroy() end
    local frame = player.gui.screen[GUI_NAME]
    if frame then frame.destroy() end
    storage.open_gui[event.player_index] = nil
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
  elseif name == EN_TOG then
    data.enable_cond.use_signal = not data.enable_cond.use_signal
    open_gui(player, data) -- rebuild to swap number <-> signal in the slot
  elseif name == DIS_TOG then
    data.disable_cond.use_signal = not data.disable_cond.use_signal
    open_gui(player, data)
  end
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
  local name = event.element.name
  local data = get_open_data(event)
  if not data then return end
  if name == "gofarovich-bc-active-signal" then
    data.active_signal = event.element.elem_value
    set_output(data)
  elseif name == "gofarovich-bc-inactive-signal" then
    data.inactive_signal = event.element.elem_value
    set_output(data)
  elseif name == EN_SIG then
    data.enable_cond.signal = event.element.elem_value
  elseif name == DIS_SIG then
    data.disable_cond.signal = event.element.elem_value
  elseif name == EN_SIG2 then
    data.enable_cond.second_signal = event.element.elem_value
  elseif name == DIS_SIG2 then
    data.disable_cond.second_signal = event.element.elem_value
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
  local name = event.element.name
  local data = get_open_data(event)
  if not data then return end
  if name == DURATION_NAME then
    data.duration = math.max(1, tonumber(event.element.text) or 1)
  elseif name == EN_CONST then
    data.enable_cond.constant = tonumber(event.element.text) or 0
  elseif name == DIS_CONST then
    data.disable_cond.constant = tonumber(event.element.text) or 0
  end
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
  dst_data.inactive_signal = src_data.inactive_signal
  dst_data.duration = src_data.duration
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

local function on_built(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local data = register(entity)
  -- Restore mod data from blueprint tags (see on_player_setup_blueprint).
  local t = event.tags and event.tags.cb
  if t then
    data.active_signal = t.active
    data.inactive_signal = t.inactive
    if t.duration then data.duration = t.duration end
    data.state = t.state or false
    if t.desc and t.desc ~= "" then entity.combinator_description = t.desc end
    data.auto = t.auto or false
    if t.enable_cond then data.enable_cond = t.enable_cond end
    if t.disable_cond then data.disable_cond = t.disable_cond end
    set_auto_tracking(data)
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

script.on_event(defines.events.on_player_setup_blueprint, function(event)
  local player = game.get_player(event.player_index)
  local bp = blueprint_stack(player)
  if not bp then return end
  local entities = bp.get_blueprint_entities()
  if not entities then return end
  local mapping = event.mapping.get()
  for _, ent in pairs(entities) do
    local idx = ent.entity_number
    local real = mapping[idx]
    if real and real.valid and NAMES[real.name] then
      local data = storage.buttons[real.unit_number]
      if data then
        bp.set_blueprint_entity_tag(idx, "cb", {
          active = data.active_signal,
          inactive = data.inactive_signal,
          duration = data.duration,
          state = data.state,
          desc = real.combinator_description,
          auto = data.auto,
          enable_cond = data.enable_cond,
          disable_cond = data.disable_cond,
        })
      end
    end
  end
end)

local function on_removed(event)
  local entity = event.entity
  if not (entity and NAMES[entity.name]) then return end
  if storage.buttons[entity.unit_number] then
    storage.buttons[entity.unit_number] = nil
    storage.auto[entity.unit_number] = nil
  end
end

script.on_event(defines.events.on_player_mined_entity, on_removed, filters)
script.on_event(defines.events.on_robot_mined_entity, on_removed, filters)
script.on_event(defines.events.on_entity_died, on_removed, filters)
script.on_event(defines.events.script_raised_destroy, on_removed, filters)
