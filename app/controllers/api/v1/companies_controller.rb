# frozen_string_literal: true

module Api
  module V1
    class CompaniesController < ApplicationController
      # GET /api/v1/companies/accessible
      # Returns list of companies accessible to platform admins
      def accessible
        # Only platform admins can access this endpoint
        unless current_user&.platform_admin? || current_user&.super_admin?
          render json: { companies: [] }
          return
        end
        
        companies = Company.where(is_deleted: [false, nil])
                          .select(:id, :name, :subdomain)
                          .order(:name)
        
        render json: { 
          companies: companies.as_json(only: [:id, :name, :subdomain])
        }
      end
    end
  end
end
