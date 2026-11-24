# frozen_string_literal: true

module Guide
  # The help assistant's window onto a dealer's records (E118): every read
  # tool the Claude connector has, run in the app as the person asking, with
  # their permissions and locations (Guide::AppContext).
  #
  # Only tools marked read_only! are offered. A write tool can never appear:
  # the list is built from McpController::READ_TOOLS and filtered again on the
  # read-only hint (spec/services/guide/look_up_spec.rb).
  #
  # When a module gets connector read tools, help can use them on the next
  # deploy with no change here.
  class LookUp
    def self.tools
      @tools ||= McpController::READ_TOOLS.select do |tool|
        hint = tool.annotations_value&.read_only_hint
        hint == true && !tool.write_tool?
      end.index_by(&:name_value).freeze
    end

    # One line per tool for the look_up description: name(arguments): what it does.
    def self.catalog
      @catalog ||= tools.map do |name, tool|
        props = tool.input_schema_value.to_h[:properties] || {}
        first = tool.description_value.to_s.split(/(?<=\.)\s/).first.to_s.first(220)
        "- #{name}(#{props.keys.join(', ')}): #{first}"
      end.join("\n").freeze
    end

    def initialize(ctx)
      @ctx = ctx
    end

    def call(name, arguments)
      tool = self.class.tools[name.to_s]
      return { error: "No lookup called #{name}. Use one of the listed tools." } unless tool

      allowed = (tool.input_schema_value.to_h[:properties] || {}).keys.map(&:to_s)
      args = (arguments.is_a?(Hash) ? arguments : {}).slice(*allowed).transform_keys(&:to_sym)
      @ctx.check_read_budget!
      result = tool.send(:with_current, @ctx) { tool.perform(@ctx, **args) }
      result = McpTools::Base::Result.new(payload: result, count: 0) unless result.is_a?(McpTools::Base::Result)
      @ctx.used!(result.count)
      Guide::Fit.call(result.payload)
    rescue McpTools::Denied => e
      { not_allowed: e.message }
    rescue McpTools::UserError, ArgumentError => e
      { error: e.message.first(300) }
    rescue ActiveRecord::RecordNotFound
      { error: 'No record with that id that you have access to.' }
    end
  end
end
