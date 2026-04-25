-- wrk harness for e2e-shop-order-saga
-- ===================================================
-- NOTE: wrk has significant limitations for stateful workloads
-- This script simulates a simplified order flow without state carryover
-- For proper saga testing with state correlation, use k6 instead
-- ===================================================

local json = require("cjson");

-- Counter variables (global per wrk instance)
local request_count = 0;
local error_count = 0;
local product_id = 1;

-- Function to generate unique username
function generate_username()
  return string.format("user_%d_%d", os.time(), request_count);
end

-- Deterministic function to get product ID.
-- Cycles through product IDs 1..500 based on request_count so request
-- sequences are reproducible across runs.
function get_random_product_id()
  return (request_count % 500) + 1;
end

-- Function to extract response field
function parse_json_field(response_body, field)
  local ok, json_body = pcall(json.decode, response_body);
  if ok and json_body then
    return json_body[field] or json_body.id or nil;
  end
  return nil;
end

-- Setup function (called once per thread)
function setup(thread)
  -- Per-thread setup if needed
  thread.request_num = 0;
end

-- Main request-building function
function request()
  -- Note: wrk does not maintain state between requests
  -- This limitation prevents proper saga workflow implementation
  -- Each request below is repeated in sequence per VU, but without state carryover

  local step = request_count % 5;
  request_count = request_count + 1;

  if step == 0 then
    -- Step 1: Register
    local username = generate_username();
    local body = json.encode({
      username = username,
      email = string.format("%s@shop.local", username),
      password = "BenchPass123!"
    });
    
    wrk.method = "POST";
    wrk.path = "/api/v1/auth/register";
    wrk.headers["Content-Type"] = "application/json";
    return wrk.format(nil, nil, nil, body);

  elseif step == 1 then
    -- Step 2: Get recommendations
    wrk.method = "GET";
    wrk.path = "/api/v1/products/recommended?limit=10";
    wrk.headers["Content-Type"] = "application/json";
    return wrk.format();

  elseif step == 2 then
    -- Step 3: Add to cart
    local product_id = get_random_product_id();
    local body = json.encode({
      product_id = product_id,
      quantity = 1
    });
    
    wrk.method = "POST";
    wrk.path = "/api/v1/cart/add";
    wrk.headers["Content-Type"] = "application/json";
    return wrk.format(nil, nil, nil, body);

  elseif step == 3 then
    -- Step 4: Get cart
    wrk.method = "GET";
    wrk.path = "/api/v1/cart";
    wrk.headers["Content-Type"] = "application/json";
    return wrk.format();

  elseif step == 4 then
    -- Step 5: Place order
    local body = json.encode({
      cart_id = "current",
      payment_method = "CARD"
    });
    
    wrk.method = "POST";
    wrk.path = "/api/v1/orders";
    wrk.headers["Content-Type"] = "application/json";
    return wrk.format(nil, nil, nil, body);
  end
end

-- Response callback (optional, for metrics)
function response(status, headers, body)
  if status >= 400 then
    error_count = error_count + 1;
  end
end

-- Done callback (called at end of test)
function done(summary, latency, requests, responses)
  -- Print summary statistics (optional)
  -- wrk's native output is sufficient for basic throughput measurement
end

-- LIMITATIONS documentation:
--[[
  wrk CANNOT properly implement e2e-shop-order-saga because:

  1. NO STATE CARRYOVER: Each request is independent. Auth tokens, order IDs,
     and saga state cannot be passed between steps.
  
  2. NO CORRELATION: JWT tokens from registration responses cannot be
     read and reused in subsequent requests within the same user journey.
  
  3. NO SAGA POLLING: Polling order status (up to 60s post-measurement)
     requires maintaining per-VU state across multiple poll cycles,
     which wrk does not support.
  
  4. NO COMPENSATION TRACKING: wrk cannot track final saga states
     (COMPLETED, COMPENSATED, FAILED) because it lacks response parsing
     and per-VU memory.

  RECOMMENDATION: Use k6 for this scenario.
  k6 provides:
  - Full session state (JWT tokens, order IDs)
  - Response correlation (extract data from responses)
  - Custom metrics (saga_success_rate, compensation_rate)
  - Proper polling loops with max attempt limits
  - Per-VU context preservation across entire user journey

  This wrk.lua is provided for throughput-only baseline measurement,
  NOT for saga completion or compensation validation.
]]
