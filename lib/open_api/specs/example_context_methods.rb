# frozen_string_literal: true

# frozen_string_literal: true

module OpenApi
  module Specs
    # Builds examples based on the `responses:` block in the yaml
    module ExampleContextMethods
      private

      # @example
      #   responses:
      #    -
      #     status: '200'
      #     description: 'OK returns Resource'
      #     schema: resource
      #     headers: ...
      #     let:
      #       resource_id: :other_resource_id
      #
      #   describe('200 - OK returns Resource') do
      #     schema do
      #       { '$ref' => '#/components/responses/resource' }
      #     end
      #
      #     headers { ... }
      #     let(:resource_id) { send(:other_resource_id) }
      #     before { ... }
      #     after { ... }
      #
      #     it('validated') do
      #       process_example # in example_methods.rb
      #     end
      #   end
      #
      def run_example(config)
        description = [config[:status], config[:description]].reject(&:blank?).join(' - ')
        # response is an rswag method
        response(config[:status], description, config[:metadata]) do
          %i[schema headers lets befores afters].each { |meth| send("#{meth}_for", config) }

          description = config[:example_description]
          description ||= config[:master_example] ? 'validated' : 'documented'
          meta = config.slice(:focus, :skip, :master_example, :example_description, :'core-version')

          it description, meta do |example|
            process_example(config, example)
          end
        end
      end

      def schema_for(config)
        schema config[:schema] || {}
      end

      def befores_for(config)
        return if config[:before].blank?

        before do
          config[:before].each { |statement| lookup_value(statement) }
        end
      end

      def afters_for(config)
        return if config[:after].blank?

        after do
          config[:after].each { |statement| lookup_value(statement) }
        end
      end

      def headers_for(config)
        config[:headers].each do |key, value|
          let(key) { value }
        end
      end

      def lets_for(config)
        config[:let].merge(config[:params]).each do |key, value|
          let(key) { lookup_value(value) }
        end
      end
    end
  end
end
