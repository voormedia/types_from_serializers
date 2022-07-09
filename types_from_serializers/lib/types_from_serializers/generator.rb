# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"

# Public: Automatically generates TypeScript interfaces for Ruby serializers.
module TypesFromSerializers
  # Internal: The configuration for TypeScript generation.
  Config = Struct.new(
    :serializers_dir,
    :output_dir,
    :name_from_serializer,
    :native_types,
    :sql_to_typescript_type_mapping,
    keyword_init: true)

  # Internal: The type metadata for a serializer.
  SerializerMetadata = Struct.new(
    :attributes,
    :associations,
    :model_name,
    :types_from,
    keyword_init: true)

  # Internal: The type metadata for a serializer field.
  FieldMetadata = Struct.new(:name, :type, :optional, :many, keyword_init: true) do
    def typescript_name
      name.to_s.camelize(:lower)
    end
  end

  # Internal: Extensions that simplify the implementation of the generator.
  module SerializerRefinements
    refine String do
      # Internal: Converts a name such as :user to the User constant.
      def to_model
        classify.safe_constantize
      end
    end

    # rubocop:disable Rails/Delegate
    refine Symbol do
      def safe_constantize
        to_s.classify.safe_constantize
      end

      def to_model
        to_s.to_model
      end
    end
    # rubocop:enable Rails/Delegate

    refine Class do
      # Internal: Name of the TypeScript interface.
      def typescript_interface_name
        TypesFromSerializers.config.name_from_serializer.(name).tr_s(":", "")
      end

      # Internal: The base name of the TypeScript file to be written.
      def typescript_interface_basename
        TypesFromSerializers.config.name_from_serializer.(name).gsub("::", "/")
      end

      # Internal: A first pass of gathering types for the serializer fields.
      def typescript_metadata
        SerializerMetadata.new(
          model_name: _serializer_model_name,
          types_from: _serializer_types_from,
          attributes: _attributes.map { |key, options|
            typed_attrs = _typed_attributes.fetch(key, {})
            FieldMetadata.new(
              **typed_attrs,
              name: key,
              optional: typed_attrs[:optional] || options.key?(:if),
            )
          },
          associations: _associations.map { |key, options|
            FieldMetadata.new(
              name: options.fetch(:root, key),
              type: options.fetch(:serializer),
              optional: options.key?(:if),
              many: options.fetch(:write_method) == :write_many,
            )
          },
        )
      end

      # Internal: Infers field types by checking the SQL columns for the model
      # serialized, or from a TypeScript interface if provided.
      def typescript_infer_types(metadata)
        model = metadata.model_name&.to_model
        interface = metadata.types_from

        metadata.attributes.reject(&:type).each do |meta|
          if model && (column = model.columns_hash[meta.name.to_s])
            meta[:type] = TypesFromSerializers.config.sql_to_typescript_type_mapping[column.type]
            meta[:optional] ||= column.null
          elsif interface
            meta[:type] = "#{interface}['#{meta.typescript_name}']"
          end
        end
      end

      def typescript_imports(metadata)
        assoc_imports = metadata.associations.map { |meta|
          [meta.type.typescript_interface_name, "~/types/serializers/#{meta.type.typescript_interface_basename}"]
        }

        attr_imports = metadata.attributes
          .flat_map { |meta| extract_typescript_types(meta.type.to_s) }
          .uniq
          .reject { |type| typescript_native_type?(type) }
          .map { |type|
            [type, "~/types/#{type}"]
          }

        (assoc_imports + attr_imports).uniq.map { |interface, filename|
          "import type #{interface} from '#{filename}'\n"
        }.uniq
      end

      # Internal: Extracts any types inside generics or array types.
      def extract_typescript_types(type)
        type.split(/[<>\[\],\s]+/)
      end

      # NOTE: Treat uppercase names as custom types.
      # Lowercase names would be native types, such as :string and :boolean.
      def typescript_native_type?(type)
        type[0] == type[0].downcase || TypesFromSerializers.config.native_types.include?(type)
      end

      def typescript_fields(metadata)
        (metadata.attributes + metadata.associations).map { |meta|
          type = meta.type.is_a?(Class) ? meta.type.typescript_interface_name : meta.type || :unknown
          type = meta.many ? "#{type}[]" : type
          "  #{meta.typescript_name}#{"?" if meta.optional}: #{type}"
        }
      end
    end
  end

  class << self
    using SerializerRefinements

    attr_reader :force_generation

    # Public: Configuration of the code generator.
    def config
      (@config ||= default_config(Rails.root)).tap do |config|
        yield(config) if block_given?
      end
    end

    # Public: Generates code for all serializers in the app.
    def generate!(force: ENV["SERIALIZER_TYPES_FORCE"])
      @force_generation = force
      generate_index_file
      all_serializers.each do |serializer|
        generate_interface_for(serializer)
      end
    end

    # Internal: Defines a TypeScript interface for the serializer.
    def generate_interface_for(serializer)
      metadata = serializer.typescript_metadata
      filename = serializer.typescript_interface_basename

      write_if_changed(filename: filename, cache_key: metadata.inspect) {
        serializer.typescript_infer_types(metadata)
        <<~TS
          //
          // DO NOT MODIFY: This file was automatically generated by TypesFromSerializers.
          #{serializer.typescript_imports(metadata).join}
          export default interface #{serializer.typescript_interface_name} {
          #{serializer.typescript_fields(metadata).join("\n")}
          }
        TS
      }
    end

    # Internal: Allows to import all serializer types from a single file.
    def generate_index_file
      write_if_changed(filename: "index", cache_key: all_serializer_files.join) {
        <<~TS
          //
          // DO NOT MODIFY: This file was automatically generated by TypesFromSerializers.
          #{all_serializers.map { |s| "export type { default as #{s.typescript_interface_name} } from './#{s.typescript_interface_basename}'" }.join("\n")}
        TS
      }
    end

    # Internal: Checks if it should avoid generating an interface.
    def skip_serializer?(name)
      name.include?('BaseSerializer')
    end

    # Internal: When a class is loaded during development, if it's a serializer,
    # check if it's necessary to regenerate serializers.
    def on_load(name, klass, abs_path)
      return if force_generation # `all_serializers` will trigger this unnecessarily in `generate!`.

      if abs_path.start_with?(config.serializers_dir) && !skip_serializer?(name)
        if generate_interface_for(klass)
          generate_index_file
        end
      end
    end

  private

    def all_serializer_files
      Dir["#{config.serializers_dir}/**/*.rb"]
    end

    def all_serializers
      all_serializer_files.each { |f| require f }
      Oj::Serializer.descendants
        .sort_by(&:name)
        .reject { |s| skip_serializer?(s.name) }
    end

    def default_config(root)
      Config.new(
        # The dir where the serializer files are located.
        serializers_dir: root.join("app/serializers").to_s,

        # The dir where interface files are placed.
        output_dir: root.join(defined?(ViteRuby) ? ViteRuby.config.source_code_dir : "app/frontend").join("types/serializers"),

        # Remove the serializer suffix from the class name.
        name_from_serializer: ->(name) { name.delete_suffix("Serializer") },

        # Types that don't need to be imported in TypeScript.
        native_types: [
          "Array",
          "Record",
          "Date",
        ].to_set,

        # Maps SQL column types to TypeScript native and custom types.
        sql_to_typescript_type_mapping: {
          boolean: :boolean,
          date: "string | Date",
          datetime: "string | Date",
          decimal: :number,
          integer: :number,
          string: :string,
          text: :string,
        }.tap do |types|
          types.default = :unknown
        end
      )
    end

    # Internal: Writes if the file does not exist or the cache key has changed.
    # The cache strategy consists of a comment on the first line of the file.
    #
    # Yields to receive the rendered file content when it needs to.
    #
    # Returns true if the file did not exist.
    def write_if_changed(filename:, cache_key:)
      filename = config.output_dir.join("#{filename}.ts")
      FileUtils.mkdir_p(filename.dirname)
      cache_key_comment = "// TypesFromSerializers CacheKey #{Digest::MD5.hexdigest(cache_key)}\n"
      File.open(filename, "a+") { |file|
        new_file = file.gets.blank?
        if stale?(file, cache_key_comment)
          file.truncate(0)
          file.write(cache_key_comment)
          file.write(yield)
        end
        new_file
      }
    end

    # Internal: Returns true if the cache key has changed since the last codegen.
    def stale?(file, cache_key_comment)
      @force_generation || file.gets != cache_key_comment
    end
  end
end