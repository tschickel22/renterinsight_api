# frozen_string_literal: true

module McpTools
  # Validation shared by the write tools, so an AI cannot invent a status,
  # a stage or an assignee the app itself would not offer.
  module WriteHelpers
    module_function

    def lead_status!(ctx, status)
      statuses = ctx.company.lead_statuses.active
      if status.blank?
        return statuses.ordered.first&.key || 'new'
      end

      key = status.to_s.strip
      return key if statuses.none? && key.length <= 50
      return key if statuses.exists?(key: key)

      raise UserError, "Unknown lead status #{key.inspect}. Valid: #{statuses.ordered.pluck(:key).join(', ')}."
    end

    def assignable_user!(ctx, user_id)
      user = ctx.company.users.active.find_by(id: user_id)
      raise UserError, "No active user #{user_id} in this company. See get_reference_data." unless user

      user
    end

    # CLAUDE.md, WRITING STYLE: no em or en dashes in anything a dealer's
    # customer reads. Refused rather than rewritten, so the AI rewrites it in
    # its own words instead of us mangling punctuation.
    def no_dashes!(*texts)
      return unless texts.flatten.compact.any? { |t| t.to_s.match?(/[\u2013\u2014]/) }

      raise UserError, 'Customer-facing text must not use em dashes or en dashes. Rewrite it with a period, ' \
                       'comma, colon or parentheses and try again.'
    end

    def entity_resource(type)
      { 'lead' => 'leads', 'contact' => 'crm', 'account' => 'crm', 'deal' => 'deals',
        'unit' => 'inventory', 'ticket' => 'service', 'quote' => 'finance' }.fetch(type)
    end

    # Note.entity_type uses the app's own names.
    def note_entity_type(type)
      { 'unit' => 'vehicle', 'ticket' => 'service_ticket' }.fetch(type, type)
    end
  end
end
