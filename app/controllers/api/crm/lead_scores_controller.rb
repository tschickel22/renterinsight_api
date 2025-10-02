module Api
  module Crm
    class LeadScoresController < ApplicationController
      # GET /api/crm/leads/:lead_id/score
      def show
        lead  = find_lead
        score = LeadScore.find_by(lead: lead)

        if score
          render json: render_json(score)
        else
          render json: {
            leadId: lead.id,
            totalScore: 0,
            demographicScore: 0,
            behaviorScore: 0,
            engagementScore: 0,
            factors: [],
            lastCalculated: nil
          }
        end
      end

      # POST /api/crm/leads/:lead_id/score/calculate
      def calculate
        lead  = find_lead
        score = LeadScore.find_or_initialize_by(lead: lead)

        # Lightweight calc compatible with your current schema
        total   = 0
        factors = []

        if lead.email.present?
          total += 10
          factors << { factor: 'has_email', points: 10, reason: 'Contact email provided' }
        end

        if lead.phone.present?
          total += 10
          factors << { factor: 'has_phone', points: 10, reason: 'Contact phone provided' }
        end

        activity_count = Activity.where(lead_id: lead.id).count
        if activity_count > 5
          total += 20
          factors << { factor: 'high_activity', points: 20, reason: "#{activity_count} activities logged" }
        elsif activity_count > 0
          total += 10
          factors << { factor: 'some_activity', points: 10, reason: "#{activity_count} activities logged" }
        end

        email_opens  = CommunicationLog.where(lead_id: lead.id, comm_type: 'email', status: 'opened').count
        email_clicks = CommunicationLog.where(lead_id: lead.id, comm_type: 'email', status: 'clicked').count
        if email_clicks > 0
          total += 15
          factors << { factor: 'email_clicks', points: 15, reason: "Clicked #{email_clicks} email(s)" }
        elsif email_opens > 0
          total += 10
          factors << { factor: 'email_opens', points: 10, reason: "Opened #{email_opens} email(s)" }
        end

        score.score  = total
        score.reason = factors.to_json
        score.save!

        render json: render_json(score, factors:)
      end

      private

      def find_lead
        Lead.find(params[:lead_id] || params[:id])
      end

      def render_json(score, factors: nil)
        parsed = factors || (JSON.parse(score.reason.presence || '[]') rescue [])
        {
          leadId: score.lead_id,
          totalScore: score.score,
          demographicScore: nil,
          behaviorScore: nil,
          engagementScore: nil,
          factors: parsed,
          lastCalculated: score.updated_at
        }
      end
    end
  end
end
