-- wrk Lua script for 10 KB JSON POST echo benchmark
local function read_payload(paths)
  for _, path in ipairs(paths) do
    local file = io.open(path, "rb")
    if file then
      local contents = file:read("*a")
      file:close()
      return contents
    end
  end
  error("Unable to load canonical payload.json from known locations")
end
local body = read_payload({
  "scenarios/json-10kb/payload.json",
  "payload.json",
})

wrk.method = "POST"
wrk.body   = body
wrk.headers["Content-Type"] = "application/json"
wrk.headers["Accept"]       = "application/json"
