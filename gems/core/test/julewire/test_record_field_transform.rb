# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordFieldTransform < Minitest::Test
    cover Julewire::Core::Processing::RecordFieldTransform

    def test_transforms_canonical_record_containers_including_error
      transform = Core::Processing::RecordFieldTransform.new(track_paths: true, preserve_top_level_keys: %i[source])
      record = {
        source: "app",
        message: "top",
        payload: { secret: "payload-secret" },
        error: { message: "error-secret", class: "RuntimeError" }
      }

      result = transform.call(record) do |_item, key:, prefixed_path:, **|
        if key == :secret || prefixed_path == "error.message"
          "[FILTERED]"
        else
          Core::Serialization::BoundedTransform::CONTINUE
        end
      end

      assert_equal "app", result.fetch(:source)
      assert_equal "top", result.fetch(:message)
      assert_equal "[FILTERED]", result.dig(:payload, :secret)
      assert_equal "[FILTERED]", result.dig(:error, :message)
      assert_equal "RuntimeError", result.dig(:error, :class)
    end

    def test_preserves_unknown_hash_sections_but_transforms_known_scalars
      transform = Core::Processing::RecordFieldTransform.new
      record = {
        message: "secret",
        custom: { secret: "kept" }
      }

      result = transform.call(record) do
        "[FILTERED]"
      end

      assert_equal "[FILTERED]", result.fetch(:message)
      assert_equal({ secret: "kept" }, result.fetch(:custom))
    end

    def test_keeps_container_keys_when_values_are_not_hashes
      transform = Core::Processing::RecordFieldTransform.new
      record = {
        message: "secret",
        payload: "payload-secret",
        context: "context-secret"
      }

      result = transform.call(record) { "[FILTERED]" }

      assert_equal "[FILTERED]", result.fetch(:message)
      assert_equal "payload-secret", result.fetch(:payload)
      assert_equal "context-secret", result.fetch(:context)
    end

    def test_preserves_configured_top_level_scalars
      transform = Core::Processing::RecordFieldTransform.new(preserve_top_level_keys: %i[message source])
      record = {
        message: "keep",
        source: "app",
        severity: :info
      }

      result = transform.call(record) { "[FILTERED]" }

      assert_equal "keep", result.fetch(:message)
      assert_equal "app", result.fetch(:source)
      assert_equal "[FILTERED]", result.fetch(:severity)
    end

    def test_accepts_single_top_level_key_to_preserve
      transform = Core::Processing::RecordFieldTransform.new(preserve_top_level_keys: :message)

      result = transform.call(message: "keep", severity: :info) { "[FILTERED]" }

      assert_equal "keep", result.fetch(:message)
      assert_equal "[FILTERED]", result.fetch(:severity)
    end

    def test_forwards_path_metadata_and_original_record
      transform = Core::Processing::RecordFieldTransform.new(track_paths: true)
      record = {
        message: "top",
        context: { request: { id: "req-1" } }
      }

      calls = transform_calls(transform, record)

      assert_includes calls, ["top", :message, "message", "message", true, 1, :message]
      assert_includes calls, ["req-1", :id, "request.id", "context.request.id", true, 2, :context]
    end

    def test_path_tracking_can_be_disabled
      transform = Core::Processing::RecordFieldTransform.new(track_paths: false)
      record = {
        message: "top",
        context: { request_id: "req-1" }
      }

      calls = transform_calls(transform, record)

      assert_includes calls, ["top", :message, nil, nil, true, 1, :message]
      assert_includes calls, ["req-1", :request_id, nil, nil, true, 1, :context]
    end

    def test_path_tracking_is_disabled_by_default
      calls = []
      transform = Core::Processing::RecordFieldTransform.new

      transform.call(message: "top") do |item, key:, path:, prefixed_path:, **|
        calls << [item, key, path, prefixed_path]
        Core::Serialization::BoundedTransform::CONTINUE
      end

      assert_equal [["top", :message, nil, nil]], calls
    end

    def test_applies_bounds_to_containers_and_scalar_results
      transform = Core::Processing::RecordFieldTransform.new(
        max_array_items: 1,
        max_hash_keys: 1,
        max_string_bytes: 3
      )
      record = {
        message: "abcdef",
        payload: { long: "abcdef", other: "kept-out" },
        attributes: { list: %w[abcdef second] }
      }

      result = transform.call(record) { Core::Serialization::BoundedTransform::CONTINUE }

      assert_equal "abc...[Truncated]", result.fetch(:message)
      assert_equal "abc...[Truncated]", result.dig(:payload, :long)
      assert_nil result.dig(:payload, :other)
      assert result.dig(:payload, :_julewire_truncation, "truncated")
      assert_equal "abc...[Truncated]", result.dig(:attributes, :list, 0)
      assert result.dig(:attributes, :list, 1, :_julewire_truncation, "truncated")
    end

    def test_applies_depth_bound
      transform = Core::Processing::RecordFieldTransform.new(max_depth: 2)
      record = {
        context: { request: { id: "req-1" } }
      }

      result = transform.call(record) { Core::Serialization::BoundedTransform::CONTINUE }

      assert_equal "[MaxDepth]", result.dig(:context, :request, :id)
      assert result.dig(:context, :_julewire_truncation, "truncated")
    end

    def test_accepts_hash_subclasses_for_container_fields
      payload = Class.new(Hash).new
      payload[:secret] = "payload-secret"
      transform = Core::Processing::RecordFieldTransform.new

      result = transform.call(payload: payload) do |item, key:, **|
        key == :secret ? "[FILTERED]" : item
      end

      assert_equal "[FILTERED]", result.dig(:payload, :secret)
    end

    def test_invalid_bounds_are_rejected_when_transform_runs
      transform = Core::Processing::RecordFieldTransform.new(max_depth: 0)

      assert_raises(ArgumentError) do
        transform.call(message: "secret") { Core::Serialization::BoundedTransform::CONTINUE }
      end
    end

    def test_exposes_canonical_container_and_scalar_key_sets
      assert_includes Core::Processing::RecordFieldTransform.container_keys, :error
      assert_includes Core::Processing::RecordFieldTransform.container_keys, :payload
      assert_includes Core::Processing::RecordFieldTransform.scalar_keys, :source
      assert Core::Processing::RecordFieldTransform.container_key?(:error)
      assert Core::Processing::RecordFieldTransform.scalar_key?(:message)
    end

    def test_field_placement_tracks_record_shape
      expected_containers = (Core::Records::Record::HASH_SECTIONS + %i[error]).sort
      expected_scalars = (Core::Records::Record::REQUIRED_KEYS - expected_containers).sort

      assert_equal expected_containers, Core::Processing::RecordFieldTransform.container_keys.sort
      assert_equal expected_scalars, Core::Processing::RecordFieldTransform.scalar_keys.sort
    end

    private

    def transform_calls(transform, record)
      [].tap do |calls|
        transform.call(record) do |item, key:, path:, prefixed_path:, original:, depth:, top_level_key:|
          calls << [item, key, path, prefixed_path, original.equal?(record), depth, top_level_key]
          Core::Serialization::BoundedTransform::CONTINUE
        end
      end
    end
  end
end
