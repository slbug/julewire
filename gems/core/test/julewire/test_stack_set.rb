# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestStackSet < Minitest::Test
    cover Julewire::Core::Fields::StackSet
    cover Julewire::Core::Fields::FieldStack
    cover Julewire::Core::Fields::Bags

    def test_bag_registry_drives_core_field_policy
      bags = Julewire::Core::Fields::Bags

      assert_equal %i[timestamp severity kind event message logger source], bags.record_scalar_keys
      assert_equal %i[execution context carry neutral attributes labels payload metrics], bags.record_hash_sections
      assert_equal Julewire::Core::Records::Record::REQUIRED_KEYS, bags.required_record_keys
      assert_equal %i[execution context carry neutral attributes labels payload metrics error],
                   bags.transform_container_sections
      assert_equal %i[carry neutral], bags.hidden_output_sections
      assert_equal %i[context carry attributes], bags.app_write_sections
      assert_equal %i[execution context carry neutral attributes summary], bags.integration_write_sections
      assert_equal %i[execution context carry], bags.propagation_sections
      assert_equal %i[context carry neutral attributes], bags.stack_sections
      assert bags.delete_paths?(:carry)
      refute bags.delete_paths?(:context)
      refute bags.delete_paths?(:neutral)
    end

    def test_bag_registry_capabilities_feed_core_components
      bags = Julewire::Core::Fields::Bags

      assert_equal bags.record_hash_sections, Julewire::Core::Records::Record::HASH_SECTIONS
      assert_equal bags.transform_container_sections, Julewire::Core::Processing::RecordFieldTransform.container_keys
      assert_equal bags.hidden_output_sections, Julewire::Core::Records::PublicProjection::INTERNAL_KEYS
      assert_equal bags.app_write_sections,
                   Julewire::Core::Fields.const_get(:SectionProxy).const_get(:STORE_METHODS).keys
      assert_equal bags.propagation_sections - [:execution],
                   Julewire::Core::Propagation.const_get(:FIELD_SECTIONS)
    end

    def test_carry_stack_preserves_delete_path_semantics
      fields = Julewire::Core::Fields::StackSet.new(
        carry: {
          http: {
            request_headers: {
              authorization: "secret",
              accept: "application/json"
            }
          }
        }
      )

      fields.delete(:carry, %i[http request_headers authorization])

      assert_nil fields.snapshot(:carry).dig(:http, :request_headers, :authorization)
      assert_equal "application/json", fields.snapshot(:carry).dig(:http, :request_headers, :accept)
    end

    def test_inherited_can_drop_attributes_and_neutral_without_dropping_context_or_carry
      source = Julewire::Core::Fields::StackSet.new(
        context: { request_id: "req-1" },
        carry: { traceparent: "trace-1" },
        attributes: { tenant_id: "tenant-1" },
        neutral: { "job.name": "ImportJob" }
      )

      inherited = Julewire::Core::Fields::StackSet.inherit_from(source, inherit_attributes: false)

      assert_equal({ request_id: "req-1" }, inherited.snapshot(:context))
      assert_equal({ traceparent: "trace-1" }, inherited.snapshot(:carry))
      assert_empty inherited.snapshot(:attributes)
      assert_empty inherited.snapshot(:neutral)
    end

    def test_existing_field_stacks_are_reused
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1" } })
      fields = Julewire::Core::Fields::StackSet.new(context: stack)

      assert_same stack, fields.stack(:context)
    end
  end
end
