# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      # @api internal
      # Immutable layers keep snapshots stable while each stack tracks only the
      # current head and snapshot cache.
      class FieldStack
        EMPTY_HASH = {}.freeze
        private_constant :EMPTY_HASH

        class Layer
          attr_reader :fields, :parent

          class << self
            def fields(parent, fields, clear_parent_deletes: true)
              clear_parent_fields = fields if clear_parent_deletes
              new(
                parent,
                fields,
                delete_paths: nil,
                clear_parent_fields:
              )
            end

            def delete_paths(parent, paths)
              new(parent, nil, delete_paths: paths, clear_parent_fields: nil)
            end

            private :new
          end

          def initialize(parent, fields, delete_paths:, clear_parent_fields:)
            @parent = parent
            @fields = fields
            @delete_paths = delete_paths
            @clear_parent_fields = clear_parent_fields
          end

          def snapshot
            @snapshot ||= build_snapshot
          end

          def value_for(key)
            return @value_cache.fetch(key) if @value_cache&.key?(key)

            value = if delete_paths_for_key?(key)
                      FieldSet.value_for(snapshot, key, default: MISSING)
                    else
                      field_value = FieldSet.value_for(@fields, key, default: MISSING)
                      field_value.equal?(MISSING) ? parent_value_for(key) : frozen_field_value(field_value)
                    end
            (@value_cache ||= {})[key] = value
          end

          def active_delete_paths
            return @active_delete_paths if instance_variable_defined?(:@active_delete_paths)

            @active_delete_paths = build_active_delete_paths
          end

          def snapshot_cached?
            !@snapshot.nil?
          end

          def merge_into(snapshot)
            Internal.merge_owned!(snapshot, FieldSet.deep_dup_owned(@fields))
          end

          private

          def build_snapshot
            sources, base = source_layers_and_base
            snapshot = base ? FieldSet.deep_dup_owned(base.snapshot) : {}
            sources.reverse_each { it.merge_into(snapshot) }
            paths = active_delete_paths
            Internal.apply_delete_paths!(snapshot, paths) if paths
            Internal.frozen_owned_copy(snapshot)
          end

          def frozen_field_value(value)
            Internal.frozen_owned_copy(value)
          end

          def source_layers_and_base(source = self, seen_sources = [], sources = [])
            return [sources, source] if source.nil? || source.snapshot_cached?

            raise Error, "field stack layer cycle" if seen_sources.include?(source)

            seen_sources << source
            sources << source
            source_layers_and_base(source.parent, seen_sources, sources)
          end

          def parent_value_for(key)
            return MISSING unless @parent

            @parent.value_for(key)
          end

          def delete_paths_for_key?(key)
            active_delete_paths&.any? { it.first == key }
          end

          def build_active_delete_paths
            paths = @parent&.active_delete_paths
            paths = clear_active_delete_paths(paths) if paths
            paths = append_delete_paths(paths) if @delete_paths
            paths
          end

          def clear_active_delete_paths(paths)
            paths = paths.dup
            Internal.clear_delete_paths!(paths, @clear_parent_fields)
            paths
          end

          def append_delete_paths(paths)
            paths ? paths + @delete_paths : @delete_paths
          end
        end
        private_constant :Layer

        def initialize(fields = nil, delete_paths: false, source: nil)
          @source = source
          @delete_paths_enabled = delete_paths
          add(fields)
        end

        def snapshot
          return @snapshot if @snapshot

          @snapshot = @source ? @source.snapshot : EMPTY_HASH
        end

        def branch
          self.class.new(delete_paths: @delete_paths_enabled, source: @source)
        end

        def value_for(key, default:)
          key = Internal.normalize_key(key)
          value = source_value_for(key)
          return default if value.equal?(MISSING)

          value
        end

        def add(fields = nil, owned: false, **keyword_fields)
          fields = field_input(fields, keyword_fields, owned: owned)
          return if fields.empty?

          @source = Layer.fields(@source, fields)
          invalidate_snapshot!
        end

        def delete(path)
          return if path.empty?
          return unless @delete_paths_enabled

          @source = Layer.delete_paths(@source, [path])
          invalidate_snapshot!
        end

        def with(fields = nil, owned: false, **keyword_fields, &)
          fields = field_input(fields, keyword_fields, owned: owned)
          return yield if fields.empty?

          with_layer(fields, &)
        end

        def without(path, &)
          raise ArgumentError, "field path is required" if path.empty?

          return yield unless @delete_paths_enabled

          with_delete_layer([path], &)
        end

        private

        def field_input(fields, keyword_fields, owned:)
          if owned
            fields = keyword_fields if fields.nil?
            Serialization::DeepFreeze.validate_symbol_hash(fields)

            return fields.merge(keyword_fields)
          end

          FieldSet.coerce(fields, keyword_fields)
        end

        def with_layer(fields)
          previous_source = @source
          @source = Layer.fields(previous_source, fields, clear_parent_deletes: false)
          invalidate_snapshot!
          begin
            yield
          ensure
            @source = previous_source
            invalidate_snapshot!
          end
        end

        def with_delete_layer(delete_paths)
          previous_source = @source
          @source = Layer.delete_paths(previous_source, delete_paths)
          invalidate_snapshot!
          begin
            yield
          ensure
            @source = previous_source
            invalidate_snapshot!
          end
        end

        def source_value_for(key)
          return MISSING unless @source

          @source.value_for(key)
        end

        def invalidate_snapshot!
          @snapshot = nil
        end
      end
    end
  end
end
