# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestParameterFilterProcessor < Minitest::Test
    cover Julewire::Rails::ParameterFilterProcessor
    cover Julewire::Rails::ParameterFilters
    cover "Julewire::Rails::ParameterFilters.build"
    def test_processor_mutates_draft_for_rails_parameter_filter
      processor = Julewire::Rails::ParameterFilterProcessor.new(%i[password token])
      input = {
        payload: { password: "secret", visible: "ok" },
        context: { token: "abc" }
      }
      draft = draft_with(input)

      assert_same draft, processor.call(draft)
      filtered = draft.to_record

      assert_instance_of Julewire::Core::Records::Draft, draft
      assert_equal "[FILTERED]", filtered.dig(:payload, :password)
      assert_equal "ok", filtered.dig(:payload, :visible)
      assert_equal "[FILTERED]", filtered.dig(:context, :token)
      assert_equal "secret", input.dig(:payload, :password)
    end

    def test_processor_can_run_inside_julewire_pipeline
      captured = []
      configure_output(captured: captured)

      Julewire.configure do |config|
        config.processors.prepend :rails_parameter_filter, %i[password]
      end

      Julewire.emit(payload: { password: "secret", visible: "ok" })

      record = captured.fetch(0)

      assert_equal "[FILTERED]", record.dig(:payload, :password)
      assert_equal "ok", record.dig(:payload, :visible)
    end

    def test_processor_defaults_to_rails_filter_parameters
      draft = draft_with(payload: { access_token: "secret", visible: "ok" })

      with_fake_rails_application_filter_parameters([:access_token]) do
        Julewire::Rails::ParameterFilterProcessor.new.call(draft)
        filtered = draft.to_record

        assert_equal "[FILTERED]", filtered.dig(:payload, :access_token)
        assert_equal "ok", filtered.dig(:payload, :visible)
      end
    end

    def test_shared_filter_lookup_reads_config_filter_parameters
      config = Data.define(:filter_parameters).new(:access_token)
      app = Data.define(:config).new(config)

      with_overridden_singleton_method(::Rails, :application, proc { app }) do
        assert_equal [:access_token], Julewire::Rails::ParameterFilters.configured
      end
    end

    def test_shared_filter_lookup_returns_empty_filters_when_rails_lookup_fails
      with_overridden_singleton_method(::Rails, :application, proc { raise "boom" }) do
        assert_equal [], Julewire::Rails::ParameterFilters.configured
      end
    end

    def test_processor_accepts_precompiled_rails_filters
      filters = ActiveSupport::ParameterFilter.precompile_filters(%i[password])
      processor = Julewire::Rails::ParameterFilterProcessor.new(filters)
      draft = draft_with(payload: { password: "secret" })

      processor.call(draft)

      assert_equal "[FILTERED]", draft.to_record.dig(:payload, :password)
    end

    def test_processor_preserves_lineage_ancestors
      ancestors = [{ type: "request", id: "request-1" }]
      processor = Julewire::Rails::ParameterFilterProcessor.new(%i[access_token])
      draft = draft_with(
        {
          execution: {
            type: "job",
            id: "job-1",
            ancestors: ancestors,
            access_token: "secret-token"
          }
        }
      )

      processor.call(draft)
      record = draft.to_record

      assert_equal ancestors, record.lineage.ancestors
      assert_equal "[FILTERED]", record.dig(:execution, :access_token)
    end

    def test_processor_preserves_top_level_and_deep_filter_semantics
      top_level_processor = Julewire::Rails::ParameterFilterProcessor.new(%i[source])
      top_level_draft = draft_with(source: "secret-source", payload: { visible: "ok" })
      deep_processor = Julewire::Rails::ParameterFilterProcessor.new(["payload.password"])
      deep_draft = draft_with(payload: { password: "secret", visible: "ok" })

      top_level_processor.call(top_level_draft)
      deep_processor.call(deep_draft)

      assert_equal "[FILTERED]", top_level_draft.to_record.fetch(:source)
      assert_equal "ok", top_level_draft.to_record.dig(:payload, :visible)
      assert_equal "[FILTERED]", deep_draft.to_record.dig(:payload, :password)
      assert_equal "ok", deep_draft.to_record.dig(:payload, :visible)
    end

    def test_processor_preserves_deep_filter_semantics_inside_arrays
      processor = Julewire::Rails::ParameterFilterProcessor.new(["payload.items.token"])
      draft = draft_with(
        payload: {
          items: [
            { token: "a", visible: "ok" },
            { nested: { token: "b" } },
            "plain"
          ],
          password_token: "c"
        }
      )

      processor.call(draft)
      record = draft.to_record

      assert_equal "[FILTERED]", record.dig(:payload, :items, 0, :token)
      assert_equal "ok", record.dig(:payload, :items, 0, :visible)
      assert_equal "b", record.dig(:payload, :items, 1, :nested, :token)
      assert_equal "c", record.dig(:payload, :password_token)
      assert_equal "plain", record.dig(:payload, :items, 2)
    end

    def test_processor_ignores_missing_deep_field_roots_and_continues
      processor = Julewire::Rails::ParameterFilterProcessor.new(["missing.password", "payload.password"])
      draft = draft_with(payload: { password: "secret", visible: "ok" })

      processor.call(draft)
      record = draft.to_record

      assert_equal "[FILTERED]", record.dig(:payload, :password)
      assert_equal "ok", record.dig(:payload, :visible)
    end

    def test_processor_preserves_regex_filter_semantics
      processor = Julewire::Rails::ParameterFilterProcessor.new([/\Asource\z/, /password/])
      draft = draft_with(source: "secret-source", payload: { password: "secret", visible: "ok" })

      processor.call(draft)
      record = draft.to_record

      assert_equal "[FILTERED]", record.fetch(:source)
      assert_equal "[FILTERED]", record.dig(:payload, :password)
      assert_equal "ok", record.dig(:payload, :visible)
    end

    def test_processor_preserves_regex_container_shape_while_filtering_nested_keys
      processor = Julewire::Rails::ParameterFilterProcessor.new([/\Apayload\z/, /password/])
      draft = draft_with(payload: { password: "secret", visible: "ok" })

      processor.call(draft)
      record = draft.to_record

      assert_equal "[FILTERED]", record.dig(:payload, :password)
      assert_equal "ok", record.dig(:payload, :visible)
    end

    def test_processor_preserves_nil_record_containers_for_regex_section_filters
      processor = Julewire::Rails::ParameterFilterProcessor.new([/\Aerror\z/])
      draft = draft_with(error: nil, payload: { visible: "ok" })

      processor.call(draft)

      assert_nil draft.to_record.fetch(:error)
    end

    def test_processor_preserves_invalid_record_container_values_for_record_validation
      processor = Julewire::Rails::ParameterFilterProcessor.new([/\Aerror\z/])
      draft = draft_with(payload: { visible: "ok" })
      draft[:error] = "boom"

      processor.call(draft)

      error = assert_raises(TypeError) { draft.to_record }
      assert_equal "record error must be nil or a Hash", error.message
    end

    def test_processor_preserves_non_container_regex_filter_semantics_for_clean_payload
      processor = Julewire::Rails::ParameterFilterProcessor.new([/password/])
      draft = draft_with(payload: { visible: { nested: "ok" } })

      processor.call(draft)

      assert_equal({ visible: { nested: "ok" } }, draft.to_record.fetch(:payload))
    end

    def test_processor_keeps_mixed_container_regex_filters_on_fast_path
      processor = Julewire::Rails::ParameterFilterProcessor.new([/does_not_match/, /\Apayload\z/])
      draft = draft_with(payload: {})
      payload = draft.fetch(:payload)

      processor.call(draft)

      assert_same payload, draft.fetch(:payload)
      assert_equal({}, draft.to_record.fetch(:payload))
    end

    def test_processor_preserves_record_container_shape_for_section_filters
      top_level_processor = Julewire::Rails::ParameterFilterProcessor.new(%i[payload password])
      top_level_draft = draft_with(payload: { password: "secret" })
      empty_processor = Julewire::Rails::ParameterFilterProcessor.new(%i[payload])
      empty_draft = draft_with(payload: {})

      top_level_processor.call(top_level_draft)
      empty_processor.call(empty_draft)

      assert_equal "[FILTERED]", top_level_draft.to_record.dig(:payload, :password)
      assert_equal({}, empty_draft.to_record.fetch(:payload))
    end

    def test_processor_masks_simple_filter_parent_key
      processor = Julewire::Rails::ParameterFilterProcessor.new(%i[password])
      draft = draft_with(payload: { password: { nested: "secret" }, visible: "ok" })

      processor.call(draft)
      record = draft.to_record

      assert_equal "[FILTERED]", record.dig(:payload, :password)
      assert_equal "ok", record.dig(:payload, :visible)
    end

    def test_processor_masks_matched_array_container_like_rails
      processor = Julewire::Rails::ParameterFilterProcessor.new(%i[password])
      draft = draft_with(payload: { password: [{ token: "a" }], visible: "ok" })

      processor.call(draft)
      record = draft.to_record

      assert_equal "[FILTERED]", record.dig(:payload, :password)
      assert_equal "ok", record.dig(:payload, :visible)
    end

    def test_processor_filters_simple_keys_inside_arrays
      processor = Julewire::Rails::ParameterFilterProcessor.new(%i[token])
      draft = draft_with(payload: { items: [{ token: "a", visible: "ok" }, { nested: { token: "b" } }] })

      processor.call(draft)
      record = draft.to_record

      assert_equal "[FILTERED]", record.dig(:payload, :items, 0, :token)
      assert_equal "ok", record.dig(:payload, :items, 0, :visible)
      assert_equal "[FILTERED]", record.dig(:payload, :items, 1, :nested, :token)
    end

    def test_processor_filters_simple_keys_case_insensitively
      processor = Julewire::Rails::ParameterFilterProcessor.new(%i[token])
      draft = draft_with(payload: { "Access_Token" => "secret", visible: "ok" })

      processor.call(draft)
      record = draft.to_record

      assert_equal "[FILTERED]", record.dig(:payload, :Access_Token)
      assert_equal "ok", record.dig(:payload, :visible)
    end

    def test_processor_accepts_single_scalar_filter
      processor = Julewire::Rails::ParameterFilterProcessor.new(:password)
      draft = draft_with(payload: { password: "secret", visible: "ok" })

      processor.call(draft)
      record = draft.to_record

      assert_equal "[FILTERED]", record.dig(:payload, :password)
      assert_equal "ok", record.dig(:payload, :visible)
    end

    def test_processor_uses_active_support_filter_for_single_top_level_scalar_filter
      processor = Julewire::Rails::ParameterFilterProcessor.new(:source)
      draft = draft_with(source: "secret-source")

      processor.call(draft)

      assert_equal "[FILTERED]", draft.to_record.fetch(:source)
    end

    def test_processor_keeps_single_scalar_filter_on_fast_path
      processor = Julewire::Rails::ParameterFilterProcessor.new(:password)
      draft = draft_with(payload: { visible: { nested: "ok" } })
      payload = draft.fetch(:payload)

      processor.call(draft)

      assert_same payload, draft.fetch(:payload)
    end

    def test_processor_uses_active_support_filter_for_array_subclass_scalar_filters
      filters = Class.new(Array) do
        def filter(_value)
          raise "array subclass must not be treated as a custom filter"
        end
      end.new([:source])
      processor = Julewire::Rails::ParameterFilterProcessor.new(filters)
      draft = draft_with(source: "secret-source")

      processor.call(draft)

      assert_equal "[FILTERED]", draft.to_record.fetch(:source)
    end

    def test_processor_keeps_array_subclass_filters_on_fast_path
      filters = Class.new(Array) do
        def filter(_value)
          raise "array subclass must not be treated as a custom filter"
        end
      end.new([:password])
      processor = Julewire::Rails::ParameterFilterProcessor.new(filters)
      draft = draft_with(payload: { visible: { nested: "ok" } })
      payload = draft.fetch(:payload)

      processor.call(draft)

      assert_same payload, draft.fetch(:payload)
    end

    def test_processor_preserves_clean_containers_for_simple_filters
      processor = Julewire::Rails::ParameterFilterProcessor.new(%i[password])
      draft = draft_with(payload: { visible: { nested: "ok" } })
      payload = draft.fetch(:payload)

      processor.call(draft)

      assert_same payload, draft.fetch(:payload)
      assert_equal({ visible: { nested: "ok" } }, draft.to_record.fetch(:payload))
    end

    def test_processor_does_not_materialize_missing_planned_field_keys
      processor = Julewire::Rails::ParameterFilterProcessor.new(["missing.password"])
      draft = draft_with(payload: { visible: "ok" })

      processor.call(draft)
      record = draft.to_record

      assert_false record.key?(:missing)
      assert_equal({ visible: "ok" }, record.fetch(:payload))
    end

    def test_processor_preserves_clean_empty_non_record_containers
      assert_preserves_clean_empty_source_container({})
    end

    def test_processor_masks_matched_empty_non_record_containers
      assert_masks_matched_empty_source_container({})
    end

    def test_processor_preserves_clean_empty_array_non_record_containers
      assert_preserves_clean_empty_source_container([])
    end

    def test_processor_masks_matched_empty_array_non_record_containers
      assert_masks_matched_empty_source_container([])
    end

    def test_processor_masks_matched_empty_container_subclasses
      assert_masks_matched_empty_source_container(Class.new(Hash).new)
      assert_masks_matched_empty_source_container(Class.new(Array).new)
    end

    def test_processor_preserves_clean_empty_container_subclasses
      assert_preserves_clean_empty_source_container(Class.new(Hash).new)
      assert_preserves_clean_empty_source_container(Class.new(Array).new)
    end

    def test_processor_preserves_empty_record_sections_for_regex_container_filters
      processor = Julewire::Rails::ParameterFilterProcessor.new([/\Apayload\z/])
      draft = draft_with(payload: {})
      payload = draft.fetch(:payload)

      processor.call(draft)

      assert_same payload, draft.fetch(:payload)
      assert_equal({}, draft.to_record.fetch(:payload))
    end

    def test_processor_preserves_deep_filter_semantics_for_empty_sections
      deep_processor = Julewire::Rails::ParameterFilterProcessor.new(["payload.password"])
      deep_draft = draft_with(payload: {})

      deep_processor.call(deep_draft)

      assert_equal({}, deep_draft.to_record.fetch(:payload))
    end

    def test_processor_keeps_proc_filters_on_whole_record_path
      filter, original_seen = password_proc_filter
      processor = Julewire::Rails::ParameterFilterProcessor.new([filter])
      draft = draft_with(payload: { password: "secret" })

      processor.call(draft)

      assert_equal "[PROC]", draft.to_record.dig(:payload, :password)
      assert_original_record_seen(original_seen.call)
    end

    def test_processor_keeps_mixed_proc_filters_on_whole_record_path
      filter, original_seen = password_proc_filter
      processor = Julewire::Rails::ParameterFilterProcessor.new([:token, filter])
      draft = draft_with(payload: { password: "secret", token: "abc" })

      processor.call(draft)
      record = draft.to_record

      assert_equal "[PROC]", record.dig(:payload, :password)
      assert_equal "[FILTERED]", record.dig(:payload, :token)
      assert_original_record_seen(original_seen.call)
    end

    def test_processor_accepts_filter_object
      filter = Class.new do
        def filter(value)
          value.merge(payload: value.fetch(:payload).merge(password: "[CUSTOM]"))
        end
      end.new
      processor = Julewire::Rails::ParameterFilterProcessor.new(filter)
      draft = draft_with(payload: { password: "secret" })

      processor.call(draft)

      assert_equal "[CUSTOM]", draft.to_record.dig(:payload, :password)
    end

    def test_processor_keeps_custom_filter_objects_on_whole_record_path
      filter = Class.new do
        attr_reader :filter_called, :filter_param_called

        def filter(value)
          @filter_called = true
          value.merge(payload: value.fetch(:payload).merge(password: "[CUSTOM]"))
        end

        def filter_param(_key, value)
          @filter_param_called = true
          value
        end
      end.new
      processor = Julewire::Rails::ParameterFilterProcessor.new(filter)
      draft = draft_with(payload: { password: "secret" })

      processor.call(draft)

      assert_equal "[CUSTOM]", draft.to_record.dig(:payload, :password)
      assert_true filter.filter_called
      assert_nil filter.filter_param_called
    end

    def test_processor_does_not_inspect_custom_filter_objects_for_fast_path_plans
      filter = Class.new do
        def filter(value) = value

        def to_s = raise "custom filters must not be planned"
      end.new

      draft = draft_with(payload: { visible: "ok" })

      assert_same draft, Julewire::Rails::ParameterFilterProcessor.new(filter).call(draft)
    end

    def test_processor_rejects_non_drafts
      processor = Julewire::Rails::ParameterFilterProcessor.new(%i[password])

      error = assert_raises(TypeError) { processor.call({ payload: { password: "secret" } }) }

      assert_equal "expected Julewire::RecordDraft", error.message
    end

    def test_processor_preserves_container_shape_for_precompiled_section_filter
      filters = ActiveSupport::ParameterFilter.precompile_filters(%i[payload])
      processor = Julewire::Rails::ParameterFilterProcessor.new(filters)
      draft = draft_with(payload: { visible: "ok" })

      processor.call(draft)

      assert_equal({ visible: "ok" }, draft.to_record.fetch(:payload))
    end

    def test_processor_preserves_hash_subclass_record_container_shape
      filters = ActiveSupport::ParameterFilter.precompile_filters(%i[payload])
      processor = Julewire::Rails::ParameterFilterProcessor.new(filters)
      payload = Class.new(Hash).new.merge!(password: "secret", visible: "ok")
      draft = draft_with(payload: {})
      draft[:payload] = payload

      processor.call(draft)

      assert_equal({ password: "secret", visible: "ok" }, draft.to_record.fetch(:payload))
    end

    def test_processor_filters_hash_subclass_record_container_after_regex_container_filter
      processor = Julewire::Rails::ParameterFilterProcessor.new([/\Apayload\z/, /password/])
      payload = Class.new(Hash).new.merge!(password: "secret", visible: "ok")
      draft = draft_with(payload: {})
      draft[:payload] = payload

      processor.call(draft)

      assert_equal "[FILTERED]", draft.to_record.dig(:payload, :password)
      assert_equal "ok", draft.to_record.dig(:payload, :visible)
    end

    def test_processor_is_noop_without_filters
      processor = Julewire::Rails::ParameterFilterProcessor.new([])
      draft = draft_with(payload: { password: "secret" })

      assert_same draft, processor.call(draft)
    end

    private

    def password_proc_filter
      original_seen = nil
      filter = proc do |key, value, original|
        original_seen = original if key == :password
        value.replace("[PROC]") if value.is_a?(String) && key == :password
      end

      [filter, -> { original_seen }]
    end

    def assert_original_record_seen(original)
      assert_instance_of Hash, original
      assert_true original.key?(:payload)
    end

    def assert_preserves_clean_empty_source_container(container)
      processor = Julewire::Rails::ParameterFilterProcessor.new([/\Apayload\z/])
      draft = draft_with(source: container)
      source = draft.fetch(:source)

      processor.call(draft)

      assert_same source, draft.fetch(:source)
      assert_equal container, draft.to_record.fetch(:source)
    end

    def assert_masks_matched_empty_source_container(container)
      processor = Julewire::Rails::ParameterFilterProcessor.new(%i[source])
      draft = draft_with(source: container)

      processor.call(draft)

      assert_equal "[FILTERED]", draft.to_record.fetch(:source)
    end

    def draft_with(input)
      Julewire::Core::Records::Draft.build(input, context: {}, scope: nil)
    end
  end
end
