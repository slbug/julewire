# frozen_string_literal: true

require "test_helper"

module Julewire
  module DisplayMessageTestHelpers
    KEYS = Julewire::Core::Fields::AttributeKeys

    def display = Julewire::Core::Records::DisplayMessage

    def build_display_record(input = nil, neutral: {}, **fields)
      input = (input || {}).merge(fields)
      Julewire::Core::Records::Draft.build(
        input,
        carry: {},
        context: {},
        neutral: neutral,
        scope: nil
      ).to_record
    end

    def assert_display_message(expected, input = nil, neutral: {}, **fields)
      assert_equal expected, display.call(build_display_record(input, neutral: neutral, **fields))
    end
  end

  class TestDisplayMessageBasic < Minitest::Test
    include DisplayMessageTestHelpers

    cover Julewire::Core::Records::DisplayMessage

    def test_explicit_message_wins
      record = build_display_record(
        { message: "explicit", error: RuntimeError.new("boom") },
        neutral: { KEYS::HTTP_REQUEST_METHOD => "GET", KEYS::URL_PATH => "/orders" }
      )

      assert_equal "explicit", display.call(record)
    end

    def test_blank_explicit_message_falls_back_to_error
      record = build_display_record(message: "", error: RuntimeError.new("boom"))

      assert_equal "RuntimeError: boom", display.call(record)
    end

    def test_display_message_reads_duck_typed_indexed_records
      record = Object.new
      record.define_singleton_method(:[]) { it == "message" ? "from indexer" : nil }

      assert_equal "from indexer", display.call(record)
    end

    def test_blank_or_unreadable_input_has_no_display_message
      assert_nil display.call({})
      assert_nil display.call(error: { class: "", message: "" })
      assert_nil display.call(Object.new)
    end

    def test_indexer_failure_has_no_display_message
      record = Object.new
      record.define_singleton_method(:[]) { raise "unreadable" }

      assert_nil display.call(record)
    end

    def test_method_missing_indexer_is_not_used_without_respond_to
      record = Class.new do
        def method_missing(method_name, *, &)
          return "ghost message" if method_name == :[]

          super
        end

        def respond_to_missing?(_method_name, _include_private = false) = false
      end.new

      assert_nil display.call(record)
    end
  end

  class TestDisplayMessageHttp < Minitest::Test
    include DisplayMessageTestHelpers

    cover Julewire::Core::Records::DisplayMessage

    def test_http_neutral_message_includes_error_and_duration
      record = build_display_record(
        { error: RuntimeError.new("boom"), metrics: { duration_ms: 12.5 } },
        neutral: {
          KEYS::HTTP_REQUEST_METHOD => "GET",
          KEYS::HTTP_RESPONSE_STATUS_CODE => 500,
          KEYS::URL_PATH => "/orders"
        }
      )

      assert_equal "GET /orders -> 500 RuntimeError in 12.5ms", display.call(record)
    end

    def test_http_neutral_message_uses_full_url_when_path_is_missing
      record = build_display_record(
        { metrics: { duration_ms: 1.2345 } },
        neutral: {
          KEYS::HTTP_REQUEST_METHOD => "POST",
          KEYS::HTTP_RESPONSE_STATUS_CODE => 201,
          KEYS::URL_FULL => "https://example.test/orders"
        }
      )

      assert_equal "POST https://example.test/orders -> 201 in 1.235ms", display.call(record)
    end

    def test_http_neutral_message_omits_invalid_duration
      record = build_display_record(
        { metrics: { duration_ms: "slow" } },
        neutral: {
          KEYS::HTTP_REQUEST_METHOD => "GET",
          KEYS::HTTP_RESPONSE_STATUS_CODE => 200,
          KEYS::URL_PATH => "/orders"
        }
      )

      assert_equal "GET /orders -> 200", display.call(record)
    end

    def test_http_neutral_message_formats_non_finite_duration
      record = {
        metrics: { duration_ms: Float::INFINITY },
        neutral: {
          KEYS::HTTP_REQUEST_METHOD => "GET",
          KEYS::HTTP_RESPONSE_STATUS_CODE => 200,
          KEYS::URL_PATH => "/orders"
        }
      }

      assert_equal "GET /orders -> 200 in Infms", display.call(record)
    end

    def test_http_neutral_message_requires_method_path_and_status
      assert_nil display.call(neutral: { KEYS::HTTP_REQUEST_METHOD => "GET", KEYS::URL_PATH => "/orders" })
      assert_nil display.call(neutral: { KEYS::HTTP_REQUEST_METHOD => "GET", KEYS::HTTP_RESPONSE_STATUS_CODE => 200 })
      assert_nil display.call(neutral: { KEYS::URL_PATH => "/orders", KEYS::HTTP_RESPONSE_STATUS_CODE => 200 })
    end

    def test_serialized_hash_neutral_message
      record = {
        "metrics" => { "duration_ms" => 3.5 },
        "neutral" => {
          KEYS::HTTP_REQUEST_METHOD.name => "GET",
          KEYS::HTTP_RESPONSE_STATUS_CODE.name => 200,
          KEYS::URL_PATH.name => "/orders"
        }
      }

      assert_equal "GET /orders -> 200 in 3.5ms", display.call(record)
    end
  end

  class TestDisplayMessageJob < Minitest::Test
    include DisplayMessageTestHelpers

    cover Julewire::Core::Records::DisplayMessage

    def test_job_neutral_message
      record = build_display_record(
        { metrics: { duration_ms: 9.0 } },
        neutral: {
          KEYS::JOB_NAME => "ImportJob",
          KEYS::JOB_QUEUE_NAME => "default",
          KEYS::JOB_STATUS => "succeeded",
          KEYS::JOB_SYSTEM => "active_job"
        }
      )

      assert_equal "active_job ImportJob queue=default -> succeeded in 9ms", display.call(record)
    end

    def test_job_neutral_message_coerces_non_string_status
      assert_display_message(
        "active_job ImportJob -> 202",
        neutral: {
          KEYS::JOB_NAME => "ImportJob",
          KEYS::JOB_STATUS => 202,
          KEYS::JOB_SYSTEM => "active_job"
        }
      )
    end

    def test_job_neutral_message_coerces_non_string_system_with_name
      assert_display_message(
        "active_job ImportJob",
        neutral: {
          KEYS::JOB_NAME => "ImportJob",
          KEYS::JOB_SYSTEM => :active_job
        }
      )
    end

    def test_job_neutral_message_coerces_non_string_status_before_error
      record = build_display_record(
        { error: RuntimeError.new("boom") },
        neutral: {
          KEYS::JOB_NAME => "ImportJob",
          KEYS::JOB_STATUS => 202
        }
      )

      assert_equal "job ImportJob -> 202 RuntimeError", display.call(record)
    end

    def test_job_neutral_message_accepts_hash_subclass_error
      error = Class.new(Hash).new.merge!(class: "SubError")
      record = {
        error: error,
        neutral: { KEYS::JOB_NAME => "ImportJob" }
      }

      assert_equal "job ImportJob -> SubError", display.call(record)
    end

    def test_job_neutral_message_uses_id_without_name
      record = build_display_record(
        neutral: {
          KEYS::JOB_ID => 123,
          KEYS::JOB_STATUS => "failed"
        }
      )

      assert_equal "job 123 -> failed", display.call(record)
    end

    def test_job_neutral_message_uses_system_without_name_or_id
      record = build_display_record(neutral: { KEYS::JOB_SYSTEM => "active_job" })

      assert_equal "active_job", display.call(record)
    end

    def test_job_neutral_message_includes_error_when_status_is_missing
      record = build_display_record(
        { error: RuntimeError.new("boom"), metrics: { duration_ms: 2.001 } },
        neutral: { KEYS::JOB_NAME => "ImportJob" }
      )

      assert_equal "job ImportJob -> RuntimeError in 2.001ms", display.call(record)
    end

    def test_neutral_message_omits_blank_optional_parts
      record = build_display_record(
        neutral: {
          KEYS::JOB_NAME => "ImportJob",
          KEYS::JOB_STATUS => "succeeded",
          KEYS::JOB_SYSTEM => "active_job"
        }
      )

      assert_equal "active_job ImportJob -> succeeded", display.call(record)
    end
  end

  class TestDisplayMessageMessaging < Minitest::Test
    include DisplayMessageTestHelpers

    cover Julewire::Core::Records::DisplayMessage

    def test_messaging_neutral_message
      record = build_display_record(
        { error: RuntimeError.new("boom"), metrics: { duration_ms: 4.25 } },
        neutral: {
          KEYS::MESSAGING_BATCH_MESSAGE_COUNT => 3,
          KEYS::MESSAGING_DESTINATION_NAME => "orders",
          KEYS::MESSAGING_DESTINATION_PARTITION_ID => "1",
          KEYS::MESSAGING_KAFKA_OFFSET => "42",
          KEYS::MESSAGING_OPERATION_NAME => "process",
          KEYS::MESSAGING_SYSTEM => "kafka"
        }
      )

      assert_equal "kafka process orders partition=1 offset=42 messages=3 RuntimeError in 4.25ms", display.call(record)
    end

    def test_messaging_neutral_message_accepts_partial_neutral_fields
      assert_equal "kafka", display.call(neutral: { KEYS::MESSAGING_SYSTEM => "kafka" })
      assert_equal "messaging consume", display.call(neutral: { KEYS::MESSAGING_OPERATION_NAME => "consume" })
      assert_equal "messaging orders", display.call(neutral: { KEYS::MESSAGING_DESTINATION_NAME => "orders" })
    end
  end

  class TestDisplayMessageError < Minitest::Test
    include DisplayMessageTestHelpers

    cover Julewire::Core::Records::DisplayMessage

    def test_error_fallback
      record = build_display_record(error: RuntimeError.new("boom"))

      assert_equal "RuntimeError: boom", display.call(record)
    end

    def test_error_fallback_accepts_partial_error_hashes
      assert_equal "RuntimeError", display.call(error: { class: "RuntimeError" })
      assert_equal "boom", display.call(error: { message: "boom" })
    end

    def test_error_fallback_coerces_non_string_message_parts
      assert_equal "404", display.call(error: { message: 404 })
      assert_equal "RuntimeError", display.call(error: { class: :RuntimeError })
      assert_equal "RuntimeError: 404", display.call(error: { class: "RuntimeError", message: 404 })
      assert_equal "RuntimeError: 404", display.call(error: { class: :RuntimeError, message: 404 })
    end

    def test_error_summary_is_shared_for_provider_formatters
      assert_equal "RuntimeError: boom", display.error_summary(class: "RuntimeError", message: "boom")
      assert_equal "RuntimeError", display.error_summary(class: "RuntimeError")
      assert_equal "boom", display.error_summary(message: "boom")
      assert_nil display.error_summary("boom")
    end

    def test_error_summary_reads_string_keys_and_ignores_non_hash_errors
      hash_subclass = Class.new(Hash)

      assert_equal "RuntimeError: boom", display.call("error" => { "class" => "RuntimeError", "message" => "boom" })
      assert_equal "SubError: sub", display.error_summary(hash_subclass.new.merge!(class: "SubError", message: "sub"))
      assert_nil display.call(error: "boom")
    end

    def test_error_summary_ignores_non_hash_indexable_objects
      error = Object.new
      error.define_singleton_method(:[]) do |_key|
        "Bogus"
      end
      record = {
        error: error,
        neutral: { KEYS::JOB_NAME => "ImportJob" }
      }

      assert_equal "job ImportJob", display.call(record)
      assert_nil display.error_summary(error)
    end
  end

  class TestDisplayMessageSourceLocation < Minitest::Test
    include DisplayMessageTestHelpers

    cover Julewire::Core::Records::DisplayMessage

    def test_source_location_neutral_message
      record = build_display_record(
        neutral: {
          KEYS::CODE_FILE_PATH => "app/jobs/import_job.rb",
          KEYS::CODE_FUNCTION_NAME => "ImportJob#perform",
          KEYS::CODE_LINE_NUMBER => 42
        }
      )

      assert_equal "app/jobs/import_job.rb:42 ImportJob#perform", display.call(record)
    end

    def test_source_location_neutral_message_without_line
      assert_display_message(
        "app/jobs/import_job.rb ImportJob#perform",
        neutral: {
          KEYS::CODE_FILE_PATH => "app/jobs/import_job.rb",
          KEYS::CODE_FUNCTION_NAME => "ImportJob#perform"
        }
      )
    end

    def test_source_location_neutral_message_coerces_function_name
      assert_display_message(
        "app/jobs/import_job.rb 123",
        neutral: {
          KEYS::CODE_FILE_PATH => "app/jobs/import_job.rb",
          KEYS::CODE_FUNCTION_NAME => 123
        }
      )
    end

    def test_source_location_neutral_message_coerces_file_path
      file = Object.new
      file.define_singleton_method(:to_s) { "dynamic.rb" }
      record = { neutral: { KEYS::CODE_FILE_PATH => file } }

      assert_equal "dynamic.rb", display.call(record)
    end
  end
end
