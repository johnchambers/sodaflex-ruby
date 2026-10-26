# frozen_string_literal: true

# The gem was wayfinder-signal, and products called it `Wayfinder::Signal`.
# This keeps that name working for one version, so upgrading is a Gemfile
# change rather than a hunt through every call site. It goes in 0.5.0.
require_relative "../sodaflex"

module Wayfinder
  Signal = ::SodaFlex
end
