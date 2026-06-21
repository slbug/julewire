# frozen_string_literal: true

module Julewire
  module Core
    class Configuration
      ATTRIBUTES = %i[
        destinations
        emit_non_standard_exception_summaries
        error_backtrace_lines
        labels
        level
        on_drop
        on_failure
        pipeline_close_timeout
        processors
      ].freeze
      REGISTRY_ATTRIBUTES = %i[destinations labels processors].freeze
      SCALAR_ATTRIBUTES = (ATTRIBUTES - REGISTRY_ATTRIBUTES).freeze

      attr_accessor(*SCALAR_ATTRIBUTES)
      attr_reader(*REGISTRY_ATTRIBUTES)

      def initialize(**options)
        reject_unknown_options!(options)
        @destinations = options.fetch(:destinations) { Destinations::Registry.new }
        @emit_non_standard_exception_summaries = options.fetch(:emit_non_standard_exception_summaries, false)
        @error_backtrace_lines = options.fetch(:error_backtrace_lines, Core::MAX_BACKTRACE_LINES)
        @labels = options.fetch(:labels) { Fields::StaticLabels.new }
        @level = options.fetch(:level, :debug)
        @on_drop = options.fetch(:on_drop, nil)
        @on_failure = options.fetch(:on_failure, nil)
        @pipeline_close_timeout = options.fetch(:pipeline_close_timeout, 1)
        @processors = options.fetch(:processors) { Processing::ProcessorRegistry.new }
      end

      def validate!
        validate_contracts!
        Validation.validate_non_negative_integer!(
          error_backtrace_lines,
          name: :error_backtrace_lines
        )
        Validation.validate_timeout!(
          pipeline_close_timeout,
          name: :pipeline_close_timeout
        )
        Records::Severity.normalize(level)
        self
      end

      def snapshot
        validate!
        copy.tap do |configuration|
          configuration.level = Records::Severity.normalize(level)
          configuration.freeze
        end
      end

      def copy
        self.class.new(**copy_options)
      end

      def build_pipeline(invalid_severity_reporter: Diagnostics::InvalidSeverityReporter.counter)
        Processing::Pipeline.new(configuration: self, invalid_severity_reporter: invalid_severity_reporter)
      end

      def freeze
        destinations.freeze
        labels.freeze
        processors.freeze
        super
      end

      private

      def reject_unknown_options!(options)
        Validation.validate_options!(options, ATTRIBUTES, name: :configuration)
      end

      def validate_contracts!
        Validation.validate_callable!(on_drop, name: :on_drop, allow_nil: true)
        Validation.validate_callable!(on_failure, name: :on_failure, allow_nil: true)
      end

      def copy_options
        {
          destinations: destinations.copy,
          emit_non_standard_exception_summaries: emit_non_standard_exception_summaries,
          error_backtrace_lines: error_backtrace_lines,
          labels: labels.copy,
          level: level,
          on_drop: on_drop,
          on_failure: on_failure,
          pipeline_close_timeout: pipeline_close_timeout,
          processors: processors.copy
        }
      end
    end
  end
end
