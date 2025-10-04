module Api
  module Crm
    class LeadsController < ApplicationController
      include Api::Crm::LeadJsonHelper

      def show
        lead = Lead.find(params[:id])
        render json: lead_with_tags_json(lead)
      end

      def index
        leads = Lead.order(created_at: :desc).limit(50)
        render json: leads.map { |l| lead_with_tags_json(l) }
      end

      def score
        lead = Lead.find(params[:id])
        payload =
          if lead.respond_to?(:calculate_score)
            lead.calculate_score
          else
            { leadId: lead.id, totalScore: (lead.try(:score) || 0),
              demographicScore: nil, behaviorScore: nil, engagementScore: nil,
              factors: [], lastCalculated: Time.current }
          end
        render json: payload
      end
    end
  end
end
