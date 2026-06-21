# frozen_string_literal: true

require "zeitwerk"
require "julewire/core"

module Julewire
  module RailsSupport
    class Error < Julewire::Error; end
  end

  loader = Zeitwerk::Loader.for_gem_extension(self)
  loader.setup
end
