# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestContextBodyProxy < Minitest::Test
    cover Julewire::Rails::ContextBodyProxy

    def test_context_body_proxy_restores_context_for_iteration_and_delegation
      contexts = 0
      handle = counting_context_handle { contexts += 1 }
      proxy = Julewire::Rails::ContextBodyProxy.new(proxy_body, handle: handle, on_close: -> {})

      assert_equal ["chunk"], proxy.each.to_a
      assert_equal "custom value", proxy.custom("value")
      assert_raises(NoMethodError) { proxy.to_str }

      assert_equal 2, contexts
    end

    def test_context_body_proxy_reports_only_public_delegated_methods
      handle = counting_context_handle { nil }
      proxy = Julewire::Rails::ContextBodyProxy.new(introspection_proxy_body, handle:, on_close: -> {})

      assert_respond_to proxy, :custom
      refute_respond_to proxy, :missing
      refute_respond_to proxy, :to_str
      refute_respond_to proxy, :hidden
      assert_false proxy.respond_to?(:hidden, true)
    end

    def test_context_body_proxy_array_conversion_closes_once
      contexts = 0
      closes = 0
      handle = counting_context_handle { contexts += 1 }
      body = proxy_body
      proxy = Julewire::Rails::ContextBodyProxy.new(body, handle: handle, on_close: -> { closes += 1 })

      assert_false proxy.closed?
      assert_equal ["array"], proxy.to_ary
      assert_true proxy.closed?
      proxy.close

      assert_equal 2, contexts
      assert_equal 1, body.closed_count
      assert_equal 1, closes
    end

    def test_context_body_proxy_array_conversion_forwards_arguments
      handle = counting_context_handle { nil }
      proxy = Julewire::Rails::ContextBodyProxy.new(argument_proxy_body, handle:, on_close: -> {})

      assert_equal [:sentinel], proxy.to_ary(:sentinel)
    end

    def test_context_body_proxy_array_conversion_closes_on_failure
      closes = 0
      body = failing_array_proxy_body
      proxy = Julewire::Rails::ContextBodyProxy.new(
        body,
        handle: counting_context_handle { nil },
        on_close: -> { closes += 1 }
      )

      error = assert_raises(RuntimeError) { proxy.to_ary }

      assert_equal "array failed", error.message
      assert_true proxy.closed?
      assert_equal 1, body.closed_count
      assert_equal 1, closes
    end

    private

    def counting_context_handle
      Object.new.tap do |handle|
        handle.define_singleton_method(:with_context) do |&block|
          yield
          block.call
        end
      end
    end

    def proxy_body
      Class.new do
        attr_reader :closed_count

        def initialize = @closed_count = 0

        def each
          yield "chunk"
        end

        def close
          @closed_count += 1
        end

        def custom(value)
          "custom #{value}"
        end

        def to_ary
          ["array"]
        end
      end.new
    end

    def argument_proxy_body
      Class.new do
        def each; end

        def to_ary(...)
          Array(...)
        end
      end.new
    end

    def failing_array_proxy_body
      Class.new do
        attr_reader :closed_count

        def initialize = @closed_count = 0

        def each; end

        def close
          @closed_count += 1
        end

        def to_ary
          raise "array failed"
        end
      end.new
    end

    def introspection_proxy_body
      Class.new do
        def each; end

        def custom = "custom"

        def to_str = "string"

        private

        def hidden = "hidden"
      end.new
    end
  end
end
