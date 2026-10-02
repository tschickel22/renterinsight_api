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

      def write_tool?
        @write_tool == true
      end

      # destructive: true for anything that changes or replaces existing data
      # (MCP: destructiveHint false promises the tool only ADDS). open_world:
      # true when it reaches people outside the system (sends messages).
      # Directory review checks these, so they must be honest.
      def writes!(destructive:, open_world: false)
        @write_tool = true
        required_scope 'mcp:write'
        annotations(read_only_hint: false, destructive_hint: destructive, idempotent_hint: false,
                    open_world_hint: open_world)
        security_schemes!('mcp:write')
      end

      # Every tool's annotations carry its title too: the Claude directory
      # checks for a title, and some clients only read the annotation's.
      def annotations_value
        base = super
        return base if base.nil? || base.title.present? || title_value.blank?

        MCP::Tool::Annotations.new(title: title_value, read_only_hint: base.read_only_hint,
                                   destructive_hint: base.destructive_hint, idempotent_hint: base.idempotent_hint,
                                   open_world_hint: base.open_world_hint)
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
        limit_reached = nil

        begin
          ctx.require_scope!(required_scope)
          ctx.check_change_limit! if write_tool?
          result = with_current(ctx) { perform(ctx, **args) }
          result = Result.new(payload: result, count: 0) unless result.is_a?(Result)
          status = 'ok'
          count = result.count
          payload = with_undo_hint(ctx, result.payload)
          MCP::Tool::Response.new([{ type: 'text', text: JSON.generate(payload) }],
                                  structured_content: payload)
        rescue Denied => e
          limit_reached = { LimitReached => :records, ChangeLimitReached => :changes }[e.class]
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

      # The connector cannot undo its own changes; a person does that in the
      # app. Said on every write that recorded a change, because the moment
      # someone saves a draft is when they want to know how to discard it.
      def with_undo_hint(ctx, payload)
        return payload unless write_tool? && ctx.pending_changes.any? && payload.is_a?(Hash)

        app = Brand.current(company: ctx.company).name
        text = "You (or an admin) can undo this change in #{app} under Settings, Integrations, AI Apps: " \
               "#{ctx.app_url('/settings?tab=ai-apps')}"
        payload.keys.first.is_a?(String) ? payload.merge('undo' => text) : payload.merge(undo: text)
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
