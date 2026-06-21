# frozen_string_literal: true

require "zeitwerk"
require "julewire/core"

module Julewire
  module GCP
    CARRY_REQUEST_HEADERS = %w[
      traceparent
      tracestate
      x-cloud-trace-context
    ].freeze
    RECOMMENDED_MAX_RECORD_BYTES = 256 * 1024
    DEFAULT_MAX_RECORD_BYTES = RECOMMENDED_MAX_RECORD_BYTES
    DEFAULT_MAX_LABELS = 64
    DEFAULT_MAX_LABEL_KEY_BYTES = 512
    DEFAULT_MAX_LABEL_VALUE_BYTES = 64 * 1024
    JULEWIRE_PAYLOAD_FIELD = "julewire"

    class << self
      def operation(id: nil, producer: nil, first: nil, last: nil)
        values = Core::Integration::Values::Shape
        operation = {}
        values.append_field(operation, :id, id)
        values.append_field(operation, :producer, producer)
        values.append_field(operation, :first, first)
        values.append_field(operation, :last, last)
        {
          gcp: {
            operation: operation
          }
        }
      end

      def source_location(file: nil, line: nil, function: nil)
        values = Core::Integration::Values::Shape
        source_location = {}
        values.append_field(source_location, :file, file)
        values.append_field(source_location, :line, line)
        values.append_field(source_location, :function, function)
        {
          gcp: {
            source_location: source_location
          }
        }
      end
    end
  end

  loader = Zeitwerk::Loader.for_gem_extension(self)
  loader.inflector.inflect("gcp" => "GCP")
  loader.setup
  Core::Destinations.register(:gcp) { |name:, **options| GCP::Destination.new(name: name, **options) }
  Core::CLI::LogFormats.register(:gcp, decoder: GCP::LogDecoder, encoder: GCP::LogEncoder, priority: 100)
end
