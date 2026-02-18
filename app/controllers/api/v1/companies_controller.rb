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
        
        companies = ::Company.select(:id, :name, :subdomain)
                          .order(:name)
        
        render json: { 
          companies: companies.as_json(only: [:id, :name, :subdomain])
        }
      end

      # GET /api/v1/companies/:id/locations
      # Returns all locations for a specific company (platform admin only)
      def locations
        # Only platform admins can access this endpoint
        unless current_user&.platform_admin? || current_user&.super_admin?
          render json: { error: 'Unauthorized' }, status: :forbidden
          return
        end

        company = ::Company.find(params[:id])
        company_locations = company.locations
                                  .where(is_deleted: [false, nil])
                                  .order(:name)
                                  .select(:id, :name, :code, :company_id)

        render json: {
          locations: company_locations.as_json(only: [:id, :name, :code, :company_id])
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Company not found' }, status: :not_found
      end
    end
  end
end
