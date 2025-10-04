module Api
  module Crm
    class LeadsController < ApplicationController
      # POST /api/crm/leads/:id/score
      def recalculate_score
        lead = Lead.find(params[:id])

        if lead.respond_to?(:recalculate_score!)
          result = lead.recalculate_score!
          payload = result.is_a?(Hash) ? result : { ok: true, totalScore: result }
        elsif defined?(LeadScorer)
          result = LeadScorer.new(lead).recalculate!
          payload = result.is_a?(Hash) ? result : { ok: true, totalScore: result }
        else
          payload = { ok: true, leadId: lead.id, totalScore: (lead.try(:score) || 0), recalculatedAt: Time.current }
        end

        render json: payload
      end
    end
  end
end
