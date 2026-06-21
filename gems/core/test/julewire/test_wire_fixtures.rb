# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestWireFixtures < Minitest::Test
    def test_propagation_fixture_matches_wire_shape
      assert_equal wire_fixture("propagation"), serialized_propagation_fixture_envelope
    end

    def test_carrier_fixture_matches_wire_shape
      carrier = {}

      Julewire::Core::Propagation::Carrier.inject(carrier, envelope: propagation_fixture_envelope)

      assert_equal wire_fixture("carrier"), carrier
    end

    private

    def serialized_propagation_fixture_envelope
      JSON.parse(JSON.generate(Julewire::Core::Serialization::Serializer.call(propagation_fixture_envelope)))
    end

    def propagation_fixture_envelope
      envelope = nil
      Julewire.with_execution(type: :request, id: "request-1", emit_summary: false) do
        Julewire.context.add(request_id: "req-1")
        Julewire.carry.add(
          http: {
            request_headers: {
              traceparent: "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
            }
          }
        )
        envelope = Julewire::Core::Propagation.capture
      end
      envelope
    end

    def wire_fixture(name)
      JSON.parse(File.read(File.expand_path("../fixtures/wire/#{name}.json", __dir__)))
    end
  end
end
