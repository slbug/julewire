# frozen_string_literal: true

module Julewire
  module Core
    class CLI
      module LogFormats
        module RecordDecoder
          class << self
            def kind(value)
              case value.to_s
              when "point" then :point
              when "summary" then :summary
              else value.to_sym
              end
            end

            def section(value)
              return {} unless value.is_a?(Hash)

              Fields::FieldSet.deep_symbolize_keys(value)
            end

            def sections(source, sections: Fields::Bags.record_hash_sections)
              sections.to_h do |name|
                value = block_given? ? yield(name, source) : source[name.to_s]

                [name, section(value)]
              end
            end

            def error(value)
              section(value) unless value.nil?
            end
          end
        end
      end
    end
  end
end
