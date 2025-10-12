module Api
  module Crm
    class LeadsController < ApplicationController
      before_action :set_lead, only: [:show, :update, :destroy, :notes, :convert, :score]

      def index
        # Only show non-converted leads
        leads = Lead.where(is_converted: [false, nil])
                    .includes(:source)
                    .order(created_at: :desc)
        
        render json: leads.map { |l| lead_json(l) }
      end

      def show
        render json: lead_json(@lead)
      end

      def create
        l = Lead.new(lead_params)
        l.save!
        render json: lead_json(l), status: :created
      end

      def update
        @lead.update!(lead_params)
        render json: lead_json(@lead)
      end

      def destroy
        @lead.destroy!
        head :no_content
      end

      def notes
        @lead.update!(notes: params[:notes].to_s)
        render json: lead_json(@lead)
      end

      def score
        # Calculate lead score based on various factors
        score_value = calculate_lead_score(@lead)
        
        render json: {
          score: score_value,
          factors: [
            { name: 'Email Engagement', value: @lead.email.present? ? 20 : 0 },
            { name: 'Phone Available', value: @lead.phone.present? ? 15 : 0 },
            { name: 'Source Quality', value: @lead.source_id.present? ? 25 : 0 },
            { name: 'Recent Activity', value: 20 },
            { name: 'Profile Completeness', value: 20 }
          ]
        }
      end

      def convert
        begin
          Rails.logger.info "Starting lead conversion for lead #{params[:id]}"
          
          # Check if already converted
          if @lead.is_converted
            render json: { error: 'Lead has already been converted' }, status: :unprocessable_entity
            return
          end
          
          # Create account with absolutely minimal fields
          account_name = params[:account_name].presence || "#{@lead.first_name} #{@lead.last_name}".strip
          account_name = "Converted Lead #{@lead.id}" if account_name.blank?
          
          Rails.logger.info "Creating account with name: #{account_name}"
          
          account = Account.new(
            name: account_name,
            company_id: @lead.company_id,
            status: 'active'
          )
          
          # Add optional fields if they won't cause validation errors
          account.email = @lead.email if @lead.email.present?
          account.phone = @lead.phone if @lead.phone.present?
          account.source_id = @lead.source_id if @lead.source_id.present?
          account.notes = @lead.notes if @lead.notes.present?
          
          # Try to set account_type if the field exists
          if account.respond_to?(:account_type=)
            account.account_type = 'converted_lead'
          end
          
          # Save the account
          if !account.save
            Rails.logger.error "Account validation failed: #{account.errors.full_messages.join(', ')}"
            render json: { error: "Failed to create account: #{account.errors.full_messages.join(', ')}" }, status: :unprocessable_entity
            return
          end
          
          Rails.logger.info "Account created with ID: #{account.id}"
          
          # Migrate lead activities to account activities
          begin
            if defined?(LeadActivity) && defined?(AccountActivity)
              Rails.logger.info "Starting migration of #{@lead.lead_activities.count} activities"
              
              @lead.lead_activities.each do |lead_activity|
                account_activity = AccountActivity.new(
                  account_id: account.id,
                  user_id: lead_activity.user_id,
                  assigned_to_id: lead_activity.assigned_to_id,
                  activity_type: lead_activity.activity_type,
                  subject: lead_activity.subject,
                  description: lead_activity.description,
                  status: lead_activity.status,
                  priority: lead_activity.priority,
                  due_date: lead_activity.due_date,
                  start_time: lead_activity.start_time,
                  end_time: lead_activity.end_time,
                  duration_minutes: lead_activity.duration_minutes,
                  completed_at: lead_activity.completed_at,
                  call_direction: lead_activity.call_direction,
                  call_outcome: lead_activity.call_outcome,
                  phone_number: lead_activity.phone_number,
                  meeting_location: lead_activity.meeting_location,
                  meeting_link: lead_activity.meeting_link,
                  meeting_attendees: lead_activity.meeting_attendees,
                  reminder_method: lead_activity.reminder_method,
                  reminder_time: lead_activity.reminder_time,
                  reminder_sent: lead_activity.reminder_sent,
                  estimated_hours: lead_activity.estimated_hours,
                  actual_hours: lead_activity.actual_hours,
                  outcome_notes: lead_activity.outcome_notes,
                  metadata: lead_activity.metadata,
                  created_at: lead_activity.created_at,
                  updated_at: lead_activity.updated_at
                )
                
                # For older "Activity" tab fields if they exist
                account_activity.outcome = lead_activity.outcome if lead_activity.respond_to?(:outcome)
                account_activity.duration = lead_activity.duration if lead_activity.respond_to?(:duration)
                account_activity.scheduled_date = lead_activity.scheduled_date if lead_activity.respond_to?(:scheduled_date)
                
                if account_activity.save
                  Rails.logger.info "Migrated activity #{lead_activity.id} to account activity #{account_activity.id}"
                else
                  Rails.logger.warn "Failed to migrate activity #{lead_activity.id}: #{account_activity.errors.full_messages.join(', ')}"
                end
              end
              
              Rails.logger.info "Activity migration completed"
            end
          rescue => e
            Rails.logger.error "Error during activity migration: #{e.message}"
            # Continue with conversion even if activity migration fails
          end
          
          # Mark lead as converted
          @lead.is_converted = true
          @lead.converted_at = Time.current
          @lead.converted_account_id = account.id
          
          if !@lead.save
            Rails.logger.error "Failed to update lead: #{@lead.errors.full_messages.join(', ')}"
            account.destroy # Rollback the account creation
            render json: { error: "Failed to mark lead as converted: #{@lead.errors.full_messages.join(', ')}" }, status: :unprocessable_entity
            return
          end
          
          Rails.logger.info "Lead marked as converted successfully"
          
          # Return simple response
          render json: {
            account: {
              id: account.id,
              name: account.name,
              email: account.email,
              phone: account.phone,
              status: account.status
            },
            contact: nil,
            deal: nil
          }, status: :ok
          
        rescue => e
          Rails.logger.error "Unexpected error during conversion: #{e.class.name}: #{e.message}"
          Rails.logger.error e.backtrace.first(10).join("\n")
          render json: { error: "Conversion failed: #{e.message}" }, status: :internal_server_error
        end
      end

      private

      def set_lead
        @lead = Lead.find(params[:id])
      end

      # Merge root + nested (:lead), accept camel & snake, normalize to snake.
      def lead_params
        allowed = [:first_name, :last_name, :email, :phone, :notes, :source_id, :status, :company_id,
                   :firstName, :lastName, :sourceId]

        root = params.permit(*allowed, lead: {})
        nested = params[:lead].is_a?(ActionController::Parameters) ? params.require(:lead).permit(*allowed) : {}

        raw = root.to_h.merge(nested.to_h) # nested wins if both present

        {
          first_name: raw['first_name'] || raw['firstName'],
          last_name:  raw['last_name']  || raw['lastName'],
          email:      raw['email'],
          phone:      raw['phone'],
          notes:      raw['notes'],
          status:     raw['status'],
          company_id: raw['company_id'],
          source_id:  (raw['source_id']  || raw['sourceId']).presence&.to_i
        }.compact
      end

      def calculate_lead_score(lead)
        score = 0
        score += 20 if lead.email.present?
        score += 15 if lead.phone.present?
        score += 25 if lead.source_id.present?
        score += 20 if lead.notes.present?
        score += 20 if lead.status.present? && lead.status != 'new'
        score
      end

      def lead_json(l)
        {
          id:        l.id,
          firstName: l.first_name,
          lastName:  l.last_name,
          email:     l.email,
          phone:     l.phone,
          notes:     l.notes,
          status:    l.status,
          sourceId:  l.source_id,
          source:    (l.source ? { id: l.source.id, name: l.source.name } : nil),
          isConverted: l.respond_to?(:is_converted) ? l.is_converted : false,
          convertedAt: l.respond_to?(:converted_at) ? l.converted_at : nil,
          convertedToAccountId: l.respond_to?(:converted_account_id) ? l.converted_account_id : nil,
          createdAt: l.created_at,
          updatedAt: l.updated_at
        }
      end
    end
  end
end
