# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRack < Minitest::Test
    cover Julewire::Rack::Error
    def test_error_inherits_julewire_error
      assert_operator Julewire::Rack::Error, :<, Julewire::Error
    end
  end
end
