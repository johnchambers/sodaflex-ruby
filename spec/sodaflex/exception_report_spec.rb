# frozen_string_literal: true

require "spec_helper"

# Reporting exceptions differs from reporting a signup in ways that make a bad
# day worse if ignored. These are the three mechanisms Honeybadger's gem has and
# this one did not.
RSpec.describe SodaFlex::ExceptionReport do
  def raised(klass = StandardError, message = "boom")
    raise klass, message
  rescue StandardError => e
    e
  end

  describe "exceptions nobody wants to see" do
    # A bot requesting /wp-admin is not an error. Reporting these buries the ones
    # that matter, which is the failure the report exists to prevent.
    it "ignores the ones Rails raises while serving ordinary traffic" do
      stub_const("ActionController::RoutingError", Class.new(StandardError))

      error = begin
        raise ActionController::RoutingError, "No route matches"
      rescue StandardError => e
        e
      end

      expect(described_class.ignored?(error)).to be(true)
    end

    it "ignores a subclass of one, since ancestors count" do
      stub_const("ActiveRecord::RecordNotFound", Class.new(StandardError))
      stub_const("MissingWidget", Class.new(ActiveRecord::RecordNotFound))

      error = begin
        raise MissingWidget, "gone"
      rescue StandardError => e
        e
      end

      expect(described_class.ignored?(error)).to be(true)
    end

    it "ignores anything the host application adds" do
      expect(described_class.ignored?(raised, [ "StandardError" ])).to be(true)
    end

    it "does not ignore an ordinary error" do
      expect(described_class.ignored?(raised)).to be(false)
    end
  end

  describe "what it sends" do
    it "carries the class and the message" do
      report = described_class.call(raised(ArgumentError, "wrong number"))

      expect(report[:exception_class]).to eq("ArgumentError")
      expect(report[:message]).to eq("wrong number")
    end

    it "truncates a message rather than sending an essay" do
      report = described_class.call(raised(StandardError, "x" * 5_000))

      expect(report[:message].length).to eq(described_class::MAX_MESSAGE)
    end

    it "names the frame it happened in, so grouping has one value to key on" do
      report = described_class.call(raised)

      expect(report[:origin]).to be_a(String)
      expect(report[:origin]).to eq(report[:location].first)
    end

    it "bounds the backtrace" do
      error = raised
      error.set_backtrace(Array.new(200) { |i| "/app/thing_#{i}.rb:1:in 'call'" })

      expect(described_class.call(error)[:location].size).to eq(described_class::MAX_FRAMES)
    end

    it "survives an exception with no backtrace at all" do
      error = StandardError.new("never raised")

      report = described_class.call(error)
      expect(report[:location]).to eq([])
      expect(report[:origin]).to be_nil
    end
  end

  describe "backtraces" do
    # Absolute paths differ between boxes, which defeats grouping, and they
    # publish the filesystem layout of a customer-facing application.
    it "makes application frames relative to the project" do
      error = raised
      error.set_backtrace([ "#{Dir.pwd}/app/models/order.rb:42:in 'total'" ])

      expect(described_class.call(error)[:origin]).to eq("app/models/order.rb:42:in 'total'")
    end

    it "marks gem frames rather than showing where gems are installed" do
      error = raised
      error.set_backtrace([ "/usr/lib/ruby/gems/3.4.0/gems/pay-7.0.0/lib/pay.rb:10:in 'charge'" ])

      origin = described_class.call(error)[:origin]
      expect(origin).to start_with("[gem]")
      expect(origin).not_to include("/usr/lib")
    end

    # The line that matters is almost never in a gem.
    it "puts application frames above gem frames" do
      error = raised
      error.set_backtrace([
        "/usr/lib/ruby/gems/3.4.0/gems/pay-7.0.0/lib/pay.rb:10:in 'charge'",
        "#{Dir.pwd}/app/models/order.rb:42:in 'total'"
      ])

      expect(described_class.call(error)[:origin]).to eq("app/models/order.rb:42:in 'total'")
    end

    # Ruby's own library is not under a gem path, so without this the top frame
    # of a stack unwinding through Kernel#require becomes what grouping keys on,
    # and unrelated errors get filed together.
    it "treats Ruby's standard library as not-your-code too" do
      error = raised
      error.set_backtrace([
        "#{RbConfig::CONFIG["rubylibdir"]}/bundled_gems.rb:60:in 'Kernel.require'",
        "#{Dir.pwd}/app/models/order.rb:42:in 'total'"
      ])

      expect(described_class.call(error)[:origin]).to eq("app/models/order.rb:42:in 'total'")
    end

    it "leaves out its own frames, which are noise in somebody else's report" do
      error = raised
      error.set_backtrace([
        "/gems/sodaflex/lib/sodaflex/client.rb:1:in 'deliver'",
        "#{Dir.pwd}/app/models/order.rb:42:in 'total'"
      ])

      expect(described_class.call(error)[:location].join).not_to include("lib/sodaflex")
    end
  end

  describe "causes" do
    # `raise Foo rescue raise Bar` loses the real cause without this.
    it "carries the exception underneath" do
      error = begin
        begin
          raise ArgumentError, "the real problem"
        rescue StandardError
          raise RuntimeError, "the one you see"
        end
      rescue StandardError => e
        e
      end

      report = described_class.call(error)
      expect(report[:exception_class]).to eq("RuntimeError")
      expect(report[:causes].first[:exception_class]).to eq("ArgumentError")
      expect(report[:causes].first[:message]).to eq("the real problem")
    end

    it "omits the key entirely when there is no cause" do
      expect(described_class.call(raised)).not_to have_key(:causes)
    end

    it "stops rather than following a chain forever" do
      error = raised
      allow(error).to receive(:cause).and_return(error)

      expect(described_class.call(error)[:causes].size).to eq(described_class::MAX_CAUSES)
    end
  end

  describe "what it never sends" do
    # An exception's bindings and instance variables routinely hold customer
    # data. Only the class, the message and where it happened travel.
    it "sends nothing but the class, message, location and causes" do
      error = raised
      error.instance_variable_set(:@credit_card, "4242424242424242")

      report = described_class.call(error)

      expect(report.keys - %i[exception_class message location origin causes]).to be_empty
      expect(report.to_s).not_to include("4242")
    end
  end
end
