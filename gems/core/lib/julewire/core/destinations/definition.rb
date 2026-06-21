# frozen_string_literal: true

module Julewire
  module Core
    module Destinations
      class Definition
        OPTION_KEYS = %i[
          close_output
          encoder
          formatter
          max_record_bytes
          name
          on_drop
          on_failure
          output
          processors
        ].freeze

        INHERIT = Core.sentinel(:inherit)
        private_constant :INHERIT

        attr_reader :kind, :name

        def initialize(kind, **options)
          @kind = Destinations.normalize_name(kind)
          validate_options!(options)
          @name = Destinations.normalize_name(options.fetch(:name, @kind))
          @options = options.freeze
        end

        def build(defaults:, output_identities: nil)
          return build_factory_destination(defaults, output_identities: output_identities) if factory

          output = resolve(:output, defaults)
          reject_shared_output!(output, output_identities) if output_identities && !output.nil?

          Destination.new(
            name: name,
            close_output: resolve(:close_output, defaults),
            encoder: resolve(:encoder, defaults),
            formatter: resolve(:formatter, defaults),
            max_record_bytes: resolve(:max_record_bytes, defaults),
            on_drop: resolve(:on_drop, defaults),
            on_failure: resolve(:on_failure, defaults),
            output: output,
            error_backtrace_lines: defaults.fetch(:error_backtrace_lines),
            processors: resolve(:processors, defaults)
          )
        end

        def copy
          self.class.new(kind, **@options)
        end

        private

        def validate_options!(options)
          return if factory

          Validation.validate_options!(options, OPTION_KEYS, name: :destination)
        end

        def build_factory_destination(defaults, output_identities:)
          destination = factory.call(**factory_options(defaults))
          Registry.validate!(destination)
          reject_shared_output!(resource_identity(destination), output_identities) if output_identities
          destination
        end

        def resource_identity(destination)
          return destination.resource_identity if destination.respond_to?(:resource_identity)

          destination
        end

        def factory_options(defaults)
          options = @options.merge(name: name)
          options[:on_drop] = defaults.fetch(:on_drop) if !options.key?(:on_drop) && defaults.key?(:on_drop)
          options[:on_failure] = defaults.fetch(:on_failure) if !options.key?(:on_failure) && defaults.key?(:on_failure)
          options
        end

        def factory
          @factory ||= Destinations.factory_for(kind)
        end

        def resolve(key, defaults)
          value = @options.fetch(key) { INHERIT }
          return default_value(key, defaults) if value.equal?(INHERIT)

          value
        end

        def default_value(key, defaults)
          return defaults.fetch(key) if defaults.key?(key)

          case key
          when :close_output
            false
          when :encoder, :formatter, :on_drop, :on_failure
            raise ArgumentError, "destination default #{key} is required"
          when :max_record_bytes
            DEFAULT_MAX_RECORD_BYTES
          when :processors
            []
          when :output
            # No inherited output exists; build raises the required-output error.
            nil
          end
        end

        def reject_shared_output!(output, output_identities)
          previous_name = output_identities[output]
          if previous_name
            raise ArgumentError,
                  "destination #{name.inspect} shares output with destination #{previous_name.inspect}; " \
                  "use a transport adapter for shared sinks"
          end

          output_identities[output] = name
        end
      end
    end
  end
end
