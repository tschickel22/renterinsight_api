# frozen_string_literal: true

module Api
  module V1
    class ManufacturersController < ApplicationController
      # Manufacturers are platform-level, but we still authenticate
      before_action :authenticate_user!
      
      # GET /api/v1/manufacturers
      def index
        # Optional industry filter
        @manufacturers = Manufacturer.active.alphabetical
        
        if params[:industry_type].present?
          @manufacturers = @manufacturers.for_industry(params[:industry_type])
        end
        
        render json: {
          data: @manufacturers.map { |m| serialize_manufacturer(m) }
        }
      end
      
      # GET /api/v1/manufacturers/:id
      def show
        @manufacturer = Manufacturer.find(params[:id])
        
        render json: {
          data: serialize_manufacturer(@manufacturer, include_stats: true)
        }
      end
      
      private
      
      def serialize_manufacturer(manufacturer, include_stats: false)
        base = {
          id: manufacturer.id,
          name: manufacturer.name,
          industryType: manufacturer.industry_type,
          contactEmail: manufacturer.contact_email,
          contactPhone: manufacturer.contact_phone,
          website: manufacturer.website,
          hasPortalAccess: manufacturer.has_portal_access,
          active: manufacturer.active
        }
        
        if include_stats
          base[:stats] = {
            totalClaims: manufacturer.total_claims_count,
            activeClaims: manufacturer.active_claims_count,
            approvedClaims: manufacturer.approved_claims_count,
            totalArOutstanding: manufacturer.total_ar_outstanding
          }
        end
        
        base
      end
    end
  end
end
