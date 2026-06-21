# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      module Settings
        class << self
          def included(base)
            base.extend(ClassMethods)
          end
        end

        module ClassMethods
          def setting(name, default: nil, predicate: false, validate: nil, &block)
            settings_defaults[name] = block || proc { default }
            settings_validators[name] = validate if validate
            ivar = :"@#{name}"

            define_method(name) { instance_variable_get(ivar) }
            define_method(:"#{name}=") do |value|
              instance_variable_set(ivar, validate_setting(name, value))
            end

            define_method(:"#{name}?") { !!public_send(name) } if predicate
          end

          def byte_limit
            proc { |value, name| Core::Validation.validate_byte_limit!(value, name: name) }
          end

          def integer_limit(positive: false)
            proc { |value, name| Core::Validation.validate_integer_limit!(value, name: name, positive: positive) }
          end

          def settings_defaults
            @settings_defaults ||= {}
          end

          def settings_validators
            @settings_validators ||= {}
          end
        end

        def initialize
          initialize_settings
        end

        def validate!
          validate_settings!
          self
        end

        private

        def initialize_settings
          self.class.settings_defaults.each do |name, default|
            public_send(:"#{name}=", setting_default(default))
          end
        end

        def setting_default(default)
          Core::Fields::FieldSet.deep_dup(instance_exec(&default))
        end

        def validate_settings!
          self.class.settings_defaults.each_key do |name|
            public_send(:"#{name}=", public_send(name))
          end
        end

        def validate_setting(name, value)
          validator = self.class.settings_validators[name]
          return value unless validator

          result = call_setting_validator(validator, name, value)
          result.nil? ? value : result
        end

        def call_setting_validator(validator, name, value)
          case validator
          when Symbol
            validator_method = method(validator)
            validator_method.arity == 1 ? validator_method.call(value) : validator_method.call(value, name)
          else
            validator.arity == 1 ? instance_exec(value, &validator) : instance_exec(value, name, &validator)
          end
        end
      end
    end
  end
end
