# frozen_string_literal: true

# Shims for RSwag for request examples and validation
module Rswag
  module Specs
    module ExampleGroupRequestHelpers
      def request_body(attributes)
        # can make this generic, and accept any incoming hash (like parameter method)
        attributes.compact!

        if metadata[:operation][:requestBody].blank?
          metadata[:operation][:requestBody] = attributes
        elsif metadata[:operation][:requestBody] && metadata[:operation][:requestBody][:content]
          # merge in
          content_hash = metadata[:operation][:requestBody][:content]
          incoming_content_hash = attributes[:content]
          content_hash.merge!(incoming_content_hash) if incoming_content_hash
        end
      end

      def request_body_json(schema:, required: true, description: nil, examples: nil)
        passed_examples = Array(examples)

        example_schema = schema.is_a?(Hash) && schema['$ref'] ? { '$ref' => schema['$ref'].sub('json/schema', 'json/examples') } : nil

        content_hash = { 'application/json' => { schema: schema, examples: example_schema }.compact }
        request_body(description: description, required: required, content: content_hash)
        if passed_examples.any?
          # the request_factory is going to have to resolve the different ways that the example can be given
          # it can contain a 'value' key which is a direct hash (easiest)
          # it can contain a 'external_value' key which makes an external call to load the json
          # it can contain a '$ref' key. Which points to #/components/examples/blog
          passed_examples.each do |passed_example|
            if passed_example.is_a?(Symbol)
              example_key_name = passed_example
              # TODO: write more tests around this adding to the parameter
              # if symbol try and use save_request_example
              param_attributes = { name: example_key_name, in: :body, required: required, param_value: example_key_name, schema: schema }
              parameter(param_attributes)
            elsif passed_example.is_a?(Hash) && passed_example[:externalValue]
              param_attributes = { name: passed_example, in: :body, required: required, param_value: passed_example[:externalValue], schema: schema }
              parameter(param_attributes)
            elsif passed_example.is_a?(Hash) && passed_example['$ref']
              param_attributes = { name: passed_example, in: :body, required: required, param_value: passed_example['$ref'], schema: schema }
              parameter(param_attributes)
            end
          end
        end
      end

      def request_body_text_plain(required: false, description: nil, examples: nil)
        content_hash = { 'test/plain' => { schema: {type: :string}, examples: examples }.compact! || {} }
        request_body(description: description, required: required, content: content_hash)
      end

      # TODO: add examples to this like we can for json, might be large lift as many assumptions are made on content-type
      def request_body_xml(schema:,required: false, description: nil, examples: nil)
        passed_examples = Array(examples)
        content_hash = { 'application/xml' => { schema: schema, examples: examples }.compact! || {} }
        request_body(description: description, required: required, content: content_hash)
      end

      def request_body_multipart(schema:, description: nil)
        content_hash = { 'multipart/form-data' => { schema: schema }}
        request_body(description: description, content: content_hash)

        schema.extend(Hashie::Extensions::DeepLocate)
        file_properties = schema.deep_locate ->(_k, v, _obj) { v == :binary }
        hash_locator = []

        file_properties.each do |match|
          hash_match = schema.deep_locate ->(_k, v, _obj) { v == match }
          hash_locator.concat(hash_match) unless hash_match.empty?
        end

        property_hashes = hash_locator.flat_map do |locator|
          locator.select { |_k,v| file_properties.include?(v) }
        end

        existing_keys = []
        property_hashes.each do |property_hash|
          property_hash.keys.each do |k|
            if existing_keys.include?(k)
              next
            else
              file_name = k
              existing_keys << k
              parameter name: file_name, in: :formData, type: :file, required: true
            end
          end
        end
      end
    end

    class RequestValidator
      def initialize(config = ::Rswag::Specs.config)
        @config = config
      end

      def validate!(metadata, request)
        return if metadata[:response][:code] == '400' # expected to fail

        swagger_doc = ActiveSupport::Deprecation.silence { @config.get_swagger_doc(metadata[:swagger_doc]) }

        validate_headers!(metadata, request[:headers])
        validate_body!(metadata, swagger_doc, request.body.read)
      end

      private

      def validate_headers!(metadata, headers)
        return # @todo implement
        expected = (metadata[:request][:headers] || {}).keys
        expected.each do |name|
          raise UnexpectedRequest, "Expected request header #{name} to be present" if headers[name.to_s].nil?
        end
      end

      def validate_body!(metadata, swagger_doc, body)
        test_schemas = extract_schemas(metadata)
        return if test_schemas.nil? || test_schemas.empty?

        validation_schema = test_schemas[:schema].merge('$schema' => 'http://tempuri.org/rswag/specs/extended_schema').merge(swagger_doc.slice(:components) || {})

        errors = JSON::Validator.fully_validate(validation_schema, body)

        # allow missing properties as that is normal for a 422
        case metadata[:response][:code]
        when '422'
          errors.reject! do |error|
            error =~ /did not contain a required property|of type (.*) did not match/
          end
        end

        raise UnexpectedRequest, "Expected request body to match schema: #{errors[0]}" if errors.any?
      end

      def extract_schemas(metadata)
        metadata.dig(:operation, :parameters)&.find { |p| p[:in] == :body }
      end
    end

    class ResponseValidator
      # def definitions_or_component_schemas(swagger_doc, version)
      #   swagger_doc.slice(:components) || {}
      # end

      private

      # change response.code to response.code.to_s for Rack::Test compatability
      def validate_code!(metadata, response)
        expected = metadata[:response][:code].to_s
        if response.code.to_s != expected
          raise UnexpectedResponse,
            "Expected response code '#{response.code}' to match '#{expected}'\n" \
              "Response body: #{response.body}"
        end
      end
    end

    class UnexpectedRequest < StandardError; end

    class RequestFactory
      def add_path(request, metadata, swagger_doc, parameters, example)
        open_api_3_doc = doc_version(swagger_doc).start_with?('3')
        uses_base_path = swagger_doc[:basePath].present?

        if open_api_3_doc && uses_base_path
          ActiveSupport::Deprecation.warn('Rswag::Specs: WARNING: basePath is replaced in OpenAPI3! Update your swagger_helper.rb')
        end

        if uses_base_path
          template = (swagger_doc[:basePath] || '') + metadata[:path_item][:template]
        else # OpenAPI 3
          template = base_path_from_servers(swagger_doc) + metadata[:path_item][:template]
        end

        request[:path] = template.tap do |path_template|
          parameters.select { |p| p[:in].to_s == 'path' }.each do |p|
            unless example.respond_to?(extract_getter(p))
              raise ArgumentError.new("`#{p[:name].to_s}` parameter key present, but not defined within example group"\
                "(i. e `it` or `let` block)")
            end
            path_template.gsub!("{#{p[:name]}}", example.send(extract_getter(p)).to_s)
          end

          parameters.select { |p| p[:in].to_s == 'query' }.each_with_index do |p, i|
            # HACK, allow for p[:name] to be something like 'page[number]'
            # and make it so defining let(:param) is optional via checking example.respond_to?
            # move ? vs & to after the next

            # ["page[number]", "page", "[number]", "number"]
            param_regx = /([^\[\]]*)(\[([^\]]*)\]){0,1}/
            _name, method_name, brackets, key_name = p[:name].match(param_regx).to_a

            value = example.respond_to?(method_name) ? example.send(method_name) : nil
            value = value&.fetch(key_name.to_sym, nil) if key_name.present? # hack to ignore ''
            # hack to allow for both stage=default and stage[]=default to work
            next if value.nil?
            next if brackets.blank? && value.is_a?(Array)
            next if brackets.present? && value.is_a?(Array) == false

            path_template.concat(path_template.include?('?') ? '&' : '?')
            path_template.concat(build_query_string_part(p, value, swagger_doc))
            # END HACK

          end
        end
      end
    end
  end
end
