# Changelog

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
