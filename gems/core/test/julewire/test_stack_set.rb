# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestStackSet < Minitest::Test
    cover Julewire::Core::Fields::StackSet
    cover Julewire::Core::Fields::FieldStack
    cover Julewire::Core::Fields::Bags
    cover "Julewire::Core::Fields::StackSet#without"

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
      assert_predicate bags.required_record_keys, :frozen?
      assert_predicate bags.hidden_output_sections, :frozen?
      assert_predicate bags.record_hash_sections, :frozen?
      assert_true bags.delete_paths?(:carry)
      assert_false bags.delete_paths?(:context)
      assert_false bags.delete_paths?(:neutral)
    end

    def test_bag_registry_capabilities_feed_core_components
      bags = Julewire::Core::Fields::Bags

      assert_equal bags.record_hash_sections, Julewire::Core::Records::Record::HASH_SECTIONS
      assert_equal bags.hidden_output_sections, Julewire::Core::Records::PublicProjection::INTERNAL_KEYS
      assert_equal bags.app_write_sections,
                   Julewire::Core::Fields.const_get(:SectionProxy).const_get(:STORE_METHODS).keys
      assert_equal bags.propagation_sections - [:execution],
                   Julewire::Core::Propagation.const_get(:FIELD_SECTIONS)
    end

    def test_carry_stack_preserves_delete_path_semantics
      fields = stack_set_with_request_headers

      fields.delete(:carry, %i[http request_headers authorization])

      assert_nil fields.snapshot(:carry).dig(:http, :request_headers, :authorization)
      assert_equal "application/json", fields.snapshot(:carry).dig(:http, :request_headers, :accept)
    end

    def test_non_delete_sections_ignore_delete_paths
      fields = Julewire::Core::Fields::StackSet.new(
        context: {
          http: {
            request_headers: {
              authorization: "secret"
            }
          }
        }
      )

      fields.delete(:context, %i[http request_headers authorization])

      assert_equal "secret", fields.snapshot(:context).dig(:http, :request_headers, :authorization)
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

    def test_dropped_inherited_sections_remain_writable_fresh_stacks
      source = Julewire::Core::Fields::StackSet.new(
        attributes: { tenant_id: "tenant-1" },
        neutral: { "job.name": "ImportJob" }
      )

      inherited = Julewire::Core::Fields::StackSet.inherit_from(source, inherit_attributes: false)
      inherited.add(:attributes, { account_id: "acct-1" })
      inherited.add(:neutral, { "worker.name": "Worker" })

      assert_instance_of Julewire::Core::Fields::FieldStack, inherited.stack(:attributes)
      assert_instance_of Julewire::Core::Fields::FieldStack, inherited.stack(:neutral)
      assert_equal({ account_id: "acct-1" }, inherited.snapshot(:attributes))
      assert_equal({ "worker.name": "Worker" }, inherited.snapshot(:neutral))
      assert_equal({ tenant_id: "tenant-1" }, source.snapshot(:attributes))
      assert_equal({ "job.name": "ImportJob" }, source.snapshot(:neutral))
    end

    def test_inherited_attribute_sections_are_included_and_branched_when_requested
      source = Julewire::Core::Fields::StackSet.new(
        context: { request_id: "req-1" },
        attributes: { tenant_id: "tenant-1" },
        neutral: { "job.name": "ImportJob" }
      )

      inherited = Julewire::Core::Fields::StackSet.inherit_from(source, inherit_attributes: true)
      inherited.add(:context, { account_id: "acct-1" })
      inherited.add(:attributes, { user_id: "user-1" })

      assert_equal({ request_id: "req-1", account_id: "acct-1" }, inherited.snapshot(:context))
      assert_equal({ tenant_id: "tenant-1", user_id: "user-1" }, inherited.snapshot(:attributes))
      assert_equal({ "job.name": "ImportJob" }, inherited.snapshot(:neutral))
      assert_equal({ request_id: "req-1" }, source.snapshot(:context))
      assert_equal({ tenant_id: "tenant-1" }, source.snapshot(:attributes))
    end

    def test_existing_field_stacks_are_reused
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1" } })
      fields = Julewire::Core::Fields::StackSet.new(context: stack)

      assert_same stack, fields.stack(:context)
    end

    def test_existing_field_stack_subclasses_are_reused
      stack_class = Class.new(Julewire::Core::Fields::FieldStack)
      stack = stack_class.new({ account: { id: "acct-1" } })
      fields = Julewire::Core::Fields::StackSet.new(context: stack)

      assert_same stack, fields.stack(:context)
    end

    def test_with_accepts_keyword_only_overlay
      fields = Julewire::Core::Fields::StackSet.new

      result = fields.with(:context, request_id: "request-1") do
        assert_equal({ request_id: "request-1" }, fields.snapshot(:context))
        :inside
      end

      assert_equal :inside, result
      assert_empty fields.snapshot(:context)
    end

    def test_add_defaults_to_unowned_input
      fields = Julewire::Core::Fields::StackSet.new
      key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY
      metadata = Julewire::Core::Serialization::Serializer.truncation_metadata(["context"])

      error = assert_raises(ArgumentError) do
        fields.add(:context, { key => metadata })
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
      assert_empty fields.snapshot(:context)
    end

    def test_add_and_with_accept_owned_truncation_metadata
      fields = Julewire::Core::Fields::StackSet.new
      key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY.to_sym
      metadata = Julewire::Core::Serialization::Serializer.truncation_metadata(["context"], key_style: :symbol)

      fields.add(:context, { key => metadata }, owned: true)

      assert_symbol_truncation_metadata(fields.snapshot(:context).fetch(key), fields: ["context"])

      result = fields.with(:context, { key => metadata }, owned: true) do
        assert_symbol_truncation_metadata(fields.snapshot(:context).fetch(key), fields: ["context"])
        :inside
      end

      assert_equal :inside, result
    end

    def test_without_temporarily_deletes_paths_for_delete_enabled_sections
      fields = stack_set_with_request_headers

      result = fields.without(:carry, %i[http request_headers authorization]) do
        assert_nil fields.snapshot(:carry).dig(:http, :request_headers, :authorization)
        assert_equal "application/json", fields.snapshot(:carry).dig(:http, :request_headers, :accept)
        :inside
      end

      assert_equal :inside, result
      assert_equal "secret", fields.snapshot(:carry).dig(:http, :request_headers, :authorization)
    end

    def test_without_yields_without_overlay_for_non_delete_sections
      fields = Julewire::Core::Fields::StackSet.new(context: { account: { id: "acct-1" } })

      result = fields.without(:context, %i[account id]) do
        assert_equal "acct-1", fields.snapshot(:context).dig(:account, :id)
        :inside
      end

      assert_equal :inside, result
      assert_equal "acct-1", fields.snapshot(:context).dig(:account, :id)
    end

    def test_with_defaults_to_unowned_overlay_input
      fields = Julewire::Core::Fields::StackSet.new
      key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY
      metadata = Julewire::Core::Serialization::Serializer.truncation_metadata(["context"])

      error = assert_raises(ArgumentError) do
        fields.with(:context, { key => metadata }) { :inside }
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
      assert_empty fields.snapshot(:context)
    end

    private

    def stack_set_with_request_headers
      Julewire::Core::Fields::StackSet.new(
        carry: {
          http: {
            request_headers: {
              authorization: "secret",
              accept: "application/json"
            }
          }
        }
      )
    end
  end
end
