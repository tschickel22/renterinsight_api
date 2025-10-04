module Api
  module Crm
    module LeadJsonHelper
      def lead_with_tags_json(lead)
        tags = Tag
          .joins("INNER JOIN tag_assignments ON tag_assignments.tag_id = tags.id")
          .where("tag_assignments.entity_type=? AND tag_assignments.entity_id=?", 'Lead', lead.id)
          .order('tags.name ASC')

        tag_arr = tags.map do |t|
          {
            id: t.id, name: t.name,
            color: t.try(:color), category: t.try(:category), type: t.try(:tag_type),
            isSystem: t.try(:is_system), isActive: t.try(:is_active)
          }.compact
        end

        base = lead.as_json
        base.merge(tags: tag_arr)
            .merge(lead: base.merge(tags: tag_arr))
            .merge(data: base.merge(tags: tag_arr))
      end
    end
  end
end
