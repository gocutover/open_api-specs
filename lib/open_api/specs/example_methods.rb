# frozen_string_literal: true

module OpenApi
  module Specs
    # Used inside examples
    module ExampleMethods
      attr_reader :api_version

      # Process the request with RSwag, and add examples
      def process_example(config, example)
        submit_request(example.metadata)

        # HACK, solves issue with [OpenStruct.new] slipping through
        if respond_to?(:last_response) && last_response.status == 204 &&
             last_response.instance_variable_get(:@body).first.is_a?(OpenStruct)
          body = last_response.instance_variable_get(:@body).first.to_h
          body = body.blank? ? '' : OpenStruct.new(body)
          last_response.body = [body]
        end

        ::Rswag::Specs::RequestValidator.new.validate!(example.metadata, request)
        ::Rswag::Specs::ResponseValidator.new.validate!(example.metadata, response)

        add_request_examples(example)
        add_response_examples(example)

        puts_request_response if config[:focus]
      rescue StandardError => e
        puts_error(example, config, e) if config[:focus]
        raise e
      end

      #
      # Add Examples
      #

      # prefer examples in requests.yml to the request.body
      def add_request_examples(example)
        return unless (request_body = example.metadata[:operation][:requestBody])

        # get examples from request.yml
        ref = request_body.dig(:content, 'application/json', :examples)&.delete('$ref')
        if ref && defined?(OpenApi::Document)
          ref_path = ref.to_s.split('/').map { |key| key.sub('~1', '/') }[1..]
          examples = OpenApi::Document.stringified_draft_components.dig(*ref_path) || {}
        else
          examples = {}
        end

        # mix in spec example
        request.body.rewind
        description = example.metadata[:example_description] || 'example'
        examples[description.parameterize(separator: '_')] ||= {
          summary: description,
          value: example_from_body(request.body.read)
        }.compact

        request_body[:content].deep_merge!('application/json' => { examples: examples })
      end

      def add_response_examples(example)
        example.metadata[:response][:examples] ||= {}
        description = example.metadata[:example_description] || 'example'
        example.metadata[:response][:examples].deep_merge!(
          'application/json' => {
            description.parameterize(separator: '_') => {
              summary: description,
              value: example_from_body(response.body)
            }.compact
          }
        )
      end

      def example_from_body(body)
        example = JSON.parse(body.presence || '{}', symbolize_names: true)

        if RSpec.configuration.open_api_example_cleaner
          example = example.reformat_with_path(&RSpec.configuration.open_api_example_cleaner)
        end

        example
      rescue JSON::ParserError => e
        body.starts_with?('<') ? {} : raise(e)
      end

      def pretty_request_body
        request.body.rewind
        body = request.body.read
        request.body.rewind

        return if body.blank?

        JSON.pretty_generate JSON.parse(body)
      end

      def pretty_response_body
        return if response.body.empty?

        JSON.pretty_generate JSON.parse(response.body)
      end

      def puts_error(example, config, _error)
        puts example.metadata[:schema].to_yaml
        puts config.to_yaml
        puts puts_request_response if response
        # puts _error.backtrace.join("\n")
      end

      def puts_request_response
        puts [
          "\npath:", request.fullpath,
          "\nrequest:", pretty_request_body || 'none',
          "\nresponse:", pretty_response_body || 'none'
        ].join("\n")
      end

      # Evaluate any Symbol inside a let.
      # Used inside of dyanmically generated let statements to convert:
      #
      # let(:param) { :param_name } into let(:param) { send(:param_name) }
      #
      # so you can reference other lets/variables inside of the yaml.
      #
      # @example call send on a method
      #   lookup_value(:method_name)
      #
      # @example pass parameters to the method
      #   lookup_value([:method_name, 'param1', 'param2'])
      #
      def lookup_value(value)
        value = Array(value).first.is_a?(Symbol) ? send(*Array(value)) : value
        value = value.reformat { |k, v| [k, lookup_value(v)] } if value.is_a?(Hash)
        value
      rescue StandardError => e
        puts "#{e.message} for:"
        puts value.inspect
        raise e
      end

      #
      # Global Let Data / Helpers
      #

      # expect data back in any root key other than meta
      # eg will check for runbook:, runbooks:, data:
      def validate_response_has_data
        data = case response.content_type
               when %r{^application/(.+\+)?xml} then xml
               else json
               end

        return unless data.except(:meta, 'meta').values.all? { |v| v.blank? && v != false }

        raise('No response data for a 200 request. Use validate_response_has_data: false if this is expected')
      end

      private

      # Add a dynamic version of
      #
      # let(:record_id) { record.id }
      #
      # as the api yaml files require the id methods by convention.
      def method_missing(method_name, *args, &block)
        # 'record_id' -> 'record'
        matching_let_method_name = method_name[/(.*)_id$/, 1]

        if matching_let_method_name && respond_to?(matching_let_method_name)
          send(matching_let_method_name).id
        else
          super
        end
      end

      def respond_to_missing?(method_name, include_private = false)
        matching_let_method_name = method_name[/(.*)_id$/, 1]
        matching_let_method_name && respond_to?(matching_let_method_name) || super
      end
    end
  end
end
