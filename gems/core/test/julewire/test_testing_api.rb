# frozen_string_literal: true

require "test_helper"
require "julewire/core/testing"

module Julewire
  class TestTestingAPI < Minitest::Test
    cover Julewire::Core::Testing::CaptureDestination
    cover Julewire::Core::Testing::NullOutput
    cover "Julewire::Core::Testing.capture"
    cover "Julewire::Core::Testing.configure_capture_destination"

    def test_capture_destination_observes_records_and_reports_health
      record = build_record({ message: "captured" })
      destination = Julewire::Testing::CaptureDestination.new

      assert_nil destination.emit(record)
      assert_equal "captured", destination.records.fetch(0).fetch(:message)
      assert_equal({ status: :ok, counts: { captured: 1 } }, destination.health)
      assert_same destination, destination.clear
      assert_empty destination.records
    end

    def test_capture_destination_defaults_to_a_detached_hash_snapshot
      record = build_record({ message: "captured", payload: { nested: { id: "one" } } })
      destination = Julewire::Testing::CaptureDestination.new

      destination.emit(record)
      captured = destination.records.fetch(0)

      assert_instance_of Hash, captured
      refute_same record, captured
      captured.dig(:payload, :nested)[:id] = "changed"

      assert_equal "one", record.dig(:payload, :nested, :id)
    end

    def test_capture_can_preserve_record_identity
      record = build_record({ message: "identity" })
      destination = Julewire::Testing::CaptureDestination.new(snapshot: false)

      destination.emit(record)

      assert_same record, destination.records.fetch(0)
      assert_same destination, destination.flush
      assert_same destination, destination.close
    end

    def test_null_output_observes_writes
      output = Julewire::Testing::NullOutput.new

      assert_equal 4, output.write("test")
      assert_equal ["test"], output.writes
      assert_same output, output.flush
      assert_same output, output.close
    end

    def test_capture_configures_runtime_and_yields_observed_records
      yielded = nil
      records = Julewire::Testing.capture do |observed|
        yielded = observed
        Julewire.emit(message: "captured")
      end

      assert_same records, yielded
      assert_equal "captured", records.fetch(0).fetch(:message)
      assert_equal :ok, Julewire.health.dig(:pipeline, :destinations, :capture, :status)
    end

    def test_capture_forwards_runtime_and_destination_options
      runtime = Julewire::Core::Runtime.new
      yielded = nil

      records = Julewire::Testing.capture(runtime, name: :observed, snapshot: false) do |observed|
        yielded = observed
        runtime.emit(message: "identity")
      end

      assert_same records, yielded
      assert_instance_of Julewire::Record, records.fetch(0)
      assert_equal "identity", records.fetch(0).message
      assert_equal :ok, runtime.health.dig(:pipeline, :destinations, :observed, :status)
    ensure
      runtime&.close
    end

    def test_capture_without_a_block_returns_live_records
      runtime = Julewire::Core::Runtime.new
      records = Julewire::Testing.capture(runtime)

      runtime.emit(message: "after-configuration")

      assert_equal "after-configuration", records.fetch(0).fetch(:message)
    ensure
      runtime&.close
    end

    def test_configure_capture_destination_clears_existing_destinations
      runtime = Julewire::Core::Runtime.new
      old_destination = Julewire::Testing::CaptureDestination.new(name: :old)
      runtime.configure { |config| config.destinations.add(old_destination) }

      destination = Julewire::Testing.configure_capture_destination(runtime, name: :new)
      runtime.emit(message: "captured")

      assert_empty old_destination.records
      assert_equal "captured", destination.records.fetch(0).fetch(:message)
      assert_equal [:new], runtime.health.dig(:pipeline, :destinations).keys
    ensure
      runtime&.close
    end
  end
end
