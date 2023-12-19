# OpenApi::Specs

## Introduction

Leverages RSwag to generate OpenAPI documentation from specs, but taking a hybrid apporach where
specs are defined in YAML format with a similar structure to OpenAPI.

The rational here is that yml files are more structured and can be compared across versions.

A future version of this gem will go futher start from a completely documentation first approach
of generation the OpenAPI document and wiring it into with 'x-spec' directives.

## Examples

Given a file `spec/api/resources/get.yml`:

```yaml
# Static OpenAPI:
id: Resources::Api
summary: Get a Resource
tags: Resource
description: get a Resource from API

parameters:
  - name: id
    in: :path
    required: true

# Dynamic RSpec
let:
  id: :resource_id
  current_user: :known_user

before:
  - :login_user
after:
  - :log_out_user

# focus: true

responses:
  -
    description: 'Returns Resource'
    status: '200'
    schema: resource
    focus: true
  -
    status: '401'
    let:
      current_user: :unknown_user
    after:
      - :validate_error_message
    schema: unauthorized # expanded out to '$ref' => '#/components/responses/unauthorized'
```

and a spec file:

```ruby

require 'api_helper'

RSpec.describe Resources::Api, type: :request do
  let(:known_user) { mock_user(:admin) }
  let(:unknown_user) { mock_user(:no_permissions) }
  let(:resource_id) { mock_resource.id }

  has_api_docs('/resources/get', custom_meta: 1)

  private

  def login_user
    # do stuff
  end

  def log_out_user
    # do stuff
  end

  def validate_error_message
    expect(response.body).to include('User unauthorized')
  end
end

```

These files will generate the spec blocks for:

```ruby

# ContextMethods#has_api_docs:
describe 'Resources::Api', api_doc: true, custom_meta: 1 do
  # uses ContextMethods#run_versions if there are multiple, each do:

  # ContextMethods#run_version produces:
  describe 'version: draft' do
    # ContextMethods#run_operation produces:

    # #apply_template_to_open_api applies RSwag Methods:
    produces 'application/json'   # only option currently
    consumes 'application/json'   # only option currently
    operationId 'Resources::Api'
    summary 'Get a Resource'
    tags ['Resource']
    request_json_body {}          # from request_body: in POST/PATCH examples

    # #apply_let_blocks
    let(:id) { send(:resource_id) }
    let(:current_user) { send(:known_user) }

    # #apply_filter_blocks(:before)
    before do
      [:login_current_user].each(&method(:send))
    end

    # #apply_filter_blocks(:after)
    after do
      [:log_out_user].each(&method(:send))
    end

    # ExampleContextMethods#run_example produces:
    describe '200 - Returns Resource', focus: true do
      it 'validated' do
        # ExampleMethods#process_example - hooks into RSwag to run and validate the example,
        # builds meta for OpenApiFormatter:
        process_example
      end
    end

    describe '401' do
      let(:current_user) { send(:unknown_user)  }
      after do
        send(:validate_error_message)
      end
      it 'validated' { process_example }
    end
  end
end
```