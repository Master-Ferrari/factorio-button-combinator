local tech = data.raw.technology["circuit-network"]
if tech then
  table.insert(tech.effects, { type = "unlock-recipe", recipe = "gofarovich-bc-pulse" })
  table.insert(tech.effects, { type = "unlock-recipe", recipe = "gofarovich-bc-switch" })
else
  data.raw.recipe["gofarovich-bc-pulse"].enabled = true
  data.raw.recipe["gofarovich-bc-switch"].enabled = true
end
