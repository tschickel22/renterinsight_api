module Api
  module Crm
    class LeadsController < ApplicationController
      # Re-define show to include tags (non-destructive override)
      def show
        lead = Lead.find(params[:id])

        # Pull tags via TagAssignment
        tags = Tag
          .joins("INNER JOIN tag_assignments ON tag_assignments.tag_id = tags.id")
          .where("tag_assignments.entity_type = ? AND tag_assignments.entity_id = ?", 'Lead', lead.id)
          .order('tags.name ASC')

        render json: lead.as_json.merge(
          tags: tags.map { |t|
            {
              id: t.id,
              name: t.name,
              color: t.try(:color),
              category: t.try(:category),
              type: t.try(:tag_type),
              isSystem: t.try(:is_system),
              isActive: t.try(:is_active)
            }.compact
          }
        )
      end
    end
  end
end
