# Changelog

## [0.4.0] — 2026-10-26

Renamed from `wayfinder-signal` to `sodaflex`: Wayfinder became SodaFlex.

- The gem is `sodaflex`, the module `SodaFlex`, the initializer
  `config/initializers/sodaflex.rb`, the rake tasks `sodaflex:status`,
  `sodaflex:test` and `sodaflex:test_error`.
- Settings are `SODAFLEX_ENDPOINT`, `SODAFLEX_BRAND_KEY` and
  `SODAFLEX_SIGNING_SECRET`; `config.brand_key` replaces `config.product_key`.
- Requests carry `X-SodaFlex-*` headers. The envelope is unchanged.
- The attribution cookie is `sodaflex_attribution`, and the helper
  `sodaflex_attribution`.
- Every old name keeps working for this version — see the README. They go in
  0.5.0.

## [0.1.0] — 2026-07-30

First release. Extracted from the Wayfinder monorepo so that products consuming
it do not need credentials for a private repository.

- `Wayfinder::Signal.track` plus convenience methods for the events worth
  instrumenting first
- HMAC-SHA256 request signing with a timestamp inside the signed payload
- Client-generated ULID envelope ids, so redelivery is idempotent
- Asynchronous delivery through Active Job, with short timeouts, bounded
  retries and a local dead-letter handler
- Key removal for configured sensitive fields, recording which names were
  dropped without their values
- Optional unhandled exception reporting via `Rails.error`
- `wayfinder:signal:status` and `wayfinder:signal:test` rake tasks
