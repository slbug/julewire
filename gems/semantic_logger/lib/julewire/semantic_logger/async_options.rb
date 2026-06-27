# frozen_string_literal: true

module Julewire
  module SemanticLogger
    class AsyncOptions
      DEFAULT_MAX_QUEUE_SIZE = 10_000
      DEFAULTS = {
        max_queue_size: DEFAULT_MAX_QUEUE_SIZE,
        lag_check_interval: 1_000,
        lag_threshold_s: 30,
        batch: nil,
        batch_size: 300,
        batch_seconds: 5,
        non_blocking: false,
        dropped_message_report_seconds: 30,
        async_max_retries: 100
      }.freeze
      BATCH_OPTIONS = { batch_size: true, batch_seconds: true }.freeze
      KEYWORD_PARAMETER_KINDS = { key: true, keyreq: true }.freeze
      SUPPORTED_DEFAULTS = DEFAULTS.keys.to_h { [it, true] }.freeze
      ASYNC_APPENDER = ::SemanticLogger::Appender::Async
      ASYNC_APPENDER_ACCEPTS_ANY_KEYWORD =
        ASYNC_APPENDER.instance_method(:initialize).parameters.any? { |kind, _name| kind == :keyrest }
      ASYNC_BATCH_APPENDER = if ::SemanticLogger::Appender.const_defined?(:AsyncBatch, false)
                               ::SemanticLogger::Appender.const_get(:AsyncBatch, false)
                             end

      class << self
        def extract(options)
          configured = []
          values = DEFAULTS.to_h do |name, default|
            if options.key?(name)
              configured << name
              [name, options.delete(name)]
            else
              [name, default]
            end
          end

          new(values: values, configured: configured)
        end
      end

      def initialize(values:, configured:)
        @values = values
        @configured = configured
      end

      def async?(base_async)
        base_async || batch_enabled?
      end

      def max_queue_size
        @values.fetch(:max_queue_size)
      end

      def build_appender(sink)
        klass = appender_class
        klass.new(appender: sink, **constructor_options(klass))
      end

      private

      if ASYNC_APPENDER_ACCEPTS_ANY_KEYWORD
        def appender_class
          ASYNC_APPENDER
        end
      else
        def appender_class
          return ASYNC_APPENDER unless batch_enabled?

          ASYNC_BATCH_APPENDER
        end
      end

      def constructor_options(klass)
        supported = supported_options(klass)
        unsupported = unsupported_configured_options(supported)
        unless unsupported.empty?
          raise ArgumentError, "#{klass} does not support async option(s): #{unsupported.join(", ")}"
        end

        DEFAULTS.each_with_object({}) do |(name, _default), kwargs|
          next unless supported.fetch(name, false)

          value = @values.fetch(name)
          kwargs[name] = value unless value.nil?
        end
      end

      def supported_options(klass)
        parameters = klass.instance_method(:initialize).parameters
        return SUPPORTED_DEFAULTS if keyrest_constructor?(parameters)

        parameters.each_with_object({}) do |(kind, name), supported|
          supported[name] = true if KEYWORD_PARAMETER_KINDS.key?(kind)
        end
      end

      def keyrest_constructor?(parameters)
        parameters.any? { |kind, _name| kind == :keyrest }
      end

      def unsupported_configured_options(supported)
        @configured.reject do |name|
          mode_selector?(name) || supported.fetch(name, false) || default_value?(name) || inactive_batch_option?(name)
        end
      end

      def mode_selector?(name)
        name == :batch
      end

      def default_value?(name)
        @values.fetch(name) == DEFAULTS.fetch(name)
      end

      def inactive_batch_option?(name)
        BATCH_OPTIONS.key?(name) && !batch_enabled?
      end

      def batch_enabled?
        @values.fetch(:batch).equal?(true)
      end
    end
  end
end
