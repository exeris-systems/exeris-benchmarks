-- wrk Lua script for the entity-read-by-id scenario.
--
-- The request path is decided HERE: a wrk `request` function overrides the path
-- in the command-line URL, so the harness forwards the desired path via the
-- WRK_REQUEST_PATH environment variable rather than the URL.
--
-- Default: the aggregate read (/api/v1/users) - byte-identical to the historical
-- hard-coded behavior, so every existing caller is unchanged.
-- The constrained single-read matrix (run-entity-read-by-id-memory-cpu-matrix.sh)
-- sets WRK_REQUEST_PATH=/api/v1/user?id=1 (derived from the fixed contract's
-- `endpoint`) so warmup and measurement drive the runtime-bound single-row read.
local path = os.getenv("WRK_REQUEST_PATH")
if path == nil or path == "" then
  path = "/api/v1/users"
end

request = function()
  return wrk.format("GET", path)
end
