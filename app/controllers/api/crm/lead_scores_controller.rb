module Api
  module Crm
    class LeadScoresController < ApplicationController
      include RbacAuthorization
      rbac_resource :crm,
                    read_actions:   [:show, :health_score, :score_history],
                    update_actions: [:calculate, :recalculate_health_score]

      before_action :set_company_scope
      before_action :set_lead

      # GET /api/crm/leads/:lead_id/score
      def show
        score = LeadScore.find_by(lead: @lead)

        if score
          render json: render_json(score)
        else
          render json: {
            leadId: @lead.id,
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
        score = LeadScore.find_or_initialize_by(lead: @lead)

        # Lightweight calc compatible with your current schema
        total   = 0
        factors = []

        if @lead.email.present?
          total += 10
          factors << { factor: 'has_email', points: 10, reason: 'Contact email provided' }
        end

        if @lead.phone.present?
          total += 10
          factors << { factor: 'has_phone', points: 10, reason: 'Contact phone provided' }
        end

        # Scope activities to this lead (already tenant-isolated through @lead)
        activity_count = Activity.where(lead_id: @lead.id).count
        if activity_count > 5
          total += 20
          factors << { factor: 'high_activity', points: 20, reason: "#{activity_count} activities logged" }
        elsif activity_count > 0
          total += 10
          factors << { factor: 'some_activity', points: 10, reason: "#{activity_count} activities logged" }
        end

        # Scope communication logs to this lead
        email_opens  = Communication.where(communicable_type: 'Lead', communicable_id: @lead.id, channel: 'email').where.not(read_at: nil).count
        
        if email_opens > 0
          total += 10
          factors << { factor: 'email_opens', points: 10, reason: "Opened #{email_opens} email(s)" }
        end

        score.score  = total
        score.reason = factors.to_json
        score.save!

        render json: render_json(score, factors:)
      end

      # GET /api/crm/leads/:lead_id/health_score
      def health_score
        latest = LeadScore.where(lead_id: @lead.id).order(created_at: :desc).first

        render json: {
          lead_id:    @lead.id,
          score:      @lead.health_score,
          band:       latest&.band,
          breakdown:  latest&.breakdown || {},
          updated_at: @lead.health_score_updated_at
        }
      end

      # POST /api/crm/leads/:lead_id/recalculate_health_score
      def recalculate_health_score
        result = LeadHealthScoreService.new(@lead).save!
        render json: {
          lead_id:    @lead.id,
          score:      result[:score],
          band:       result[:band],
          breakdown:  result[:breakdown],
          updated_at: Time.current
        }
      end

      # GET /api/crm/leads/:lead_id/score_history
      def score_history
        history = LeadScore.where(lead_id: @lead.id).order(created_at: :desc).limit(50)
        render json: history.map { |s|
          {
            id:         s.id,
            score:      s.score,
            band:       s.band,
            reason:     s.reason,
            breakdown:  s.breakdown,
            created_at: s.created_at
          }
        }
      end

      private

      def set_company_scope
        # Use ApplicationController's standard company context (handles platform admin switching)
        super
      end

      def set_lead
        @lead = @company.leads.find_by(id: params[:lead_id] || params[:id])
        unless @lead
          render json: { error: 'Lead not found or access denied' }, status: :not_found
          return
        end
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
