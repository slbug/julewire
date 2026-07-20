# frozen_string_literal: true

require "test_helper"

module Julewire
  module Core
    class TestValidation < Minitest::Test
      cover Julewire::Core::Validation
      cover "Julewire::Core::Validation.validate_symbol_choice!"

      class TimeoutLike
        def finite? = true

        def >=(_other) = true
      end

      class BrokenNumericTimeout < Numeric
        def finite?
          raise "broken timeout"
        end
      end

      def test_validate_options_allows_known_keys_and_reports_unknown_keys
        assert_nil Validation.validate_options!({ known: false }, %i[known], name: :contract)

        error = assert_raises(ArgumentError) do
          Validation.validate_options!({ known: true, unknown: nil }, %i[known], name: :contract)
        end

        assert_equal "unknown contract options: unknown", error.message

        error = assert_raises(ArgumentError) do
          Validation.validate_options!({ one: true, two: false }, [], name: :contract)
        end

        assert_equal "unknown contract options: one, two", error.message
      end

      def test_validate_byte_limit_allows_nil_and_positive_integer_only
        assert_nil Validation.validate_byte_limit!(nil, name: :limit)
        assert_equal 1, Validation.validate_byte_limit!(1, name: :limit)

        error = assert_raises(ArgumentError) { Validation.validate_byte_limit!(0, name: :limit) }
        assert_equal "limit must be nil or a positive Integer", error.message

        error = assert_raises(ArgumentError) { Validation.validate_byte_limit!("1", name: :limit) }
        assert_equal "limit must be nil or a positive Integer", error.message
      end

      def test_validate_timeout_rejects_non_numeric_timeout_like_objects
        error = assert_raises(ArgumentError) do
          Validation.validate_timeout!(TimeoutLike.new, name: :timeout)
        end

        assert_equal "timeout must be nil or a non-negative finite Numeric", error.message
      end

      def test_validate_timeout_contains_numeric_predicate_errors
        error = assert_raises(ArgumentError) do
          Validation.validate_timeout!(BrokenNumericTimeout.new, name: :timeout)
        end

        assert_equal "timeout must be nil or a non-negative finite Numeric", error.message
      end

      def test_validate_timeout_allows_nil_and_non_negative_finite_numeric_values
        assert_nil Validation.validate_timeout!(nil, name: :timeout)
        assert_nil Validation.validate_timeout!(0, name: :timeout)
        assert_nil Validation.validate_timeout!(0.25, name: :timeout)
      end

      def test_validate_timeout_rejects_negative_and_non_finite_numeric_values
        [-0.1, Float::INFINITY, Float::NAN].each do |value|
          error = assert_raises(ArgumentError, value.inspect) do
            Validation.validate_timeout!(value, name: :timeout)
          end

          assert_equal "timeout must be nil or a non-negative finite Numeric", error.message
        end
      end

      def test_validate_integer_limit_allows_non_negative_integer_only
        assert_equal 0, Validation.validate_integer_limit!(0, name: :count)
        assert_equal 2, Validation.validate_integer_limit!(2, name: :count)

        error = assert_raises(ArgumentError) { Validation.validate_integer_limit!(-1, name: :count) }
        assert_equal "count must be a non-negative Integer", error.message

        error = assert_raises(ArgumentError) { Validation.validate_integer_limit!(nil, name: :count) }
        assert_equal "count must be a non-negative Integer", error.message
      end

      def test_validate_integer_limit_rejects_numeric_ducks_and_requires_positive_when_requested
        numeric_duck = Object.new
        def numeric_duck.positive? = true

        assert_equal 1, Validation.validate_integer_limit!(1, name: :count, positive: true)

        [0, -1, numeric_duck].each do |value|
          error = assert_raises(ArgumentError, value.inspect) do
            Validation.validate_integer_limit!(value, name: :count, positive: true)
          end

          assert_equal "count must be a positive Integer", error.message
        end
      end

      def test_validate_non_negative_integer_delegates_to_integer_limit_contract
        assert_equal 0, Validation.validate_non_negative_integer!(0, name: :count)

        error = assert_raises(ArgumentError) { Validation.validate_non_negative_integer!(-1, name: :count) }
        assert_equal "count must be a non-negative Integer", error.message
      end

      def test_validate_callable_rejects_nil_by_default_and_allows_nil_when_requested
        error = assert_raises(ArgumentError) do
          Validation.validate_callable!(nil, name: :callback)
        end

        assert_equal "callback must respond to #call", error.message
        assert_nil Validation.validate_callable!(nil, name: :callback, allow_nil: true)
      end

      def test_validate_callable_accepts_callable_and_rejects_non_nil_non_callable_even_when_nil_allowed
        callable = -> {}

        assert_nil Validation.validate_callable!(callable, name: :callback)

        error = assert_raises(ArgumentError) do
          Validation.validate_callable!(Object.new, name: :callback, allow_nil: true)
        end

        assert_equal "callback must respond to #call", error.message
      end

      def test_validate_symbol_choice_accepts_symbolizable_choices
        choice = Class.new(String).new("json")

        assert_equal :json, Validation.validate_symbol_choice!(choice, name: :format, choices: %i[json text])
      end

      def test_validate_symbol_choice_rejects_unknown_and_unsymbolizable_choices
        error = assert_raises(ArgumentError) do
          Validation.validate_symbol_choice!("xml", name: :format, choices: %i[json text])
        end

        assert_equal "format must be one of: json, text", error.message

        error = assert_raises(ArgumentError) do
          Validation.validate_symbol_choice!(Object.new, name: :format, choices: %i[json text])
        end

        assert_equal "format must be one of: json, text", error.message
      end
    end
  end
end
