# sodaflex

The `sodaflex` gem. The repository is `sodaflex-ruby` because `sodaflex` is the
application's own.

Sends operational events from a Rails application to SodaFlex.

[![CI](https://github.com/johnchambers/sodaflex-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/johnchambers/sodaflex-ruby/actions/workflows/ci.yml)

The gem is deliberately small. It knows how to build an event envelope, sign it,
and hand it to Active Job. It has no opinion about what any event means — that is
SodaFlex's job — and it shares no models or business logic with it.

## The guarantee

**SodaFlex being unavailable must never affect your product.**

Everything else here follows from that:

- `track` only builds an envelope and enqueues a job. Nothing blocks the request.
- The job uses a 2-second open timeout and a 3-second read timeout.
- Retries are bounded (5 attempts, polynomial backoff) and then stop.
- A 4xx that will never succeed is discarded immediately rather than retried.
- Every public method rescues `StandardError`. `track` returns `nil` on failure.
- Exhausted deliveries go to your `on_delivery_failure` handler, so they stay
  visible locally instead of vanishing.

If you can make this gem raise into a controller action, that is a bug.

## Renamed from wayfinder-signal

Version 0.4.0 renamed the gem from `wayfinder-signal` to `sodaflex`. For this
version only, the old names keep working, so upgrading is a Gemfile change:

- `require "wayfinder/signal"` and `Wayfinder::Signal` still work, and are this
  module under its old name.
- `WAYFINDER_SIGNAL_ENDPOINT`, `WAYFINDER_PRODUCT_KEY` and
  `WAYFINDER_SIGNING_SECRET` are read when the `SODAFLEX_*` ones are absent.
- `config.product_key =` still sets `brand_key`.
- `wayfinder:signal:*` rake tasks run the `sodaflex:*` ones.
- A visitor's first touch recorded in the old `wf_attribution` cookie is kept.

SodaFlex accepts both the old and new request headers, so a product can move
whenever it is next deployed. The old names go in 0.5.0.

## Install

```ruby
# Gemfile
gem "sodaflex"
```

```ruby
# config/initializers/sodaflex.rb
SodaFlex.configure do |config|
  config.endpoint       = ENV.fetch("SODAFLEX_ENDPOINT")
  config.brand_key      = ENV.fetch("SODAFLEX_BRAND_KEY")
  config.signing_secret = ENV.fetch("SODAFLEX_SIGNING_SECRET")
  config.environment    = Rails.env
  config.enabled        = !Rails.env.test?
  config.release        = ENV["GIT_SHA"]
end
```

Verify it:

```bash
bin/rails sodaflex:status          # shows configuration without printing secrets
bin/rails sodaflex:test            # sends one event synchronously and reports the result
```

## Use

```ruby
SodaFlex.track("customer.created",
  actor: current_user,
  subject: customer,
  customer: customer,
  properties: { plan: customer.plan_name, source: customer.acquisition_source })
```

Convenience wrappers for the events worth instrumenting first:

```ruby
SodaFlex.customer_created(customer, plan: "professional")
SodaFlex.onboarding_completed(customer)
SodaFlex.trial_started(customer)
SodaFlex.subscription_started(subscription, customer: customer, amount_cents: 24_900)
SodaFlex.invoice_paid(invoice, customer: customer, amount_cents: 24_900, currency: "EUR")
SodaFlex.invoice_failed(invoice, customer: customer)
SodaFlex.support_requested(customer, message: params[:message])
SodaFlex.feature_requested(customer, request: params[:request])
SodaFlex.release_deployed(release, version: "2026.07.30.1")
SodaFlex.deployment_failed(release, reason: "migration timeout")
SodaFlex.exception_reported(exception)
```

### What gets sent

Records contribute their class name and identifier — never their attributes.
Passing `subject: customer` sends `{"type" => "Customer", "external_id" => "42"}`,
not the customer's columns. Anything you want in the event goes in `properties`,
explicitly.

Property keys matching `config.redact_keys` are replaced with `[redacted]` before
the event leaves your process. SodaFlex refuses them at the door too, but a
rejected event is a lost event — redaction here means the secret never travels.

Never put passwords, session tokens, card data or raw request bodies in
`properties`. The gem will catch the obvious cases; it cannot catch all of them.

### Where a lead came from

`include SodaFlex::Attribution` in the controllers a prospect passes through,
and pass `sodaflex_attribution` with a lead. It keeps the first visit's
`utm_*` tags, click identifiers, external referrer and landing page in a
cookie for 90 days — first touch, not last.

**A marketing site on another domain.** Its visitors reach the product only
when they submit a form or follow a link, by which point the tags are behind
them and the referrer is the marketing site. Have the site pass them on as
fields or link parameters — `utm_source` and the rest, plus `referrer` and
`landing_page` — and they win over what the product's own request says. List
the site so arriving from it is not counted as a channel:

```ruby
config.own_hosts = %w[nibbleos.com]   # or SODAFLEX_OWN_HOSTS=nibbleos.com
```

## Idempotency

Every envelope carries a client-generated ULID as its `id`. SodaFlex has a unique
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

Sent as `X-SodaFlex-Signature`, with the unix timestamp in
`X-SodaFlex-Timestamp`. SodaFlex rejects anything more than five minutes out of
step. Because the timestamp is inside the signed payload, a captured request
cannot be replayed with a fresh one.

SodaFlex implements the same algorithm independently on the server. Changing
it here is a breaking change to the wire protocol, not a refactor: every
connected product would stop being able to deliver. `spec/wayfinder/signal/signature_spec.rb`
pins a fixed vector for that reason.

## Rotating the signing secret

SodaFlex issues a new credential without revoking the old one. Deploy the new
secret, confirm events are arriving, then revoke the old credential from the
connection page. There is no window where deliveries fail.
