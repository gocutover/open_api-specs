# OpenApi::Specs

## Status

This gem leverages [RSwag](https://github.com/rswag/rswag) to generate OpenAPI documentation from specs, but takes a hybrid apporach where
specs are defined in YAML format first, rather than rspec blocks, with a similar structure to OpenAPI. Essentially it is just using Rswag more as a runner and compliler, than a generator. The rational here is that YAML files are more structured than ruby files and can be compared (diffed) across versions (though in practice, the final OpenAPI file has been suitable for this).

The approach was developed in 2019 (outside of Cutover), first applied to [Core](https://github.com/gocutover/core), then to the [Public Api](https://github.com/gocutover/public-api). The approach works well, but given resource could be evolved based on what we've learnt.

### Pros

- Structured YAML, unlike RSWag, keeps specs focused on the API schema and testing http statuses (rather than functionality).
- Simple to write specs
- Saves real examples to the file (leveraged in the Public API as real mock data)

### Cons

- YAML files are currently a hybrid of static OpenAPI syntax and RSpec modifiers (plus some sugar), which abstracts learning of OpenAPI for new users.
- Because of this, the raw files cannot be used directly with OpenAPI tooling such as [Stoplight Studio](https://github.com/stoplightio/studio)

### Future

The current approach works well for Core where there are extensive `let:` statements and you are testing real functionality in a legacy environment, but for designing new APIs (such as Public API) a more document driven approach would be preferable. A v2.0 of this gem would likely take a raw OpenAPI file, and run it within RSpec, then output a new version of the file with real examples mixed in (if necessary). Effectively a simpler tool that auto generates specs from the document, rather generating documentation from specs (RSWAG). 

To move in this direction, work is being undertaken in the current iteration to move the YAML files closer to compliant OpenAPI. For example, the additional syntax (`let:`, `focus:` etc) should be namespaced within an `x-spec:` object) and the syntax sugar should be replaced with vanilla OpenAPI/JSON Schema. 

Initial tests with Stuoplight Studio, showed it was hard to break the `"paths"` section up into separate files using `$ref`, so there's also a question about navigating one big YAML vs individual files (which helps when working on specs, using `focus: true` etc).

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
