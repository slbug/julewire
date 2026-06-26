# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      # @api internal
      # Immutable layers keep snapshots stable while each stack tracks only its
      # current head and versioned read caches.
      class FieldStack
        EMPTY_HASH = {}.freeze
        private_constant :EMPTY_HASH

        class Layer
          attr_reader :fields, :parent

          def initialize(parent, fields, delete_paths: nil, clear_parent_deletes: true, owned: false)
            @parent = parent
            @fields = fields
            @delete_paths = delete_paths
            @clear_parent_deletes = clear_parent_deletes
            @owned = owned
            @active_delete_paths_computed = false
            @active_delete_paths = nil
            @snapshot = nil
            @value_cache = nil
          end

          def owned? = @owned

          def snapshot
            @snapshot ||= build_snapshot
          end

          def value_for(key)
            return @value_cache[key] if @value_cache&.key?(key)

            value = if delete_paths_for_key?(key)
                      FieldSet.value_for(snapshot, key, default: MISSING)
                    else
                      field_value = FieldSet.value_for(@fields, key, default: MISSING)
                      field_value.equal?(MISSING) ? parent_value_for(key) : frozen_field_value(field_value)
                    end
            (@value_cache ||= {})[key] = value
          end

          def active_delete_paths
            return @active_delete_paths if @active_delete_paths_computed

            @active_delete_paths = build_active_delete_paths
            @active_delete_paths_computed = true
            @active_delete_paths
          end

          def snapshot_cached?
            !@snapshot.nil?
          end

          def delete_paths_for_snapshot
            @clear_parent_deletes ? @delete_paths : active_delete_paths
          end

          def merge_into(snapshot)
            if @owned
              Fields::Internal.merge_owned!(snapshot, FieldSet.deep_symbolize_owned_keys(@fields))
            else
              FieldSet.merge!(snapshot, @fields)
            end
          end

          private

          def build_snapshot
            return build_direct_snapshot unless @parent
            return build_parent_snapshot if @parent.snapshot_cached?

            snapshot = source_snapshot_base
            source_chain.reverse_each do |source|
              source.merge_into(snapshot)
              paths = source.delete_paths_for_snapshot
              Fields::Internal.apply_delete_paths!(snapshot, paths) if paths
            end
            Fields::Internal.frozen_owned_copy(snapshot)
          end

          def build_direct_snapshot
            snapshot = merge_into({})
            paths = delete_paths_for_snapshot
            Fields::Internal.apply_delete_paths!(snapshot, paths) if paths
            Fields::Internal.frozen_owned_copy(snapshot)
          end

          def build_parent_snapshot
            snapshot = FieldSet.deep_dup_owned(@parent.snapshot)
            merge_into(snapshot)
            paths = delete_paths_for_snapshot
            Fields::Internal.apply_delete_paths!(snapshot, paths) if paths
            Fields::Internal.frozen_owned_copy(snapshot)
          end

          def source_snapshot_base
            source = source_chain_base
            source ? FieldSet.deep_dup_owned(source.snapshot) : {}
          end

          def frozen_field_value(value)
            @owned ? Fields::Internal.frozen_owned_copy(value) : Fields::Internal.frozen_copy(value)
          end

          def source_chain
            sources = []
            source = self
            until source.nil? || source.snapshot_cached?
              sources << source
              source = source.parent
            end
            sources
          end

          def source_chain_base
            source = self
            source = source.parent until source.nil? || source.snapshot_cached?
            source
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
            paths = clear_active_delete_paths(paths) if paths && @clear_parent_deletes && !@fields.empty?
            paths = append_delete_paths(paths) if @delete_paths
            return unless paths

            paths.empty? ? nil : paths
          end

          def clear_active_delete_paths(paths)
            paths = paths.dup
            Fields::Internal.clear_delete_paths!(paths, @fields)
            paths
          end

          def append_delete_paths(paths)
            paths ? paths + @delete_paths : @delete_paths
          end
        end
        private_constant :Layer

        def initialize(fields = {}, delete_paths: false, source: nil)
          @source = source
          @delete_paths_enabled = delete_paths
          @version = 0
          @snapshot_version = nil
          @snapshot = nil
          @value_cache = nil
          add(fields) if fields.is_a?(Hash) && !fields.empty?
        end

        def snapshot
          return @snapshot if @snapshot_version == @version

          @snapshot = @source ? @source.snapshot : EMPTY_HASH
          @snapshot_version = @version
          @snapshot
        end

        def fork
          self.class.new(delete_paths: @delete_paths_enabled, source: @source)
        end

        def value_for(key, default:)
          cache = @value_cache
          return cache[key] if cache&.key?(key)

          if key.is_a?(String)
            key = Fields::Internal.normalize_key(key)
            cache = @value_cache
            return cache[key] if cache&.key?(key)
          end

          value = source_value_for(key)
          return default if value.equal?(MISSING)

          (@value_cache ||= {})[key] = value
        end

        def add(fields = nil, owned: false, **keyword_fields)
          fields = field_input(fields, keyword_fields, owned: owned)
          return unless fields.is_a?(Hash)
          return if fields.empty?

          fields = normalize_owned_keys(fields) if owned
          @source = Layer.new(@source, fields, clear_parent_deletes: true, owned: owned)
          invalidate_snapshot!
        end

        def delete(path)
          return if path.empty?
          return unless @delete_paths_enabled

          @source = Layer.new(@source, {}, delete_paths: [path], clear_parent_deletes: false)
          invalidate_snapshot!
        end

        def with(fields = nil, owned: false, **keyword_fields, &)
          fields = field_input(fields, keyword_fields, owned: owned)
          return yield unless fields.is_a?(Hash)
          return yield if fields.empty?

          fields = normalize_owned_keys(fields) if owned
          with_layer(fields, owned: owned, &)
        end

        def without(path, &)
          raise ArgumentError, "field path is required" if path.empty?

          return yield unless @delete_paths_enabled

          with_layer({}, delete_paths: [path], &)
        end

        private

        def field_input(fields, keyword_fields, owned:)
          if owned
            return fields if keyword_fields.empty?
            return keyword_fields if fields.nil?
            return fields.merge(keyword_fields) if fields.is_a?(Hash)

            return keyword_fields
          end

          return FieldSet.deep_symbolize_keys(fields) if keyword_fields.empty?

          FieldSet.coerce(fields, keyword_fields)
        end

        def with_layer(fields, delete_paths: nil, owned: false)
          previous_source = @source
          @source = Layer.new(
            previous_source,
            fields,
            delete_paths: delete_paths,
            clear_parent_deletes: false,
            owned: owned
          )
          invalidate_snapshot!
          begin
            yield
          ensure
            @source = previous_source
            invalidate_snapshot!
          end
        end

        def normalize_owned_keys(fields)
          return fields unless fields.any? { |key, _value| key.is_a?(String) }

          fields.to_h { |key, value| [Fields::Internal.normalize_key(key), value] }
        end

        def source_value_for(key)
          return MISSING unless @source

          unless @source.parent
            # Single-layer hits avoid Layer's delete-path/cache bookkeeping.
            field_value = FieldSet.value_for(@source.fields, key, default: MISSING)
            return frozen_source_value(field_value, @source.owned?) unless field_value.equal?(MISSING)
          end

          value = @source.value_for(key)
          value.equal?(MISSING) ? MISSING : value
        end

        def frozen_source_value(value, owned)
          owned ? Fields::Internal.frozen_owned_copy(value) : Fields::Internal.frozen_copy(value)
        end

        def invalidate_snapshot!
          @version += 1
          @snapshot = nil
          @snapshot_version = nil
          @value_cache = nil
        end
      end
    end
  end
end
