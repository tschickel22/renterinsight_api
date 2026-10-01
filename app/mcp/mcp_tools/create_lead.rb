# frozen_string_literal: true

module McpTools
  class CreateLead < Base
    tool_name 'create_lead'
    title 'Create a lead'
    description 'Create a new lead. Refuses a second open lead with the same email (and returns the existing ' \
                'one). Owner defaults to the signed-in user and location to their first location. Confirm the ' \
                'details with the user before calling.'
    input_schema(
      properties: {
        first_name: { type: 'string' }, last_name: { type: 'string' },
        email: { type: 'string' }, phone: { type: 'string' },
        status: { type: 'string', description: 'A lead status key from get_reference_data' },
        owner_user_id: { type: 'integer' }, location_id: { type: 'integer' },
        notes: { type: 'string', description: 'What they are looking for, how they found you' }
      },
      required: %w[first_name]
    )
    writes!

    def self.perform(ctx, first_name:, last_name: nil, email: nil, phone: nil, status: nil, owner_user_id: nil,
                     location_id: nil, notes: nil)
      ctx.authorize!('leads', 'create')
      raise UserError, 'Give an email or a phone number so someone can follow up.' if email.blank? && phone.blank?

      company = ctx.company
      if email.present?
        # Same company-wide block as the app, but only name the existing lead
        # when this user can see it, so the check cannot reveal who is a lead
        # at a location they have no access to.
        dup = company.leads.where(is_converted: [false, nil]).where('LOWER(email) = ?', email.strip.downcase)
        if dup.exists?
          visible = ctx.can?('leads', 'read') ? Records.new(ctx).scope('lead').merge(dup).first : nil
          raise UserError, 'A lead with that email already exists.' unless visible

          raise UserError, "A lead with that email already exists: lead:#{visible.id} " \
                           "(#{[visible.first_name, visible.last_name].compact_blank.join(' ')})."
        end
      end

      status_key = WriteHelpers.lead_status!(ctx, status)
      owner_id = owner_user_id.present? ? WriteHelpers.assignable_user!(ctx, owner_user_id).id : ctx.user.id
      if location_id.present?
        raise Denied, 'You do not have access to that location.' unless ctx.location_allowed?(location_id)
      end

      lead = company.leads.create!(
        first_name: first_name.strip, last_name: last_name&.strip, email: email&.strip, phone: phone&.strip,
        status: status_key, owner_id: owner_id, location_id: location_id.presence || ctx.default_location_id,
        notes: notes, origin: 'ai_connector'
      )
      ctx.record_change(action: 'created', record: lead, after: Undo.lead_snapshot(lead))
      records = Records.new(ctx)
      Base::Result.new(payload: { created: records.summary('lead', lead) }, count: 1)
    end
  end
end
