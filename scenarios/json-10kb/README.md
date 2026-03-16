# scenario: json-10kb

- Name key: `<tier>-<protocol>-json-10kb`
- Path: `POST /echo`
- Payload: ~10 KB JSON
- Purpose: medium payload parse/serialize and buffer pressure
- Protocols: H1, H2, H3
