# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordPublicProjection < Minitest::Test
    cover Julewire::Core::Records::PublicProjection
    cover "Julewire::Core::Serialization::Serializer#hash_like?"

    def test_record_public_projection_is_enumerable
      record = Core::Records::Draft.build({ message: "hello" }, context: {}, scope: nil).to_record
      keys = Core::Records::PublicProjection.new(record).map { |key, _value| key }

      assert_includes keys, :message
    end

    def test_record_public_projection_each_returns_enumerator
      record = Core::Records::Draft.build({ event: "record.output" }, context: {}, scope: nil).to_record
      projection = Core::Records::PublicProjection.new(record)

      assert_equal projection.to_h, projection.each.to_h
    end

    def test_record_public_projection_requires_a_record
      error = assert_raises(TypeError) do
        Core::Records::PublicProjection.new(event: "record.output")
      end

      assert_equal "expected Julewire::Record", error.message
    end

    def test_projects_public_execution_fields
      execution = { type: "job", id: "job-1", depth: 2, root: { type: "request", id: "request-1" }, custom: "kept" }

      assert_equal(
        { type: "job", id: "job-1", custom: "kept" },
        Core::Records::PublicProjection.public_execution(execution)
      )
    end

    def test_public_execution_reuses_hash_without_internal_fields
      execution = { type: "job", id: "job-1", custom: "kept" }

      assert_same execution, Core::Records::PublicProjection.public_execution(execution)
    end

    def test_to_h_projects_public_execution_fields
      record = Core::Records::Record.from_owned_hash(
        normalized_record(
          execution: {
            type: "job",
            id: "job-1",
            depth: 2,
            root: { type: "request", id: "request-1" },
            parent: { type: "request", id: "request-1" },
            custom: "kept"
          }
        )
      )

      output = Core::Records::PublicProjection.new(record).to_h

      assert_equal({ type: "job", id: "job-1", custom: "kept" }, output.fetch(:execution))
    end

    def test_strips_neutral_section_and_keeps_integration_namespaces
      record = Core::Records::Draft.build(
        {
          neutral: Core::Fields::AttributeKeys.fields("http.request.method": "GET"),
          attributes: {
            "my_app.some_key": 123,
            web: { controller: "HomeController" }
          }
        },
        context: {},
        scope: nil
      ).to_record

      output = Core::Records::PublicProjection.new(record).to_h

      assert_false output.key?(:neutral)
      assert_equal({ "my_app.some_key": 123, web: { controller: "HomeController" } }, output.fetch(:attributes))
    end

    def test_keeps_internal_execution_names_inside_other_hash_sections
      record = Core::Records::Draft.build(
        {
          payload: {
            root: "payload-root",
            depth: 2
          }
        },
        context: {},
        scope: nil
      ).to_record

      output = Core::Records::PublicProjection.new(record).to_h

      assert_equal({ root: "payload-root", depth: 2 }, output.fetch(:payload))
    end

    def test_serializer_treats_record_public_projection_as_hash_like_projection
      record = Core::Records::Draft.build(
        {
          event: "record.output",
          execution: {
            type: "job",
            id: "job-1",
            depth: 2,
            root: { type: "request", id: "request-1" },
            custom: "kept"
          },
          neutral: Core::Fields::AttributeKeys.fields("http.request.method": "GET")
        },
        context: {},
        scope: nil
      ).to_record

      serialized = Core::Serialization::Serializer.call(Core::Records::PublicProjection.new(record))

      assert_equal "record.output", serialized.fetch("event")
      assert_equal({ "type" => "job", "id" => "job-1", "custom" => "kept" }, serialized.fetch("execution"))
      refute_includes serialized, "neutral"
      refute_includes serialized.fetch("execution"), "root"
    end

    def test_serializer_treats_record_public_projection_subclasses_as_hash_like_projection
      output_class = Class.new(Core::Records::PublicProjection)
      record = Core::Records::Draft.build({ event: "record.output" }, context: {}, scope: nil).to_record

      serialized = Core::Serialization::Serializer.call(output_class.new(record))

      assert_equal "record.output", serialized.fetch("event")
    end
  end
end
