# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestFieldStack < Minitest::Test
    cover Julewire::Core::Fields::FieldStack
    cover Julewire::Core::Serialization::ValueCopy

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
      refute inside.dig(:http, :request_headers).key?(:authorization)
      assert_equal "secret", after.dig(:http, :request_headers, :authorization)
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

    def test_owned_top_level_string_keys_are_readable_by_symbol
      nested = { "id" => "acct-1" }
      stack = Julewire::Core::Fields::FieldStack.new

      stack.add("account" => nested, owned: true)

      assert_equal nested, stack.value_for(:account, default: {})
      assert_equal({ account: { id: "acct-1" } }, stack.snapshot)
    end

    def test_value_for_cache_respects_delete_paths
      stack = sensitive_header_stack
      stack.delete(%i[http request_headers authorization])

      first = stack.value_for(:http, default: {})
      second = stack.value_for(:http, default: {})

      assert_same first, second
      refute first[:request_headers].key?(:authorization)
      assert_equal "trace-1", first.dig(:request_headers, :traceparent)
    end

    def test_add_ignores_non_hash_or_empty_fields
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1" } })
      snapshot = stack.snapshot

      assert_nil stack.add("ignored")
      assert_nil stack.add("ignored", owned: true)
      assert_nil stack.add({})
      assert_nil stack.add({}, owned: true)

      assert_same snapshot, stack.snapshot
      assert_equal({ account: { id: "acct-1" } }, stack.snapshot)
    end

    def test_with_ignores_non_hash_or_empty_fields
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1" } })
      snapshot = stack.snapshot

      assert_equal :yielded, stack.with("ignored") { :yielded }
      assert_equal :yielded, stack.with("ignored", owned: true) { :yielded }
      assert_equal :yielded, stack.with({}) { :yielded }
      assert_equal :yielded, stack.with({}, owned: true) { :yielded }

      assert_same snapshot, stack.snapshot
    end

    def test_delete_and_without_require_paths
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1" } }, delete_paths: true)
      snapshot = stack.snapshot

      assert_nil stack.delete([])
      assert_same snapshot, stack.snapshot
      assert_raises_message(ArgumentError, "field path is required") { stack.without([]) { :unreachable } }
    end

    def test_delete_paths_are_disabled_by_default_and_preserved_by_fork
      stack = Julewire::Core::Fields::FieldStack.new(
        { http: { request_headers: { authorization: "secret" } } }
      )
      fork = stack.fork

      stack.delete(%i[http request_headers authorization])

      fork.without(%i[http request_headers authorization]) do
        assert_equal "secret", fork.snapshot.dig(:http, :request_headers, :authorization)
      end

      assert_equal "secret", stack.snapshot.dig(:http, :request_headers, :authorization)
      assert_equal "secret", fork.snapshot.dig(:http, :request_headers, :authorization)
    end

    def test_delete_paths_are_ordered_with_later_adds
      stack = sensitive_header_stack

      stack.delete(%i[http request_headers authorization])
      stack.add(http: { request_headers: { authorization: "new" } })

      assert_equal "new", stack.snapshot.dig(:http, :request_headers, :authorization)
      assert_equal "new", stack.value_for(:http, default: {}).dig(:request_headers, :authorization)
      assert_nil stack.snapshot.dig(:http, :request_headers, :traceparent)
    end

    def test_fork_inside_overlay_keeps_overlay_after_parent_pop
      stack = Julewire::Core::Fields::FieldStack.new({ account: { id: "acct-1", plan: "free" } })
      fork = nil

      stack.with(account: { plan: "pro" }) do
        fork = stack.fork
      end

      assert_equal({ id: "acct-1", plan: "free" }, stack.snapshot.fetch(:account))
      assert_equal({ plan: "pro" }, fork.snapshot.fetch(:account))
    end

    def test_fork_inside_delete_overlay_keeps_delete_after_parent_pop
      stack = sensitive_header_stack
      fork = nil

      stack.without(%i[http request_headers authorization]) do
        fork = stack.fork
      end

      assert_equal "secret", stack.snapshot.dig(:http, :request_headers, :authorization)
      refute fork.snapshot.dig(:http, :request_headers).key?(:authorization)
      assert_equal "trace-1", fork.snapshot.dig(:http, :request_headers, :traceparent)
    end

    def sensitive_header_stack
      Julewire::Core::Fields::FieldStack.new(
        { http: { request_headers: { authorization: "secret", traceparent: "trace-1" } } },
        delete_paths: true
      )
    end
  end
end
