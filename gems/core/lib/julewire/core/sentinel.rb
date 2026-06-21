# frozen_string_literal: true

module Julewire
  module Core
    class Sentinel
      attr_reader :name

      def initialize(name)
        @name = Core.normalize_name(name, name: :sentinel)
        freeze
      end

      def inspect = "#<#{self.class} #{@name}>"

      def to_s = inspect
    end
  end
end
