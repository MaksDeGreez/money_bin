# The tools of the MCP server (McpServer, docs/decisions/0008-mcp-server.md). Each one is a thin adapter
# over a query object of app/queries/, the same one the REST API calls, so the two interfaces cannot
# disagree about a number: it checks its arguments with QueryArguments, runs the query, and answers with
# the REST endpoint's JSON as `structuredContent` plus a short text for people and models to read.
#
# A new tool goes in ALL; test/integration/mcp_server_test.rb then fails until it has a description, the
# read-only annotations, a happy path, an argument error and a comparison with its REST endpoint.
module McpTools
  # Every tool, in the order tools/list shows them.
  def self.all
    [ SpendingSummary, SearchTransactions, ListCategories, ListAccounts, RecentReceipts, GetReceipt ]
  end

  # The JSON Schema (2020-12) of a component of docs/openapi.yaml, for a tool's outputSchema: the
  # structured content of each tool is the JSON of its REST endpoint, so the document that describes one
  # describes the other. OpenAPI 3.0 writes a value that may be null as `nullable: true`, JSON Schema as a
  # type list, and refers to components where JSON Schema refers to `$defs`; both are converted here.
  # `example` (an OpenAPI keyword) is dropped.
  module OutputSchema
    DOCUMENT_PATH = Rails.root.join("docs/openapi.yaml")
    REF_PREFIX = "#/components/schemas/".freeze

    module_function

    def of(component)
      components = YAML.load_file(DOCUMENT_PATH).dig("components", "schemas")
      defs = {}
      root = convert(components.fetch(component), components, defs)
      defs.empty? ? root : root.merge("$defs" => defs)
    end

    def convert(node, components, defs)
      case node
      when Array then node.map { |item| convert(item, components, defs) }
      when Hash
        if (ref = node["$ref"])
          name = ref.delete_prefix(REF_PREFIX)
          unless defs.key?(name)
            defs[name] = {} # claimed first, so a component that refers to itself stops here
            defs[name] = convert(components.fetch(name), components, defs)
          end
          return { "$ref" => "#/$defs/#{name}" }
        end

        node.except("nullable", "example").to_h { |key, value| [ key, convert(value, components, defs) ] }.tap do |schema|
          schema["type"] = [ schema["type"], "null" ] if node["nullable"] && schema["type"].is_a?(String)
        end
      else node
      end
    end
  end
end
