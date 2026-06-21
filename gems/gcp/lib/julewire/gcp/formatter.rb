# frozen_string_literal: true

module Julewire
  module GCP
    class Formatter
      SEVERITIES = {
        debug: "DEBUG",
        info: "INFO",
        warn: "WARNING",
        error: "ERROR",
        fatal: "CRITICAL",
        unknown: "DEFAULT"
      }.freeze
      EMPTY_HASH = {}.freeze
      TRUE_VALUES = %w[true 1 yes].freeze
      private_constant :EMPTY_HASH, :TRUE_VALUES

      def initialize(project_id: nil,
                     operation_producer: nil,
                     service_context: nil,
                     trace_headers_paths: [
                       %i[carry http request_headers],
                       %i[payload request_headers],
                       %i[context request_headers]
                     ],
                     **options)
        FormatterOptions.validate!(options)
        @project_id = project_id
        @operation_producer = operation_producer
        @service_context = frozen_service_context(service_context)
        @trace_headers_paths = FormatterOptions.trace_headers_paths(trace_headers_paths)
        @label_formatter = FormatterOptions.label_formatter(options)
        @trace_id_path = FormatterOptions.trace_value_path(options[:trace_id_path])
        @span_id_path = FormatterOptions.trace_value_path(options[:span_id_path])
        @trace_sampled_path = FormatterOptions.trace_value_path(options[:trace_sampled_path])
        @execution_payload = ExecutionPayload.new(
          trace_id_path: @trace_id_path,
          span_id_path: @span_id_path,
          trace_sampled_path: @trace_sampled_path
        )
      end

      def call(record)
        Julewire::Record.validate_normalized!(record)

        error = record.fetch(:error)
        operation_options = operation_options(record)
        neutral_attributes = Core::Fields::AttributeKeys.from(record.fetch(:neutral))
        source_location_options = SourceLocationOptions.call(record, neutral_attributes)
        entry = {
          "severity" => severity(record.fetch(:severity)),
          "time" => record.fetch(:timestamp)
        }
        append_log_field(entry, "message", Core::Records::DisplayMessage.call(record))
        entry.tap do |log_entry|
          append_special_fields(
            log_entry,
            record,
            error: error,
            operation_options: operation_options,
            source_location_options: source_location_options,
            neutral_attributes: neutral_attributes
          )
          append_payload_fields(log_entry, record, error: error, operation_options: operation_options)
        end
      end

      private

      def frozen_service_context(value) = value ? Core::Fields::FieldSet.frozen_copy(value) : nil

      def append_special_fields(entry, record, error:, operation_options:, source_location_options:,
                                neutral_attributes:)
        trace_context = trace_context(record)
        append_log_field(entry, "httpRequest", HttpRequestFields.http_request(record, neutral_attributes))
        append_log_field(entry, "logging.googleapis.com/labels", labels(record))
        append_log_field(entry, "logging.googleapis.com/operation", operation(record, operation_options))
        append_log_field(
          entry,
          "logging.googleapis.com/sourceLocation",
          source_location(error, source_location_options)
        )
        append_log_field(entry, "logging.googleapis.com/trace", trace(record, trace_context))
        append_log_field(
          entry,
          "logging.googleapis.com/spanId",
          trace_value(record, trace_context, @span_id_path, :span_id)
        )
        append_log_field(
          entry,
          "logging.googleapis.com/trace_sampled",
          trace_value(record, trace_context, @trace_sampled_path, :trace_sampled)
        )
      end

      def append_payload_fields(entry, record, error:, operation_options:)
        stack_trace = stack_trace(error)
        append_log_field(entry, JULEWIRE_PAYLOAD_FIELD, julewire_payload(record,
                                                                         error: error,
                                                                         operation_options: operation_options,
                                                                         stack_trace: stack_trace))
        append_log_field(entry, "attributes", attributes_payload(record))
        append_log_field(entry, "payload", application_payload(record))
        append_log_field(entry, "stack_trace", stack_trace)
        append_log_field(entry, "serviceContext", @service_context)
      end

      def append_log_field(entry, key, value)
        return if value.nil?
        return if (value.is_a?(Hash) || value.is_a?(Array)) && value.empty?

        entry[key] = value
        nil
      end

      def severity(value) = SEVERITIES.fetch(value)

      def labels(record)
        @label_formatter.call(record.fetch(:labels))
      end

      def operation(record, options)
        execution = record.fetch(:execution)
        id = options[:id] || execution[:id] || record.lineage.root_reference&.fetch(:id, nil)
        return unless id

        operation = {
          "id" => id.to_s
        }
        append_log_field(operation, "producer", operation_producer(record, options))
        operation["first"] = true if true_value?(options[:first])
        operation["last"] = true if record.fetch(:kind) == :summary || true_value?(options[:last])
        operation
      end

      def operation_options(record)
        options = record.dig(:payload, :gcp, :operation)
        options.is_a?(Hash) ? options : EMPTY_HASH
      end

      def operation_producer(record, options)
        options[:producer] || @operation_producer || record[:source] || record[:logger]
      end

      def source_location(error, options)
        return SourceLocation.call(options) unless options.empty?
        return unless error.is_a?(Hash) && !error.empty?

        SourceLocation.from_error(error)
      end

      def trace(record, trace_context)
        value = trace_value(record, trace_context, @trace_id_path, :trace_id)
        return unless value

        trace = value.to_s
        return trace if trace.start_with?("projects/") || @project_id.nil?

        "projects/#{@project_id}/traces/#{trace}"
      end

      def trace_context(record)
        @trace_headers_paths.each do |path|
          context = TraceContext.extract(Core::Integration::Values::Read.path_value(record, path))
          return context unless context.empty?
        end
        EMPTY_HASH
      end

      def trace_value(record, trace_context, path, key)
        value = Core::Integration::Values::Read.path_value(record, path) if path
        Core::Integration::Values::Read.blank?(value) ? trace_context[key] : value
      end

      def application_payload(record)
        payload = record.fetch(:payload)
        control = payload[:gcp]
        remove_gcp_control_payload(payload, control)
      end

      def attributes_payload(record)
        record.fetch(:attributes)
      end

      def remove_gcp_control_payload(payload, control)
        return payload unless control.is_a?(Hash) && gcp_control_payload?(control)

        cleaned_payload = payload.dup
        cleaned_control = control.dup
        cleaned_control.delete(:operation)
        cleaned_control.delete(:source_location)
        if cleaned_control.empty?
          cleaned_payload.delete(:gcp)
        else
          cleaned_payload[:gcp] = cleaned_control
        end
        cleaned_payload
      end

      def gcp_control_payload?(control)
        control.key?(:operation) || control.key?(:source_location)
      end

      def julewire_payload(record, error:, operation_options:, stack_trace: nil)
        {}.tap do |payload|
          append_log_field(payload, :kind, record.fetch(:kind))
          append_log_field(payload, :event, record.fetch(:event))
          append_log_field(payload, :logger, record.fetch(:logger))
          append_log_field(payload, :source, record.fetch(:source))
          append_log_field(
            payload,
            :execution,
            @execution_payload.call(record, operation_options: operation_options)
          )
          append_log_field(payload, :context, record.fetch(:context))
          append_log_field(payload, :error, julewire_error(error, stack_trace: stack_trace))
          append_log_field(payload, :metrics, record[:metrics])
        end
      end

      def julewire_error(error, stack_trace:)
        return error unless error.is_a?(Hash) && stack_trace

        StackTrace.remove_backtraces(error)
      end

      def stack_trace(error)
        return unless error.is_a?(Hash) && !error.empty?

        StackTrace.call(error)
      end

      def true_value?(value)
        TRUE_VALUES.include?(value.to_s.downcase)
      end
    end
  end
end
