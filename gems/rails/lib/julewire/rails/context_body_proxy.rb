# frozen_string_literal: true

module Julewire
  module Rails
    class ContextBodyProxy
      def initialize(body, handle:, on_close:)
        @body = body
        @handle = handle
        @on_close = on_close
        @closed = false
      end

      def each(&block)
        return enum_for(:each) unless block_given?

        @handle.with_context do
          @body.each { block.yield(it) }
        end
      end

      def close
        return if @closed

        @closed = true
        begin
          @handle.with_context { @body.close if @body.respond_to?(:close) }
        ensure
          @on_close.call
        end
      end

      def closed? = @closed

      def respond_to_missing?(method_name, include_private = false)
        (method_name != :to_str && @body.respond_to?(method_name, include_private)) || super
      end

      def method_missing(method_name, ...)
        case method_name
        when :to_str
          super
        when :to_ary
          begin
            @handle.with_context { @body.public_send(method_name, ...) }
          ensure
            close
          end
        else
          @handle.with_context { @body.public_send(method_name, ...) }
        end
      end
    end
  end
end
