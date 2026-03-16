-- wrk Lua script for 1 KB JSON POST echo benchmark
-- Usage: wrk -t 4 -c 100 -d 30s --latency --script runtime/wrk/lua/json-post.lua http://localhost:8080/echo

local payload = string.rep("x", 700)
local body = string.format(
  '{"id":"bench-0001","type":"echo_request","ts":"2026-01-01T00:00:00Z","data":"%s"}',
  payload
)

wrk.method = "POST"
wrk.body   = body
wrk.headers["Content-Type"] = "application/json"
wrk.headers["Accept"]       = "application/json"
