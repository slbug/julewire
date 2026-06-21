# frozen_string_literal: true

require "time"

module Julewire
  module SemanticLogger
    class Transport
      LOGGER_NAME = "julewire"
      DEFAULT_MAX_QUEUE_SIZE = 10_000
      LEVEL_MAP = {
        # SemanticLogger has no unknown level; fatal keeps unknown core records visible.
        unknown: :fatal
      }.freeze
      LEVEL_SET = ::SemanticLogger::LEVELS.to_h { [it, true] }.freeze

      def initialize(**options)
        @mutex = Mutex.new
        @async = options.delete(:async) { false }
        @max_queue_size = options.delete(:max_queue_size) { DEFAULT_MAX_QUEUE_SIZE }
        @lag_check_interval = options.delete(:lag_check_interval) { 1_000 }
        @lag_threshold_s = options.delete(:lag_threshold_s) { 30 }
        @write_count = 0
        @failure_count = 0
        @degraded = false
        @closed = false
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
        log = log_for(value, severity: severity)
        @mutex.synchronize do
          @write_count += 1
          # Synchronous appenders write under our mutex; async appenders own
          # queue synchronization and may block on bounded queues.
          appender.log(log) unless @async
        end
        appender.log(log) if @async
        clear_degraded
        nil
      rescue StandardError
        @mutex.synchronize do
          @failure_count += 1
          @degraded = true
        end
        raise
      end

      def flush
        appender.flush if appender.respond_to?(:flush)
        clear_degraded
        nil
      end

      def close
        appender.close if appender.respond_to?(:close)
        @mutex.synchronize { @closed = true }
        nil
      end

      def reopen
        appender.reopen if appender.respond_to?(:reopen)
        @mutex.synchronize do
          @closed = false
          @degraded = false
        end
        nil
      end

      def after_fork! = reopen

      def health
        counts = @mutex.synchronize do
          {
            closed: @closed,
            degraded: @degraded,
            failures: @failure_count,
            writes: @write_count
          }
        end

        {
          type: "semantic_logger",
          status: status(counts),
          async: @async,
          warnings: lifecycle_warnings,
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

        ::SemanticLogger::Appender::Async.new(
          appender: sink,
          lag_check_interval: @lag_check_interval,
          lag_threshold_s: @lag_threshold_s,
          max_queue_size: @max_queue_size
        )
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
        level = value.is_a?(Symbol) ? value : value.to_s.downcase.to_sym
        level = LEVEL_MAP.fetch(level, level)
        return level if LEVEL_SET.key?(level)

        :info
      end

      def status(counts)
        return :closed if counts.fetch(:closed)
        return :degraded if appender.is_a?(::SemanticLogger::Appender::Async) && !appender.active?
        return :degraded if counts.fetch(:degraded)

        :ok
      end

      def clear_degraded
        @mutex.synchronize { @degraded = false }
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
