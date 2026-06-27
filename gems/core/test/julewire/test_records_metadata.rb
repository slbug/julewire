# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordsMetadata < Minitest::Test
    cover Julewire::Core::Records::Metadata
    class KeyOnlyRecord
      def key?(_key) = true
    end

    class BrokenRecordish
      def key?(_key) = raise("broken key lookup")

      def [](_key) = raise("broken value lookup")
    end

    class LabelHash < Hash
    end

    def test_metadata_rejects_non_record_like_inputs
      assert_equal({}, metadata.call(Object.new))
      assert_equal({}, metadata.call(KeyOnlyRecord.new))
      assert_equal({}, metadata.call(BrokenRecordish.new))
    end

    def test_metadata_extracts_public_record_metadata
      record = {
        event: "request",
        labels: { service: "api" },
        logger: "Rails",
        severity: :error,
        source: "controller",
        payload: { ignored: true }
      }

      assert_equal(
        {
          event: "request",
          labels: { service: "api" },
          logger: "Rails",
          severity: :error,
          source: "controller"
        },
        metadata.call(record)
      )
    end

    def test_metadata_compacts_missing_scalars_but_keeps_empty_labels
      assert_equal({ labels: {} }, metadata.call({}))
    end

    def test_metadata_deep_copies_hash_labels
      labels = { service: "api", nested: { region: "eu" } }
      copied = metadata.call(labels: labels).fetch(:labels)

      labels.fetch(:nested)[:region] = "us"

      assert_equal "eu", copied.dig(:nested, :region)

      copied.fetch(:nested)[:region] = "apac"

      assert_equal "us", labels.dig(:nested, :region)
    end

    def test_metadata_accepts_hash_subclass_labels
      labels = LabelHash[service: "api"]

      assert_equal({ labels: { service: "api" } }, metadata.call(labels: labels))
    end

    def test_metadata_normalizes_non_hash_labels_to_empty_hash
      assert_equal({ labels: {} }, metadata.call(labels: "api"))
    end

    private

    def metadata
      Julewire::Core::Records::Metadata
    end
  end
end
