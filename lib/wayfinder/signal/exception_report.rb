# frozen_string_literal: true

require "set"

module Wayfinder
  module Signal
    # Turns an exception into the properties of an `exception.reported` event.
    #
    # Reporting exceptions differs from reporting a customer signing up in three
    # ways, each of which is a way to make a bad day worse if ignored. These are
    # the mechanisms Honeybadger's gem has and this one did not.
    #
    # 1. **Most exceptions are not errors.** A bot requesting /wp-admin raises
    #    ActionController::RoutingError. Reporting those buries the ones that
    #    matter under noise, which is the exact failure the report exists to
    #    prevent. IGNORED lists the ones nobody wants to see.
    #
    # 2. **Exceptions arrive in bursts.** One bad deploy can raise the same error
    #    thousands of times a minute. Unbounded reporting turns a broken page into
    #    a broken queue as well. Throttle counts per class and stops.
    #
    # 3. **Raw backtraces are unusable and leak.** Absolute paths differ between
    #    boxes, which defeats grouping, and they publish the filesystem layout of
    #    a customer-facing application. Frames are made relative and tagged.
    class ExceptionReport
      # Rails raises these in the ordinary course of serving traffic. Matched
      # against the exception's own class and its ancestors, so a subclass of
      # anything here is ignored too.
      IGNORED = %w[
        ActionController::RoutingError
        ActionController::UnknownFormat
        ActionController::UnknownHttpMethod
        ActionController::BadRequest
        ActionController::ParameterMissing
        ActionController::InvalidAuthenticityToken
        ActionController::InvalidCrossOriginRequest
        ActionDispatch::Http::MimeNegotiation::InvalidType
        ActionDispatch::RemoteIp::IpSpoofAttackError
        ActiveRecord::RecordNotFound
        Rack::QueryParser::InvalidParameterError
        Rack::QueryParser::ParameterTypeError
        Mime::Type::InvalidMimeType
      ].to_set.freeze

      # Enough to identify where it happened without shipping a novel. Grouping
      # only ever needs the top application frame.
      MAX_FRAMES = 20
      # `raise Foo rescue raise Bar` loses the real cause without this.
      MAX_CAUSES = 3
      MAX_MESSAGE = 500

      GEM_MARKER = "[gem]"
      PROJECT_MARKER = ""

      def self.ignored?(exception, extra = [])
        names = [ exception.class.name, *exception.class.ancestors.map(&:name) ].compact
        names.any? { |name| IGNORED.include?(name) || extra.include?(name) }
      end

      def self.call(...) = new(...).to_h

      def initialize(exception, config: Signal.config)
        @exception = exception
        @config = config
      end

      def to_h
        {
          exception_class: exception.class.name,
          message: exception.message.to_s.first(MAX_MESSAGE),
          location: frames(exception),
          # The top application frame, so Wayfinder can group on one value
          # instead of re-deriving it from the list every time.
          origin: frames(exception).first,
          causes: causes
        }.compact
      end

      private
        attr_reader :exception, :config

        def causes
          found = []
          current = exception.cause

          while current && found.size < MAX_CAUSES
            found << {
              exception_class: current.class.name,
              message: current.message.to_s.first(MAX_MESSAGE),
              origin: frames(current).first
            }.compact
            current = current.cause
          end

          found.empty? ? nil : found
        end

        # Application frames first and gem frames after, because the line that
        # matters is almost never in a gem — and if every frame is a gem frame,
        # the top one is still the most useful thing to show.
        def frames(error)
          all = Array(error.backtrace).map { |line| clean(line) }.compact
          application, library = all.partition { |line| !line.start_with?(GEM_MARKER) }

          (application + library).first(MAX_FRAMES)
        end

        def clean(line)
          line = line.to_s
          return nil if line.empty?
          # Our own frames are noise in a report about somebody else's code.
          return nil if line.include?("lib/wayfinder/signal")

          if (root = project_root) && line.start_with?(root)
            line.sub(root, PROJECT_MARKER).sub(%r{\A/}, "")
          elsif gem_path?(line)
            "#{GEM_MARKER} #{File.basename(line)}"
          else
            line
          end
        end

        def project_root
          @project_root ||= begin
            root = defined?(::Rails) && ::Rails.respond_to?(:root) ? ::Rails.root.to_s : Dir.pwd
            root.to_s.chomp("/")
          rescue StandardError
            nil
          end
        end

        # Gems and Ruby's own standard library both count as "not your code".
        # Ruby's is not under a gem path, so without the second check the top
        # frame of a stack that unwinds through Kernel#require becomes the thing
        # grouping keys on, which files unrelated errors together.
        def gem_path?(line)
          Gem.path.any? { |path| line.start_with?(path) } ||
            line.include?("/gems/") ||
            ruby_lib_dirs.any? { |path| line.start_with?(path) }
        rescue StandardError
          false
        end

        def ruby_lib_dirs
          @ruby_lib_dirs ||= [
            RbConfig::CONFIG["rubylibdir"], RbConfig::CONFIG["libdir"],
            RbConfig::CONFIG["rubyarchdir"]
          ].compact.reject(&:empty?)
        end
    end
  end
end
