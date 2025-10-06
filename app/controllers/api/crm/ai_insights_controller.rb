module Api
  module Crm
    class AiInsightsController < ApplicationController
      before_action :set_lead, only: [:index, :generate]

      def index
        insights = @lead.ai_insights.recent
        render json: insights.map { |i| insight_json(i) }
      end

      def generate
        # Simple rule-based insights (can be replaced with actual AI later)
        insights = generate_insights_for_lead(@lead)
        
        render json: insights.map { |i| insight_json(i) }
      end

      def mark_read
        insight = AiInsight.find(params[:id])
        insight.mark_as_read!
        render json: insight_json(insight)
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id] || params[:id])
      end

      def generate_insights_for_lead(lead)
        insights = []
        
        # Check for recent activity
        recent_activities = Activity.where(lead_id: lead.id).where('created_at > ?', 7.days.ago).count
        if recent_activities == 0
          insights << lead.ai_insights.create!(
            insight_type: 'next_action',
            title: 'No recent activity',
            description: 'This lead has not been contacted in over 7 days. Consider reaching out.',
            confidence: 85,
            actionable: true,
            suggested_actions: [
              'Send a follow-up email',
              'Schedule a phone call',
              'Check if lead is still interested'
            ],
            generated_at: Time.current
          )
        end
        
        # Check email engagement
        email_opens = CommunicationLog.where(lead_id: lead.id, comm_type: 'email', status: 'opened').count
        if email_opens > 3
          insights << lead.ai_insights.create!(
            insight_type: 'communication_style',
            title: 'High email engagement',
            description: "This lead has opened #{email_opens} emails. They are engaged via email.",
            confidence: 90,
            actionable: true,
            suggested_actions: [
              'Continue email communication',
              'Share product information via email',
              'Send personalized follow-up'
            ],
            generated_at: Time.current
          )
        end
        
        # Check for positive outcomes
        positive_count = Activity.where(lead_id: lead.id, outcome: 'positive').count
        if positive_count >= 2
          insights << lead.ai_insights.create!(
            insight_type: 'risk_assessment',
            title: 'High conversion potential',
            description: "#{positive_count} positive interactions recorded. This lead shows strong interest.",
            confidence: 88,
            actionable: true,
            suggested_actions: [
              'Move to qualified status',
              'Schedule product demo',
              'Prepare proposal'
            ],
            generated_at: Time.current
          )
        end
        
        # Timing insight based on activity patterns
        last_activity = Activity.where(lead_id: lead.id).order(created_at: :desc).first
        if last_activity
          hour = last_activity.created_at.hour
          if hour >= 14 && hour <= 16
            insights << lead.ai_insights.create!(
              insight_type: 'timing',
              title: 'Best contact time: Afternoon',
              description: 'Based on past interactions, this lead is most responsive between 2-4 PM.',
              confidence: 75,
              actionable: true,
              suggested_actions: [
                'Schedule next call for 2-4 PM',
                'Send emails in early afternoon'
              ],
              generated_at: Time.current
            )
          end
        end
        
        insights
      end

      def insight_json(insight)
        {
          id: insight.id,
          leadId: insight.lead_id,
          type: insight.insight_type,
          title: insight.title,
          description: insight.description,
          confidence: insight.confidence,
          actionable: insight.actionable,
          suggestedActions: insight.suggested_actions,
          metadata: insight.metadata,
          generatedAt: insight.generated_at,
          isRead: insight.is_read,
          createdAt: insight.created_at,
          updatedAt: insight.updated_at
        }.compact
      end
    end
  end
end
