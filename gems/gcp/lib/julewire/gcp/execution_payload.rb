# frozen_string_literal: true

module Julewire
  module GCP
    class ExecutionPayload
      def initialize(trace_id_path:, span_id_path:, trace_sampled_path:)
        @trace_keys = trace_execution_keys(trace_id_path, span_id_path, trace_sampled_path)
      end

      def call(record, operation_options:)
        execution = record.fetch(:execution)
        output = nil
        execution.each do |key, value|
          next if promoted_key?(key, value, operation_options)

          (output ||= {})[key] = value
        end
        output
      end

      private

      def promoted_key?(key, value, operation_options)
        return true if key == :id && !operation_options[:id]

        @trace_keys.key?(key) && !Core::Integration::Values::Read.blank?(value)
      end

      def trace_execution_keys(*paths)
        paths.map { trace_execution_key(it) }.to_h { [it, true] }
      end

      def trace_execution_key(path)
        return unless path&.length == 2
        return unless path.fetch(0) == :execution

        path.fetch(1)
      end
    end
  end
end
