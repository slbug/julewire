# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3::memory:"

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "solid_queue"
require "julewire/active_job"
require "julewire/core/testing"
require "minitest/autorun"
require "minitest/strict"
require "stringio"
require_relative "../../../../support/testing/test_reports"
Julewire::TestSupport::TestReports.start!

module Julewire
  class TestSolidQueueIntegration < Minitest::Test
    class Application < ::Rails::Application
      config.eager_load = false
      config.root = File.expand_path("../..", __dir__)
      config.logger = Logger.new(StringIO.new)
      config.active_job.queue_adapter = :solid_queue
      config.solid_queue.use_skip_locked = false
    end

    Application.initialize!
    ::ActiveRecord::Migration.suppress_messages do
      load File.join(Gem.loaded_specs.fetch("solid_queue").full_gem_path,
                     "lib/generators/solid_queue/install/templates/db/queue_schema.rb")
    end

    class BatchJob < ::ActiveJob::Base
      def perform(event)
        Julewire.emit(event: event, source: "test", attributes: { batch_id: batch.id })
        raise "failed member" if event == "member.failure"
      end
    end

    def setup
      @records = Julewire::Testing.capture
      BatchJob.queue_name = name
      @process = ::SolidQueue::Process.register(kind: "Worker", name: name, pid: Process.pid)
    end

    def test_bulk_members_and_success_callbacks_preserve_context
      batch = Julewire.context.with(request_id: "batch-origin") do
        ::SolidQueue::Batch.enqueue(on_success: BatchJob.new("success"), on_finish: BatchJob.new("finish")) do
          ::ActiveJob.perform_all_later(BatchJob.new("member"), BatchJob.new("member"))
        end
      end
      members = ::SolidQueue::ReadyExecution.claim([name], 2, @process.id)

      assert_equal 2, members.length

      Julewire.context.with(worker_name: "unrelated-worker") { members.each(&:perform) }

      assert_true batch.reload.finished?
      assert_equal 2, batch.completed_jobs
      callbacks = ::SolidQueue::ReadyExecution.claim([name], 2, @process.id)

      assert_equal 2, callbacks.length

      callbacks.each(&:perform)
      points = @records.select { it[:source] == "test" }
      summaries = @records.select { it[:event] == "job.completed" }

      assert_equal %w[finish member member success], points.map { it.fetch(:event) }.sort
      assert_equal ["batch-origin"], points.map { it.dig(:context, :request_id) }.uniq
      assert_equal [batch.id], points.map { it.dig(:attributes, :batch_id) }.uniq
      assert_equal 4, summaries.length
      assert_equal ["ok"], summaries.map { it.dig(:attributes, :active_job, :status) }.uniq
      assert_equal ["batch-origin"], summaries.map { it.dig(:context, :request_id) }.uniq
      assert_empty Julewire.context.to_h
      assert_false Julewire.current_execution?
    end

    def test_failure_callbacks_preserve_context_after_a_member_fails
      batch = Julewire.context.with(request_id: "batch-origin") do
        ::SolidQueue::Batch.enqueue(on_failure: BatchJob.new("failure"), on_finish: BatchJob.new("finish")) do
          BatchJob.perform_later("member.failure")
        end
      end
      members = ::SolidQueue::ReadyExecution.claim([name], 1, @process.id)

      assert_equal 1, members.length

      Julewire.context.with(worker_name: "unrelated-worker") do
        assert_raises(RuntimeError) { members.fetch(0).perform }
      end

      assert_true batch.reload.failed?
      callbacks = ::SolidQueue::ReadyExecution.claim([name], 2, @process.id)

      assert_equal 2, callbacks.length

      callbacks.each(&:perform)
      points = @records.select { it[:source] == "test" }
      summaries = @records.select { it[:event] == "job.completed" }

      assert_equal %w[failure finish member.failure], points.map { it.fetch(:event) }.sort
      assert_equal ["batch-origin"], points.map { it.dig(:context, :request_id) }.uniq
      assert_equal [batch.id], points.map { it.dig(:attributes, :batch_id) }.uniq
      assert_equal(%w[error ok ok], summaries.map { it.dig(:attributes, :active_job, :status) })
      assert_equal ["batch-origin"], summaries.map { it.dig(:context, :request_id) }.uniq
      assert_empty Julewire.context.to_h
      assert_false Julewire.current_execution?
    end
  end
end
