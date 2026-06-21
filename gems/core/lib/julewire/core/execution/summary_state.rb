# frozen_string_literal: true

module Julewire
  module Core
    module Execution
      class SummaryState
        Measurement = Data.define(:count_key, :duration_key)
        private_constant :Measurement

        def initialize(event:, severity:, source:)
          @event = event
          @severity = severity
          @source = source
          @payload = {}
          @neutral = {}
          @attributes = {}
          @metrics = {}
          @errors = []
          @error_severity = nil
          @record_input = nil
        end

        def payload_hash
          Fields::FieldSet.deep_dup(@payload)
        end

        def metrics_hash
          Fields::FieldSet.deep_dup(@metrics)
        end

        def add(fields, owned: false)
          merge_fields!(@payload, fields, owned: owned)
        end

        def add_attributes(fields, owned: false)
          deep_merge_fields!(@attributes, fields, owned: owned)
        end

        def add_neutral(fields, owned: false)
          deep_merge_fields!(@neutral, fields, owned: owned)
        end

        def increment_attribute(path, by: 1)
          path = Fields::Internal.normalize_path(path)
          raise ArgumentError, "attribute path is required" if path.empty?

          container = attribute_container(path)
          key = path.last
          value = Fields::FieldSet.value_for(container, key, default: MISSING)
          existing = !value.equal?(MISSING)
          container[Fields::Internal.normalize_key(key)] = incremented_value(value, by, existing: existing)
        end

        def increment(key, by: 1)
          key = Fields::Internal.normalize_key(key)
          value = Fields::FieldSet.value_for(@payload, key, default: MISSING)
          existing = !value.equal?(MISSING)
          @payload[key] = incremented_value(value, by, existing: existing)
        end

        def append(key, value)
          key = Fields::Internal.normalize_key(key)
          current = Fields::FieldSet.value_for(@payload, key, default: MISSING)
          values = array_value(current, existing: !current.equal?(MISSING))
          @payload[key] = values
          values << Fields::FieldSet.deep_dup(value)
        end

        def record_error(error, severity: nil)
          @errors << error
          @error_severity = Records::Severity.normalize(severity) unless severity.nil?
        end

        def non_standard_exception?
          @errors.any? { !it.is_a?(StandardError) }
        end

        def record_duration(duration_ms)
          @metrics[:duration_ms] = duration_ms
        end

        def measurement(key)
          base = measurement_base(key)
          Measurement.new(:"#{base}_count", :"#{base}_duration_ms")
        end

        def record_measurement(measurement, duration_ms)
          increment(measurement.count_key)
          increment_metric(measurement.duration_key, by: duration_ms)
        end

        def record_input(**fields)
          Fields::FieldSet.deep_dup(owned_record_input(**fields))
        end

        def owned_record_input(**fields)
          @record_input || build_record_input(**fields)
        end

        def finalize_record_input(**fields)
          @record_input = build_record_input(**fields)
        end

        private

        def merge_fields!(target, fields, owned:)
          if owned
            Fields::Internal.merge_owned!(target, fields)
          else
            Fields::FieldSet.merge!(target, fields)
          end
        end

        def deep_merge_fields!(target, fields, owned:)
          if owned
            Fields::Internal.deep_merge_owned!(target, fields)
          else
            Fields::Internal.deep_merge!(target, fields)
          end
        end

        def build_record_input(timestamp:, execution:, context:, carry:, neutral:, attributes:, labels:)
          {
            timestamp: timestamp,
            kind: :summary,
            event: @event,
            source: @source,
            execution: execution,
            context: context,
            carry: carry,
            neutral: neutral_hash(neutral),
            attributes: attributes_hash(attributes),
            labels: labels,
            metrics: metrics_hash,
            payload: payload_hash,
            error: @errors.last
          }.tap do |record|
            severity = summary_severity
            record[:severity] = severity if severity
          end
        end

        def attributes_hash(base_attributes)
          return base_attributes if @attributes.empty?

          Fields::Internal.deep_merge(base_attributes, @attributes)
        end

        def neutral_hash(base_neutral)
          return base_neutral if @neutral.empty?

          Fields::Internal.deep_merge(base_neutral, @neutral)
        end

        def array_value(value, existing:)
          return [] unless existing
          return value if value.is_a?(Array)

          [value]
        end

        def incremented_value(value, by, existing:)
          return Fields::FieldSet.deep_dup(by) unless existing
          return value + by if value.is_a?(Numeric) && by.is_a?(Numeric)

          array_value(value, existing: true).tap { it << Fields::FieldSet.deep_dup(by) }
        end

        def increment_metric(key, by:)
          value = Fields::FieldSet.value_for(@metrics, key, default: MISSING)
          existing = !value.equal?(MISSING)
          @metrics[key] = incremented_value(value, by, existing: existing)
        end

        def measurement_base(key)
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise ArgumentError, "measurement key must be a String or Symbol"
          end

          base = key.to_s
          raise ArgumentError, "measurement key is required" if base.empty?

          base
        end

        def attribute_container(path)
          path[0...-1].reduce(@attributes) do |container, key|
            normalized = Fields::Internal.normalize_key(key)
            child = container[normalized]
            unless child.is_a?(Hash)
              child = {}
              container[normalized] = child
            end
            child
          end
        end

        def summary_severity
          return @severity if @errors.empty?

          @error_severity || :error
        end
      end
    end
  end
end
