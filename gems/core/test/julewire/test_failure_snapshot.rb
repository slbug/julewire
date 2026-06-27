# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestFailureSnapshot < Minitest::Test
    cover Julewire::Core::Diagnostics::FailureSnapshot
    def test_failure_snapshot_keeps_public_health_metadata_shape
      labels = { service: "api" }

      snapshot = Julewire::Core::Diagnostics::FailureSnapshot.build(
        RuntimeError.new("hidden"),
        action: :flush,
        component: :subscriber,
        destination: :audit,
        event: "request.failed",
        integration: :rails,
        output_class: "StringIO",
        phase: :destination_processor,
        processor: "AuditProcessor",
        reason: :output_error,
        record_metadata: {
          event: "request",
          labels: labels,
          logger: "ignored",
          severity: :error,
          source: "controller"
        },
        result_class: "String",
        status: :degraded
      )

      labels[:service] = "changed"

      assert_predicate snapshot, :frozen?
      assert_predicate snapshot.fetch(:at), :utc?
      assert_equal "RuntimeError", snapshot.fetch(:class)
      assert_equal :flush, snapshot.fetch(:action)
      assert_equal :subscriber, snapshot.fetch(:component)
      assert_equal :audit, snapshot.fetch(:destination)
      assert_equal "request.failed", snapshot.fetch(:event)
      assert_equal :rails, snapshot.fetch(:integration)
      assert_equal "StringIO", snapshot.fetch(:output_class)
      assert_equal :destination_processor, snapshot.fetch(:phase)
      assert_equal "AuditProcessor", snapshot.fetch(:processor)
      assert_equal :output_error, snapshot.fetch(:reason)
      assert_equal "String", snapshot.fetch(:result_class)
      assert_equal :degraded, snapshot.fetch(:status)
      assert_equal(
        { event: "request", labels: { service: "api" }, severity: :error, source: "controller" },
        snapshot.fetch(:record)
      )
    end

    def test_failure_snapshot_omits_missing_record_metadata
      snapshot = Julewire::Core::Diagnostics::FailureSnapshot.build(RuntimeError.new("hidden"))

      refute_includes snapshot, :record
    end

    def test_failure_snapshot_omits_non_hash_record_metadata
      snapshot = Julewire::Core::Diagnostics::FailureSnapshot.build(
        RuntimeError.new("hidden"),
        record_metadata: Object.new
      )

      refute_includes snapshot, :record
    end

    def test_failure_snapshot_omits_non_hash_record_labels
      snapshot = Julewire::Core::Diagnostics::FailureSnapshot.build(
        RuntimeError.new("hidden"),
        record_metadata: { event: "log", labels: "not labels" }
      )

      assert_equal({ event: "log" }, snapshot.fetch(:record))
    end

    def test_failure_snapshot_allows_record_metadata_without_labels
      snapshot = Julewire::Core::Diagnostics::FailureSnapshot.build(
        RuntimeError.new("hidden"),
        record_metadata: { event: "log" }
      )

      assert_equal({ event: "log" }, snapshot.fetch(:record))
    end

    def test_failure_snapshot_allows_record_metadata_without_event
      snapshot = Julewire::Core::Diagnostics::FailureSnapshot.build(
        RuntimeError.new("hidden"),
        record_metadata: { severity: :warn, source: "worker" }
      )

      assert_equal({ severity: :warn, source: "worker" }, snapshot.fetch(:record))
    end

    def test_failure_snapshot_accepts_hash_subclass_record_metadata
      labels = Class.new(Hash).new.merge(service: "api")
      metadata = Class.new(Hash).new.merge(event: "log", labels: labels)

      snapshot = Julewire::Core::Diagnostics::FailureSnapshot.build(
        RuntimeError.new("hidden"),
        record_metadata: metadata
      )

      assert_equal({ event: "log", labels: { service: "api" } }, snapshot.fetch(:record))
    end
  end
end
