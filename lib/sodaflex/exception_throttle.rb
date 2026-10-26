# frozen_string_literal: true

module SodaFlex
  # Caps how many times one exception class is reported per minute.
  #
  # One bad deploy raises the same error on every request. Without a cap, a
  # broken page becomes a broken job queue as well, and the hundredth identical
  # report tells nobody anything the first did not.
  #
  # Per class rather than overall, so a flood of one error cannot hide a
  # different one that starts at the same time — which is exactly when a second
  # error is most likely and most worth seeing.
  class ExceptionThrottle
    WINDOW = 60 # seconds

    def initialize(limit:)
      @limit = limit
      @counts = Hash.new(0)
      @window_started_at = monotonic_now
      @mutex = Mutex.new
    end

    # True when this one should be sent. Also reports the moment a class starts
    # being suppressed, once, so silence is never mistaken for health.
    def allow?(exception_class)
      return true if @limit.nil? || @limit <= 0

      @mutex.synchronize do
        reset_if_window_elapsed

        count = (@counts[exception_class] += 1)
        if count == @limit + 1
          SodaFlex.log(:warn, "throttling #{exception_class}: more than #{@limit} in a minute")
        end

        count <= @limit
      end
    end

    private
      def reset_if_window_elapsed
        return if monotonic_now - @window_started_at < WINDOW

        @counts.clear
        @window_started_at = monotonic_now
      end

      # Monotonic, so the clock being adjusted cannot jam the window open.
      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
