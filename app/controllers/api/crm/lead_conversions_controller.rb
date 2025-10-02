module Api
  module Crm
    class LeadConversionsController < ApplicationController
      def convert
        lead = Lead.find(params[:lead_id] || params[:id])
        
        ActiveRecord::Base.transaction do
          # Create account from lead
          account = Account.create!(
            name: params[:account_name] || "#{lead.first_name} #{lead.last_name}",
            email: lead.email,
            phone: lead.phone,
            notes: lead.notes,
            source_id: lead.source_id,
            converted_from_lead_id: lead.id
          )
          
          # Create deal if requested
          deal = nil
          if params[:create_deal].present?
            deal_params = params[:create_deal]
            deal = Deal.create!(
              account: account,
              name: deal_params[:name] || "Deal for #{account.name}",
              stage: deal_params[:stage] || 'proposal',
              value: deal_params[:value],
              notes: deal_params[:notes],
              source_id: lead.source_id
            )
          end
          
          # Update lead status
          lead.update!(notes: "#{lead.notes}\n\nConverted to account ##{account.id} on #{Time.current}")
          
          render json: {
            success: true,
            account: account_json(account),
            contact: account_json(account), # For backwards compatibility
            deal: deal ? deal_json(deal) : nil
          }
        end
      rescue => e
        render json: { success: false, error: e.message }, status: :unprocessable_entity
      end

      private

      def account_json(account)
        {
          id: account.id,
          name: account.name,
          email: account.email,
          phone: account.phone,
          notes: account.notes,
          sourceId: account.source_id,
          convertedFromLeadId: account.converted_from_lead_id,
          createdAt: account.created_at,
          updatedAt: account.updated_at
        }.compact
      end

      def deal_json(deal)
        {
          id: deal.id,
          name: deal.name,
          accountId: deal.account_id,
          stage: deal.stage,
          value: deal.value,
          notes: deal.notes,
          sourceId: deal.source_id,
          createdAt: deal.created_at,
          updatedAt: deal.updated_at
        }.compact
      end
    end
  end
end
