# wayfinder-signal

Sends operational events from a Rails application to Wayfinder.

[![CI](https://github.com/johnchambers/wayfinder-signal/actions/workflows/ci.yml/badge.svg)](https://github.com/johnchambers/wayfinder-signal/actions/workflows/ci.yml)

The gem is deliberately small. It knows how to build an event envelope, sign it,
and hand it to Active Job. It has no opinion about what any event means — that is
Wayfinder's job — and it shares no models or business logic with it.

## The guarantee

**Wayfinder being unavailable must never affect your product.**

Everything else here follows from that:

- `track` only builds an envelope and enqueues a job. Nothing blocks the request.
- The job uses a 2-second open timeout and a 3-second read timeout.
- Retries are bounded (5 attempts, polynomial backoff) and then stop.
- A 4xx that will never succeed is discarded immediately rather than retried.
- Every public method rescues `StandardError`. `track` returns `nil` on failure.
- Exhausted deliveries go to your `on_delivery_failure` handler, so they stay
  visible locally instead of vanishing.

If you can make this gem raise into a controller action, that is a bug.

## Install

```ruby
# Gemfile
gem "wayfinder-signal"
```

```ruby
# config/initializers/wayfinder_signal.rb
Wayfinder::Signal.configure do |config|
  config.endpoint       = ENV.fetch("WAYFINDER_SIGNAL_ENDPOINT")
  config.product_key    = ENV.fetch("WAYFINDER_PRODUCT_KEY")
  config.signing_secret = ENV.fetch("WAYFINDER_SIGNING_SECRET")
  config.environment    = Rails.env
  config.enabled        = !Rails.env.test?
  config.release        = ENV["GIT_SHA"]
end
```

Verify it:

```bash
bin/rails wayfinder:signal:status   # shows configuration without printing secrets
bin/rails wayfinder:signal:test     # sends one event synchronously and reports the result
```

## Use

```ruby
Wayfinder::Signal.track("customer.created",
  actor: current_user,
  subject: customer,
  customer: customer,
  properties: { plan: customer.plan_name, source: customer.acquisition_source })
```

Convenience wrappers for the events worth instrumenting first:

```ruby
Wayfinder::Signal.customer_created(customer, plan: "professional")
Wayfinder::Signal.onboarding_completed(customer)
Wayfinder::Signal.trial_started(customer)
Wayfinder::Signal.subscription_started(subscription, customer: customer, amount_cents: 24_900)
Wayfinder::Signal.invoice_paid(invoice, customer: customer, amount_cents: 24_900, currency: "EUR")
Wayfinder::Signal.invoice_failed(invoice, customer: customer)
Wayfinder::Signal.support_requested(customer, message: params[:message])
Wayfinder::Signal.feature_requested(customer, request: params[:request])
Wayfinder::Signal.release_deployed(release, version: "2026.07.30.1")
Wayfinder::Signal.deployment_failed(release, reason: "migration timeout")
Wayfinder::Signal.exception_reported(exception)
```

### What gets sent

Records contribute their class name and identifier — never their attributes.
Passing `subject: customer` sends `{"type" => "Customer", "external_id" => "42"}`,
not the customer's columns. Anything you want in the event goes in `properties`,
explicitly.

Property keys matching `config.redact_keys` are replaced with `[redacted]` before
the event leaves your process. Wayfinder refuses them at the door too, but a
rejected event is a lost event — redaction here means the secret never travels.

Never put passwords, session tokens, card data or raw request bodies in
`properties`. The gem will catch the obvious cases; it cannot catch all of them.

## Idempotency

Every envelope carries a client-generated ULID as its `id`. Wayfinder has a unique
index on `(connection, id)`, so a retried delivery is a no-op rather than a
duplicate. Retry freely.

## Exception reporting

Off by default. To stream unhandled exceptions:

```ruby
config.report_exceptions = true
```

This subscribes to `Rails.error` and sends the exception class, message and the
first five backtrace lines. It never sends bindings or local variables.

## Signing scheme

```
signed_payload = "#{timestamp}.#{raw_body}"
signature      = "v1=" + HMAC-SHA256(signing_secret, signed_payload).hexdigest
```

Sent as `X-Wayfinder-Signature`, with the unix timestamp in
`X-Wayfinder-Timestamp`. Wayfinder rejects anything more than five minutes out of
step. Because the timestamp is inside the signed payload, a captured request
cannot be replayed with a fresh one.

Wayfinder implements the same algorithm independently on the server. Changing
it here is a breaking change to the wire protocol, not a refactor: every
connected product would stop being able to deliver. `spec/wayfinder/signal/signature_spec.rb`
pins a fixed vector for that reason.

## Rotating the signing secret

Wayfinder issues a new credential without revoking the old one. Deploy the new
secret, confirm events are arriving, then revoke the old credential from the
connection page. There is no window where deliveries fail.
