require("util")

local g = "__button-combinator__/graphics/"
local atlas = g .. "atlas.png"
local shadow = g .. "atlas-shadow.png"
local luminance = g .. "luminance.png" -- same layout as atlas.png; opaque black bg, so drawn additively
local husk = g .. "husk.png"   -- remnant sheet: two 128x128 variations

-- main frame + glow (visible at night) + matching shadow layer (same x/y in every atlas)
local function cell(x, y)
  return {
    layers = {
      { filename = atlas, x = x, y = y, width = 128, height = 128, scale = 0.5 },
      { filename = luminance, x = x, y = y, width = 128, height = 128, scale = 0.5, draw_as_glow = true, blend_mode = "additive" },
      { filename = shadow, x = x, y = y, width = 128, height = 128, scale = 0.5, draw_as_shadow = true },
    },
  }
end

-- The 4 entity directions encode (side, on/off), so control.lua just rotates the
-- entity and the engine draws the matching frame as a normal, depth-sorted entity
-- sprite (no overlay, no rendering object):
--   north = front-off   east = front-on   south = back-off   west = back-on
-- Atlas layout (cell 128, top-left coords):
--   (0,0) switch front-on   (128,0)  pulse  back-off   (256,0)  switch front-off (384,0)  pulse  back-on
--   (0,128) pulse front-on   (128,128) switch back-off (256,128) pulse front-off  (384,128) switch back-on
local SPRITES = {
  ["gofarovich-bc-pulse"] = {
    north = cell(256, 128), east = cell(0, 128), south = cell(128, 0),   west = cell(384, 0),
  },
  ["gofarovich-bc-switch"] = {
    north = cell(256, 0),   east = cell(0, 0),   south = cell(128, 128), west = cell(384, 128),
  },
}

local function make_button(name, icon)
  local entity = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
  entity.name = name
  entity.icon = g .. icon
  entity.icon_size = 64
  entity.minable = { mining_time = 0.1, result = name }
  entity.fast_replaceable_group = nil
  entity.corpse = "gofarovich-bc-husk"
  entity.sprites = SPRITES[name]
  entity.activity_led_sprites = util.empty_sprite()
  -- Wire attach points. The array is indexed by direction in the fixed order
  -- N, E, S, W. Direction encodes (side, on/off): N/E = front, S/W = back. We want
  -- the wires to depend only on the physical side (not on/off), so both facings of
  -- a side share one point => no jump when state flips. Hence just two points:
  --   FRONT_WIRE -> N (front-off) and E (front-on)
  --   BACK_WIRE  -> S (back-off)  and W (back-on)
  -- EDIT the coords here (pixels from entity centre; util.by_pixel(px,py)={px/32,py/32}).
  local FRONT_WIRE = {
    wire   = { red = util.by_pixel(-13.5, -18.5), green = util.by_pixel(14,  -17.5) },
    shadow = { red = util.by_pixel(1.5,    -1),    green = util.by_pixel(30, -2)    },
  }
  local BACK_WIRE = {
    wire   = { red = util.by_pixel(14,  -6), green = util.by_pixel(-13, -5) },
    shadow = { red = util.by_pixel(29, 10),  green = util.by_pixel(2, 10)  },
  }
  entity.circuit_wire_connection_points = {
    FRONT_WIRE, -- [1] north = front-off
    FRONT_WIRE, -- [2] east  = front-on
    BACK_WIRE,  -- [3] south = back-off
    BACK_WIRE,  -- [4] west  = back-on
  }

  local item = {
    type = "item",
    name = name,
    icon = g .. icon,
    icon_size = 64,
    subgroup = "circuit-network",
    order = "c[combinators]-d[" .. name .. "]",
    place_result = name,
    stack_size = 50,
  }

  local recipe = {
    type = "recipe",
    name = name,
    enabled = false,
    energy_required = 0.5,
    ingredients = {
      { type = "item", name = "copper-cable", amount = 2 },
      { type = "item", name = "electronic-circuit", amount = 1 },
      { type = "item", name = "iron-gear-wheel", amount = 2 },
    },
    results = { { type = "item", name = name, amount = 1 } },
  }

  data:extend({ entity, item, recipe })
end

make_button("gofarovich-bc-pulse", "icon-pulse.png")
make_button("gofarovich-bc-switch", "icon-switch.png")

-- Разблокировка рецептов кнопок висит на Circuit network и живёт целиком в
-- data-updates.lua — здесь её быть не должно, иначе эффекты добавятся дважды и
-- в окне исследования кнопки покажутся по два раза.

-- Remnant left on the ground after a button is destroyed. `animation` is a list
-- of variations, so the engine picks one of the two husk cells at random.
local function husk_variation(x)
  return { filename = husk, x = x, y = 0, width = 128, height = 128, scale = 0.5, direction_count = 1 }
end

data:extend({
  {
    type = "corpse",
    name = "gofarovich-bc-husk",
    icon = g .. "icon-switch.png",
    icon_size = 64,
    flags = { "placeable-neutral", "not-on-map" },
    subgroup = "remnants",
    order = "z[gofarovich-bc-husk]",
    selectable_in_game = false,
    time_before_removed = 60 * 60 * 15, -- ~15 min, like vanilla remnants
    final_render_layer = "remnants",
    animation = { husk_variation(0), husk_variation(128) },
  },

  { type = "sound", name = "gofarovich-bc-press", filename = "__core__/sound/gui-click.ogg", volume = 0.7 },
  { type = "sound", name = "gofarovich-bc-release", filename = "__core__/sound/gui-click.ogg", volume = 0.6, speed = 0.8 },

  -- played when a back-signal-locked button is clicked manually.
  -- Swap `filename` to taste (see the sound list given in chat).
  { type = "sound", name = "gofarovich-bc-locked", filename = "__core__/sound/deconstruct-cancel-end.ogg", volume = 0.8 },
})

-- Подложки условий обратной связи — те же, что у условий рельса: обычная
-- decider_combinator_frame, а при выполнении условия — fulfilled-рамка. Ванильный
-- decider_combinator_fulfilled_condition_frame несёт вшитую фиксированную ширину
-- (width/natural_width), которую horizontally_stretchable не перебивает (явный width
-- приоритетнее растяжки) — поэтому активная карточка «отрывалась» от окна на свою ширину.
-- Решение: наследуемся от той же базы, что и обычная карточка (decider_combinator_frame),
-- и берём у fulfilled-стиля ТОЛЬКО зелёную рамку (graphical_set). Геометрия обоих
-- состояний идентична, меняется лишь обводка.
local gstyle = data.raw["gui-style"].default
gstyle["gofarovich-bc-cond-fulfilled-frame"] = {
  type = "frame_style",
  parent = "decider_combinator_frame",
  graphical_set = gstyle.decider_combinator_fulfilled_condition_frame.graphical_set,
}
