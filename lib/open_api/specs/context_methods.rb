# frozen_string_literal: true

module OpenApi
  module Specs
    # Digest the yaml files via the {OperationTemaplate} class and dynamically build RSpec block
    module ContextMethods
      # @example pull operation from RSpec
      #   RSpec.describe 'GET /namespace/resources' do
      #     has_api_docs(focus: true)
      #   end
      #
      # @example explicitly define the operation
      #   has_api_docs('/namespace/resources/get', focus: true)
      #
      def has_api_docs(*args)
        meta = args.extract_options!
        # used by bin/build_open_api_doc to speed up
        meta[:api_doc] = true

        args << description if args.blank?

        if args.length == 1
          run_versions(args.first, meta)
        else
          args.each do |operation|
            context(context_name_for(operation)) { run_versions(operation, meta) }
          end
        end
      end

      private

      # Make {OperationTemplate} accessable in {has_api_docs} and subsequent contexts.
      def operation_template
        @operation_template || metadata[:operation_template]
      end

      delegate :operation, :api_version, to: :operation_template

      # "/path/to/verb" => 'VERB /path/to'
      def context_name_for(operation)
        parts = operation.sub(description, '').split('/')
        verb = parts.pop.upcase
        "#{verb} #{parts.join('/')}"
      end

      #
      # Operation Context
      #

      # Run operation against multiple versions of the API
      #
      # @example
      #   run_versions('/namespace/resources/get', focus: true)
      #
      # @example builds:
      #   context('version: 1', meta) do
      #     # {run_operation}
      #   end
      #
      #   context('version: 2', meta) do
      #     # {run_operation}
      #   end
      #
      def run_versions(operation, meta)
        Versions.find_range(metadata).each do |api_version|
          @operation_template = OperationTemplate.find(operation, api_version)

          # This context replaces the ones created by RSwag ExampleGroupHelpers#path and #{method} methods
          context "version: #{api_version}", operation_template.context_metadata.merge(meta) do
            run_operation
          end
        end
      end

      # Apply {#operation_template} to the context for one operation and then loop through examples.
      #
      # @example builds
      #   consumes 'application/json'
      #   produces 'application/json'
      #   operationId 'Namespace::Resource'           # from yaml `id:`
      #   tags ['resource']                           # from yaml `tags:`
      #   request_body_json { schema: { ... } }       # from yaml `request_body:`
      #
      #   let(:resource_id) { send(:resource_id) }    # from yaml `let:`
      #   before { [send(:symbol1), send(:symbol2)] } # from yaml `before: [:symbol1, :symbol2]`
      #   after { send(:symbol) }                     # from yaml `after: ...`
      #
      #   operation_template.examples.each do |config|
      #     run_example(config) # in example_context_methods.rb
      #   end
      def run_operation
        apply_template_to_open_api
        apply_let_blocks
        apply_filter_blocks(:before)
        apply_filter_blocks(:after)
        operation_template.examples.each(&method(:run_example))
      end

      # Apply {#operation_template} to metadata via RSwag ExampleGroupHelpers methods
      def apply_template_to_open_api
        consumes(*operation_template.consumes)
        operation_template.parameters.each(&method(:parameter))

        %i[produces operationId tags request_body_json security].each do |key|
          if (value = operation_template.send(key))
            value.is_a?(Hash) ? send(key, **value) : send(key, value)
          end
        end
      end

      # Take each 'let: :mapping' from the operation yaml and look it up in rspec's context.
      def apply_let_blocks
        # default nil values to ensure no method not found errors
        operation_template.parameter_keys.each do |key|
          let(key) { nil } unless instance_methods.include?(key) || key.match?(/_id$/)
        end

        operation_template.lets_and_params.each do |key, value|
          let(key) { lookup_value(value) }
        end
      end

      # build `before {}` and `after {}` filters.
      def apply_filter_blocks(type)
        filters = operation_template.send(type)

        return unless filters.any?

        send(type) do
          filters.each { |statement| lookup_value(statement) }
        end
      end
    end
  end
end
