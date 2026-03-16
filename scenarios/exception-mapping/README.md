# scenario: exception-mapping

- Name key: `<tier>-<protocol>-exception-mapping`
- Path: `GET /throw`
- Expected: mapped exception response (e.g., 422)
- Purpose: exception-to-response path overhead
- Protocols: H1, H2, H3
