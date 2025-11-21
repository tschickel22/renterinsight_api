# frozen_string_literal: true

module Api
  module V1
    class LandParcelsController < ApplicationController
      include RbacAuthorization
      rbac_resource :inventory,
        read_actions: [:index, :show, :stats, :export],
        create_actions: [:create],
        update_actions: [:update],
        delete_actions: [:destroy, :bulk_delete]

      before_action :set_company
      before_action :set_land_parcel, only: [:show, :update, :destroy]
      
      def index
        # STRICT TENANT ISOLATION: Only return land parcels from current user's company
        # RBAC: Location-tier users only see their assigned locations
        parcels = if current_user.uses_rbac?
          if current_user.effective_admin?  # Use RBAC-aware admin check
            @company.land_parcels.active
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              # Include parcels in assigned locations OR unassigned parcels (NULL location_id)
              @company.land_parcels.active.where("location_id IN (?) OR location_id IS NULL", location_ids)
            else
              @company.land_parcels.active
            end
          end
        else
          @company.land_parcels.active
        end
        
        # Filters
        parcels = parcels.by_status(params[:status]) if params[:status].present?
        parcels = parcels.by_zoning(params[:zoning_type]) if params[:zoning_type].present?
        parcels = parcels.by_city(params[:city]) if params[:city].present?
        parcels = parcels.by_state(params[:state]) if params[:state].present?
        
        # Price range filter
        if params[:min_price].present? && params[:max_price].present?
          parcels = parcels.by_price_range(params[:min_price].to_f, params[:max_price].to_f)
        end
        
        # Acreage range filter
        if params[:min_acreage].present? && params[:max_acreage].present?
          parcels = parcels.by_acreage_range(params[:min_acreage].to_f, params[:max_acreage].to_f)
        end
        
        # Search
        parcels = parcels.search(params[:search]) if params[:search].present?
        
        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order] || 'desc'
        parcels = parcels.order("#{sort_by} #{sort_order}")
        
        # Pagination
        page = params[:page]&.to_i || 1
        per_page = [params[:per_page]&.to_i || 25, 100].min
        total_count = parcels.count
        parcels = parcels.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          parcels: parcels.map { |p| parcel_json(p) },
          meta: {
            current_page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end
      
      def show
        render json: { parcel: parcel_json(@parcel) }
      end
      
      def create
        permitted_params = parcel_params
        
        parcel = @company.land_parcels.new(permitted_params)
        parcel.created_by = current_user&.id
        
        # RBAC: Location-tier users auto-assign to their location
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          parcel.location_id ||= location_ids.first if location_ids.any?
        end
        
        if parcel.save
          render json: { parcel: parcel_json(parcel) }, status: :created
        else
          render json: { errors: parcel.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      def update
        @parcel.updated_by = current_user&.id
        
        if @parcel.update(parcel_params)
          render json: { parcel: parcel_json(@parcel) }
        else
          render json: { errors: @parcel.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      def destroy
        @parcel.soft_delete!
        head :no_content
      end
      
      def stats
        parcels = @company.land_parcels.active
        
        render json: {
          total: parcels.count,
          available: parcels.available.count,
          sold: parcels.sold.count,
          pending: parcels.pending.count,
          under_contract: parcels.under_contract.count,
          by_status: parcels.group(:status).count,
          by_zoning: parcels.group(:zoning_type).count,
          total_acreage: parcels.sum(:acreage).to_f.round(2),
          total_value: parcels.sum(:price).to_f,
          avg_price_per_acre: parcels.where.not(price_per_acre: nil).average(:price_per_acre).to_f.round(2)
        }
      end
      
      def bulk_delete
        parcel_ids = params[:parcel_ids] || []
        
        return render json: { error: 'No parcels selected' }, status: :bad_request if parcel_ids.empty?
        
        parcels = @company.land_parcels.where(id: parcel_ids)
        parcels.each(&:soft_delete!)
        
        render json: {
          success: true,
          deleted_count: parcels.count
        }
      end
      
      def export
        parcels = @company.land_parcels.active
        
        # Apply same filters as index
        parcels = parcels.by_status(params[:status]) if params[:status].present?
        parcels = parcels.by_zoning(params[:zoning_type]) if params[:zoning_type].present?
        parcels = parcels.search(params[:search]) if params[:search].present?
        
        # Generate CSV
        require 'csv'
        
        csv_data = CSV.generate(headers: true) do |csv|
          csv << [
            'Parcel Number', 'Name', 'Status', 'Zoning', 'Acreage',
            'Price', 'Price/Acre', 'Address', 'City', 'State', 'ZIP',
            'County', 'Utilities', 'Features', 'Owner', 'Acquisition Date'
          ]
          
          parcels.each do |parcel|
            csv << [
              parcel.parcel_number,
              parcel.name,
              parcel.status,
              parcel.zoning_type,
              parcel.acreage,
              parcel.price,
              parcel.price_per_acre,
              parcel.address,
              parcel.city,
              parcel.state,
              parcel.zip,
              parcel.county,
              parcel.utility_list.join('; '),
              (parcel.features || []).join('; '),
              parcel.owner_name,
              parcel.acquisition_date
            ]
          end
        end
        
        send_data csv_data, filename: "land-parcels-#{Date.today}.csv", type: 'text/csv'
      end
      
      private
      
      def set_company
        # STRICT TENANT ISOLATION: Only load company from authenticated user
        unless current_user
          Rails.logger.error "🚫 [LandParcelsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [LandParcelsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [LandParcelsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [LandParcelsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end
      
      def set_land_parcel
        # STRICT TENANT ISOLATION: Only find parcels within company
        # RBAC: Location-tier users only access their assigned locations
        @parcel = if current_user.uses_rbac? && !current_user.effective_admin?  # Use RBAC-aware admin check
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # Include parcels in assigned locations OR unassigned parcels (NULL location_id)
            @company.land_parcels.active.where("location_id IN (?) OR location_id IS NULL", location_ids).find(params[:id])
          else
            @company.land_parcels.active.find(params[:id])
          end
        else
          @company.land_parcels.active.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Land parcel not found or access denied' }, status: :not_found
        return
      end
      
      def parcel_params
        # Convert camelCase to snake_case
        raw_params = params.require(:parcel)
        transformed = {}
        
        # Helper method to get value from params (try both symbol and string keys)
        get_param = ->(key) {
          raw_params[key] || raw_params[key.to_s] || raw_params[key.to_sym]
        }
        
        # Field mappings (camelCase to snake_case)
        field_mappings = {
          'parcelNumber' => :parcel_number,
          'zoningType' => :zoning_type,
          'pricePerAcre' => :price_per_acre,
          'ownerName' => :owner_name,
          'ownerPhone' => :owner_phone,
          'ownerEmail' => :owner_email,
          'acquisitionDate' => :acquisition_date
        }
        
        # Transform camelCase fields
        field_mappings.each do |camel_str, snake|
          value = get_param.call(camel_str)
          transformed[snake] = value if value.present?
        end
        
        # Direct fields (same in both camelCase and snake_case)
        direct_fields = [
          'name', 'address', 'city', 'state', 'zip', 'county',
          'latitude', 'longitude', 'acreage', 'status', 'price',
          'description', 'notes', 'utilities', 'features', 'images', 'documents'
        ]
        
        direct_fields.each do |field_str|
          value = get_param.call(field_str)
          transformed[field_str.to_sym] = value if value.present?
        end
        
        # Return as ActionController::Parameters
        ActionController::Parameters.new(transformed).permit(
          :parcel_number, :name, :address, :city, :state, :zip, :county,
          :latitude, :longitude, :acreage, :zoning_type, :status, :price,
          :price_per_acre, :owner_name, :owner_phone, :owner_email,
          :acquisition_date, :description, :notes,
          utilities: {}, features: [], images: [], documents: []
        )
      end
      
      def parcel_json(parcel)
        base_url = Rails.env.production? ? "https://#{request.host}" : "http://#{request.host}:#{request.port}"
        
        # Convert image URLs - only prepend base URL to relative paths
        # Don't modify complete URLs (http/https/data/blob)
        full_image_urls = (parcel.images || []).map do |url|
          # Ensure url is a string and not nil
          url_str = url.to_s.strip
          next nil if url_str.blank?
          
          # Log the URL for debugging
          Rails.logger.debug "Processing image URL: #{url_str[0..50]}..."
          
          # Check if it's already a complete URL (including data URLs and blob URLs)
          if url_str.match?(/^(https?|data|blob):/) 
            # Already a complete URL, return as-is
            Rails.logger.debug "  -> Complete URL, returning as-is"
            url_str
          elsif url_str.start_with?('/')
            # Relative path starting with /, prepend base URL
            Rails.logger.debug "  -> Relative path with /, prepending base URL"
            "#{base_url}#{url_str}"
          else
            # Relative path not starting with /, prepend base URL with /
            Rails.logger.debug "  -> Relative path, prepending base URL with /"
            "#{base_url}/#{url_str}"
          end
        end.compact
        
        {
          id: parcel.id.to_s,
          parcelNumber: parcel.parcel_number,
          name: parcel.name,
          displayName: parcel.display_name,
          status: parcel.status,
          zoningType: parcel.zoning_type,
          acreage: parcel.acreage&.to_f,
          price: parcel.price&.to_f,
          pricePerAcre: parcel.price_per_acre&.to_f,
          address: parcel.address,
          city: parcel.city,
          state: parcel.state,
          zip: parcel.zip,
          county: parcel.county,
          fullAddress: parcel.full_address,
          coordinates: parcel.coordinates,
          utilities: parcel.utilities || {},
          features: parcel.features || [],
          images: full_image_urls,
          documents: parcel.documents || [],
          description: parcel.description,
          notes: parcel.notes,
          ownerName: parcel.owner_name,
          ownerPhone: parcel.owner_phone,
          ownerEmail: parcel.owner_email,
          acquisitionDate: parcel.acquisition_date,
          createdAt: parcel.created_at,
          updatedAt: parcel.updated_at
        }
      end
    end
  end
end
