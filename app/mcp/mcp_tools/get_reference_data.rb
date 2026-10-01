# frozen_string_literal: true

module McpTools
  # The vocabulary the other tools take: status keys, stage keys, who can be
  # assigned work and which locations exist for this user.
  class GetReferenceData < Base
    tool_name 'get_reference_data'
    title 'Statuses, stages, people and locations'
    description 'Who the signed-in user is, plus the lead status keys, deal pipeline stage keys, the active ' \
                'users work can be assigned to, and the locations this user can see. Call this before ' \
                'filtering by status or stage, or assigning work.'
    input_schema(properties: {})
    read_only!

    def self.perform(ctx)
      company = ctx.company
      locations = company.locations.active
      locations = locations.where(id: ctx.location_ids) unless ctx.location_ids.nil?

      {
        you: { id: ctx.user.id, name: ctx.user.full_name, company: company.name },
        lead_statuses: company.lead_statuses.active.ordered.map do |s|
          { key: s.key, label: s.label, closed: s.is_excluded }
        end,
        deal_stages: company.pipeline_stages.map do |s|
          key = (s['key'] || s[:key]).to_s.downcase
          { key: key, label: s['name'] || s[:name], probability: company.pipeline_stage_probability(key) }
        end,
        users: company.users.active.order(:first_name, :last_name).limit(200).map { |u| { id: u.id, name: u.full_name } },
        locations: locations.order(:name).map { |l| { id: l.id, name: l.name } }
      }
    end
  end
end
