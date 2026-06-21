# frozen_string_literal: true

require "support/active_job_test_support"

module Julewire
  class TestActiveJobContinuations < Minitest::Test
    include ActiveJobTestSupport

    def test_continuation_events_enrich_active_job_summary # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      records = capture_records
      subscriber = Julewire::ActiveJob::Subscribers::Event.new

      Julewire::ActiveJob::JobExecution.call(fake_job, configuration: Julewire::ActiveJob::Configuration.new) do
        subscriber.emit(
          name: "active_job.step_started",
          timestamp: 1_000_000_000,
          payload: { step: "import", cursor: 10, resumed: true }
        )
        subscriber.emit(
          name: "active_job.step",
          timestamp: 1_000_000_001,
          payload: { step: "import", cursor: 11, interrupted: true }
        )
        subscriber.emit(
          name: "active_job.interrupt",
          timestamp: 1_000_000_002,
          payload: { description: "at 'import'", reason: :stopping }
        )
      end

      summary = records.find { it[:kind] == :summary }

      assert_equal 1, active_job_attributes(summary).fetch(:continuation_steps_started)
      assert_equal 1, active_job_attributes(summary).fetch(:continuation_steps_interrupted)
      assert_equal 1, active_job_attributes(summary).fetch(:continuation_interruptions)
      assert_equal "interrupted", active_job_attributes(summary).fetch(:continuation_status)
      assert_equal "import", active_job_attributes(summary).fetch(:continuation_last_step).to_s
      assert_equal 11, active_job_attributes(summary).fetch(:continuation_last_step_cursor)
      assert_equal "interrupted", active_job_attributes(summary).fetch(:continuation_last_step_state)
    end

    def test_continuation_events_enrich_skipped_resume_and_failed_steps # rubocop:disable Metrics/AbcSize
      records = capture_records
      subscriber = Julewire::ActiveJob::Subscribers::Event.new

      Julewire::ActiveJob::JobExecution.call(fake_job, configuration: Julewire::ActiveJob::Configuration.new) do
        subscriber.emit(
          name: "active_job.step_skipped",
          payload: { step: "export", cursor: 2 }
        )
        subscriber.emit(
          name: "active_job.resume",
          payload: { description: "after deploy" }
        )
        subscriber.emit(
          name: "active_job.step",
          payload: { step: "export", cursor: 3, exception_class: "RuntimeError" }
        )
      end

      summary = records.find { it[:kind] == :summary }

      assert_equal 1, active_job_attributes(summary).fetch(:continuation_steps_skipped)
      assert_equal 1, active_job_attributes(summary).fetch(:continuation_resumptions)
      assert_equal 1, active_job_attributes(summary).fetch(:continuation_steps_failed)
      assert_equal "resumed", active_job_attributes(summary).fetch(:continuation_status)
      assert_equal "export", active_job_attributes(summary).fetch(:continuation_last_step).to_s
      assert_equal 3, active_job_attributes(summary).fetch(:continuation_last_step_cursor)
      assert_equal "failed", active_job_attributes(summary).fetch(:continuation_last_step_state)
    end

    def test_real_active_job_continuation_events_run_inside_julewire_boundary # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      require "active_job/continuation"

      reset_active_job_event_reporter_subscriber!
      ::ActiveJob::Base.queue_adapter = :inline
      Julewire::ActiveJob.install!(base: ::ActiveJob::Base)
      records = capture_records
      Object.send(:remove_const, :ContinuationSmokeJob) if Object.const_defined?(:ContinuationSmokeJob)
      Object.const_set(:ContinuationSmokeJob, Class.new(::ActiveJob::Base) do
        include ::ActiveJob::Continuable

        def perform
          step(:import, start: 0) do |step|
            Julewire.emit(event: "continuation.inside", source: "test", payload: { cursor: step.cursor })
            step.set!(1)
          end
        end
      end)

      ::ContinuationSmokeJob.perform_later

      step_started = records.find { it[:event] == "active_job.step_started" }
      inside = records.find { it[:event] == "continuation.inside" }
      step_completed = records.find { it[:event] == "active_job.step" }
      summary = records.find { it[:event] == "job.completed" }

      assert_equal summary.dig(:context, :job_id), step_started.dig(:context, :job_id)
      assert_equal summary.dig(:context, :job_id), inside.dig(:context, :job_id)
      assert_equal summary.dig(:context, :job_id), step_completed.dig(:context, :job_id)
      assert_equal 1, active_job_attributes(summary).fetch(:continuation_steps_started)
      assert_equal 1, active_job_attributes(summary).fetch(:continuation_steps_completed)
      assert_equal "import", active_job_attributes(summary).fetch(:continuation_last_step).to_s
      assert_equal 1, active_job_attributes(summary).fetch(:continuation_last_step_cursor)
      assert_equal "completed", active_job_attributes(summary).fetch(:continuation_last_step_state)
    ensure
      Object.send(:remove_const, :ContinuationSmokeJob) if Object.const_defined?(:ContinuationSmokeJob)
    end
  end
end
