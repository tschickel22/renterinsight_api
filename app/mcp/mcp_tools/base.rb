# frozen_string_literal: true

module McpTools
  # Every DealerTide MCP tool. Subclasses implement `perform(ctx, **args)` and
  # return a Hash (the result) plus, through `count:`, how many records it
  # handed back, which feeds the daily record budget.
  #
  # Tools never call `as_json` on a model. Each serializer names its fields,
  # so a cost or margin column added to a table later cannot leak through.
  class Base < MCP::Tool
    Result = Struct.new(:payload, :count, keyword_init: true)

    class << self
      def required_scope(value = nil)
        value ? @required_scope = value : (@required_scope || 'mcp:read')
      end

      def read_only!
        annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
        security_schemes!('mcp:read')
      end

      def writes!(destructive: false)
        required_scope 'mcp:write'
        annotations(read_only_hint: false, destructive_hint: destructive, idempotent_hint: false, open_world_hint: false)
        security_schemes!('mcp:write')
      end

      # ChatGPT reads a per-tool securitySchemes declaration to know a tool
      # needs the linked account, and which scope. Harmless to other clients.
      def security_schemes!(scope)
        meta({ 'securitySchemes' => [{ 'type' => 'oauth2', 'scopes' => [scope] }] })
      end

      def call(server_context:, **args)
        ctx = server_context.mcp_context
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status = 'error'
        count = nil
        message = nil
        limit_reached = false

        begin
          ctx.require_scope!(required_scope)
          result = with_current(ctx) { perform(ctx, **args) }
          result = Result.new(payload: result, count: 0) unless result.is_a?(Result)
          status = 'ok'
          count = result.count
          MCP::Tool::Response.new([{ type: 'text', text: JSON.generate(result.payload) }],
                                  structured_content: result.payload)
        rescue Denied => e
          limit_reached = e.is_a?(LimitReached)
          status = 'denied'
          message = e.message
          error(e.message)
        rescue UserError, ActiveRecord::RecordInvalid => e
          message = e.message
          error(e.message)
        rescue ActiveRecord::RecordNotFound
          message = 'not found'
          error('No record with that id that you have access to.')
        ensure
          ctx.audit!(tool_name: name_value, arguments: args, status: status, result_count: count,
                     duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
                     error_message: message)
          ctx.grant&.touch_used!
          Alerts.after_call(ctx, status: status, limit_reached: limit_reached) if status == 'denied'
        end
      end

      private

      def error(text)
        MCP::Tool::Response.new([{ type: 'text', text: text }], error: true)
      end

      # Model callbacks (activity logs, notifications, workflow events) read
      # Current.user, so writes made through MCP are attributed to the person
      # exactly as if they had made them in the app.
      def with_current(ctx)
        Current.set(user: ctx.user, original_user: ctx.user, company_id: ctx.company.id,
                    location_id: nil, ip_address: ctx.ip_address) { yield }
      end
    end
  end
end
