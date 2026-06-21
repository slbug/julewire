# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestCLILogFormats < Minitest::Test
    def test_core_log_decoder_reads_sections_from_bag_taxonomy
      payload = {
        "timestamp" => "2026-06-19T10:00:00Z",
        "severity" => "info",
        "kind" => "point",
        "event" => "tail.event"
      }
      Core::Fields::Bags.record_hash_sections.each do |section|
        payload[section.to_s] = { "value" => section.to_s }
      end

      decoded = Core::CLI::LogFormats.decode(payload, format: :core)

      Core::Fields::Bags.record_hash_sections.each do |section|
        assert_equal({ value: section.to_s }, decoded.fetch(section))
      end
    end
  end
end
