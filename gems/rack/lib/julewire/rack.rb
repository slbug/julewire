# frozen_string_literal: true

require "zeitwerk"
require "julewire/core"

module Julewire
  module Rack
    class Error < Julewire::Error; end
  end

  loader = Zeitwerk::Loader.for_gem_extension(self)
  loader.setup
end
