# frozen_string_literal: true

require "support/active_job_test_support"

module Julewire
  class TestActiveJobJobSerialization < Minitest::Test
    cover Julewire::ActiveJob::JobSerialization
    include ActiveJobTestSupport

    def test_job_serialization_stores_and_restores_julewire_carrier
      job_data = serialized_fake_job_with_request_context

      assert job_data["julewire.carrier"]
      assert_instance_of String, job_data["julewire.carrier"]

      restored = FakeSerializedJob.new
      restored.deserialize(job_data)

      carrier = restored.instance_variable_get(:@julewire_carrier)

      assert_equal job_data["julewire.carrier"], carrier["julewire"]
    end

    def test_job_serialization_carrier_restores_into_job_execution
      records = capture_records
      job_data = serialized_fake_job_with_request_context

      restored = FakeSerializedJob.new
      restored.deserialize(job_data)

      Julewire::ActiveJob::JobExecution.call(restored, configuration: Julewire::ActiveJob::Configuration.new) do
        Julewire.emit(event: "job.point", source: "test")
      end

      point = records.find { it[:event] == "job.point" }

      assert_equal "request-1", point.dig(:context, :request_id)
    end

    def test_real_active_job_serialization_stores_and_restores_julewire_carrier
      Julewire::ActiveJob.install!(
        base: ::ActiveJob::Base,
        configuration: real_active_job_configuration
      )

      with_real_active_job_class(:CarrierSmokeJob) do |job_class|
        job_data = serialize_real_job(job_class)
        restored = ::ActiveJob::Base.deserialize(job_data)
        carrier = restored.instance_variable_get(:@julewire_carrier)

        assert job_data["julewire.carrier"]
        assert_instance_of String, job_data["julewire.carrier"]
        assert_equal job_data["julewire.carrier"], carrier.fetch("julewire")
      end
    end

    def test_job_serialization_reads_string_carrier_value_for_symbol_carrier_key
      with_active_job_config(:carrier_key, :julewire) do
        job_data = serialize_fake_job_with_context

        assert job_data["julewire.carrier"]
      end
    end

    def test_job_serialization_uses_installed_configuration_not_later_global_config
      installed_configuration = Julewire::ActiveJob::Configuration.new
      installed_configuration.carrier_key = :installed
      installed_configuration.serialized_carrier_key = "installed.carrier"
      installed_configuration.execution = false
      installed_configuration.structured_events = false
      installed_configuration.silence_log_subscriber = false
      base = Class.new(SerializationBase)

      Julewire::ActiveJob.install!(base: base, configuration: installed_configuration)
      Julewire::ActiveJob.reset!

      job_data = nil
      Julewire.with_execution(type: :request, id: "request-1") do
        Julewire.context.add(request_id: "request-1")
        job_data = base.new.serialize
      end

      restored = base.new
      restored.deserialize(job_data)

      assert job_data["installed.carrier"]
      refute job_data["julewire.carrier"]
      assert_equal job_data["installed.carrier"], restored.instance_variable_get(:@julewire_carrier).fetch(:installed)
    end

    def test_real_active_job_serialization_uses_installed_configuration_not_later_global_config
      installed_configuration = real_active_job_configuration
      installed_configuration.carrier_key = :installed
      installed_configuration.serialized_carrier_key = "installed.carrier"
      base = Class.new(::ActiveJob::Base)

      Julewire::ActiveJob.install!(base: base, configuration: installed_configuration)
      Julewire::ActiveJob.reset!

      with_real_active_job_class(:InstalledCarrierSmokeJob, base: base) do |job_class|
        job_data = serialize_real_job(job_class)
        restored = ::ActiveJob::Base.deserialize(job_data)

        assert job_data["installed.carrier"]
        refute job_data["julewire.carrier"]
        assert_equal job_data["installed.carrier"], restored.instance_variable_get(:@julewire_carrier).fetch(:installed)
      end
    end

    def test_job_serialization_omits_oversized_carrier
      with_active_job_config(:carrier_max_bytes, 10) do
        job_data = serialize_fake_job_with_context

        assert_false job_data.key?("julewire.carrier")
        assert_empty Julewire.health.fetch(:process_integrations)
      end
    end

    def test_job_serialization_respects_disabled_propagation_and_bad_job_data
      previous = Julewire::ActiveJob.config.propagation
      Julewire::ActiveJob.config.propagation = false

      assert_false FakeSerializedJob.new.serialize.key?("julewire.carrier")

      bad_data = Object.new
      def bad_data.[]=(_key, _value)
        raise "no writes"
      end

      def bad_data.[](_key) = raise("no reads")

      job = job_serializing(bad_data)

      assert_same bad_data, job.serialize
      restored = FakeSerializedJob.new
      restored.deserialize(bad_data)

      assert_equal({}, restored.instance_variable_get(:@julewire_carrier))
      assert_empty Julewire.health.fetch(:process_integrations)
    ensure
      Julewire::ActiveJob.config.propagation = previous if defined?(previous)
    end

    def test_job_serialization_contains_injection_and_extraction_failures
      bad_data = Object.new
      def bad_data.[]=(_key, _value)
        raise "no writes"
      end

      Julewire.with_execution(type: :request, id: "request-1") do
        assert_same bad_data, job_serializing(bad_data).serialize
      end

      assert_equal :degraded, Julewire.health.dig(:process_integrations, :active_job, :status)
      assert_equal :carrier_inject, Julewire.health.dig(:process_integrations, :active_job, :last_failure, :action)
      assert_equal :job_serialization,
                   Julewire.health.dig(:process_integrations, :active_job, :last_failure, :component)
      assert_equal "RuntimeError", Julewire.health.dig(:process_integrations, :active_job, :last_failure, :class)

      job = FakeSerializedJob.new
      bad_read_data = Object.new
      def bad_read_data.[](_key)
        raise "no reads"
      end

      job.deserialize(bad_read_data)

      assert_equal({}, job.instance_variable_get(:@julewire_carrier))
      assert_equal :degraded, Julewire.health.dig(:process_integrations, :active_job, :status)
      assert_equal :carrier_extract, Julewire.health.dig(:process_integrations, :active_job, :last_failure, :action)
      assert_equal :job_serialization,
                   Julewire.health.dig(:process_integrations, :active_job, :last_failure, :component)
      assert_equal "RuntimeError", Julewire.health.dig(:process_integrations, :active_job, :last_failure, :class)
    end

    def test_job_serialization_success_clears_previous_injection_failure
      bad_data = Object.new
      def bad_data.[]=(_key, _value)
        raise "no writes"
      end

      Julewire.with_execution(type: :request, id: "request-1") do
        job_serializing(bad_data).serialize
        job_serializing({}).serialize
      end

      assert_equal :ok, Julewire.health.dig(:process_integrations, :active_job, :status)
    end

    def test_job_serialization_extracts_empty_carrier_when_payload_missing
      job = FakeSerializedJob.new

      job.deserialize({})

      assert_equal({}, job.instance_variable_get(:@julewire_carrier))
      assert_equal :ok, Julewire.health.dig(:process_integrations, :active_job, :status)
    end

    def test_job_serialization_deserialize_returns_super_result
      job = Class.new do
        prepend Julewire::ActiveJob::JobSerialization

        def deserialize(_job_data)
          :deserialized
        end
      end.new

      assert_equal :deserialized, job.deserialize({})
    end

    def test_job_serialization_falls_back_when_installed_configuration_raises
      base = Class.new(SerializationBase)
      base.define_singleton_method(:julewire_active_job_configuration) { raise "bad config" }
      base.prepend Julewire::ActiveJob::JobSerialization

      Julewire.with_execution(type: :request, id: "request-1") do
        assert_true base.new.serialize.key?("julewire.carrier")
      end
    end

    private

    def serialized_fake_job_with_request_context
      Julewire.with_execution(type: :request, id: "request-1") do
        Julewire.context.add(request_id: "request-1")
        FakeSerializedJob.new.serialize
      end
    end

    def job_serializing(job_data)
      Class.new do
        prepend Julewire::ActiveJob::JobSerialization

        define_method(:serialize) { job_data }
        define_method(:deserialize) { |_data| nil }
      end.new
    end
  end
end
