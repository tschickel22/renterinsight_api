# frozen_string_literal: true

module Api
  module Crm
    class ActivitiesController < ApplicationController
      include RbacAuthorization
      rbac_resource :crm, read_actions: [:lead_activities, :account_activities, :contact_activities, :deal_activities]

      before_action :set_company_scope
      
      # GET /api/crm/leads/activities
      # Collection endpoint for all lead activities
      def lead_activities
        activities = @company.leads.includes(:lead_activities => [:user, :assigned_to])
                              .flat_map(&:lead_activities)
        
        # Filter by activity_type if provided
        if params[:activity_type].present?
          activity_types = Array(params[:activity_type])
          activities = activities.select { |a| activity_types.include?(a.activity_type) }
        end
        
        # Filter by status if provided
        if params[:status].present?
          statuses = Array(params[:status])
          activities = activities.select { |a| statuses.include?(a.status) }
        end
        
        # Sort by due date
        activities = activities.sort_by { |a| a.due_date || a.start_time || a.created_at }
        
        render json: activities.map { |a| activity_json(a, 'lead') }, status: :ok
      rescue => e
        Rails.logger.error "[ActivitiesController#lead_activities] #{e.class}: #{e.message}"
        render json: { error: 'Failed to load lead activities', message: e.message }, status: :internal_server_error
      end
      
      # GET /api/crm/accounts/activities
      # Collection endpoint for all account activities
      def account_activities
        activities = @company.accounts.includes(:activities => [:user, :assigned_to])
                              .flat_map(&:activities)
        
        # Filter by activity_type if provided
        if params[:activity_type].present?
          activity_types = Array(params[:activity_type])
          activities = activities.select { |a| activity_types.include?(a.activity_type) }
        end
        
        # Filter by status if provided
        if params[:status].present?
          statuses = Array(params[:status])
          activities = activities.select { |a| statuses.include?(a.status) }
        end
        
        # Sort by due date
        activities = activities.sort_by { |a| a.due_date || a.start_time || a.created_at }
        
        render json: activities.map { |a| activity_json(a, 'account') }, status: :ok
      rescue => e
        Rails.logger.error "[ActivitiesController#account_activities] #{e.class}: #{e.message}"
        render json: { error: 'Failed to load account activities', message: e.message }, status: :internal_server_error
      end
      
      # GET /api/crm/contacts/activities
      # Collection endpoint for all contact activities
      def contact_activities
        activities = @company.contacts.includes(:contact_activities => [:user, :assigned_to])
                              .flat_map(&:contact_activities)
        
        # Filter by activity_type if provided
        if params[:activity_type].present?
          activity_types = Array(params[:activity_type])
          activities = activities.select { |a| activity_types.include?(a.activity_type) }
        end
        
        # Filter by status if provided
        if params[:status].present?
          statuses = Array(params[:status])
          activities = activities.select { |a| statuses.include?(a.status) }
        end
        
        # Sort by due date
        activities = activities.sort_by { |a| a.due_date || a.start_time || a.created_at }
        
        render json: activities.map { |a| activity_json(a, 'contact') }, status: :ok
      rescue => e
        Rails.logger.error "[ActivitiesController#contact_activities] #{e.class}: #{e.message}"
        render json: { error: 'Failed to load contact activities', message: e.message }, status: :internal_server_error
      end
      
      # GET /api/crm/deals/activities
      # Collection endpoint for all deal activities
      def deal_activities
        activities = @company.deals.includes(:activities => [:user, :assigned_to])
                              .flat_map(&:activities)
        
        # Filter by activity_type if provided
        if params[:activity_type].present?
          activity_types = Array(params[:activity_type])
          activities = activities.select { |a| activity_types.include?(a.activity_type) }
        end
        
        # Filter by status if provided
        if params[:status].present?
          statuses = Array(params[:status])
          activities = activities.select { |a| statuses.include?(a.status) }
        end
        
        # Sort by due date
        activities = activities.sort_by { |a| a.due_date || a.start_time || a.created_at }
        
        render json: activities.map { |a| activity_json(a, 'deal') }, status: :ok
      rescue => e
        Rails.logger.error "[ActivitiesController#deal_activities] #{e.class}: #{e.message}"
        render json: { error: 'Failed to load deal activities', message: e.message }, status: :internal_server_error
      end
      
      private

      def set_company_scope
        unless current_user
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
      end
      
      def activity_json(activity, entity_type)
        entity_data = case entity_type
        when 'lead'
          { lead_id: activity.lead_id, lead: activity.lead ? { id: activity.lead.id, first_name: activity.lead.first_name, last_name: activity.lead.last_name } : nil }
        when 'account'
          { account_id: activity.account_id, account: activity.account ? { id: activity.account.id, name: activity.account.name } : nil }
        when 'contact'
          { contact_id: activity.contact_id, contact: activity.contact ? { id: activity.contact.id, first_name: activity.contact.first_name, last_name: activity.contact.last_name } : nil }
        when 'deal'
          { deal_id: activity.deal_id, deal: activity.deal ? { id: activity.deal.id, name: activity.deal.name, value: activity.deal.value } : nil }
        else
          {}
        end
        
        {
          id: activity.id,
          userId: activity.user_id,
          assignedToId: activity.assigned_to_id,
          assigned_to: activity.assigned_to ? {
            id: activity.assigned_to.id,
            name: activity.assigned_to.name,
            email: activity.assigned_to.email
          } : nil,
          activity_type: activity.activity_type,
          subject: activity.subject,
          description: activity.description,
          status: activity.status,
          priority: activity.priority,
          due_date: activity.due_date&.iso8601,
          start_time: activity.start_time&.iso8601,
          end_time: activity.end_time&.iso8601,
          completed_at: activity.completed_at&.iso8601,
          created_at: activity.created_at&.iso8601,
          updated_at: activity.updated_at&.iso8601
        }.merge(entity_data)
      end
    end
  end
end
