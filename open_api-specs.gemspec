# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = 'open_api-specs'
  spec.version = '0.0.0'

  spec.summary = 'Wrapper around RSwag to implement specs in a more document first approach.'
  spec.required_ruby_version = '>= 3.0.0'
  spec.authors = ['Zachary Powell']

  spec.files = Dir['lib/**/*']
  spec.require_paths = ['lib']

  spec.add_dependency 'rspec', '>= 3.0.0'
  spec.add_dependency 'open_api-schema_validator', '~> 0.2.0'
  spec.add_dependency 'rswag', '2.12.0'
end
