# frozen_string_literal: true

require "test_helper"

module Julewire
  module SemanticLogger
    class TestAsyncOptions < Minitest::Test
      cover Julewire::SemanticLogger::AsyncOptions
      class NoopAppender < ::SemanticLogger::Subscriber
        attr_reader :logs

        def initialize
          super
          @logs = []
        end

        def log(log)
          @logs << log
        end

        def batch(logs)
          @logs.concat(logs)
        end

        def flush; end

        def close; end
      end

      class FixedAsyncAppender
        def initialize(appender:, max_queue_size:, lag_check_interval:, lag_threshold_s:); end
      end

      class FixedBatchAppender
        def initialize(
          appender:,
          max_queue_size:,
          lag_check_interval:,
          lag_threshold_s:,
          batch_size:,
          batch_seconds:
        )
          @appender = appender
          @options = {
            max_queue_size: max_queue_size,
            lag_check_interval: lag_check_interval,
            lag_threshold_s: lag_threshold_s,
            batch_size: batch_size,
            batch_seconds: batch_seconds
          }
        end
      end

      class PositionalNonBlockingAppender
        def initialize(non_blocking, appender:, max_queue_size:); end
      end

      class KeyrestAsyncAppender
        def initialize(appender:, **options); end
      end

      def test_extract_consumes_known_options_and_preserves_child_appender_options
        options = { io: :child, max_queue_size: 17, batch: true }

        async_options = AsyncOptions.extract(options)

        assert_equal({ io: :child }, options)
        assert_true async_options.async?(false)
        assert_equal 17, async_options.max_queue_size
      end

      def test_base_async_enables_async_without_batch_options
        async_options = AsyncOptions.extract({})

        assert_true async_options.async?(true)
        assert_false async_options.async?(false)
      end

      def test_fixed_signature_constructor_options_use_supported_defaults_only
        options = constructor_options_for(
          FixedAsyncAppender,
          max_queue_size: 17,
          non_blocking: false,
          dropped_message_report_seconds: 30,
          async_max_retries: 100
        )

        assert_equal(
          {
            max_queue_size: 17,
            lag_check_interval: 1_000,
            lag_threshold_s: 30
          },
          options
        )
      end

      def test_fixed_signature_constructor_options_reject_non_default_unsupported_options
        assert_unsupported_async_options(FixedAsyncAppender, /does not support async option\(s\): non_blocking/,
                                         non_blocking: true)
      end

      def test_fixed_signature_constructor_options_names_multiple_unsupported_options
        assert_unsupported_async_options(
          FixedAsyncAppender,
          /FixedAsyncAppender does not support async option\(s\): non_blocking, async_max_retries/,
          non_blocking: true,
          async_max_retries: 4
        )
      end

      def test_positional_parameters_do_not_count_as_supported_keywords
        assert_unsupported_async_options(PositionalNonBlockingAppender,
                                         /does not support async option\(s\): non_blocking/,
                                         non_blocking: true)
      end

      def test_fixed_signature_constructor_options_ignore_inactive_batch_options
        options = constructor_options_for(FixedAsyncAppender, batch_size: 2, batch_seconds: 9)

        refute_includes options, :batch_size
        refute_includes options, :batch_seconds
      end

      def test_fixed_signature_constructor_options_reject_active_batch_options
        assert_unsupported_async_options(FixedAsyncAppender, /does not support async option\(s\): batch_size/,
                                         batch: true, batch_size: 2)
      end

      def test_batch_signature_constructor_options_include_active_batch_options
        options = constructor_options_for(FixedBatchAppender, batch: true, batch_size: 2, batch_seconds: 9)

        assert_equal 2, options.fetch(:batch_size)
        assert_equal 9, options.fetch(:batch_seconds)
      end

      def test_keyrest_signature_constructor_options_accept_all_non_nil_defaults
        options = constructor_options_for(KeyrestAsyncAppender)

        assert_equal(
          {
            max_queue_size: 10_000,
            lag_check_interval: 1_000,
            lag_threshold_s: 30,
            batch_size: 300,
            batch_seconds: 5,
            non_blocking: false,
            dropped_message_report_seconds: 30,
            async_max_retries: 100
          },
          options
        )
      end

      def test_build_appender_uses_loaded_async_appender
        appender = build_loaded_appender(max_queue_size: 5, lag_check_interval: 12, lag_threshold_s: 3)

        assert_instance_of ::SemanticLogger::Appender::Async, appender
      ensure
        appender&.close
      end

      def test_batch_build_appender_uses_loaded_batch_proxy_when_available
        appender = build_loaded_appender(batch: true, batch_size: 2, batch_seconds: 9, max_queue_size: 5)

        assert_instance_of async_batch_class || ::SemanticLogger::Appender::Async, appender
      ensure
        appender&.close
      end

      def test_non_true_batch_value_does_not_select_batch_appender
        appender = build_loaded_appender(batch: :yes)

        assert_false AsyncOptions.extract(batch: :yes).async?(false)
        assert_instance_of ::SemanticLogger::Appender::Async, appender
      ensure
        appender&.close
      end

      def test_inactive_batch_options_do_not_select_batch_appender
        appender = build_loaded_appender(batch_size: 2, batch_seconds: 9)

        assert_false AsyncOptions.extract(batch_size: 2, batch_seconds: 9).async?(false)
        assert_instance_of ::SemanticLogger::Appender::Async, appender
      ensure
        appender&.close
      end

      def test_default_newer_async_options_build_on_every_supported_semantic_logger_version
        appender = build_loaded_appender(
          non_blocking: false,
          dropped_message_report_seconds: 30,
          async_max_retries: 100
        )

        assert_instance_of ::SemanticLogger::Appender::Async, appender
      ensure
        appender&.close
      end

      def test_non_default_v5_async_options_follow_loaded_semantic_logger_signature
        if semantic_logger_v5_async_options?
          appender = build_loaded_appender(
            non_blocking: true,
            dropped_message_report_seconds: 7,
            async_max_retries: 4
          )

          assert_predicate appender, :non_blocking?
          assert_equal 7, appender.processor.dropped_message_report_seconds
          assert_equal 4, appender.processor.async_max_retries
        else
          error = assert_raises(ArgumentError) { build_loaded_appender(non_blocking: true) }

          assert_match(/does not support async option\(s\): non_blocking/, error.message)
        end
      ensure
        appender&.close
      end

      private

      def constructor_options_for(klass, **options)
        AsyncOptions.extract(options).send(:constructor_options, klass)
      end

      def assert_unsupported_async_options(klass, message_pattern, **)
        error = assert_raises(ArgumentError) { constructor_options_for(klass, **) }

        assert_match(message_pattern, error.message)
      end

      def build_loaded_appender(**options)
        AsyncOptions.extract(options).build_appender(NoopAppender.new)
      end

      def async_batch_class
        return unless ::SemanticLogger::Appender.const_defined?(:AsyncBatch, false)

        ::SemanticLogger::Appender.const_get(:AsyncBatch, false)
      end

      def semantic_logger_v5_async_options?
        ::SemanticLogger::Appender::Async.instance_method(:initialize).parameters.any? { |kind, _name| kind == :keyrest }
      end
    end
  end
end
