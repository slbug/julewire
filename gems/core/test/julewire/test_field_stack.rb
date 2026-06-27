# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestFieldStack < Minitest::Test
    cover Julewire::Core::Fields::FieldStack
    cover Julewire::Core::Fields::Internal
    cover "Julewire::Core::Fields::Internal.normalize_path"
    cover "Julewire::Core::Fields::Internal::Deletion.deep_delete_path!"

    def test_snapshot_is_memoized_until_fields_change
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1" } })

      first = stack.snapshot
      second = stack.snapshot
      stack.add(request_id: "request-1")
      third = stack.snapshot

      assert_same first, second
      refute_same first, third
      assert_equal "request-1", third.fetch(:request_id)
    end

    def test_source_snapshot_is_memoized_until_fields_change
      source = SnapshotSource.new(account_id: "acct-1")
      stack = Julewire::Core::Fields::FieldStack.new(source: source)

      first = stack.snapshot
      second = stack.snapshot

      assert_same first, second
      assert_equal 1, source.calls
      assert_equal "acct-1", second.fetch(:account_id)
    end

    def test_empty_snapshot_is_frozen_and_memoized
      stack = Julewire::Core::Fields::FieldStack.new

      first = stack.snapshot
      second = stack.snapshot

      assert_same first, second
      assert_empty first
      assert_predicate first, :frozen?
    end

    def test_snapshot_is_deep_frozen
      stack = Julewire::Core::Fields::FieldStack.new({ account: { tags: ["first"] } })
      snapshot = stack.snapshot

      assert_predicate snapshot, :frozen?
      assert_predicate snapshot.fetch(:account), :frozen?
      assert_predicate snapshot.dig(:account, :tags), :frozen?
      assert_raises(FrozenError) { snapshot.fetch(:account).fetch(:tags) << "second" }
    end

    def test_overlay_push_and_pop_invalidate_snapshot
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1" } })
      outside = stack.snapshot
      inside = nil

      stack.with(account: { plan: "pro" }) do
        inside = stack.snapshot
      end

      after = stack.snapshot

      refute_same outside, inside
      refute_same inside, after
      assert_equal outside, after
      assert_equal "pro", inside.dig(:account, :plan)
      assert_nil after.dig(:account, :plan)
    end

    def test_overlay_with_copies_unowned_input
      stack = Julewire::Core::Fields::FieldStack.new
      overlay = { account: { id: "acct-1" } }

      stack.with(overlay) do
        overlay[:account][:id] = "changed"

        assert_equal "acct-1", stack.value_for(:account, default: {}).fetch(:id)
        assert_equal "acct-1", stack.snapshot.dig(:account, :id)
      end
    end

    def test_delete_overlay_push_and_pop_invalidate_snapshot
      stack = sensitive_header_stack
      outside = stack.snapshot
      inside = nil

      stack.without(%i[http request_headers authorization]) do
        inside = stack.snapshot
      end

      after = stack.snapshot

      refute_same outside, inside
      assert_equal outside, after
      assert_false inside.dig(:http, :request_headers).key?(:authorization)
      assert_equal "secret", after.dig(:http, :request_headers, :authorization)
    end

    def test_without_yields_for_stacks_without_delete_paths
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1" } })

      result = stack.without(%i[account id]) do
        assert_equal "acct-1", stack.snapshot.dig(:account, :id)
        :yielded
      end

      assert_equal :yielded, result
      assert_equal "acct-1", stack.snapshot.dig(:account, :id)
    end

    def test_overlay_snapshot_applies_changes_after_cached_parent_snapshot
      stack = sensitive_header_stack
      parent_snapshot = stack.snapshot
      inside = nil

      stack.with(
        http: {
          request_headers: { authorization: "new", traceparent: "trace-2" },
          response_headers: { content_type: "application/json" }
        }
      ) do
        stack.without(%i[http request_headers authorization]) do
          inside = stack.snapshot
        end
      end

      assert_equal "application/json", inside.dig(:http, :response_headers, :content_type)
      assert_false inside.dig(:http, :request_headers).key?(:authorization)
      assert_equal "trace-2", inside.dig(:http, :request_headers, :traceparent)
      assert_equal parent_snapshot, stack.snapshot
    end

    def test_nested_delete_overlays_accumulate_delete_paths
      stack = sensitive_header_stack

      stack.without(%i[http request_headers authorization]) do
        stack.without(%i[http request_headers traceparent]) do
          assert_nil stack.snapshot.dig(:http, :request_headers)
        end
      end
    end

    def test_unrelated_child_add_keeps_parent_delete_path
      stack = sensitive_header_stack

      stack.without(%i[http request_headers authorization]) do
        stack.with(worker: { id: "worker-1" }) do
          assert_equal "worker-1", stack.snapshot.dig(:worker, :id)
          assert_false stack.snapshot.dig(:http, :request_headers).key?(:authorization)
          assert_equal "trace-1", stack.snapshot.dig(:http, :request_headers, :traceparent)
        end
      end
    end

    def test_snapshot_cache_is_a_build_time_optimization_only
      stack = Julewire::Core::Fields::FieldStack.new({ body: "x" * 4_096 })
      snapshot = stack.snapshot

      frozen_record_data = Julewire::Core::Serialization::ValueCopy.call(
        { context: snapshot },
        freeze_values: true
      )

      refute_same snapshot, frozen_record_data.fetch(:context)
      assert_equal snapshot, frozen_record_data.fetch(:context)
    end

    def test_value_for_is_memoized_until_fields_change
      stack = Julewire::Core::Fields::FieldStack.new({ account: { tags: ["first"] } })

      first = stack.value_for(:account, default: {})
      second = stack.value_for(:account, default: {})
      stack.add(account: { plan: "pro" })
      third = stack.value_for(:account, default: {})

      assert_same first, second
      refute_same first, third
      assert_equal({ plan: "pro" }, third)
      assert_predicate third, :frozen?
    end

    def test_value_for_cache_respects_delete_paths
      stack = sensitive_header_stack
      stack.delete(%i[http request_headers authorization])

      first = stack.value_for(:http, default: {})
      second = stack.value_for(:http, default: {})

      assert_same first, second
      assert_false first[:request_headers].key?(:authorization)
      assert_equal "trace-1", first.dig(:request_headers, :traceparent)
    end

    def test_value_for_delete_paths_only_rebuilds_matching_top_level_key
      stack = Julewire::Core::Fields::FieldStack.new(
        {
          http: { request_headers: { authorization: "secret", traceparent: "trace-1" } },
          worker: { id: "worker-1" }
        },
        delete_paths: true
      )

      stack.delete(%i[http request_headers authorization])

      assert_equal({ id: "worker-1" }, stack.value_for(:worker, default: {}))
      assert_false stack.value_for(:http, default: {}).fetch(:request_headers).key?(:authorization)
    end

    def test_active_delete_paths_are_memoized
      parent = ActiveDeleteParent.new([[Core::Fields::Internal.normalize_path(%i[http request_headers authorization])]])
      layer = field_stack_layer.fields(parent, { worker: { id: "worker-1" } })

      first = layer.active_delete_paths
      second = layer.active_delete_paths

      assert_same first, second
      assert_equal 1, parent.calls
    end

    def test_add_ignores_non_hash_or_empty_unowned_fields
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1" } })
      snapshot = stack.snapshot

      assert_nil stack.add("ignored")
      assert_nil stack.add({})
      assert_nil stack.add({}, owned: true)

      assert_same snapshot, stack.snapshot
      assert_equal({ account: { id: "acct-1" } }, stack.snapshot)
    end

    def test_with_ignores_non_hash_or_empty_unowned_fields
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1" } })
      snapshot = stack.snapshot

      assert_equal :yielded, stack.with("ignored") {
        assert_same(snapshot, stack.snapshot)
        :yielded
      }
      assert_equal :yielded, stack.with({}) {
        assert_same(snapshot, stack.snapshot)
        :yielded
      }
      assert_equal :yielded, stack.with({}, owned: true) {
        assert_same(snapshot, stack.snapshot)
        :yielded
      }

      assert_same snapshot, stack.snapshot
    end

    def test_owned_fields_require_symbol_keyed_hashes
      stack = Julewire::Core::Fields::FieldStack.new

      non_hash = assert_raises(TypeError) { stack.add("ignored", owned: true) }
      string_key = assert_raises(TypeError) { stack.with({ nested: { "id" => 1 } }, owned: true) { :entered } }

      assert_equal "owned data must be a Hash", non_hash.message
      assert_equal "record must not use string keys", string_key.message
      assert_empty stack.snapshot
    end

    def test_with_symbolizes_unowned_fields_and_keywords
      stack = Julewire::Core::Fields::FieldStack.new

      stack.with({ "account" => { "id" => "acct-1" } }, request_id: "request-1") do
        assert_equal "acct-1", stack.snapshot.dig(:account, :id)
        assert_equal "request-1", stack.snapshot.fetch(:request_id)
      end

      assert_empty stack.snapshot
    end

    def test_with_unowned_keywords_work_without_hash_fields
      stack = Julewire::Core::Fields::FieldStack.new

      stack.with(nil, request_id: "request-1") do
        assert_equal({ request_id: "request-1" }, stack.snapshot)
      end

      stack.with("ignored", request_id: "request-2") do
        assert_equal({ request_id: "request-2" }, stack.snapshot)
      end
    end

    def test_with_owned_fields_preserve_owned_nested_values
      stack = Julewire::Core::Fields::FieldStack.new
      nested = { id: "acct-1" }

      stack.with({ account: nested }, owned: true) do
        assert_equal nested, stack.value_for(:account, default: {})
        assert_equal({ account: { id: "acct-1" } }, stack.snapshot)
      end

      assert_empty stack.snapshot
    end

    def test_value_for_owned_fields_preserves_symbol_truncation_metadata
      stack = Julewire::Core::Fields::FieldStack.new
      metadata = symbol_truncation_metadata

      stack.add({ payload: { _julewire_truncation: metadata } }, owned: true)

      value = stack.value_for(:payload, default: {})

      assert_symbol_truncation_metadata value.fetch(:_julewire_truncation), fields: ["ids"],
                                                                            max_hash_keys: 10
      assert_predicate value, :frozen?
    end

    def test_with_unowned_fields_reject_reserved_truncation_metadata
      stack = Julewire::Core::Fields::FieldStack.new

      error = assert_raises(ArgumentError) do
        stack.with(
          Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY.to_sym => {
            truncated: true,
            truncated_fields: ["field"],
            limits: { max_string_bytes: 10 }
          }
        ) { :unused }
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_with_owned_fields_merge_keywords_at_top_level
      stack = Julewire::Core::Fields::FieldStack.new
      nested = { id: "acct-1" }

      stack.with({ account: nested }, request_id: "request-1", owned: true) do
        assert_equal nested, stack.value_for(:account, default: {})
        assert_equal "request-1", stack.value_for(:request_id, default: nil)
        assert_equal({ account: { id: "acct-1" }, request_id: "request-1" }, stack.snapshot)
      end
    end

    def test_with_owned_fields_accept_hash_subclasses
      stack = Julewire::Core::Fields::FieldStack.new
      fields = Class.new(Hash).new.merge!(account: { id: "acct-1" })

      stack.with(fields, request_id: "request-1", owned: true) do
        assert_equal "acct-1", stack.snapshot.dig(:account, :id)
        assert_equal "request-1", stack.snapshot.fetch(:request_id)
      end
    end

    def test_with_owned_keywords_work_without_explicit_fields
      stack = Julewire::Core::Fields::FieldStack.new

      stack.with(nil, request_id: "request-1", owned: true) do
        assert_equal({ request_id: "request-1" }, stack.snapshot)
      end
    end

    def test_with_owned_keywords_rejects_non_hash_explicit_fields
      stack = Julewire::Core::Fields::FieldStack.new

      error = assert_raises(TypeError) { stack.with("invalid", request_id: "request-2", owned: true) { flunk } }

      assert_equal "owned data must be a Hash", error.message
      assert_empty stack.snapshot
    end

    def test_delete_and_without_require_paths
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1" } }, delete_paths: true)
      snapshot = stack.snapshot

      assert_nil stack.delete([])
      assert_same snapshot, stack.snapshot
      assert_raises_message(ArgumentError, "field path is required") { stack.without([]) { :unreachable } }
    end

    def test_delete_path_noops_for_empty_normalized_path
      target = { account: { id: "acct-1" } }

      result = Julewire::Core::Fields::Internal::Deletion.delete_path!(target, [])

      assert_same target, result
      assert_equal({ account: { id: "acct-1" } }, target)
    end

    def test_delete_path_noops_for_nil_path
      target = { account: { id: "acct-1" } }

      result = Julewire::Core::Fields::Internal::Deletion.delete_path!(target, nil)

      assert_same target, result
      assert_equal({ account: { id: "acct-1" } }, target)
    end

    def test_internal_normalize_path_flattens_and_symbolizes_segments
      assert_equal %i[account id leaf], Julewire::Core::Fields::Internal.normalize_path(["account", %w[id leaf]])
      assert_equal [], Julewire::Core::Fields::Internal.normalize_path(nil)
    end

    def test_deep_delete_path_ignores_non_hash_targets_and_children
      assert_nil Julewire::Core::Fields::Internal::Deletion.__send__(:deep_delete_path!, "not a hash", %i[account id])

      empty_like = Object.new
      def empty_like.empty? = true

      nested = { account: empty_like }
      Julewire::Core::Fields::Internal::Deletion.__send__(:deep_delete_path!, nested, %i[account id])

      assert_same empty_like, nested.fetch(:account)
    end

    def test_delete_path_normalizes_nested_path_arrays
      target = { account: { id: "acct-1", name: "Acme" } }

      result = Julewire::Core::Fields::Internal::Deletion.delete_path!(target, [%i[account id]])

      assert_nil result
      assert_equal({ account: { name: "Acme" } }, target)
    end

    def test_delete_path_supports_hash_subclasses_and_removes_empty_child
      hash_class = Class.new(Hash)
      target = hash_class.new.merge!(
        account: hash_class.new.merge!(id: "acct-1")
      )

      Julewire::Core::Fields::Internal::Deletion.delete_path!(target, %i[account id])

      assert_empty target
    end

    def test_delete_paths_are_disabled_by_default_and_preserved_by_branch
      stack = Julewire::Core::Fields::FieldStack.new(
        { http: { request_headers: { authorization: "secret" } } }
      )
      branch = stack.branch

      stack.delete(%i[http request_headers authorization])

      branch.without(%i[http request_headers authorization]) do
        assert_equal "secret", branch.snapshot.dig(:http, :request_headers, :authorization)
      end

      assert_equal "secret", stack.snapshot.dig(:http, :request_headers, :authorization)
      assert_equal "secret", branch.snapshot.dig(:http, :request_headers, :authorization)
    end

    def test_branch_preserves_enabled_delete_paths
      branch = sensitive_header_stack.branch

      branch.without(%i[http request_headers authorization]) do
        assert_false branch.snapshot.dig(:http, :request_headers).key?(:authorization)
        assert_equal "trace-1", branch.snapshot.dig(:http, :request_headers, :traceparent)
      end
    end

    def test_delete_paths_are_ordered_with_later_adds
      stack = sensitive_header_stack

      stack.delete(%i[http request_headers authorization])
      stack.add(http: { request_headers: { authorization: "new" } })

      assert_equal "new", stack.snapshot.dig(:http, :request_headers, :authorization)
      assert_equal "new", stack.value_for(:http, default: {}).dig(:request_headers, :authorization)
      assert_nil stack.snapshot.dig(:http, :request_headers, :traceparent)
    end

    def test_later_multi_field_add_clears_only_overlapping_parent_delete_paths
      stack = Julewire::Core::Fields::FieldStack.new(
        {
          http: { request_headers: { authorization: "secret", traceparent: "trace-1" } },
          trace: { id: "trace-1" }
        },
        delete_paths: true
      )

      stack.delete(%i[http request_headers authorization])
      stack.delete(%i[trace id])
      stack.add(http: { request_headers: { authorization: "new" } }, worker: { id: "worker-1" })

      assert_equal "new", stack.snapshot.dig(:http, :request_headers, :authorization)
      assert_equal "worker-1", stack.snapshot.dig(:worker, :id)
      refute_includes stack.snapshot, :trace
    end

    def test_clear_delete_paths_removes_path_when_any_later_add_overlaps
      paths = [%i[http request_headers authorization], %i[trace id]]

      Julewire::Core::Fields::Internal::Deletion.clear_delete_paths!(
        paths,
        {
          http: { request_headers: { authorization: "new" } },
          worker: { id: "worker-1" }
        }
      )

      assert_equal [%i[trace id]], paths
    end

    def test_parent_delete_path_is_cleared_by_later_child_add
      stack = sensitive_header_stack

      stack.delete([:http])
      stack.add(http: { request_headers: { traceparent: "new" } })

      assert_equal({ request_headers: { traceparent: "new" } }, stack.snapshot.fetch(:http))
    end

    def test_temporary_field_overlay_does_not_clear_parent_delete_paths
      stack = sensitive_header_stack

      stack.without(%i[http request_headers authorization]) do
        stack.with(http: { request_headers: { authorization: "new", traceparent: "trace-2" } }) do
          assert_false stack.snapshot.dig(:http, :request_headers).key?(:authorization)
          assert_equal "trace-2", stack.snapshot.dig(:http, :request_headers, :traceparent)
        end
      end
    end

    def test_later_child_add_does_not_mutate_shared_parent_delete_paths
      stack = sensitive_header_stack

      stack.delete([:http])
      branch = stack.branch
      stack.add(http: { request_headers: { traceparent: "new" } })

      assert_equal({ request_headers: { traceparent: "new" } }, stack.snapshot.fetch(:http))
      refute_includes branch.snapshot, :http
    end

    def test_branch_snapshot_uses_cached_parent_snapshot_as_boundary
      stack = Julewire::Core::Fields::FieldStack.new({ parent: { keep: true } })

      assert_equal({ keep: true }, stack.snapshot.fetch(:parent))
      stack.instance_variable_get(:@source).fields.fetch(:parent)[:poison] = true
      branch = stack.branch
      branch.add(child: true)

      assert_equal({ keep: true }, branch.snapshot.fetch(:parent))
      assert_true branch.snapshot.fetch(:child)
    end

    def test_parent_delete_path_is_preserved_by_unrelated_later_add
      stack = sensitive_header_stack

      stack.delete(%i[http request_headers authorization])
      stack.add(worker: { id: "worker-1" })

      assert_equal "worker-1", stack.snapshot.dig(:worker, :id)
      assert_false stack.snapshot.dig(:http, :request_headers).key?(:authorization)
      assert_equal "trace-1", stack.snapshot.dig(:http, :request_headers, :traceparent)
    end

    def test_unrelated_delete_paths_do_not_force_snapshot_lookup
      stack = sensitive_header_stack
      stack.delete(%i[http request_headers authorization])
      stack.add(worker: { id: "worker-1" })
      layer = stack.instance_variable_get(:@source)

      refute_predicate layer, :snapshot_cached?
      assert_equal({ id: "worker-1" }, stack.value_for(:worker, default: {}))
      refute_predicate layer, :snapshot_cached?
    end

    def test_delete_path_overlap_matches_parent_child_prefixes
      deletion = Julewire::Core::Fields::Internal::Deletion

      assert_true deletion.send(:path_overlap?, [:http], %i[http request_headers])
      assert_true deletion.send(:path_overlap?, %i[http request_headers], [:http])
      assert_false deletion.send(:path_overlap?, %i[http request_headers], %i[worker request_headers])
    end

    def test_delete_field_paths_ignore_non_hash_fields
      assert_equal [], deletion_field_paths("ignored")
      assert_equal [], deletion_field_paths(nil)
    end

    def test_delete_field_paths_normalize_nested_hash_subclasses
      nested = Class.new(Hash).new.merge!("authorization" => "secret")
      headers = Class.new(Hash).new.merge!("request_headers" => nested)
      fields = Class.new(Hash).new.merge!("http" => headers, "trace" => "trace-1")

      assert_equal(
        [%i[http request_headers authorization], [:trace]],
        deletion_field_paths(fields)
      )
    end

    def test_branch_inside_overlay_keeps_overlay_after_parent_pop
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1", plan: "free" } })
      branch = nil

      stack.with(account: { plan: "pro" }) do
        branch = stack.branch
      end

      assert_equal({ id: "acct-1", plan: "free" }, stack.snapshot.fetch(:account))
      assert_equal({ plan: "pro" }, branch.snapshot.fetch(:account))
    end

    def test_branch_inside_delete_overlay_keeps_delete_after_parent_pop
      stack = sensitive_header_stack
      branch = nil

      stack.without(%i[http request_headers authorization]) do
        branch = stack.branch
      end

      assert_equal "secret", stack.snapshot.dig(:http, :request_headers, :authorization)
      assert_false branch.snapshot.dig(:http, :request_headers).key?(:authorization)
      assert_equal "trace-1", branch.snapshot.dig(:http, :request_headers, :traceparent)
    end

    def test_snapshot_rejects_corrupted_layer_cycles
      cycle_start = field_stack_layer.__send__(:fields, nil, { account: { id: "acct-1" } })
      cycle_end = field_stack_layer.__send__(:fields, cycle_start, { request_id: "request-1" })
      cycle_start.instance_variable_set(:@parent, cycle_end)
      layer = field_stack_layer.__send__(:fields, cycle_start, { trace_id: "trace-1" })
      stack = Julewire::Core::Fields::FieldStack.new
      stack.instance_variable_set(:@source, layer)

      error = assert_raises(Julewire::Core::Error) do
        safe_thread_value(safe_thread { stack.snapshot }, timeout: 0.1)
      end

      assert_equal "field stack layer cycle", error.message
    end

    def sensitive_header_stack
      Julewire::Core::Fields::FieldStack.new(
        { http: { request_headers: { authorization: "secret", traceparent: "trace-1" } } },
        delete_paths: true
      )
    end

    def deletion_field_paths(fields)
      Julewire::Core::Fields::Internal::Deletion.send(:field_paths, fields)
    end

    def field_stack_layer
      Julewire::Core::Fields::FieldStack.const_get(:Layer, false)
    end

    def symbol_truncation_metadata
      {
        truncated: true,
        truncated_fields: ["ids"],
        limits: {
          max_array_items: nil,
          max_depth: 20,
          max_hash_keys: 10,
          max_string_bytes: nil
        }
      }
    end

    class SnapshotSource
      attr_reader :calls

      def initialize(fields)
        @fields = fields
        @calls = 0
      end

      def snapshot
        @calls += 1
        @fields.dup.freeze
      end
    end

    class ActiveDeleteParent
      attr_reader :calls

      def initialize(paths)
        @calls = 0
        @paths = paths
      end

      def active_delete_paths
        @calls += 1
        @paths
      end
    end
  end
end
