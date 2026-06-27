# frozen_string_literal: true

require "test_helper"
require File.expand_path("../../../../support/quality/api_tags", __dir__)

module Julewire
  class TestQualityApiTags < Minitest::Test
    cover Julewire::Quality::ApiTags
    cover Julewire::Quality::RubySource

    def test_api_tags_accept_required_class_module_and_method_tags
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, <<~RUBY)
          # This ordinary source comment must not become an API tag.

          # @api public
          class Probe
            #  @api extension
            module Extension
            end

            # @api   integration_spi
            def call = true
          end

          # @api public
          class Julewire::Qualified
          end
        RUBY

        assert_nil Julewire::Quality::ApiTags.assert!(
          tag_values: %w[public extension integration_spi],
          requirements: {
            path => {
              "Probe" => "public",
              "Extension" => "extension",
              "call" => "integration_spi",
              "Qualified" => "public"
            }
          }
        )
      end
    end

    def test_api_tags_reject_unknown_and_unattached_tags
      in_temporary_repo do
        write_temporary_repo_file("gems/probe/lib/julewire/probe.rb", <<~RUBY)
          # @api unknown
          class Probe
          end

          # @api public
          VALUE = true

          # @api public
        RUBY

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ApiTags.assert!(tag_values: ["public"], requirements: {})
        end

        assert_includes error.message, "unknown unknown"
        assert_includes error.message, "not attached to class/module/def"
      end
    end

    def test_api_tags_reject_missing_required_tag
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, "class Probe\nend\n")

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ApiTags.assert!(tag_values: ["public"], requirements: { path => { "Probe" => "public" } })
        end

        assert_includes error.message, "#{path}:Probe:missing @api public"
      end
    end

    def test_api_tags_reject_required_target_that_is_absent_from_source
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, "class Probe\nend\n")

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ApiTags.assert!(
            tag_values: ["public"],
            requirements: { path => { "Absent" => "public" } }
          )
        end

        assert_includes error.message, "#{path}:Absent:missing @api public"
      end
    end

    def test_api_tags_do_not_allow_a_later_duplicate_tag_to_mask_an_invalid_one
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, <<~RUBY)
          # @api internal
          def call
          end

          # @api public
          def call
          end
        RUBY

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ApiTags.assert!(
            tag_values: %w[internal public],
            requirements: { path => { "call" => "public" } }
          )
        end

        assert_includes error.message, "#{path}:call:missing @api public"
      end
    end

    def test_api_tags_report_source_line_and_target_for_each_invalid_tag
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, <<~RUBY)
          # @api unknown
          class Probe
          end

          # @api public
          VALUE = true
        RUBY

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ApiTags.assert!(tag_values: ["public"], requirements: {})
        end

        assert_equal(
          [
            "invalid @api tags:",
            "#{path}:1:unknown unknown",
            "#{path}:5:not attached to class/module/def"
          ].join("\n"),
          error.message
        )
      end
    end

    def test_api_tags_report_invalid_ruby_before_evaluating_requirements
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, "def broken(\n")

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ApiTags.assert!(tag_values: ["public"], requirements: { path => {} })
        end

        assert_match(/could not parse #{Regexp.escape(path)}:\n1:/, error.message)
        assert_equal 3, error.message.scan(/^1:/).size
        assert_includes error.message, "expected a `)` to close the parameters"
      end
    end

    def test_dynamic_constant_name_without_an_error_collector_warns_and_returns_nil
      result = Prism.parse("receiver::VALUE\n")
      node = Julewire::Quality::RubySource.each_node(result.value).find do |source_node|
        source_node.is_a?(Prism::ConstantPathNode)
      end

      error = nil
      _stdout, stderr = capture_io do
        error = assert_raises(RuntimeError) do
          Julewire::Quality::RubySource.constant_name(node)
        end
      end

      assert_equal "warning: skipping dynamic constant path in 1", error.message
      assert_equal "warning: skipping dynamic constant path in 1\n", stderr
    end
  end
end
