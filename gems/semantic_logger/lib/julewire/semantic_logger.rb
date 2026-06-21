# frozen_string_literal: true

require "zeitwerk"
require "julewire/core"
require "semantic_logger"

module Julewire
  module SemanticLogger
    ENCODER = Julewire::JsonEncoder.new(append_newline: false).freeze
    private_constant :ENCODER
  end

  loader = Zeitwerk::Loader.for_gem_extension(self)
  loader.setup
  Core::Destinations.register(:semantic_logger) do |name:, **options|
    Julewire::SemanticLogger::Destination.new(name: name, **options)
  end
end
