# frozen_string_literal: true

require "time"

module Julewire
  module SemanticLogger
    class Transport
      LOGGER_NAME = "julewire"
      DEFAULT_MAX_QUEUE_SIZE = AsyncOptions::DEFAULT_MAX_QUEUE_SIZE
      LEVEL_MAP = {
        # SemanticLogger has no unknown level; fatal keeps unknown core records visible.
        unknown: :fatal
      }.freeze
      LEVEL_SET = ::SemanticLogger::LEVELS.to_h { [it, true] }.freeze

      def initialize(**options)
        @mutex = Mutex.new
        @async = options.delete(:async)
        @async_options = AsyncOptions.extract(options)
        @async = @async_options.async?(@async)
        @max_queue_size = @async_options.max_queue_size
        @health = Core::Integration::DestinationHealth.new(counter_keys: %i[writes])
        @appenders = build_appenders(
          appenders: options.delete(:appenders),
          appender: options.delete(:appender),
          file_name: options.delete(:file_name),
          io: options.delete(:io),
          options: options
        )
        @sink = build_sink(@appenders)
        @appender = build_transport_appender(@sink)
      end

      def write(value, severity:)
        degradation_marker = @health.degradation_marker
        log = log_for(value, severity: severity)
        @health.increment(:writes)
        @mutex.synchronize { appender.log(log) } unless @async
        appender.log(log) if @async
        @health.clear_degradation_if_unchanged(degradation_marker)
      rescue StandardError => e
        @health.record_failure(e)
        raise
      end

      def flush
        degradation_marker = @health.degradation_marker
        appender.flush
        @health.clear_degradation_if_unchanged(degradation_marker)
        nil
      end

      def close
        appender.close
        @closed = true
        nil
      end

      def reopen
        degradation_marker = @health.degradation_marker
        appender.reopen if appender.respond_to?(:reopen)
        @closed = false
        @health.clear_degradation_if_unchanged(degradation_marker)
        nil
      end

      def after_fork! = reopen

      def health
        snapshot = @health.snapshot(status: status)
        counts = snapshot.fetch(:counts)

        {
          type: "semantic_logger",
          status: snapshot.fetch(:status),
          async: @async,
          warnings: lifecycle_warnings,
          last_failure: snapshot[:last_failure],
          counts: {
            writes: counts.fetch(:writes),
            failures: counts.fetch(:failures)
          },
          appender: appender_health(appender),
          appenders: @appenders.each_with_index.map { |child, index| appender_health(child, index: index) }
        }
      end

      private

      attr_reader :appender

      def build_appenders(appenders:, appender:, file_name:, io:, options:)
        specs = appenders.is_a?(Hash) ? [appenders] : Array(appenders).dup
        specs << { appender: appender } if appender
        specs << { file_name: file_name } if file_name
        specs << { io: io } if io
        raise ArgumentError, "semantic logger transport requires io, file_name, appender, or appenders" if specs.empty?

        specs.map { build_appender(it, defaults: options) }
      end

      def build_appender(spec, defaults:)
        options = normalize_appender_spec(spec, defaults: defaults)
        options[:formatter] ||= ExactFormatter.new
        ::SemanticLogger::Appender.factory(**options, async: false, batch: false)
      end

      def normalize_appender_spec(spec, defaults:)
        case spec
        when Hash
          defaults.merge(spec)
        else
          defaults.merge(appender: spec)
        end
      end

      def build_sink(appenders)
        return appenders.first if appenders.one?

        ::SemanticLogger::Appenders.new.tap do |collection|
          appenders.each { collection << it }
        end
      end

      def build_transport_appender(sink)
        return sink unless @async

        @async_options.build_appender(sink)
      end

      def log_for(value, severity:)
        log = ::SemanticLogger::Log.new(LOGGER_NAME, level_for(severity))
        log.assign(payload: { ExactFormatter::PAYLOAD_KEY => value })
        log
      end

      def level_for(severity)
        semantic_level(severity)
      end

      def semantic_level(value)
        level = LEVEL_MAP.fetch(value, value)
        return level if LEVEL_SET.key?(level)

        :info
      end

      def status
        return :closed if @closed

        :degraded if async_appender_inactive?
      end

      def async_appender_inactive?
        @async && !appender.active?
      end

      def lifecycle_warnings
        LifecycleWarnings.call(async: @async, appender_count: @appenders.length, max_queue_size: @max_queue_size)
      end

      def appender_health(value, index: nil)
        AppenderHealth.call(value, index: index)
      end
    end
  end
end
