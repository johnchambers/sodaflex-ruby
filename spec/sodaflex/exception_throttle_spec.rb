# frozen_string_literal: true

require "spec_helper"

# One bad deploy raises the same error on every request. Without a cap, a broken
# page becomes a broken job queue too, and the hundredth identical report tells
# nobody anything the first did not.
RSpec.describe SodaFlex::ExceptionThrottle do
  subject(:throttle) { described_class.new(limit: 3) }

  it "allows up to the limit" do
    3.times { expect(throttle.allow?("BoomError")).to be(true) }
  end

  it "stops after it" do
    3.times { throttle.allow?("BoomError") }

    expect(throttle.allow?("BoomError")).to be(false)
  end

  # Per class, because a flood of one error must not hide a different one
  # starting at the same time — which is exactly when a second one is likely.
  it "counts each class separately" do
    4.times { throttle.allow?("BoomError") }

    expect(throttle.allow?("OtherError")).to be(true)
  end

  it "says once that it has started suppressing, so silence is not mistaken for health" do
    expect(SodaFlex).to receive(:log).with(:warn, /throttling BoomError/).once

    6.times { throttle.allow?("BoomError") }
  end

  it "starts again in the next window" do
    3.times { throttle.allow?("BoomError") }
    expect(throttle.allow?("BoomError")).to be(false)

    allow(Process).to receive(:clock_gettime).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 61)

    expect(throttle.allow?("BoomError")).to be(true)
  end

  it "does nothing at all when no limit is set" do
    unlimited = described_class.new(limit: nil)

    1_000.times { expect(unlimited.allow?("BoomError")).to be(true) }
  end
end
