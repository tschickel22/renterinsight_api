module Api
  module Crm
    class LeadsController < ApplicationController
      include LeadJsonHelper rescue nil
      include Api::Crm::LeadJsonHelper

      # GET /api/crm/leads/:id
      def show
        lead = Lead.find(params[:id])
        render json: lead_with_tags_json(lead)
      end

      # GET /api/crm/leads
      def index
        leads = Lead.order(created_at: :desc).limit(50)
        render json: leads.map { |l| lead_with_tags_json(l) }
      end
    end
  end
end
