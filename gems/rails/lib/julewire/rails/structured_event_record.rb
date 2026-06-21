# frozen_string_literal: true

require "active_support/parameter_filter"

module Julewire
  module Rails
    class StructuredEventRecord
      DEBUG_EVENT_PREFIXES = %w[
        action_view.
        active_record.
      ].freeze

      DEBUG_EVENTS = %w[
        action_controller.unpermitted_parameters
      ].freeze

      def initialize(configuration, parameter_filter: Core::UNSET)
        @configuration = configuration
        @parameter_filter_override = parameter_filter
      end

      def call(event, name:, payload:)
        values = Core::Integration::Values::Shape
        {
          timestamp: values.timestamp(event[:timestamp]),
          severity: severity_for(name),
          event: name,
          logger: "Rails.event",
          source: @configuration.source,
          context: values.hash_or_empty(event[:context]),
          attributes: attributes_for(event, payload),
          neutral: neutral_for(event)
        }.compact
      end

      def payload_hash(payload)
        case payload
        when nil
          {}
        when Hash
          values = Core::Integration::Values::Shape
          values.payload_hash(payload)
        else
          serialize_payload_object(payload)
        end
      end

      private

      def attributes_for(event, payload)
        values = Core::Integration::Values::Shape
        rails = payload.empty? ? {} : payload
        values.append_compact_field(rails, :tags, values.hash_or_empty(event[:tags]))
        { rails: rails }
      end

      def neutral_for(event)
        values = Core::Integration::Values::Shape
        values.source_location_attributes(event[:source_location])
      end

      def severity_for(name)
        return :debug if DEBUG_EVENTS.include?(name)
        return :debug if DEBUG_EVENT_PREFIXES.any? { name.start_with?(it) }

        :info
      end

      def serialize_payload_object(payload)
        if payload.respond_to?(:serialize)
          serialized = payload.serialize
          return object_payload_hash(serialized) if serialized.is_a?(Hash)

          { Julewire::Core::Fields::FieldSet::VALUE_KEY => serialized }
        else
          { Julewire::Core::Fields::FieldSet::VALUE_KEY => payload }
        end
      rescue StandardError => e
        {
          Julewire::Core::Fields::FieldSet::VALUE_KEY => payload,
          serialize_error_class: e.class.name
        }
      end

      def object_payload_hash(serialized)
        Julewire::Core::Fields::FieldSet.deep_symbolize_keys(filter_event_payload(serialized))
      end

      def filter_event_payload(payload)
        return payload unless @configuration.filter_event_payloads?

        filter = rails_parameter_filter
        return payload unless filter

        filtered = filter.filter(payload)
        filtered.is_a?(Hash) ? filtered : payload
      rescue StandardError
        payload
      end

      def rails_parameter_filter
        return @parameter_filter_override unless @parameter_filter_override.equal?(Core::UNSET)
        return @rails_parameter_filter if @rails_parameter_filter_loaded

        @rails_parameter_filter_loaded = true
        filters = rails_filter_parameters
        @rails_parameter_filter = build_parameter_filter(filters)
      end

      def build_parameter_filter(filters)
        return if filters.empty?

        ::ActiveSupport::ParameterFilter.new(::ActiveSupport::ParameterFilter.precompile_filters(filters))
      end

      def rails_filter_parameters
        app = ::Rails.application if defined?(::Rails) && ::Rails.respond_to?(:application)
        return Array(app.filter_parameters) if app.respond_to?(:filter_parameters)

        config = app.config if app.respond_to?(:config)
        filters = config.filter_parameters if config.respond_to?(:filter_parameters)
        Array(filters)
      rescue StandardError
        []
      end
    end
  end
end
