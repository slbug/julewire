# frozen_string_literal: true

require_relative "integration_fields"

module Julewire
  module Core
    module Testing
      module Contracts
        module Integration
          include IntegrationFields

          def assert_julewire_integration_spi_contract
            assert_julewire_integration_health_contract
            assert_julewire_integration_field_overlay_contract
            assert_julewire_integration_timestamp_contract
            assert_julewire_integration_payload_contract
            assert_julewire_integration_value_contract
            assert_julewire_deadline_scheduler_spi_contract
            assert_julewire_integration_ivar_state_contract
          end

          def assert_julewire_validation_spi_contract
            validation = Julewire::Core::Validation
            assert_nil validation.validate_options!({ known: true }, %i[known], name: :contract)
            assert_equal 1, validation.validate_byte_limit!(1, name: :limit)
            assert_equal 0, validation.validate_integer_limit!(0, name: :count)

            error = assert_raises(ArgumentError) do
              validation.validate_options!({ unknown: true }, %i[known], name: :contract)
            end
            assert_match "unknown contract options: unknown", error.message

            error = assert_raises(ArgumentError) do
              validation.validate_byte_limit!(0, name: :limit)
            end
            assert_match "limit must be nil or a positive Integer", error.message

            error = assert_raises(ArgumentError) do
              validation.validate_integer_limit!(-1, name: :count)
            end
            assert_match "count must be a non-negative Integer", error.message
          end

          def assert_julewire_truncation_marker_spi_contract
            assert_equal "[MaxDepth]", Julewire::Core::Serialization::Serializer::MAX_DEPTH_VALUE
            assert_equal "...[Truncated]", Julewire::Core::Serialization::Serializer::TRUNCATED_SUFFIX
            assert_equal "_julewire_truncation", Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY
            assert_equal(
              {
                "truncated" => true,
                "truncated_fields" => ["array_items"],
                "limits" => {
                  "max_array_items" => 1,
                  "max_depth" => 8,
                  "max_hash_keys" => 1_000,
                  "max_string_bytes" => 3
                }
              },
              Julewire::Core::Serialization::Serializer.truncation_metadata(
                ["array_items"],
                max_array_items: 1,
                max_string_bytes: 3
              )
            )
          end

          def assert_julewire_bounded_transform_spi_contract
            marker_key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY.to_sym
            result = Julewire::Core::Serialization::BoundedTransform.call(
              { secret: "value", list: [1, 2], long: "abcdef" },
              max_array_items: 1,
              max_string_bytes: 3
            ) do |_value, key:, **|
              key == :secret ? "[FILTERED]" : Julewire::Core::Serialization::BoundedTransform::CONTINUE
            end

            assert_equal "[FI...[Truncated]", result.fetch(:secret)
            assert_equal "abc...[Truncated]", result.fetch(:long)
            assert_equal ["array_items"], result.dig(:list, 1, marker_key, "truncated_fields")
          end

          def assert_julewire_integration_failure_contract(integration:, component:, exercise:)
            assert_nil exercise.call

            health = Julewire.health
            integration_health = health.dig(:process_integrations, integration.to_sym)

            assert_equal :degraded, health.fetch(:status)
            assert_kind_of Hash, integration_health
            assert_equal :degraded, integration_health.fetch(:status)
            assert_equal 1, integration_health.dig(:counts, :failures)
            assert_equal component.to_sym, integration_health.dig(:last_failure, :component)
            refute_includes integration_health.fetch(:last_failure), :message

            [health, integration_health]
          end

          def assert_julewire_integration_health_contract
            Julewire::Core::Diagnostics::ProcessIntegrationHealth.reset!
            Julewire::Core::Integration::Health.record_failure(
              :contract,
              RuntimeError.new("secret"),
              component: :subscriber
            )

            degraded = Julewire::Core::Diagnostics::ProcessIntegrationHealth.health.fetch(:contract)
            assert_equal :degraded, degraded.fetch(:status)
            assert_equal 1, degraded.dig(:counts, :failures)
            refute_includes degraded.fetch(:last_failure), :message

            Julewire::Core::Integration::Health.record_success(:contract)
            recovered = Julewire::Core::Diagnostics::ProcessIntegrationHealth.health.fetch(:contract)
            assert_equal :ok, recovered.fetch(:status)
            assert_equal 1, recovered.dig(:counts, :failures)
            assert_equal "RuntimeError", recovered.dig(:last_failure, :class)
          ensure
            Julewire::Core::Diagnostics::ProcessIntegrationHealth.reset!
          end

          def assert_julewire_integration_timestamp_contract
            now = Time.utc(2026, 5, 30, 12, 0, 0, 123_456)
            values = Julewire::Core::Integration::Values::Shape

            assert_equal "2026-05-30T12:00:00.123456000Z", values.timestamp(now)
            assert_equal "1970-01-01T00:00:01.000000002Z", values.timestamp(1_000_000_002)
          end

          def assert_julewire_integration_payload_contract
            values = Julewire::Core::Integration::Values::Shape

            assert_equal({ account_id: "acct-1" }, values.payload_hash("account_id" => "acct-1"))
            assert_equal(
              { Julewire::Core::Fields::FieldSet::VALUE_KEY => "raw" },
              values.payload_hash("raw")
            )
            assert_equal({ request_id: "req-1" }, values.hash_or_empty("request_id" => "req-1"))
            assert_equal({}, values.hash_or_empty("raw"))
          end

          def assert_julewire_integration_value_contract
            values = Julewire::Core::Integration::Values::Read

            assert_equal [true, false], [values.blank?(""), values.blank?("value")]
            assert_equal "symbol", values.value({ key: "symbol" }, :key)
            assert_equal "string", values.value({ "key" => "string" }, :key)
            assert_equal "method", values.value(Class.new { def key = "method" }.new, :key)
            assert_equal(
              "nested",
              values.nested_value({ outer: { "inner" => "nested" } }, :outer, :inner)
            )
            assert_equal "path", values.path_value({ outer: { "inner" => "path" } }, %i[outer inner])
            assert_equal :fallback, values.value(Object.new, :missing, default: :fallback)
          end

          def assert_julewire_integration_ivar_state_contract
            owner = Object.new
            state = Julewire::Core::Integration::IvarState.new(:@julewire_contract_install)
            assert_nil state.fetch(owner)
            assert_equal :installed, state.store(owner, :installed)
            assert_equal :installed, state.fetch(owner)
          end
        end
      end
    end
  end
end
