# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestCaptureJsonBody < Minitest::Test
    cover Julewire::Rack::Capture::JsonBody

    def test_string_body_mode_keeps_raw_body
      fields = body_fields(:request, '{"ok":true}', mode: Julewire::Rack::Capture::Settings::STRING_BODY)

      assert_equal(
        { request_body_bytes: 11, request_body_truncated: false, request_body: '{"ok":true}' },
        fields
      )
    end

    def test_json_body_mode_parses_valid_body
      fields = body_fields(:response, '{"ok":true}', mode: Julewire::Rack::Capture::Settings::JSON_BODY)

      assert_equal(
        { response_body_bytes: 11, response_body_truncated: false, response_body_json: { "ok" => true } },
        fields
      )
    end

    def test_json_body_mode_reports_parse_error
      fields = body_fields(:request, "nope", mode: Julewire::Rack::Capture::Settings::JSON_BODY)

      assert_equal "JSON::ParserError", fields.fetch(:request_body_parse_error)
      refute_includes fields, :request_body
      refute_includes fields, :request_body_json
    end

    def test_json_body_mode_does_not_parse_truncated_body
      fields = Julewire::Rack::Capture::JsonBody.fields(
        :response,
        '{"ok"',
        bytes: 11,
        truncated: true,
        mode: Julewire::Rack::Capture::Settings::JSON_BODY
      )

      assert_equal({ response_body_bytes: 11, response_body_truncated: true }, fields)
    end

    private

    def body_fields(section, body, mode:)
      Julewire::Rack::Capture::JsonBody.fields(
        section,
        body,
        bytes: body.bytesize,
        truncated: false,
        mode: mode
      )
    end
  end
end
