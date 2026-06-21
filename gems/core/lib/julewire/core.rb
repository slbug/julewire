# frozen_string_literal: true

require "zeitwerk"

module Julewire
  # Each gem extends the shared Julewire namespace.
  loader = Zeitwerk::Loader.for_gem_extension(self)
  loader.inflector.inflect("cli" => "CLI")
  loader.ignore("#{__dir__}/core/testing.rb", "#{__dir__}/core/testing")
  loader.setup

  module Core
    DEFAULT_MAX_RECORD_BYTES = 1_048_576
    MAX_BACKTRACE_LINES = 20
    NORMALIZATION_MAX_DEPTH = 128
    CIRCULAR_REFERENCE = "[Circular]"

    class << self
      def sentinel(name) = Sentinel.new(name)

      def normalize_name(value, name: :name)
        case value
        when String
          raise ArgumentError, "#{name} must not be empty" if value.empty?

          value.to_sym
        when Symbol
          raise ArgumentError, "#{name} must not be empty" if value.name.empty?

          value
        else
          raise ArgumentError, "#{name} must be a String or Symbol"
        end
      end

      def deep_compact_empty(value)
        Serialization::DeepCompactEmpty.call(value)
      end

      def emit_input(input, fields)
        return fields if input.equal?(UNSET)
        return input if fields.empty?
        return input.merge(fields) if input.is_a?(Hash)

        { message: input.to_s }.merge(fields)
      end
    end

    UNSET = sentinel(:unset)
    MISSING = sentinel(:missing)
    private_constant :MISSING
  end

  extend Core::FacadeMethods

  Core::RuntimeLocator.current = Core::Runtime.new
  Core.singleton_class.class_eval do
    define_method(:loader) { loader }
    private :loader
  end

  ConsoleFormatter = Core::Records::ConsoleFormatter
  JsonEncoder = Core::Serialization::JsonEncoder
  Match = Core::Processing::Match
  Record = Core::Records::Record
  RecordDraft = Core::Records::Draft
  RecordFormatter = Core::Records::Formatter
  Sampling = Core::Processing::Sampling
  Serializer = Core::Serialization::Serializer
  Tail = Core::Diagnostics::Tail
  TailSampling = Core::Destinations::TailSampling
  TextEncoder = Core::Serialization::TextEncoder

  Core::Processing.register(:sampling) do |rate:, key: nil|
    Core::Processing::Sampling.head(rate: rate, key: key)
  end
  Core::Destinations.register(:tail_sampling) do |name:, **options|
    Core::Destinations::TailSampling.new(name: name, **options)
  end
end
