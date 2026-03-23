local total_ids = 1000
local counter = 0

request = function()
  counter = (counter % total_ids) + 1
  return wrk.format("GET", "/api/v1/entities/" .. counter)
end
