# frozen_string_literal: true

module OpenApi
  module Specs
    #
    # Loads the YAML docs and reformats it building RSpec/RSwag with the helper modules.
    #
    class OperationTemplate # rubocop:disable Metrics/ClassLength
      DEFAULT_EXAMPLE_METADATA = {
        before: [], after: [], headers: [], let: {}, params: {}, parameters: [], metadata: {}
      }.freeze
      DEFAULT_REQUEST_CONTENT_TYPES = %w[application/json].freeze
      DEFAULT_SECURITY = [api_key: []].freeze

      class << self
        # @param [String] operation '/api/endpoint/get'
        # @param [String, nil] api_version '1.0.0' or default to 'draft'
        def find(operation, api_version = nil)
          # 'GET /api/endpoint' => '/api/endoint/get'
          operation = operation.split(' ').reverse.map(&:downcase).join('/')
          attributes = Versions.template_for(operation, api_version).merge(
            operation: operation, api_version: api_version,
            http_method: operation.split('/').last, path: operation.split('/')[0..-2].join('/')
          )

          new attributes
        end
      end

      attr_reader :attributes

      delegate_missing_to :attributes

      def initialize(attributes)
        @attributes = attributes.transform_keys do |key|
          case key
          when :id
            :operationId
          else
            key.to_s.sub(/^x\-/, '').to_sym
          end
        end
      end

      # An operation is a combination of endpoint/path and method
      # @example
      #   '/api/runbooks/{id}/get'
      def operation
        attributes[:operation]
      end

      def api_version
        attributes[:api_version] || Api::Versions::DRAFT
      end

      def http_method
        attributes[:http_method]
      end

      def path
        attributes[:path]
      end

      #
      # RSpec and RSwag Context data
      #

      def context_metadata
        {
          # from rswag #path and #{method} in :
          # https://github.com/jdanielian/open-api-rswag/blob/master/rswag-specs/lib/open_api/rswag/specs/example_group_helpers.rb
          operation: attributes.slice(:description, :summary).merge(verb: http_method),
          path_item: { template: path }, swagger_doc: "#{api_version}.json",
          operation_template: self # custom
        }.merge(attribute_metadata)
      end

      def attribute_metadata
        attributes.slice(:focus, :skip)
      end

      def before
        attributes[:before] || []
      end

      def after
        attributes[:after] || []
      end

      def let
        attributes[:let] || {}
      end

      #
      # RSwag metadata
      #

      def consumes
        Array(attributes[:request_content_type] || DEFAULT_REQUEST_CONTENT_TYPES).flatten
      end

      def parameters
        # @todo parameter(name: :api_version, in: :header) if api_version.match?(/\d\-/)

        Array(attributes[:parameters]).map do |config|
          if config.is_a?(String)
            { '$ref' => "#/components/parameters/#{config}" }
          else
            next config if config[:content]

            config = config.reverse_merge(in: :formData, schema: {})
            # default to string unless we detect a dynamic schema
            unless config[:schema].keys.grep(/Of$/).any?
              config[:schema] [:type] ||= config[:type] || 'string'
            end
            config[:in] = config[:in]&.to_sym
            config.except(:type)
          end
        end
      end

      # extract :name from parameters:
      def parameter_keys
        parameters.map { |h| h[:name] || h[:'$ref'].to_s.split('/').last }.compact.map(&:to_sym)
      end

      def params
        attributes[:params] || {}
      end

      def lets_and_params
        let.merge(params)
      end

      def produces
        'application/json'
      end

      def request_body_json
        return unless (config = attributes[:request_body])

        # !config.key? should not be needed, we should either use 'string' or schema: ... in the files.
        config = { schema: config } if !config.is_a?(Hash) || !config.key?(:schema)

        config.merge! normalize_refs(:requestBodies, schema: config[:schema])
        config[:examples] ||= :request_body
        config
      end

      def security
        # disabled, haven't needed to do per-endpoint security.

        # return if attributes[:security] == false
        # attributes[:security] || DEFAULT_SECURITY
      end

      def id
        # HACK: Core has no operation ids yet
        return attributes[:operationId] if operation.starts_with?('/api')

        attributes[:operationId] || raise('Operation ID is missing in API spec yml file')
      end

      alias operationId id

      def summary
        attributes[:summary]
      end

      def tags
        Array(attributes[:tags]).flatten.join(',')
      end

      #
      # RSwag Examples
      #

      # @return [Array<Hash>]
      def responses
        attributes[:responses].map do |status, response|
          # responses should be a `{ '200': { config ...} }` format but legacy is an array.
          response ||= status
          response[:status] ||= status

          # description = [response[:status], response[:description]].compact.join(' - ')
          # response[:description] = description
          response[:description] ||= ''
          response[:examples] ||= []
          response
        end
      end

      # (rspec) examples always include the root response ('validated'), then optionally additional
      # (openapi) examples ('documented') that will get written out into the document.
      def examples
        responses.each_with_object([]) do |response, all_examples|
          # master validation example
          master_example = DEFAULT_EXAMPLE_METADATA.merge(
                             response.except(:examples),
                             attributes.slice(:'core-version'),
                             master_example: true
                           )

          master_example = normalize_refs(:responses, master_example)

          if master_example[:status] == '200' && master_example[:validate_response_has_data] != false
            master_example[:after] |= [:validate_response_has_data]
          end

          all_examples << master_example

          # documented examples(record )
          response[:examples].each { |example| all_examples << build_example(example, master_example) }
        end
      end

      def build_example(example, master_example)
        example = master_example.except(:master_example, :focus, :skip)
                                .merge(example.except(:description), example_description: example[:description])

        normalize_refs(:responses, example)
      end

      #
      # Helpers
      #

      # converts 'resource' into  { '$ref' => #/components/responses/resource' }
      def normalize_refs(component_type, data)
        # nest the data in a fake structure so that the method knows the context for $ref expansion.
        data[:schema] = Compiler.normalize_refs(
          components: { component_type => { x: { schema: data[:schema] } } }
        )[:components][component_type][:x][:schema]

        data
      end
    end
  end
end
