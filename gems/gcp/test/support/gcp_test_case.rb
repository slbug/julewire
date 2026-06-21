# frozen_string_literal: true

module Julewire
  class GcpTestCase < Minitest::Test
    private

    def normalized_record(input = {})
      Core::Records::Draft.build(input, context: {}, scope: nil).to_record
    end

    def formatted_record(record = normalized_record, formatter: GCP::Formatter.new)
      JSON.parse(Core::Serialization::JsonEncoder.new.call(formatter.call(record)))
    end

    def trace_carry
      {
        http: {
          request_headers: {
            "traceparent" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
          }
        }
      }
    end

    def request_summary_neutral
      Julewire::Core::Fields::AttributeKeys.fields(
        "http.request.method": "GET",
        "url.full": "http://example.com/hello",
        "url.path": "/hello",
        "http.response.status_code": 200,
        "user_agent.original": "curl",
        "client.address": "127.0.0.1",
        "http.response.body.size": 456
      )
    end

    def request_summary_attributes
      {
        rails: {
          filtered_path: "/hello"
        }
      }
    end

    def error_shape(error_class, message, backtrace, cause: nil)
      {
        class: error_class,
        message: message,
        backtrace: backtrace
      }.tap do |error|
        error[:cause] = cause if cause
      end
    end

    def gcp_fixture(name)
      JSON.parse(File.read(File.expand_path("../fixtures/gcp/#{name}.json", __dir__)))
    end
  end
end
