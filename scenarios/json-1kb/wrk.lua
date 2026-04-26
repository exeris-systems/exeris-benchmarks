-- wrk Lua script for 1 KB JSON POST echo benchmark
-- Usage: wrk -t 4 -c 100 -d 30s --latency --script scenarios/json-1kb/wrk.lua http://localhost:8080/echo

local payload = string.rep("x", 700)
local body = string.format(
  '{"id":"bench-0001","type":"echo_request","timestamp":"2026-01-01T00:00:00Z","payload":{"name":"benchmark-user","email":"bench@exeris.io","region":"eu-west","tier":"community","roles":["user","reader"],"metadata":{"created":"2026-01-01","version":"1.0.0","flags":["flag_a","flag_b","flag_c"]},"data":"%s"}}',
  payload
)

wrk.method = "POST"
wrk.body   = body
wrk.headers["Content-Type"] = "application/json"
wrk.headers["Accept"]       = "application/json"
