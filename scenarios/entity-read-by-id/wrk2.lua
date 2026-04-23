-- wrk2 Lua script for entity-read-by-id scenario
-- Endpoint: GET /api/v1/users
--
-- wrk2 is API-compatible with wrk. The request() function is identical.
-- Rate (-R) is passed on the command line; calibrate to 60-80% of observed
-- wrk saturation throughput before the p99_stable measurement window.

request = function()
  return wrk.format("GET", "/api/v1/users")
end
