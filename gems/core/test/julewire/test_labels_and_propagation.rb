# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestLabelsAndPropagation < Minitest::Test
    cover Julewire::Core::Fields::StaticLabels

    def test_static_labels_are_added_to_point_and_summary_records
      output = StringIO.new

      configure_output_with_labels(output, service: "billing", env: "test")

      Julewire.with_execution(type: :operation) do
        Julewire.emit(message: "hello", labels: { component: "controller" })
      end

      point, summary = output.string.lines.map { JSON.parse(it) }

      assert_equal "billing", point.dig("labels", "service")
      assert_equal "test", point.dig("labels", "env")
      assert_equal "controller", point.dig("labels", "component")
      assert_equal "billing", summary.dig("labels", "service")
    end

    def test_record_labels_override_static_label_collisions
      output = StringIO.new

      configure_output_with_labels(output, service: "core", env: "test")

      Julewire.emit(labels: { service: "worker" })

      record = JSON.parse(output.string)

      assert_equal "worker", record.dig("labels", "service")
      assert_equal "test", record.dig("labels", "env")
    end

    def test_execution_labels_apply_to_point_and_summary_records
      output = StringIO.new

      configure_output_with_labels(output, service: "billing")

      Julewire.with_execution(type: :operation, labels: { tenant: "acme" }) do
        Julewire.emit(message: "inside", labels: { tenant: "override" })
      end

      point, summary = output.string.lines.map { JSON.parse(it) }

      assert_equal "override", point.dig("labels", "tenant")
      assert_equal "acme", summary.dig("labels", "tenant")
      assert_equal "billing", summary.dig("labels", "service")
    end

    def test_static_labels_can_remove_keys
      labels = Julewire::Core::Fields::StaticLabels.new
      labels.add(service: "billing", "env" => "test")

      labels.remove(:service).remove(:env)

      assert_empty labels.to_h
    end

    def test_static_labels_remove_uses_string_symbol_equivalence
      labels = Julewire::Core::Fields::StaticLabels.new
      labels.add(foo: 1, "bar" => 2)

      labels.remove("foo").remove(:bar)

      assert_empty labels.to_h
    end

    def test_propagation_capture_keeps_context_values_raw
      envelope = capture_propagation(
        type: :operation,
        execution: { token: "execution-secret" },
        context: { token: "context-secret" },
        summary: { token: "summary-secret" }
      )

      assert_equal "context-secret", envelope.dig(:context, "token")
      assert_equal "execution-secret", envelope.dig(:execution, "token")
      refute_includes envelope, :summary
      refute_includes envelope.fetch(:context).values, "summary-secret"
    end

    def test_propagation_capture_snapshots_string_values
      context_value = +"context"
      execution_value = +"execution"

      envelope = capture_propagation(
        type: :operation,
        execution: { token: execution_value },
        context: { token: context_value }
      )
      context_value << "-changed"
      execution_value << "-changed"

      assert_equal "context", envelope.dig(:context, "token")
      assert_equal "execution", envelope.dig(:execution, "token")
    end

    def test_propagation_capture_without_execution_omits_execution_envelope
      Julewire.context.add(account_id: "acct-1")

      envelope = Julewire::Core::Propagation.capture

      assert_equal "acct-1", envelope.dig(:context, "account_id")
      refute_includes envelope, :execution
    end

    def test_propagation_capture_omits_record_local_attributes
      Julewire.attributes.add(tenant: "record-local")

      envelope = Julewire::Core::Propagation.capture

      refute_includes envelope, :attributes
    end

    private

    def configure_output_with_labels(output, **labels)
      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.labels.add(labels)
      end
    end
  end
end
