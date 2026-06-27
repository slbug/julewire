# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestWriteStep < Minitest::Test
    cover Julewire::Core::Destinations::WriteStep
    class RecordingOutput
      attr_reader :writes

      def initialize(result: true)
        @result = result
        @writes = []
      end

      def write(value)
        writes << value
        @result
      end
    end

    class RaisingOutput
      def write(_value)
        raise "output failed"
      end
    end

    class EncodedString < String
    end

    def test_returns_true_only_for_accepted_output
      output = RecordingOutput.new(result: 12)
      step = write_step(output: output)

      assert_true step.call(record)
      assert_equal ["encoded:work"], output.writes
      assert_equal 1, counters.fetch(:received)
      assert_equal 1, counters.fetch(:formatted)
      assert_equal 1, counters.fetch(:output_accepted)
      assert_empty failure_events
      assert_empty losses
    end

    def test_formatter_nil_is_a_handled_drop
      step = write_step(formatter: ->(_record) {})

      assert_false step.call(record)
      assert_equal 1, counters.fetch(:formatter_error)
      assert_instance_of TypeError, failure_events.fetch(0).fetch(:error)
      assert_equal "formatter must return a payload object", failure_events.fetch(0).fetch(:error).message
      assert_equal :formatter, failure_events.fetch(0).dig(:metadata, :phase)
      assert_same record, failure_events.fetch(0).dig(:metadata, :record)
      assert_equal :formatter_error, losses.fetch(0).fetch(:reason)
      assert_same record, losses.fetch(0).dig(:metadata, :record)
    end

    def test_encoder_non_string_is_a_handled_drop
      step = write_step(encoder: ->(_payload) { :not_a_string })

      assert_false step.call(record)
      assert_equal 1, counters.fetch(:encode_error)
      assert_instance_of TypeError, failure_events.fetch(0).fetch(:error)
      assert_equal "encoder must return a String", failure_events.fetch(0).fetch(:error).message
      assert_equal :encode, failure_events.fetch(0).dig(:metadata, :phase)
      assert_same record, failure_events.fetch(0).dig(:metadata, :record)
      assert_equal :encode_error, losses.fetch(0).fetch(:reason)
    end

    def test_encoder_accepts_string_subclasses
      output = RecordingOutput.new
      step = write_step(encoder: ->(payload) { EncodedString.new("encoded:#{payload}") }, output: output)

      assert_true step.call(record)
      assert_equal ["encoded:work"], output.writes
      assert_empty failure_events
      assert_empty losses
    end

    def test_record_size_limit_is_inclusive
      accepted = write_step(output: RecordingOutput.new, max_record_bytes: "encoded:work".bytesize)

      assert_true accepted.call(record)

      reset_tracking
      rejected = write_step(output: RecordingOutput.new, max_record_bytes: "encoded:work".bytesize - 1)

      assert_false rejected.call(record)
      assert_equal 1, counters.fetch(:record_too_large)
      assert_equal :record_too_large, losses.fetch(0).fetch(:reason)
      assert_equal "encoded:work".bytesize, losses.fetch(0).dig(:metadata, :bytesize)
      assert_equal "encoded:work".bytesize - 1, losses.fetch(0).dig(:metadata, :max_record_bytes)
      assert_same record, losses.fetch(0).dig(:metadata, :record)
    end

    def test_nil_record_size_limit_accepts_without_size_drop
      step = write_step(output: RecordingOutput.new, max_record_bytes: nil)

      assert_true step.call(record)
      assert_equal 0, counters[:record_too_large]
      assert_empty losses
    end

    def test_false_output_return_is_a_rejection
      step = write_step(output: RecordingOutput.new(result: false))

      assert_false step.call(record)
      assert_equal 1, counters.fetch(:output_rejected)
      assert_equal 1, counters.fetch(:output_error)
      assert_equal :output_rejected, losses.fetch(0).fetch(:reason)
      assert_same record, losses.fetch(0).dig(:metadata, :record)
    end

    def test_output_exception_is_reported_with_output_metadata
      step = write_step(output: RaisingOutput.new)

      assert_false step.call(record)
      assert_equal 1, counters.fetch(:output_exception)
      assert_equal 1, counters.fetch(:output_error)
      assert_equal "output failed", failure_events.fetch(0).fetch(:error).message
      assert_equal :output, failure_events.fetch(0).dig(:metadata, :phase)
      assert_equal :write, failure_events.fetch(0).dig(:metadata, :action)
      assert_equal "TestWriteStep::RaisingOutput", failure_events.fetch(0).dig(:metadata, :output_class)
      assert_same record, failure_events.fetch(0).dig(:metadata, :record)
      assert_equal :output_exception, losses.fetch(0).fetch(:reason)
      assert_equal :write, losses.fetch(0).dig(:metadata, :action)
      assert_equal "TestWriteStep::RaisingOutput", losses.fetch(0).dig(:metadata, :output_class)
      assert_same record, losses.fetch(0).dig(:metadata, :record)
    end

    private

    def record
      @record ||= build_record({ message: "work" })
    end

    def write_step(
      formatter: ->(record) { record.fetch(:message) },
      encoder: ->(payload) { "encoded:#{payload}" },
      output: RecordingOutput.new,
      max_record_bytes: Julewire::Core::DEFAULT_MAX_RECORD_BYTES
    )
      reset_tracking
      Julewire::Core::Destinations::WriteStep.new(
        formatter: formatter,
        encoder: encoder,
        output: output,
        max_record_bytes: max_record_bytes,
        increment: ->(key) { counters[key] += 1 },
        failure: ->(error, metadata) { failure_events << { error: error, metadata: metadata } },
        loss: ->(reason, metadata) { losses << { reason: reason, metadata: metadata } },
        output_class_name: -> { output.class.name&.delete_prefix("Julewire::") }
      )
    end

    def reset_tracking
      @counters = Hash.new(0)
      @failure_events = []
      @losses = []
    end

    attr_reader :counters, :failure_events, :losses
  end
end
