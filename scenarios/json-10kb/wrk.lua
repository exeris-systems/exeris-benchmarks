-- wrk Lua script for 10 KB JSON POST echo benchmark
local payload = string.rep("x", 9700)
local body = string.format(
  '{"id":"bench-0001","type":"echo_request","ts":"2026-01-01T00:00:00Z","data":"%s"}',
  payload
)

wrk.method = "POST"
wrk.body   = body
wrk.headers["Content-Type"] = "application/json"
wrk.headers["Accept"]       = "application/json"
