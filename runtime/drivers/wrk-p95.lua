-- wrk-p95.lua — Emits p95 latency to stdout so run-comparative.sh can grep it.
-- wrk --latency prints only p50/p75/p90/p99; this done() callback adds p95.
-- Output format intentionally matches wrk's Latency Distribution block so the
-- existing grep -oP '95(?:\.00)?%\s+\K[\d.]+(?:us|ms|s)' pattern captures it.
done = function(summary, latency, requests)
  local p95_us = latency:percentile(95.0)
  if not p95_us then return end
  local val
  if p95_us >= 1000000 then
    val = string.format("%.2fs",  p95_us / 1000000.0)
  elseif p95_us >= 1000 then
    val = string.format("%.2fms", p95_us / 1000.0)
  else
    val = string.format("%.2fus", p95_us)
  end
  io.write(string.format("     95.00%%  %s\n", val))
end
