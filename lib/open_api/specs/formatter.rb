# frozen_string_literal: true

require 'active_support/core_ext/hash/deep_merge'
require 'rspec/core/formatters/base_text_formatter'
require 'api_helper'

module OpenApi
  module Specs
    class Formatter < ::RSpec::Core::Formatters::BaseTextFormatter
      ActiveSupport::Deprecation.warn('Rswag::Specs: WARNING: Support for Ruby 2.6 will be dropped in v3.0') if RUBY_VERSION.start_with? '2.6'

      if Rswag::Specs::RSPEC_VERSION > 2
        ::RSpec::Core::Formatters.register self, :example_group_finished, :stop
      else
        ActiveSupport::Deprecation.warn('Rswag::Specs: WARNING: Support for RSpec 2.X will be dropped in v3.0')
      end

      def initialize(output, config = Rswag::Specs.config)
        @output = output
        @config = config

        @output.puts 'Generating Swagger docs ...'
      end

      def example_group_finished(notification)
        metadata = if Rswag::Specs::RSPEC_VERSION > 2
          notification.group.metadata
        else
          notification.metadata
        end

        # !metadata[:document] won't work, since nil means we should generate
        # docs.
        return if metadata[:document] == false
        return unless metadata.key?(:response)

        swagger_doc = @config.get_swagger_doc(metadata[:swagger_doc])

        unless doc_version(swagger_doc).start_with?('2')
          # This is called multiple times per file!
          # metadata[:operation] is also re-used between examples within file
          # therefore be careful NOT to modify its content here.
          upgrade_request_type!(metadata)
          upgrade_servers!(swagger_doc)
          upgrade_oauth!(swagger_doc)
          upgrade_response_produces!(swagger_doc, metadata)
        end

        swagger_doc.deep_merge!(metadata_to_swagger(metadata))
      end

      def stop(_notification = nil)
        @config.swagger_docs.each do |url_path, doc|
          unless doc_version(doc).start_with?('2')
            doc[:paths]&.each_pair do |_k, v|
              v.each_pair do |_verb, value|
                is_hash = value.is_a?(Hash)
                if is_hash && value[:parameters]
                  schema_param = value[:parameters]&.find { |p| (p[:in] == :body || p[:in] == :formData) && p[:schema] }
                  mime_list = value[:consumes] || doc[:consumes]

                  if value && schema_param && mime_list
                    value[:requestBody] = { content: {} } unless value.dig(:requestBody, :content)
                    value[:requestBody][:required] = true if schema_param[:required]
                    value[:requestBody][:description] = schema_param[:description] if schema_param[:description]
                    examples = value.dig(:request_examples)
                    mime_list.each do |mime|
                      # HACK
                      # value[:requestBody][:content][mime] = { schema: schema_param[:schema] }
                      value[:requestBody][:content][mime].merge!(schema_param.slice(:schema, :examples))
                      # END HACK

                      if examples
                        value[:requestBody][:content][mime][:examples] ||= {}
                        examples.map do |example|
                          value[:requestBody][:content][mime][:examples][example[:name]] = {
                            summary: example[:summary] || value[:summary],
                            value: example[:value]
                          }
                        end
                      end
                    end
                  end

                  value[:parameters].reject! { |p| p[:in] == :body || p[:in] == :formData }
                end
                remove_invalid_operation_keys!(value)
              end
            end
          end

          file_path = File.join(@config.swagger_root, url_path)
          dirname = File.dirname(file_path)
          FileUtils.mkdir_p dirname unless File.exist?(dirname)

          # errors = OpenApi::SchemaValidator.fully_validate(doc)
          # puts errors if errors.is_a?(Array) # fully_validate returns true if successful.



          File.open(file_path, 'w') do |file|
            file.write(pretty_generate(doc))
          end

          @output.puts "Swagger doc generated at #{file_path}"
        end
      end

      private

      def pretty_generate(doc)
        if @config.swagger_format == :yaml
          clean_doc = yaml_prepare(doc)
          YAML.dump(clean_doc)
        else # config errors are thrown in 'def swagger_format', no throw needed here
          # HACK: gsubs to remove whitespace inside  {} and [] as it seems to alternate inconsistently.
          JSON.pretty_generate(doc).gsub(/{(\s)*}/, '{}').gsub(/\[(\s)*\]/, '[]')
        end
      end

      def yaml_prepare(doc)
        json_doc = JSON.pretty_generate(doc)
        JSON.parse(json_doc)
      end

      def metadata_to_swagger(metadata)
        response_code = metadata[:response][:code]
        response = metadata[:response].reject { |k, _v| k == :code }

        # HACK need to merge in to response
        (response.delete(:examples) || {}).each do |content_type, examples|
          new_hash = {}
          schema = response.dig(:content, content_type, :schema)
          new_hash[:schema] = schema unless schema.blank?
          new_hash[:examples] = examples unless examples.blank?

          unless new_hash.empty?
            response[:content] ||= {}
            response[:content][content_type] = new_hash
          end
        end
        # END HACK

        verb = metadata[:operation][:verb]
        operation = metadata[:operation]
          .reject { |k, _v| k == :verb }
          .merge(responses: { response_code => response })

        path_template = metadata[:path_item][:template]
        path_item = metadata[:path_item]
          .reject { |k, _v| k == :template }
          .merge(verb => operation)

        { paths: { path_template => path_item } }
      end

      def doc_version(doc)
        doc[:openapi] || doc[:swagger] || '3'
      end

      def upgrade_response_produces!(swagger_doc, metadata)
        # Accept header
        mime_list = Array(metadata[:operation][:produces] || swagger_doc[:produces])
        target_node = metadata[:response]
        upgrade_content!(mime_list, target_node)
        metadata[:response].delete(:schema)
      end

      def upgrade_content!(mime_list, target_node)
        schema = target_node[:schema]
        return if mime_list.empty? || schema.nil?

        target_node[:content] ||= {}
        mime_list.each do |mime_type|
          # TODO: upgrade to have content-type specific schema
          (target_node[:content][mime_type] ||= {}).merge!(schema: schema)
        end
      end

      def upgrade_request_type!(metadata)
        # No deprecation here as it seems valid to allow type as a shorthand
        operation_nodes = metadata[:operation][:parameters] || []
        path_nodes = metadata[:path_item][:parameters] || []
        header_node = metadata[:response][:headers] || {}

        (operation_nodes + path_nodes + [header_node]).each do |node|
          if node && node[:type] && node[:schema].nil?
            node[:schema] = { type: node[:type] }
            node.delete(:type)
          end
        end
      end

      def upgrade_servers!(swagger_doc)
        return unless swagger_doc[:servers].nil? && swagger_doc.key?(:schemes)

        ActiveSupport::Deprecation.warn('Rswag::Specs: WARNING: schemes, host, and basePath are replaced in OpenAPI3! Rename to array of servers[{url}] (in swagger_helper.rb)')

        swagger_doc[:servers] = { urls: [] }
        swagger_doc[:schemes].each do |scheme|
          swagger_doc[:servers][:urls] << scheme + '://' + swagger_doc[:host] + swagger_doc[:basePath]
        end

        swagger_doc.delete(:schemes)
        swagger_doc.delete(:host)
        swagger_doc.delete(:basePath)
      end

      def upgrade_oauth!(swagger_doc)
        # find flow in securitySchemes (securityDefinitions will have been re-written)
        schemes = swagger_doc.dig(:components, :securitySchemes)
        return unless schemes&.any? { |_k, v| v.key?(:flow) }

        schemes.each do |name, v|
          next unless v.key?(:flow)

          ActiveSupport::Deprecation.warn("Rswag::Specs: WARNING: securityDefinitions flow is replaced in OpenAPI3! Rename to components/securitySchemes/#{name}/flows[] (in swagger_helper.rb)")
          flow = swagger_doc[:components][:securitySchemes][name].delete(:flow).to_s
          if flow == 'accessCode'
            ActiveSupport::Deprecation.warn("Rswag::Specs: WARNING: securityDefinitions accessCode is replaced in OpenAPI3! Rename to clientCredentials (in swagger_helper.rb)")
            flow = 'authorizationCode'
          end
          if flow == 'application'
            ActiveSupport::Deprecation.warn("Rswag::Specs: WARNING: securityDefinitions application is replaced in OpenAPI3! Rename to authorizationCode (in swagger_helper.rb)")
            flow = 'clientCredentials'
          end
          flow_elements = swagger_doc[:components][:securitySchemes][name].except(:type).each_with_object({}) do |(k, _v), a|
            a[k] = swagger_doc[:components][:securitySchemes][name].delete(k)
          end
          swagger_doc[:components][:securitySchemes][name].merge!(flows: { flow => flow_elements })
        end
      end

      def remove_invalid_operation_keys!(value)
        return unless value.is_a?(Hash)

        value.delete(:consumes) if value[:consumes]
        value.delete(:produces) if value[:produces]
        value.delete(:request_examples) if value[:request_examples]
        value[:parameters].each { |p| p.delete(:getter) } if value[:parameters]
      end
    end
  end
end
