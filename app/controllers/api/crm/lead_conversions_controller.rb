# frozen_string_literal: true
module Api
  module Crm
    class LeadConversionsController < ApplicationController
      include RbacAuthorization
      rbac_resource :leads, update_actions: [:convert]

      before_action :set_company_scope
      before_action :set_lead

      # POST /api/crm/leads/:lead_id/convert
      def convert
        # Idempotent: if already converted, return existing account id
        if @lead.respond_to?(:converted_account_id) && @lead.converted_account_id.present?
          render json: { success: true, leadId: @lead.id, accountId: @lead.converted_account_id }, status: :ok
          return
        end

        account_name =
          (@lead.respond_to?(:name) && @lead.name.present?) ? @lead.name :
          [@lead.try(:first_name), @lead.try(:last_name)].compact.join(' ').presence ||
          "Lead #{@lead.id}"

        cols = Account.column_names
        attrs = {}
        attrs[:name]       = account_name        if cols.include?('name')
        attrs[:email]      = @lead.try(:email)   if cols.include?('email')
        attrs[:phone]      = @lead.try(:phone)   if cols.include?('phone')
        attrs[:lead_id]    = @lead.id            if cols.include?('lead_id')
        attrs[:company_id] = @company.id         if cols.include?('company_id')
        attrs[:metadata]   = {}                  if cols.include?('metadata')

        account = Account.create!(attrs)

        updates = { converted_account_id: account.id }
        updates[:status] = 'converted' if @lead.respond_to?(:status)
        @lead.update!(updates)

        # Create activity with company scope
        activity_attrs = {
          lead_id:       @lead.id,
          activity_type: 'status_change',
          description:   "Converted to account ##{account.id} (#{account.try(:name) || account.id})",
          metadata:      {}
        }
        activity_attrs[:company_id] = @company.id if Activity.column_names.include?('company_id')
        Activity.create!(activity_attrs)

        render json: { success: true, leadId: @lead.id, accountId: account.id }, status: :created
      rescue => e
        Rails.logger.error "🚫 [LeadConversionsController] Conversion failed: #{e.message}"
        render json: { success: false, error: e.message }, status: :unprocessable_entity
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [LeadConversionsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [LeadConversionsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [LeadConversionsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [LeadConversionsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_lead
        @lead = @company.leads.find_by(id: params[:lead_id] || params[:id])
        unless @lead
          render json: { error: 'Lead not found or access denied' }, status: :not_found
          return
        end
      end
    end
  end
end
