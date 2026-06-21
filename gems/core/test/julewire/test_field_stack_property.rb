# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestFieldStackProperty < Minitest::Test
    cover Julewire::Core::Fields::FieldStack

    SEED = 42_013
    KEYS = %i[account http job request].freeze
    NESTED_KEYS = %i[id plan token status].freeze

    def test_random_layer_sequences_match_naive_replay
      random = Random.new(SEED)
      stack = Julewire::Core::Fields::FieldStack.new(delete_paths: true)
      model = {}

      120.times do |index|
        with_property_context(index) do
          stack, model = apply_random_operation(stack, model, random)

          assert_stack_matches_model(stack, model, random)
        end
      end
    end

    private

    def apply_random_operation(stack, model, random)
      case random.rand(7)
      when 0, 1
        apply_add(stack, model, random)
      when 2
        apply_owned_add(stack, model, random)
      when 3
        apply_delete(stack, model, random)
      when 4
        assert_temporary_overlay(stack, model, random)
        [stack, model]
      when 5
        assert_temporary_delete(stack, model, random)
        [stack, model]
      else
        assert_fork_matches_model(stack, model, random)
      end
    end

    def apply_add(stack, model, random)
      fields = random_fields(random)
      stack.add(fields)
      [stack, model_merge(model, fields)]
    end

    def apply_owned_add(stack, model, random)
      fields = random_owned_fields(random)
      stack.add(fields, owned: true)
      [stack, model_merge(model, fields)]
    end

    def apply_delete(stack, model, random)
      path = random_path(random)
      stack.delete(path)
      [stack, model_delete(model, path)]
    end

    def assert_fork_matches_model(stack, model, random)
      fork = stack.fork
      fork_model = model_deep_dup(model)
      fork_fields = random_fields(random)
      fork.add(fork_fields)

      assert_stack_matches_model(fork, model_merge(fork_model, fork_fields), random)
      [stack, model]
    end

    def assert_temporary_overlay(stack, model, random)
      fields = random_fields(random)

      assert_temporary_scope(stack, model, random) do
        stack.with(fields) do
          assert_temporary_scoped_model(stack, model_merge(model_deep_dup(model), fields), random)
        end
      end
    end

    def assert_temporary_delete(stack, model, random)
      path = random_path(random)

      assert_temporary_scope(stack, model, random) do
        stack.without(path) do
          assert_temporary_scoped_model(stack, model_delete(model_deep_dup(model), path), random)
        end
      end
    end

    def assert_temporary_scope(stack, outside_model, random)
      yield

      assert_stack_matches_model(stack, outside_model, random)
    end

    def assert_temporary_scoped_model(stack, inside_model, random)
      assert_stack_matches_model(stack, inside_model, random)
      fork = stack.fork

      assert_stack_matches_model(fork, inside_model, random)
    end

    def assert_stack_matches_model(stack, model, random)
      assert_equal model, stack.snapshot

      key = KEYS.sample(random: random)
      expected = model.fetch(key, :missing)

      assert_equal expected, stack.value_for(key, default: :missing)
      assert_equal expected, stack.value_for(key.to_s, default: :missing)
    end

    def with_property_context(index)
      yield
    rescue Minitest::Assertion => e
      flunk("FieldStack property seed=#{SEED} step=#{index}: #{e.message}")
    end

    def random_fields(random)
      { random_key(random) => random_value(random) }
    end

    def random_owned_fields(random)
      { random_key(random) => random_value(random, string_nested_keys: false) }
    end

    def random_key(random)
      key = KEYS.sample(random: random)
      random.rand(2).zero? ? key : key.to_s
    end

    def random_path(random)
      [KEYS.sample(random: random), NESTED_KEYS.sample(random: random)]
    end

    def random_value(random, string_nested_keys: true)
      case random.rand(4)
      when 0
        random.rand(1_000)
      when 1
        "value-#{random.rand(1_000)}"
      else
        nested_key = NESTED_KEYS.sample(random: random)
        nested_key = nested_key.to_s if string_nested_keys && random.rand(2).zero?
        { nested_key => "nested-#{random.rand(1_000)}" }
      end
    end

    def model_merge(model, fields)
      fields.each do |key, value|
        model[normalize_key(key)] = model_symbolize(value)
      end
      model
    end

    def model_delete(model, path)
      deep_delete(model, Array(path).flatten.map { normalize_key(it) })
      model
    end

    def deep_delete(target, path)
      return if path.empty? || !target.is_a?(Hash)

      key = path.first
      if path.one?
        target.delete(key)
        return
      end

      child = target[key]
      deep_delete(child, path.drop(1))
      target.delete(key) if child.is_a?(Hash) && child.empty?
    end

    def model_symbolize(value)
      case value
      when Hash
        value.to_h { |key, child| [normalize_key(key), model_symbolize(child)] }
      when Array
        value.map { model_symbolize(it) }
      else
        value
      end
    end

    def model_deep_dup(value)
      case value
      when Hash
        value.to_h { |key, child| [key, model_deep_dup(child)] }
      when Array
        value.map { model_deep_dup(it) }
      else
        value
      end
    end

    def normalize_key(key) = key.is_a?(String) ? key.to_sym : key
  end
end
