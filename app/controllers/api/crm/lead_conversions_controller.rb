# frozen_string_literal: true
module Api
  module Crm
    class LeadConversionsController < ApplicationController
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
        attrs[:name]     = account_name      if cols.include?('name')
        attrs[:email]    = @lead.try(:email) if cols.include?('email')
        attrs[:phone]    = @lead.try(:phone) if cols.include?('phone')
        attrs[:lead_id]  = @lead.id          if cols.include?('lead_id')
        attrs[:metadata] = {}                if cols.include?('metadata')

        account = Account.create!(attrs)

        updates = { converted_account_id: account.id }
        updates[:status] = 'converted' if @lead.respond_to?(:status)
        @lead.update!(updates)

        Activity.create!(
          lead_id:       @lead.id,
          activity_type: 'status_change',
          description:   "Converted to account ##{account.id} (#{account.try(:name) || account.id})",
          metadata:      {}
        )

        render json: { success: true, leadId: @lead.id, accountId: account.id }, status: :created
      rescue => e
        render json: { success: false, error: e.message }, status: :unprocessable_entity
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id] || params[:id])
      end
    end
  end
end
