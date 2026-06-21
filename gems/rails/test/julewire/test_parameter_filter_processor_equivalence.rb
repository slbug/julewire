# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestParameterFilterProcessorEquivalence < Minitest::Test
    cover Julewire::Rails::ParameterFilterProcessor

    FAST_PATH_CASES = [
      [
        %i[password token],
        {
          payload: { password: "secret", visible: "ok" },
          context: { token: "abc" },
          attributes: { user: { token: "nested" } }
        }
      ],
      [
        ["payload.password"],
        { payload: { password: "secret", visible: "ok" } }
      ],
      [
        ["payload.items.token"],
        { payload: { items: [{ token: "a", visible: "ok" }, { nested: { token: "b" } }, "plain"] } }
      ],
      [
        %i[source],
        { source: "secret-source", payload: { visible: "ok" } }
      ],
      [
        %i[token],
        { payload: { items: [{ token: "a", visible: "ok" }, { nested: { token: "b" } }] } }
      ],
      [
        %i[token],
        { payload: { "Access_Token" => "secret", visible: "ok" } }
      ],
      [
        %i[password],
        { payload: { visible: { nested: "ok" } } }
      ],
      [
        ["payload.password"],
        { payload: {} }
      ]
    ].freeze
    private_constant :FAST_PATH_CASES

    def test_fast_path_matches_rails_parameter_filter_for_record_matrix
      FAST_PATH_CASES.each do |filters, input|
        input = input.merge(timestamp: Time.utc(2026, 1, 1))
        expected_draft = draft_with(input)
        expected = rails_parameter_filter(filters).filter(expected_draft.to_h)
        actual_draft = draft_with(input)

        Julewire::Rails::ParameterFilterProcessor.new(filters).call(actual_draft)

        assert_equal expected, actual_draft.to_h, filters.inspect
      end
    end

    private

    def rails_parameter_filter(filters)
      ActiveSupport::ParameterFilter.new(ActiveSupport::ParameterFilter.precompile_filters(filters))
    end

    def draft_with(input)
      Julewire::Core::Records::Draft.build(input, context: {}, scope: nil)
    end
  end
end
