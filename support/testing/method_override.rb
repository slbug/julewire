# frozen_string_literal: true

module Julewire
  module TestSupport
    module MethodOverride
      def with_overridden_singleton_method(receiver, method_name, replacement)
        singleton_class = receiver.singleton_class
        method_defined_here = singleton_class.public_method_defined?(method_name, false) ||
                              singleton_class.protected_method_defined?(method_name, false) ||
                              singleton_class.private_method_defined?(method_name, false)
        original = singleton_class.instance_method(method_name) if method_defined_here
        visibility = singleton_method_visibility(singleton_class, method_name) if method_defined_here
        verbose = $VERBOSE
        $VERBOSE = nil
        singleton_class.define_method(method_name, replacement)
        yield
      ensure
        $VERBOSE = nil
        restore_singleton_method(singleton_class, method_name, original, visibility)
        $VERBOSE = verbose
      end

      private

      def restore_singleton_method(singleton_class, method_name, original, visibility)
        if original
          singleton_class.define_method(method_name, original)
          singleton_class.__send__(visibility, method_name)
        elsif singleton_class&.public_method_defined?(method_name, false) ||
              singleton_class&.protected_method_defined?(method_name, false) ||
              singleton_class&.private_method_defined?(method_name, false)
          singleton_class.remove_method(method_name)
        end
      end

      def singleton_method_visibility(singleton_class, method_name)
        return :private if singleton_class.private_method_defined?(method_name, false)
        return :protected if singleton_class.protected_method_defined?(method_name, false)

        :public
      end
    end
  end
end
