# frozen_string_literal: true

require "test_helper"
require "support/gcp_test_case"

module Julewire
  class GcpLabelTest < GcpTestCase
    cover "Julewire::GCP::Formatter#append_log_field"
    cover "Julewire::GCP::Formatter#initialize"
    cover "Julewire::GCP::Formatter#labels"
    cover Julewire::GCP::FormatterOptions
    cover Julewire::GCP::LabelFormatter
    def test_shapes_labels_to_configured_provider_limits
      record = normalized_record(labels: { first: "123456", second: "ok", third: "drop" })

      formatted = formatted_record(record, formatter: GCP::Formatter.new(max_labels: 2, max_label_value_bytes: 5))

      assert_equal({ "first" => "12345", "second" => "ok" }, formatted.fetch("logging.googleapis.com/labels"))
    end

    def test_drops_labels_with_oversized_keys
      record = normalized_record(labels: { "too_long" => "drop", ok: "yes" })

      formatted = formatted_record(record, formatter: GCP::Formatter.new(max_label_key_bytes: 4))

      assert_equal({ "ok" => "yes" }, formatted.fetch("logging.googleapis.com/labels"))
    end

    def test_default_label_limits_are_provider_limits
      labels = 63.times.to_h { |index| [:"label_#{index}", index] }
      labels[:long] = "x" * (GCP::DEFAULT_MAX_LABEL_VALUE_BYTES + 1)
      labels[("k" * (GCP::DEFAULT_MAX_LABEL_KEY_BYTES + 1)).to_sym] = "drop"
      record = normalized_label_record(labels)

      formatted = GCP::Formatter.new.call(record).fetch("logging.googleapis.com/labels")

      assert_equal GCP::DEFAULT_MAX_LABELS, formatted.size
      assert_false formatted.key?("k" * (GCP::DEFAULT_MAX_LABEL_KEY_BYTES + 1))
      assert_equal GCP::DEFAULT_MAX_LABEL_VALUE_BYTES, formatted.fetch("long").bytesize
    end

    def test_default_label_count_limit_drops_extra_valid_labels
      labels = 65.times.to_h { |index| [:"label_#{index}", index] }
      record = normalized_label_record(labels)

      formatted = GCP::Formatter.new.call(record).fetch("logging.googleapis.com/labels")

      assert_equal GCP::DEFAULT_MAX_LABELS, formatted.size
      assert_false formatted.key?("label_64")
    end

    def test_default_label_key_limit_drops_oversized_key
      long_key = ("k" * (GCP::DEFAULT_MAX_LABEL_KEY_BYTES + 1)).to_sym
      record = normalized_label_record(long_key => "drop", ok: "yes")

      formatted = GCP::Formatter.new.call(record).fetch("logging.googleapis.com/labels")

      assert_equal({ "ok" => "yes" }, formatted)
    end

    def test_can_disable_label_count_limit
      record = normalized_record(labels: { first: "1", second: "2", third: "3" })

      formatted = formatted_record(record, formatter: GCP::Formatter.new(max_labels: nil))

      assert_equal({ "first" => "1", "second" => "2", "third" => "3" },
                   formatted.fetch("logging.googleapis.com/labels"))
    end

    def test_can_disable_label_byte_limits
      long_key = "k" * (GCP::DEFAULT_MAX_LABEL_KEY_BYTES + 1)
      long_value = "x" * (GCP::DEFAULT_MAX_LABEL_VALUE_BYTES + 1)
      record = normalized_label_record(long_key.to_sym => long_value)

      formatted = GCP::Formatter.new(max_label_key_bytes: nil, max_label_value_bytes: nil).call(record)

      assert_equal({ long_key => long_value }, formatted.fetch("logging.googleapis.com/labels"))
    end

    def test_label_value_byte_limits
      assert_label_value_output(:exact, "12345", expected: "12345", max_bytes: 5)
      assert_label_value_output(:long, "123456", expected: "12345", max_bytes: 5)
      assert_label_value_output(:split, "é", expected: "?", max_bytes: 1)
    end

    def test_top_level_label_options_override_nested_label_options_without_mutating_input
      label_options = { max_labels: 1 }
      record = normalized_record(labels: { first: "1", second: "2", third: "3" })

      formatted = formatted_record(
        record,
        formatter: GCP::Formatter.new(label_options: label_options, max_labels: 2)
      )

      assert_equal({ "first" => "1", "second" => "2" }, formatted.fetch("logging.googleapis.com/labels"))
      assert_equal({ max_labels: 1 }, label_options)
    end

    def test_nested_label_options_apply_without_top_level_overrides
      record = normalized_record(labels: { first: "1", second: "2" })

      formatted = formatted_record(record, formatter: GCP::Formatter.new(label_options: { max_labels: 1 }))

      assert_equal({ "first" => "1" }, formatted.fetch("logging.googleapis.com/labels"))
    end

    def test_custom_label_formatter_wins_over_limit_options
      formatter = Object.new
      formatter.define_singleton_method(:call) { |_labels| { "custom" => "label" } }
      record = normalized_record(labels: { first: "1", second: "2" })

      formatted = formatted_record(
        record,
        formatter: GCP::Formatter.new(label_formatter: formatter, max_labels: 1)
      )

      assert_equal({ "custom" => "label" }, formatted.fetch("logging.googleapis.com/labels"))
    end

    def test_empty_hash_subclass_label_output_is_omitted
      assert_empty_label_output_is_omitted(Class.new(Hash).new)
    end

    def test_empty_array_subclass_label_output_is_omitted
      assert_empty_label_output_is_omitted(Class.new(Array).new)
    end

    def assert_formatted_labels(expected, record, **)
      formatted = GCP::Formatter.new(**).call(record)

      assert_equal expected, formatted.fetch("logging.googleapis.com/labels")
    end

    def assert_label_value_output(key, value, expected:, max_bytes:)
      record = normalized_record(labels: { key => value })

      assert_formatted_labels({ key.to_s => expected }, record, max_label_value_bytes: max_bytes)
    end

    def assert_empty_label_output_is_omitted(labels)
      formatter = Object.new
      formatter.define_singleton_method(:call) { |_labels| labels }
      record = normalized_record(labels: { tenant: "acme" })

      formatted = GCP::Formatter.new(label_formatter: formatter).call(record)

      assert_false formatted.key?("logging.googleapis.com/labels")
    end

    def test_short_string_subclass_label_value_does_not_use_truncation_path
      string = Class.new(String) do
        def byteslice(*) = raise "unexpected truncation"
      end
      value = Object.new
      value.define_singleton_method(:to_s) { string.new("ok") }

      formatted = GCP::LabelFormatter.new(max_label_value_bytes: 10).call(short: value)

      assert_equal({ "short" => "ok" }, formatted)
    end

    private

    def normalized_label_record(labels)
      base = normalized_record
      Core::Records::Record.from_normalized_hash(base.to_h.merge(labels: labels), lineage: base.lineage)
    end
  end

  class GcpSourceLocationOptionsTest < GcpTestCase
    cover Julewire::GCP::SourceLocationOptions
    def test_maps_partial_neutral_source_location_attributes
      cases = [
        [Core::Fields::AttributeKeys::CODE_FILE_PATH, "app/job.rb", { file: "app/job.rb" }],
        [Core::Fields::AttributeKeys::CODE_LINE_NUMBER, 42, { line: 42 }],
        [Core::Fields::AttributeKeys::CODE_FUNCTION_NAME, "Job#perform", { function: "Job#perform" }]
      ]

      cases.each do |key, value, expected|
        record = normalized_record(neutral: Core::Fields::AttributeKeys.fields(key => value))

        assert_equal expected, GCP::SourceLocationOptions.call(record, record.fetch(:neutral))
      end
    end

    def test_non_hash_control_uses_neutral_attributes
      record = normalized_record(
        payload: { gcp: "not-options" },
        neutral: Core::Fields::AttributeKeys.fields(Core::Fields::AttributeKeys::CODE_FILE_PATH => "neutral.rb")
      )

      assert_equal(
        { file: "neutral.rb" },
        GCP::SourceLocationOptions.call(record, record.fetch(:neutral))
      )
    end

    def test_control_without_source_location_uses_neutral_attributes
      record = normalized_record(
        payload: { gcp: { extra: true } },
        neutral: Core::Fields::AttributeKeys.fields(Core::Fields::AttributeKeys::CODE_FILE_PATH => "neutral.rb")
      )

      assert_equal(
        { file: "neutral.rb" },
        GCP::SourceLocationOptions.call(record, record.fetch(:neutral))
      )
    end
  end

  class GcpSourceLocationTest < GcpTestCase
    cover Julewire::GCP::SourceLocation
    def test_source_location_helper_omits_empty_input
      assert_nil GCP::SourceLocation.call({})
    end

    def test_source_location_helper_stringifies_values
      assert_equal(
        { "file" => "123", "line" => "42", "function" => "perform" },
        GCP::SourceLocation.call(file: 123, line: 42, function: :perform)
      )
    end

    def test_source_location_helper_omits_blank_values
      assert_nil GCP::SourceLocation.call(file: "", line: nil, function: "")
    end

    def test_source_location_helper_ignores_non_hash_errors
      assert_nil GCP::SourceLocation.from_error(Object.new)
    end

    def test_source_location_helper_ignores_errors_without_backtrace
      assert_nil GCP::SourceLocation.from_error(class: "RuntimeError")
    end

    def test_source_location_helper_accepts_hash_subclass_errors
      error = Class.new(Hash).new
      error[:backtrace] = ["/tmp/job.rb:9:in 'perform'"]

      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_error(error)
      )
    end

    def test_source_location_helper_accepts_single_string_backtrace
      error = {
        backtrace: "/tmp/job.rb:9:in 'perform'"
      }

      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_error(error)
      )
    end

    def test_source_location_helper_skips_invalid_backtrace_lines
      error = {
        backtrace: ["not a backtrace line", "/tmp/job.rb:9:in 'perform'"]
      }

      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_error(error)
      )
    end

    def test_source_location_helper_ignores_non_string_backtrace_lines
      assert_nil GCP::SourceLocation.from_backtrace_line(nil)
    end

    def test_source_location_helper_coerces_backtrace_lines_to_strings
      line = Object.new
      line.define_singleton_method(:to_s) { "/tmp/job.rb:9:in 'perform'" }

      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_backtrace_line(line)
      )
    end

    def test_source_location_helper_parses_plain_backtrace_function
      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_backtrace_line("/tmp/job.rb:9:in perform")
      )
    end

    def test_source_location_helper_parses_quoted_backtrace_function
      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_backtrace_line("/tmp/job.rb:9:in `perform'")
      )
    end

    def test_source_location_helper_keeps_half_quoted_backtrace_function
      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "`perform" },
        GCP::SourceLocation.from_backtrace_line("/tmp/job.rb:9:in `perform")
      )
      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform'" },
        GCP::SourceLocation.from_backtrace_line("/tmp/job.rb:9:in perform'")
      )
    end

    def test_source_location_helper_omits_empty_quoted_backtrace_function
      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9" },
        GCP::SourceLocation.from_backtrace_line("/tmp/job.rb:9:in ''")
      )
    end

    def test_source_location_helper_keeps_single_quote_backtrace_function
      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "'" },
        GCP::SourceLocation.from_backtrace_line("/tmp/job.rb:9:in '")
      )
    end

    def test_source_location_helper_parses_backtrace_without_function
      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "42" },
        GCP::SourceLocation.from_backtrace_line("/tmp/job.rb:42")
      )
    end

    def test_source_location_helper_parses_non_ascii_backtrace_path
      assert_equal(
        { "file" => "/tmp/é/job.rb", "line" => "9" },
        GCP::SourceLocation.from_backtrace_line("/tmp/é/job.rb:9")
      )
      assert_equal(
        { "file" => "/tmp/é/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_backtrace_line("/tmp/é/job.rb:9:in `perform'")
      )
    end

    def test_source_location_helper_rejects_backtrace_without_file
      assert_nil GCP::SourceLocation.from_backtrace_line(":9:in `perform'")
    end

    def test_source_location_helper_rejects_backtrace_without_numeric_line
      assert_nil GCP::SourceLocation.from_backtrace_line("/tmp/job.rb:line:in `perform'")
    end

    def test_source_location_helper_completes_on_adversarial_long_line
      adversarial = "a:not-a-line#{":in `x" * 5_000}"

      assert_nil GCP::SourceLocation.from_backtrace_line(adversarial)
    end

    def test_source_location_helper_parses_adversarial_long_function_line
      function = "x" * 20_000

      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => function },
        GCP::SourceLocation.from_backtrace_line("/tmp/job.rb:9:in `#{function}'")
      )
    end
  end

  class GcpFormatterSourceLocationTest < GcpTestCase
    cover "Julewire::GCP::Formatter#append_payload_fields"
    cover "Julewire::GCP::Formatter#append_special_fields"
    cover "Julewire::GCP::Formatter#call"
    cover "Julewire::GCP::Formatter#source_location"
    def test_maps_source_location_special_field
      record = normalized_record(
        payload: GCP.source_location(
          file: "app/jobs/import_job.rb",
          line: 42,
          function: "ImportJob#perform"
        )
      )

      formatted = formatted_record(record)

      assert_equal(
        {
          "file" => "app/jobs/import_job.rb",
          "line" => "42",
          "function" => "ImportJob#perform"
        },
        formatted.fetch("logging.googleapis.com/sourceLocation")
      )
      assert_false formatted.key?("payload")
    end

    def test_omits_invalid_source_location_line
      record = normalized_record(
        payload: {
          gcp: {
            source_location: { file: "worker.rb", line: "unknown" }
          }
        }
      )

      formatted = formatted_record(record)

      assert_equal({ "file" => "worker.rb" }, formatted.fetch("logging.googleapis.com/sourceLocation"))
    end

    def test_maps_neutral_source_location_attributes
      record = normalized_record(
        neutral: Core::Fields::AttributeKeys.fields(
          Core::Fields::AttributeKeys::CODE_FILE_PATH => "app/jobs/import_job.rb",
          Core::Fields::AttributeKeys::CODE_LINE_NUMBER => 42,
          Core::Fields::AttributeKeys::CODE_FUNCTION_NAME => "ImportJob#perform"
        )
      )

      formatted = formatted_record(record)

      assert_equal(
        {
          "file" => "app/jobs/import_job.rb",
          "line" => "42",
          "function" => "ImportJob#perform"
        },
        formatted.fetch("logging.googleapis.com/sourceLocation")
      )
    end

    def test_explicit_source_location_wins_over_neutral_attributes
      record = normalized_record(
        payload: GCP.source_location(file: "explicit.rb", line: 7),
        neutral: Core::Fields::AttributeKeys.fields(
          Core::Fields::AttributeKeys::CODE_FILE_PATH => "event.rb",
          Core::Fields::AttributeKeys::CODE_LINE_NUMBER => 12
        )
      )

      formatted = formatted_record(record)

      assert_equal({ "file" => "explicit.rb", "line" => "7" },
                   formatted.fetch("logging.googleapis.com/sourceLocation"))
    end

    def test_infers_source_location_from_error_backtrace
      record = normalized_record(
        error: {
          class: "RuntimeError",
          message: "boom",
          backtrace: ["/app/controllers/orders_controller.rb:12:in 'OrdersController#create'"]
        }
      )

      formatted = formatted_record(record)

      assert_equal(
        {
          "file" => "/app/controllers/orders_controller.rb",
          "line" => "12",
          "function" => "OrdersController#create"
        },
        formatted.fetch("logging.googleapis.com/sourceLocation")
      )
    end

    def test_explicit_source_location_wins_over_error_backtrace
      record = normalized_record(
        payload: GCP.source_location(file: "explicit.rb", line: 7),
        error: {
          class: "RuntimeError",
          message: "boom",
          backtrace: ["/app/controllers/orders_controller.rb:12:in 'OrdersController#create'"]
        }
      )

      formatted = formatted_record(record)

      assert_equal(
        {
          "file" => "explicit.rb",
          "line" => "7"
        },
        formatted.fetch("logging.googleapis.com/sourceLocation")
      )
    end
  end

  class GcpSourceLocationPayloadTest < GcpTestCase
    cover Julewire::GCP::SourceLocationOptions
    def test_non_hash_source_location_payload_falls_back_to_neutral_attributes
      record = normalized_record(
        payload: { gcp: { source_location: "not-options" } },
        neutral: Core::Fields::AttributeKeys.fields(Core::Fields::AttributeKeys::CODE_FILE_PATH => "neutral.rb")
      )

      formatted = formatted_record(record)

      assert_equal({ "file" => "neutral.rb" }, formatted.fetch("logging.googleapis.com/sourceLocation"))
    end

    def test_hash_subclass_source_location_wins_over_neutral_attributes
      control = Class.new(Hash).new
      source_location = Class.new(Hash).new
      source_location[:file] = "explicit.rb"
      control[:source_location] = source_location
      record = owned_record(
        payload: { gcp: control },
        neutral: Core::Fields::AttributeKeys.fields(Core::Fields::AttributeKeys::CODE_FILE_PATH => "neutral.rb")
      )

      formatted = formatted_record(record)

      assert_equal({ "file" => "explicit.rb" }, formatted.fetch("logging.googleapis.com/sourceLocation"))
    end
  end

  class GcpFormatterErrorTest < GcpTestCase
    cover "Julewire::GCP::Formatter#append_payload_fields"
    cover "Julewire::GCP::Formatter#julewire_error"
    cover "Julewire::GCP::Formatter#julewire_payload"
    cover "Julewire::GCP::Formatter#stack_trace"
    def test_omits_error_derived_fields_for_empty_error
      formatted = GCP::Formatter.new.call(normalized_record(error: {}))

      assert_false formatted.key?("stack_trace")
      assert_false formatted.key?("logging.googleapis.com/sourceLocation")
      assert_false formatted.fetch("julewire").key?(:error)
    end

    def test_preserves_error_without_stack_trace
      error = { class: "RuntimeError", message: "boom" }

      formatted = GCP::Formatter.new.call(normalized_record(error: error))

      assert_false formatted.key?("stack_trace")
      assert_false formatted.key?("logging.googleapis.com/sourceLocation")
      assert_equal error, formatted.fetch("julewire").fetch(:error)
    end

    def test_preserves_empty_backtrace_when_no_stack_trace_is_emitted
      error = { class: "RuntimeError", message: "boom", backtrace: [] }

      formatted = GCP::Formatter.new.call(normalized_record(error: error))

      assert_false formatted.key?("stack_trace")
      assert_equal error, formatted.fetch("julewire").fetch(:error)
    end

    def test_accepts_hash_subclass_error
      error = Class.new(Hash).new
      error[:class] = "RuntimeError"
      error[:message] = "boom"
      error[:backtrace] = ["/app/job.rb:9"]

      formatted = GCP::Formatter.new.call(normalized_record(error: error))

      assert_equal "RuntimeError: boom\n/app/job.rb:9", formatted.fetch("stack_trace")
      assert_equal({ class: "RuntimeError", message: "boom" }, formatted.fetch("julewire").fetch(:error))
      assert_equal({ "file" => "/app/job.rb", "line" => "9" },
                   formatted.fetch("logging.googleapis.com/sourceLocation"))
    end
  end

  class GcpStackTraceUnitTest < GcpTestCase
    cover Julewire::GCP::StackTrace
    def test_stack_trace_ignores_non_hash_input
      assert_nil GCP::StackTrace.call(Object.new)
    end

    def test_stack_trace_accepts_hash_subclass_input
      error = Class.new(Hash).new
      error[:class] = "RuntimeError"
      error[:message] = "boom"
      error[:backtrace] = ["/app/job.rb:9"]

      assert_equal "RuntimeError: boom\n/app/job.rb:9", GCP::StackTrace.call(error)
    end

    def test_stack_trace_ignores_empty_error
      assert_nil GCP::StackTrace.call({})
    end

    def test_stack_trace_compacts_nil_backtrace_lines
      assert_equal(
        "RuntimeError: boom\n/app/job.rb:9",
        GCP::StackTrace.call(
          class: "RuntimeError",
          message: "boom",
          backtrace: ["/app/job.rb:9", nil]
        )
      )
    end

    def test_stack_trace_prefixes_cause_lines
      assert_equal(
        "RuntimeError: boom\n/app/job.rb:9\nCaused by: ArgumentError: bad\n/app/cause.rb:3",
        GCP::StackTrace.call(
          error_shape(
            "RuntimeError",
            "boom",
            ["/app/job.rb:9"],
            cause: error_shape("ArgumentError", "bad", ["/app/cause.rb:3"])
          )
        )
      )
    end

    def test_stack_trace_accepts_hash_subclass_cause
      cause = Class.new(Hash).new
      cause[:class] = "ArgumentError"
      cause[:message] = "bad"
      cause[:backtrace] = ["/app/cause.rb:3"]

      assert_equal(
        "RuntimeError: boom\n/app/job.rb:9\nCaused by: ArgumentError: bad\n/app/cause.rb:3",
        GCP::StackTrace.call(
          class: "RuntimeError",
          message: "boom",
          backtrace: ["/app/job.rb:9"],
          cause: cause
        )
      )
    end

    def test_stack_trace_uses_cause_when_parent_has_no_backtrace
      assert_equal(
        "RuntimeError: boom\nCaused by: ArgumentError: bad\n/app/cause.rb:3",
        GCP::StackTrace.call(
          class: "RuntimeError",
          message: "boom",
          cause: {
            class: "ArgumentError",
            message: "bad",
            backtrace: ["/app/cause.rb:3"]
          }
        )
      )
    end

    def test_stack_trace_ignores_non_hash_cause
      assert_equal(
        "RuntimeError: boom\n/app/job.rb:9",
        GCP::StackTrace.call(
          class: "RuntimeError",
          message: "boom",
          backtrace: ["/app/job.rb:9"],
          cause: "not-a-hash"
        )
      )
    end

    def test_stack_trace_removes_backtraces_recursively
      value = {
        class: "RuntimeError",
        backtrace: ["top"],
        cause: {
          class: "ArgumentError",
          backtrace: ["cause"]
        },
        nested: [
          { backtrace: ["nested"], kept: true },
          "plain"
        ]
      }

      assert_equal(
        {
          class: "RuntimeError",
          cause: {
            class: "ArgumentError"
          },
          nested: [
            { kept: true },
            "plain"
          ]
        },
        GCP::StackTrace.remove_backtraces(value)
      )
    end
  end
end
