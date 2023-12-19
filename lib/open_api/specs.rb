# frozen_string_literal: true

require 'rswag/specs'

module OpenApi
  module Specs
    # YAML compilation/parsing
    autoload :Compiler, 'open_api/specs/compiler'
    autoload :OperationTemplate, 'open_api/specs/operation_template'
    autoload :Versions, 'open_api/specs/versions'

    # RSpec modules
    autoload :ContextMethods, 'open_api/specs/context_methods'
    autoload :ExampleContextMethods, 'open_api/specs/example_context_methods'
    autoload :ExampleMethods, 'open_api/specs/example_methods'
    autoload :Formatter, 'open_api/specs/formatter'

    def self.init!
      require_relative './specs/rswag'

      ::RSpec.configure do |config|
        config.extend Rswag::Specs::ExampleGroupRequestHelpers
        config.extend ContextMethods
        config.extend ExampleContextMethods
        config.include ExampleMethods

        config.add_setting :open_api_example_cleaner
        config.swagger_dry_run = false
      end
    end
  end
end
