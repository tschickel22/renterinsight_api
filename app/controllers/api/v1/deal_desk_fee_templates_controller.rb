# frozen_string_literal: true

module Api
  module V1
    # Read-only list of fee templates to populate the Deal Desk fee dropdown.
    # @company-scoped, gated by deal_desk:read.
    class DealDeskFeeTemplatesController < ApplicationController
      include ModuleAccessRequired

      before_action :set_company_scope
      require_module! 'sales.deal_desk'

      # GET /api/v1/deal_desk/fee_templates
      def index
        return unless authorize_action!('deal_desk', 'read')

        fees = @company.fee_templates.active.ordered
        render json: {
          fee_templates: fees.map do |f|
            {
              id: f.id, name: f.name, fee_type: f.fee_type,
              default_amount: f.default_amount, taxable: f.taxable,
              applies_to: f.applies_to, is_seeded: f.is_seeded
            }
          end
        }
      end
    end
  end
end
