# frozen_string_literal: true

module McpTools
  class CreateServiceTicket < Base
    tool_name 'create_service_ticket'
    title 'Open a service ticket'
    description 'Open a service ticket, optionally for a contact, account or inventory unit (typed ids). ' \
                'Assigned to the signed-in user unless another user id is given.'
    input_schema(
      properties: {
        title: { type: 'string' },
        description: { type: 'string' },
        priority: { type: 'string', enum: %w[low medium high urgent] },
        customer_id: { type: 'string', description: 'contact:12 or account:5' },
        unit_id: { type: 'string', description: 'unit:118' },
        assigned_to_user_id: { type: 'integer' }
      },
      required: %w[title description]
    )
    writes!

    def self.perform(ctx, title:, description:, priority: 'medium', customer_id: nil, unit_id: nil,
                     assigned_to_user_id: nil)
      ctx.authorize!('service', 'create')
      records = Records.new(ctx)
      attrs = {
        title: title.to_s.strip.first(255), description: description, priority: priority.presence || 'medium',
        status: 'open',
        assigned_to: (assigned_to_user_id.present? ? WriteHelpers.assignable_user!(ctx, assigned_to_user_id).id : ctx.user.id).to_s
      }
      if customer_id.present?
        type, customer = records.find(customer_id)
        raise UserError, 'customer_id must be a contact or an account.' unless %w[contact account].include?(type)

        attrs[:"#{type}_id"] = customer.id
        attrs[:account_id] ||= customer.account_id if type == 'contact'
        attrs[:location_id] = customer.location_id
      end
      if unit_id.present?
        type, unit = records.find(unit_id)
        raise UserError, 'unit_id must be an inventory unit.' unless type == 'unit'

        attrs[:vehicle_id] = unit.id
        attrs[:location_id] ||= unit.location_id
      end
      attrs[:location_id] ||= ctx.default_location_id

      ticket = ctx.company.service_tickets.create!(attrs)
      Base::Result.new(payload: { created: records.summary('ticket', ticket) }, count: 1)
    end
  end
end
