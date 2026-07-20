# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRactorPortLifecycle < Minitest::Test
    cover "Julewire::Ractor::PortLifecycle.close"
    cover "Julewire::Ractor::PortLifecycle.with_port"

    def test_with_port_closes_its_real_port_after_success
      observed = nil

      result = Julewire::Ractor::PortLifecycle.with_port do |port|
        observed = port
        :done
      end

      assert_equal :done, result
      assert_predicate observed, :closed?
    end

    def test_with_port_closes_its_real_port_after_failure
      observed = nil

      error = assert_raises(RuntimeError) do
        Julewire::Ractor::PortLifecycle.with_port do |port|
          observed = port
          raise "operation failed"
        end
      end

      assert_equal "operation failed", error.message
      assert_predicate observed, :closed?
    end

    def test_close_is_idempotent_and_accepts_nil
      port = ::Ractor::Port.new

      assert_nil Julewire::Ractor::PortLifecycle.close(port)
      assert_predicate port, :closed?
      assert_nil Julewire::Ractor::PortLifecycle.close(port)
      assert_nil Julewire::Ractor::PortLifecycle.close(nil)
    end

    def test_close_ignores_objects_without_a_real_close_protocol
      calls = []
      object = Object.new
      object.define_singleton_method(:method_missing) do |name, *_arguments, &_block|
        calls << name
      end
      object.define_singleton_method(:respond_to_missing?) { |_name, _include_private| false }

      assert_nil Julewire::Ractor::PortLifecycle.close(object)
      assert_empty calls
    end

    def test_close_accepts_a_close_protocol_without_a_closed_predicate
      calls = []
      port = Object.new
      port.define_singleton_method(:close) { calls << :close }

      assert_nil Julewire::Ractor::PortLifecycle.close(port)
      assert_equal [:close], calls
    end

    def test_close_swallows_close_failures
      port = Object.new
      port.define_singleton_method(:close) { raise "close failed" }

      assert_nil Julewire::Ractor::PortLifecycle.close(port)
    end
  end
end
