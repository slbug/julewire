# frozen_string_literal: true

require "support/active_job_test_support"

module Julewire
  class TestActiveJobPropagationLifecycle < Minitest::Test
    cover Julewire::ActiveJob::JobSerialization
    cover Julewire::ActiveJob::JobExecution
    include ActiveJobTestSupport

    class ContextJob < ::ActiveJob::Base
      def perform
        Julewire.emit(event: "job.point", source: "test", attributes: { forwarded: Julewire.carry.to_h })
      end
    end

    class RetryingJob < ContextJob
      retry_on RuntimeError, wait: 0, attempts: 2

      def perform
        super
        raise "retry once" if executions == 1
      end
    end

    class ParentJob < ContextJob
      def perform
        Julewire.context.add(step: "child")
        ContextJob.perform_later
      end
    end

    def setup
      super
      @records = capture_records
      @configuration = Julewire::ActiveJob::Configuration.new
      @configuration.structured_events = false
      @configuration.silence_log_subscriber = false
      ContextJob.queue_adapter = :test
      ContextJob.logger = Logger.new(StringIO.new)
      Julewire::ActiveJob.install!(base: ::ActiveJob::Base, configuration: @configuration)
    end

    def test_reserialization_preserves_origin_without_an_ambient_context
      job_data = serialized_job
      restored = ::ActiveJob::Base.deserialize(job_data)

      ::ActiveJob::Base.execute(restored.serialize)

      assert_equal "request-1", point_records.fetch(0).dig(:context, :request_id)
      assert_equal({ id: 7 }, point_records.fetch(0).dig(:context, :account))
      assert_equal({ headers: { traceparent: "incoming" } }, point_records.fetch(0).dig(:attributes, :forwarded))
      assert_equal 1, job_summaries.length
      assert_equal :summary, job_summaries.fetch(0).fetch(:kind)
      assert_equal "ok", job_summaries.fetch(0).dig(:attributes, :active_job, :status)
      assert_empty Julewire.context.to_h
      assert_empty Julewire.carry.to_h
      assert_false Julewire.current_execution?
    end

    def test_worker_context_cannot_replace_a_deserialized_jobs_origin
      restored = ::ActiveJob::Base.deserialize(serialized_job)
      reserialized = Julewire.context.with(worker_name: "worker-1") { restored.serialize }

      ::ActiveJob::Base.execute(reserialized)

      assert_equal "request-1", point_records.fetch(0).dig(:context, :request_id)
      assert_false point_records.fetch(0).fetch(:context).key?(:worker_name)
    end

    def test_unrelated_request_cannot_rebind_a_deserialized_job
      restored = ::ActiveJob::Base.deserialize(serialized_job)
      reserialized = Julewire.with_execution(type: :request, id: "request-2") do
        Julewire.context.add(request_id: "request-2", tenant: "unrelated")
        restored.serialize
      end

      ::ActiveJob::Base.execute(reserialized)

      assert_equal "request-1", point_records.fetch(0).dig(:context, :request_id)
      assert_false point_records.fetch(0).fetch(:context).key?(:tenant)
    end

    def test_bulk_enqueued_jobs_restore_context_when_performed_later
      jobs = [ContextJob.new, ContextJob.new]
      Julewire.context.with(request_id: "bulk-request") { ::ActiveJob.perform_all_later(jobs) }
      queued = ContextJob.queue_adapter.enqueued_jobs

      assert_equal 2, queued.length

      queued.each { ::ActiveJob::Base.execute(it) }

      assert_equal(%w[bulk-request bulk-request], point_records.map { it.dig(:context, :request_id) })
      assert_equal(jobs.map(&:job_id), point_records.map { it.dig(:context, :job_id) })
      assert_equal 2, job_summaries.length
      assert_empty Julewire.context.to_h
      assert_false Julewire.current_execution?
    end

    def test_retry_on_retains_origin_after_the_perform_scope_unwinds
      job_data = serialized_job(job_class: RetryingJob)
      ::ActiveJob::Base.execute(job_data)
      queued = ContextJob.queue_adapter.enqueued_jobs

      assert_equal 1, queued.length

      ::ActiveJob::Base.execute(queued.fetch(0))

      assert_equal(%w[request-1 request-1], point_records.map { it.dig(:context, :request_id) })
      assert_equal(%w[error ok], job_summaries.map { it.dig(:attributes, :active_job, :status) })
      assert_empty Julewire.context.to_h
      assert_false Julewire.current_execution?
    end

    def test_new_child_job_captures_the_live_parent_context
      ::ActiveJob::Base.execute(serialized_job(job_class: ParentJob))
      queued = ContextJob.queue_adapter.enqueued_jobs

      assert_equal 1, queued.length

      ::ActiveJob::Base.execute(queued.fetch(0))

      assert_equal "request-1", point_records.fetch(0).dig(:context, :request_id)
      assert_equal "child", point_records.fetch(0).dig(:context, :step)
      assert_empty Julewire.context.to_h
    end

    def test_missing_inbound_carrier_does_not_capture_a_worker_context
      job_data = ContextJob.new.serialize
      job_data.delete("julewire.carrier")
      restored = ::ActiveJob::Base.deserialize(job_data)
      reserialized = Julewire.context.with(request_id: "unrelated") { restored.serialize }

      assert_false reserialized.key?("julewire.carrier")
      assert_equal :ok, Julewire.health.dig(:process_integrations, :active_job, :status)

      ::ActiveJob::Base.execute(reserialized)

      assert_false point_records.fetch(0).fetch(:context).key?(:request_id)
    end

    def test_saved_carrier_obeys_exact_and_unlimited_byte_limits
      job_data = serialized_job
      restored = ::ActiveJob::Base.deserialize(job_data)
      [nil, job_data.fetch("julewire.carrier").bytesize].each do |limit|
        @configuration.carrier_max_bytes = limit
        ::ActiveJob::Base.execute(restored.serialize)
      end

      assert_equal(%w[request-1 request-1], point_records.map { it.dig(:context, :request_id) })
    end

    def test_oversized_saved_carrier_is_omitted_without_capturing_worker_context
      job_data = serialized_job
      restored = ::ActiveJob::Base.deserialize(job_data)
      @configuration.carrier_max_bytes = job_data.fetch("julewire.carrier").bytesize - 1
      reserialized = Julewire.context.with(request_id: "unrelated") { restored.serialize }

      assert_false reserialized.key?("julewire.carrier")

      ::ActiveJob::Base.execute(reserialized)

      assert_false point_records.fetch(0).fetch(:context).key?(:request_id)
    end

    def test_changed_carrier_key_does_not_rebind_an_existing_job
      restored = ::ActiveJob::Base.deserialize(serialized_job)
      @configuration.carrier_key = :changed
      reserialized = Julewire.context.with(request_id: "unrelated") { restored.serialize }

      assert_false reserialized.key?("julewire.carrier")
      assert_equal :ok, Julewire.health.dig(:process_integrations, :active_job, :status)

      ::ActiveJob::Base.execute(reserialized)
      ::ActiveJob::Base.execute(serialized_job)

      assert_false point_records.fetch(0).fetch(:context).key?(:request_id)
      assert_equal "request-1", point_records.fetch(1).dig(:context, :request_id)
    end

    def test_disabling_propagation_omits_a_previously_deserialized_carrier
      restored = ::ActiveJob::Base.deserialize(serialized_job)
      @configuration.propagation = false
      reserialized = restored.serialize

      assert_false reserialized.key?("julewire.carrier")

      ::ActiveJob::Base.execute(reserialized)

      assert_false point_records.fetch(0).fetch(:context).key?(:request_id)
    end

    def test_invalid_reserialized_carriers_report_health_without_preventing_execution
      { 12 => :non_hash, "{" => :malformed }.each do |value, status|
        @records.clear
        job_data = ContextJob.new.serialize.merge("julewire.carrier" => value)
        restored = ::ActiveJob::Base.deserialize(job_data)
        ::ActiveJob::Base.execute(restored.serialize)

        assert_equal 1, point_records.length
        assert_false point_records.fetch(0).fetch(:context).key?(:request_id)
        assert_equal "ok", job_summaries.fetch(0).dig(:attributes, :active_job, :status)
        health = Julewire.health.fetch(:process_integrations).fetch(:active_job)

        assert_equal :degraded, health.fetch(:status)
        assert_equal :carrier_restore, health.dig(:last_failure, :action)
        assert_equal status, health.dig(:last_failure, :status)
        assert_empty Julewire.context.to_h
      end
    end

    private

    def serialized_job(job_class: ContextJob)
      Julewire.with_execution(type: :request, id: "request-1") do
        Julewire.context.add(request_id: "request-1", account: { id: 7 })
        Julewire.carry.add(headers: { traceparent: "incoming" })
        job_class.new.serialize
      end
    end

    def point_records
      @records.select { it[:event] == "job.point" }
    end

    def job_summaries
      @records.select { it[:event] == "job.completed" }
    end
  end
end
