-- Рецепты кнопок открываются исследованием Circuit network
-- (https://wiki.factorio.com/Circuit_network_(research)).
-- Единственное место, где эффекты добавляются: раньше то же самое делал ещё и
-- data.lua, из-за чего в окне исследования кнопки висели по два раза.
-- Вставка идемпотентна — повторный запуск (или чужой мод, добавивший тот же
-- анлок) дубля уже не создаст.
local RECIPES = { "gofarovich-bc-pulse", "gofarovich-bc-switch" }

local tech = data.raw.technology["circuit-network"]
if tech then
  tech.effects = tech.effects or {}
  for _, name in ipairs(RECIPES) do
    local present = false
    for _, effect in pairs(tech.effects) do
      if effect.type == "unlock-recipe" and effect.recipe == name then
        present = true
        break
      end
    end
    if not present then
      table.insert(tech.effects, { type = "unlock-recipe", recipe = name })
    end
  end
else
  -- технологию кто-то выпилил — тогда рецепты просто доступны сразу
  for _, name in ipairs(RECIPES) do
    data.raw.recipe[name].enabled = true
  end
end
