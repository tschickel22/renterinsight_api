module Api
  module Crm
    class LeadScoresController < ApplicationController
      include RbacAuthorization
      rbac_resource :crm, read_actions: [:show], update_actions: [:calculate]

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
        email_opens  = CommunicationLog.where(lead_id: @lead.id, comm_type: 'email', status: 'opened').count
        email_clicks = CommunicationLog.where(lead_id: @lead.id, comm_type: 'email', status: 'clicked').count
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

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [LeadScoresController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [LeadScoresController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [LeadScoresController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [LeadScoresController] Company scope set: #{@company.name} (ID: #{@company.id})"
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
