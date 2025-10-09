module Api
  module Crm
    class AiInsightsController < ApplicationController
      before_action :set_lead, only: [:index, :generate]

      def index
        insights = @lead.ai_insights.recent
        render json: insights.map { |i| insight_json(i) }
      end

      def generate
        # Delete old insights for this lead to avoid duplicates
        @lead.ai_insights.destroy_all
        
        # Generate new insights - limit to ONE per type to avoid duplicates
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
        insight_types_used = Set.new
        
        # Helper to add insight only if type not already used
        add_insight = lambda do |type, title, description, confidence, actions|
          return if insight_types_used.include?(type)
          insight_types_used.add(type)
          
          insights << lead.ai_insights.create!(
            insight_type: type,
            title: title,
            description: description,
            confidence: confidence,
            actionable: true,
            suggested_actions: actions,
            generated_at: Time.current
          )
        end
        
        # Priority 1: New lead insight (highest priority)
        if lead.created_at > 24.hours.ago
          add_insight.call(
            'next_action',
            'New Lead - Quick Action Recommended',
            'This lead was just added. Respond quickly to increase conversion chances by 3x.',
            95,
            [
              'Send welcome email within 1 hour',
              'Make initial contact call',
              'Add to nurture sequence'
            ]
          )
        end
        
        # Priority 2: Check for recent activity (only if not a new lead)
        if !insight_types_used.include?('next_action')
          recent_activities = Activity.where(lead_id: lead.id).where('created_at > ?', 7.days.ago).count
          if recent_activities == 0 && lead.created_at < 7.days.ago
            add_insight.call(
              'next_action',
              'No recent activity',
              'This lead has not been contacted in over 7 days. Consider reaching out to maintain engagement.',
              85,
              [
                'Send a follow-up email',
                'Schedule a phone call',
                'Check if lead is still interested'
              ]
            )
          end
        end
        
        # Priority 3: Email engagement analysis
        email_logs = CommunicationLog.where(lead_id: lead.id, comm_type: 'email')
        email_count = email_logs.count
        email_opens = email_logs.where(status: 'opened').count
        
        if email_count > 0 && !insight_types_used.include?('communication_style')
          if email_opens > 3
            add_insight.call(
              'communication_style',
              'High email engagement',
              "This lead has opened #{email_opens} out of #{email_count} emails. They are highly engaged via email.",
              90,
              [
                'Continue email communication',
                'Share product information via email',
                'Send personalized follow-up'
              ]
            )
          elsif email_opens == 0 && email_count >= 2
            add_insight.call(
              'communication_style',
              'Low email engagement',
              "This lead has not opened any of #{email_count} emails. Try a different communication channel.",
              80,
              [
                'Try phone call instead',
                'Send SMS message',
                'Check if email address is correct'
              ]
            )
          end
        end
        
        # Priority 4: Activity outcome analysis
        activities = Activity.where(lead_id: lead.id)
        positive_count = activities.where(outcome: 'positive').count
        negative_count = activities.where(outcome: 'negative').count
        
        if !insight_types_used.include?('risk_assessment')
          if positive_count >= 2
            add_insight.call(
              'risk_assessment',
              'High conversion potential',
              "#{positive_count} positive interactions recorded. This lead shows strong interest and is likely to convert.",
              88,
              [
                'Move to qualified status',
                'Schedule product demo',
                'Prepare proposal'
              ]
            )
          elsif negative_count >= 2
            add_insight.call(
              'risk_assessment',
              'Risk of losing lead',
              "#{negative_count} negative interactions recorded. This lead may need a different approach.",
              75,
              [
                'Review previous interactions',
                'Try different value proposition',
                'Consider pausing outreach'
              ]
            )
          end
        end
        
        # Priority 5: Timing insight based on activity patterns
        last_activity = activities.order(created_at: :desc).first
        if last_activity && !insight_types_used.include?('timing')
          hour = last_activity.created_at.hour
          if hour >= 14 && hour <= 16
            add_insight.call(
              'timing',
              'Best contact time: Afternoon',
              'Based on past interactions, this lead is most responsive between 2-4 PM.',
              75,
              [
                'Schedule next call for 2-4 PM',
                'Send emails in early afternoon'
              ]
            )
          elsif hour >= 9 && hour <= 11
            add_insight.call(
              'timing',
              'Best contact time: Morning',
              'Based on past interactions, this lead is most responsive between 9-11 AM.',
              75,
              [
                'Schedule next call for 9-11 AM',
                'Send emails in morning hours'
              ]
            )
          end
        end
        
        # Fallback: ALWAYS provide at least one insight if nothing else matched
        if insights.empty?
          insights << lead.ai_insights.create!(
            insight_type: 'next_action',
            title: 'Build engagement',
            description: 'Start building a relationship with this lead through consistent communication.',
            confidence: 70,
            actionable: true,
            suggested_actions: [
              'Log first activity or interaction',
              'Add lead to nurture sequence',
              'Send introductory email',
              'Schedule follow-up reminder'
            ],
            generated_at: Time.current
          )
        end
        
        insights
      end

      def insight_json(insight)
        {
          id: insight.id,
          lead_id: insight.lead_id,
          type: insight.insight_type,
          title: insight.title,
          description: insight.description,
          confidence: insight.confidence,
          actionable: insight.actionable,
          suggested_actions: insight.suggested_actions,
          metadata: insight.metadata,
          generated_at: insight.generated_at&.iso8601,
          is_read: insight.is_read,
          created_at: insight.created_at&.iso8601,
          updated_at: insight.updated_at&.iso8601
        }.compact
      end
    end
  end
end
