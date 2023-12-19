# frozen_string_literal: true

require 'open_api/schema_validator'

module OpenApi
  module Specs
    # Load yaml files, expanding any shorthands to the proper OpenApi spec.
    class Compiler
      # Match files that should be wrapped in { components: { name: .... } }
      # /requests.yml => 'requests'
      COMPONENT_REGEXP = %r{/(examples|parameters|requests|responses|schemas)}

      # Keywords that can contain $ref schemas
      COMPOSITION_KEYWORDS_REGEXP = /oneOf|allOf|anyOf|not/

      OPERATION_REGEXP = %r{/(get|post|patch|put|delete)}.freeze

      # Match paths to a $ref that should be expanded
      REF_REGEXPS = {
        # /components/responses/{name}/content/application/json/schema
        # /components/responses/{name}/content/application/json/schema/allOf/0
        component_schema: %r{
          ^
          components
          /(requestBodies|responses)
          /[^/]+
          (/content/application/json){0,1}
          /schema
          (/#{COMPOSITION_KEYWORDS_REGEXP}){0,1}
          $
        }x,

        # /components/schemas/{name}
        # /components/schemas/{name}/allOf/0
        # .../properties/{name}
        # .../properties/{name}/allOf/0
        # .../allOf/properties/{name}
        # .../allOf/properties/{name}/allOf/0
        schema: %r{
          (/(#{COMPOSITION_KEYWORDS_REGEXP})){0,1}
          (^components/schemas|/properties)
          /[^/]+
          (/items){0,1}
          (/#{COMPOSITION_KEYWORDS_REGEXP}){0,1}
          $
        }x
      }.freeze

      #
      # Class Methods
      #
      class << self
        # Expands 'Schema' to { '$ref' => '#/components/schemas/Schema' }
        # with varying formats depending on the context. See {REF_REGEXPS} for matchers.
        #
        # For example, it allows this:
        #
        # properties:
        #   runbook:
        #     $ref: '#/components/schemas/Runbook'
        #
        # to be written as this:
        #
        # properties:
        #   runbook: Runbook
        #
        # and also handles:
        # * composition within a Schema: (use of oneOf:, allOf:, etc).
        # * correct paths for other component types
        #
        def normalize_ref(path, value) # rubocop:disable Metrics/MethodLength case
          case value
          when String
            case path.join('/')

            # /properties/{name}/
            # /properties/{name}/allOf/0
            when REF_REGEXPS[:schema]
              { '$ref' => "#/components/schemas/#{value}" }

            # /components/responses/{name}/content/application/json/schema
            # /components/responses/{name}/content/application/json/schema/allOf/0
            when REF_REGEXPS[:component_schema]
              { '$ref' => "#/components/#{path[1]}/#{value}/content/application~1json/schema" }

            # just a leaf value
            else
              value
            end
          when Array
            value.map { |item| normalize_ref(path, item) }
          else
            value
          end
        end

        # Normalize all '$ref paths in the document.
        def normalize_refs(data)
          data.reformat_with_path do |key, value, path|
            [key, normalize_ref(path, value)]
          end
        end
      end

      #
      # Instance Methods
      #

      def initialize(files = nil)
        @files = files || Dir['./spec/api/**.yml']
      end

      # @param files [Array<String>] paths to yaml files to be loaded and combined
      # @return [Hash]
      def call
        doc = @files.each_with_object({}) do |file, hash|
          hash.deep_merge! load(file)
        end

        doc.reject { |k, _v| k.to_s.start_with?('_') }

        result = validate(doc.deep_merge(info: { version: '1' }))
        puts result unless result == true

        doc
      end

      private

      # @param [String]
      # @return [Hash]
      def load(file)
        data = YAML.load_file(file, symbolize_names: true)
        data = normalize_content(file, data)
        data = normalize_path(file, data)
        self.class.normalize_refs(data)
      end

      def validate(json)
        # we are calling this method first, as it does additional schema setup.
        # https://github.com/ketiko/open_api-schema_validator/blob/master/lib/open_api/schema_validator.rb
        OpenApi::SchemaValidator.validate_schema!(OpenApi::SchemaValidator.oas3, json)
      rescue JSON::Schema::ValidationError => e
        exclusions = "The property '#/components/parameters/core.custom_field_value_params' " \
                     "of type object did not match any of the required schemas"
        return if exclusions == e.message

        JSON::Validator.fully_validate(OpenApi::SchemaValidator.oas3, json)
      end

      #
      # Helpers
      #

      # Expand { schema: {}, examples: {} }
      # to { content: { application/json: { schema: {}, examples: {} } } }
      def normalize_content(file, data)
        component = file[COMPONENT_REGEXP, 1]
        return data unless component

        mime_type = :'application/json'
        data.each_value do |value|
          next unless value.key?(:schema) || value.key?(:examples)

          value[:content] = {
            mime_type => {
              schema: value.delete(:schema), examples: value.delete(:examples)
            }.compact
          }
        end

        data
      end

      # worth out the deep nesting of the data based on its path
      def normalize_path(file, data)
        path = file.sub('./spec', '').sub('.yml', '')
        case path
        when %r{/open_api}
          data
        when OPERATION_REGEXP
          path = path.split('/')
          http_method = path.pop
          { paths: { path.join('/').to_sym => { http_method.to_sym => data } } }
        when COMPONENT_REGEXP
          component = file[COMPONENT_REGEXP, 1]
          component = 'requestBodies' if component == 'requests'

          { components: { component.to_sym => data } }
        else
          data
        end
      end
    end
  end
end
