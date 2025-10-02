module Api
  module Crm
    class LeadScoresController < ApplicationController
      def show
        lead = Lead.find(params[:lead_id] || params[:id])
        score = LeadScore.find_by(lead: lead)
        
        if score
          render json: score_json(score)
        else
          render json: { score: 0, factors: [] }
        end
      end

      def calculate
        lead = Lead.find(params[:lead_id] || params[:id])
        score = LeadScore.calculate_for_lead(lead)
        
        render json: score_json(score)
      end

      private

      def score_json(score)
        {
          leadId: score.lead_id,
          totalScore: score.total_score,
          demographicScore: score.demographic_score,
          behaviorScore: score.behavior_score,
          engagementScore: score.engagement_score,
          lastCalculated: score.last_calculated,
          factors: score.factors
        }.compact
      end
    end
  end
end
