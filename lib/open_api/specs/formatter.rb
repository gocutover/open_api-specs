# frozen_string_literal: true

require 'active_support/core_ext/hash/deep_merge'

require 'rspec'
require 'rswag/specs/swagger_formatter'

module OpenApi
  module Specs
    class Formatter < ::Rswag::Specs::SwaggerFormatter
      # rubocop:disable all
      def metadata_to_swagger(metadata)
        response_code = metadata[:response][:code]
        response = metadata[:response].reject { |k, _v| k == :code }

        # need to merge in to response
        (response.delete(:examples) || {}).each do |content_type, examples|
          new_examples = examples.each_with_object({}) do |(description, value), hash|
            hash[description.parameterize(separator: '_')] = {
              summary: description,
              value: value.dup
            }
          end

          new_hash = {}
          schema = response.dig(:content, content_type, :schema)
          new_hash[:schema] = schema unless schema.blank?
          new_hash[:examples] = new_examples unless new_examples.blank?

          unless new_hash.empty?
            response[:content] ||= {}
            response[:content][content_type] = new_hash
          end
        end

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
      # rubocop:enable all
    end
  end
end
