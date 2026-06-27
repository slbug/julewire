# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRequestContextNeutralFields < Minitest::Test
    cover "Julewire::Rails::RequestContext#neutral_fields"

    def test_neutral_fields_are_derived_from_the_real_request
      request = ::ActionDispatch::Request.new(
        ::Rack::MockRequest.env_for("/orders?token=secret", method: "POST")
      )
      context = Julewire::Rails::RequestContext.new(
        configuration: Julewire::Rails::Configuration.new,
        request: request,
        event_reporter: nil
      )

      fields = context.neutral_fields

      assert_equal "POST", fields.fetch(:"http.request.method")
      assert_equal "/orders", fields.fetch(:"url.path")
    end
  end
end
