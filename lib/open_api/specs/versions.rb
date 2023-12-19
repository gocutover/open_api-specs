# frozen_string_literal: true

module OpenApi
  module Specs
    #
    # Handles yaml files in {ROOT_PATH}, deep mergeing and grouping them by version number.
    #
    class Versions
      DRAFT = 'draft'
      DRAFT_ONLY = true
      ROOT_PATH = './spec/api'
      PREFIX = '/api'

      OPERATION_REGEXP = %r{/(get|post|patch|put|delete)}.freeze # contains /get /post etc
      OPERATION_VERSION_REGEXP = %r{(.+)(/[\d\.]*){0,1}\.yml}.freeze # get/20201101.yml
      VERSIONED_EXT_REGEXP = %r{(.+)(/[\d\.]*){1}\.yml}.freeze

      class << self
        # Find a range from context metadata.
        # eg, an operation can begin to be documented (after: '1.0', until: '2.5')
        def find_range(metadata)
          if metadata[:draft] || DRAFT_ONLY
            [DRAFT]
          else
            range(metadata[:after], metadata[:until]).reverse
          end
        end

        # Latest version (not including 'draft')
        def latest
          versions[-2]
        end

        # operation(after: 1, until: 3) means the operation will only test against version 2 and 3
        # it uses 'after' syntax father than 'from' as when you won't know the version number
        # while writing the code (as they're date based)
        #
        # @example
        #   [1,2,3]
        #   range(0, 3) => [1,2,3]
        #   range(1, 3) => [2,3]
        #   range(1,4) => [2,3]
        def range(include_after, include_until)
          i ||= (versions.index(include_after) || -1) + 1
          j = versions.index(include_until) || -1
          versions[i..j]
        end

        # List all versions
        # @todo need handle sorting by semvar, this was based on yyyymmddd versioning.
        # @return [Array] [..., 'draft']
        def versions
          @versions ||= (yamls.values.map(&:keys).flatten + [DRAFT]).uniq.sort
        end

        # Get the template for a specific version and operation
        #
        # @param [String] operation, eg '/api/endpoint/get'
        # @param [String] version '1.0' or 'draft'
        # @return [Hash]
        def template_for(operation, version)
          operation = PREFIX + operation unless operation.start_with?(PREFIX)

          versions = yamls[operation] || raise(operation_not_found_error(operation, version))
          possible = [version, DRAFT].uniq
          versions.slice(*possible).values.first
        end

        # Initial compiled document including all static openapi data from /_openapi/
        # @param [String]
        # @return [Hash]
        def static_docs_for(version)
          @static_docs ||= {}
          @static_docs[version] ||= begin
            files = static_files_for(version)
            { info: { version: version } }.deep_merge Compiler.new(files).call
          end
        end

        private

        # @example
        #   extract_operation_version('/api/endpoint/method.yml')
        #   => ['/api/endpoint/method', 'draft']
        # @example
        #   extract_operation_version('/api/endpoint/method/20190101.yml')
        #   => ['/api/endpoint/method', '20190101']
        def extract_operation_version(operation_path)
          path, version = operation_path.sub(ROOT_PATH, PREFIX).match(OPERATION_VERSION_REGEXP)[1..2]
          version = (version.presence || DRAFT).sub('/', '')
          [path, version]
        end

        # Hash of all files by operation, indexed by version
        # @return [Hash] { '/api/endpoint/method' => { '1.0' => yml, '2.0' => 'yml' } }
        def yamls
          @yamls ||= begin
            paths = Dir["#{ROOT_PATH}/**/*.yml"]
            paths.each_with_object({}) do |operation, hash|
              next unless operation.match(OPERATION_REGEXP)

              op, api_version = extract_operation_version(operation)
              hash[op] ||= {}
              hash[op][api_version] = load_yaml(operation)
            end
          end
        end

        # @param operation [String] eg '/api/endpoint/get'
        # @return [Hash]
        def load_yaml(operation)
          yaml = File.open(operation).read

          raise "$ref:'...' should be $ref: '...' (note the space)" if yaml.include?("$ref:'")

          hash = YAML.load(yaml) # rubocop:disable Security/YAMLLoad performance
          raise "#{operation} missing or empty" unless hash.is_a?(Hash)

          hash.deep_symbolize_keys
        rescue Psych::BadAlias, Psych::SyntaxError => e
          puts operation
          puts_lines yaml
          raise e
        end

        # output combined yaml with line numbers for debugging purposes.
        def puts_lines(yaml)
          yaml.each_line.with_index do |line, index|
            puts "#{index + 1}: #{line}"
          end
        end

        # returns only the shared files for the specified version
        # @return [Array]
        def static_files_for(version)
          path = "#{ROOT_PATH}/**/*.yml"
          path = path.sub('.yml', "/#{version}.yml") unless version == DRAFT

          files = Dir[path].reject { |f| f =~ OPERATION_REGEXP }
          files = files.reject { |p| p.match(VERSIONED_EXT_REGEXP) } if version == DRAFT
          files.sort_by { |f| [f.match?(/index/) ? 0 : 1, f] }
        end

        def operation_not_found_error(operation, version)
          "Could not find #{operation.split('/').last}.yml "\
          "in the spec directory #{operation.split('/')[0...-1].join('/')}. "\
          "Have you defined it? \n\n"\
          "#{operation} #{version} not found: #{yamls.keys}."
        end
      end
    end
  end
end
