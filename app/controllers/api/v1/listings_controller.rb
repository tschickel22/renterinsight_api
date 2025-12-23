# frozen_string_literal: true

module Api
  module V1
    class ListingsController < ApplicationController
      include RbacAuthorization
      rbac_resource :listings,
        read_actions: [:index, :show, :stats],
        create_actions: [:create],
        update_actions: [:update, :publish, :unpublish],
        delete_actions: [:destroy]

      before_action :set_company
      before_action :set_listing, only: [:show, :update, :destroy, :publish, :unpublish]

      # GET /api/v1/listings
      def index
        Rails.logger.info "[Listings#index] ========== START =========="
        Rails.logger.info "[Listings#index] Params: #{params.inspect}"
        Rails.logger.info "[Listings#index] vehicle_type param: '#{params[:vehicle_type]}'"
        
        # STRICT TENANT ISOLATION: Only return listings from current user's company
        # RBAC: Location-tier users only see listings for vehicles in their assigned locations
        listings = if current_user.uses_rbac?
          if current_user.effective_admin?  # Use RBAC-aware admin check
            @company.listings.active
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              # Strict location filtering - only assigned locations
              @company.listings.active.joins(:vehicle)
                      .where(vehicles: { location_id: location_ids })
            else
              @company.listings.active
            end
          end
        else
          @company.listings.active
        end
        
        # Apply strict location filter - only listings for vehicles explicitly assigned to selected location
        if Current.location_filtered?
          listings = listings.joins(:vehicle).where(vehicles: { location_id: Current.location_id })
        end
        
        Rails.logger.info "[Listings#index] Initial count: #{listings.count}"
        
        # Join vehicle table once if needed for any filter
        needs_vehicle_join = params[:search].present? || params[:vehicle_type].present?
        if needs_vehicle_join
          listings = listings.joins(:vehicle)
          Rails.logger.info "[Listings#index] After joins(:vehicle): #{listings.count}"
        end
        
        # Filters
        listings = listings.by_status(params[:status]) if params[:status].present?
        listings = listings.by_offer_type(params[:offer_type]) if params[:offer_type].present?
        
        # Filter by vehicle listing type (manufactured_home vs rv)
        if params[:vehicle_type].present?
          Rails.logger.info "[Listings#index] Filtering by vehicle_type: #{params[:vehicle_type]}"
          listings = listings.where(vehicles: { listing_type: params[:vehicle_type] })
          Rails.logger.info "[Listings#index] After vehicle_type filter: #{listings.count}"
          Rails.logger.info "[Listings#index] SQL: #{listings.to_sql}"
        end
        
        # Search by description or vehicle info
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          listings = listings.where(
            "listings.description ILIKE ? OR vehicles.make ILIKE ? OR vehicles.model ILIKE ?",
            search_term, search_term, search_term
          )
        end
        
        # Filter by offer type (sale vs rent) - keeping legacy support
        case params[:listing_type]
        when 'sale'
          listings = listings.for_sale
        when 'rent'
          listings = listings.for_rent
        when 'manufactured_home', 'rv'
          # Support vehicle type via listing_type for backwards compatibility
          unless needs_vehicle_join
            listings = listings.joins(:vehicle)
            needs_vehicle_join = true
          end
          listings = listings.where(vehicles: { listing_type: params[:listing_type] })
        end
        
        # Filter by published status
        case params[:published]
        when 'true', true
          listings = listings.published
        when 'false', false
          listings = listings.draft
        end

        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order] || 'desc'
        listings = listings.order("#{sort_by} #{sort_order}")

        # Pagination
        page = params[:page]&.to_i || 1
        per_page = [params[:per_page]&.to_i || 25, 100].min
        total_count = listings.count
        listings = listings.offset((page - 1) * per_page).limit(per_page)

        render json: {
          listings: listings.map { |l| listing_json(l) },
          meta: {
            current_page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      # GET /api/v1/listings/:id
      def show
        render json: { listing: listing_json(@listing, detailed: true) }
      end

      # POST /api/v1/listings
      def create
        vehicle = @company.vehicles.find_by(id: params[:listing][:vehicle_id])
        
        unless vehicle
          return render json: { error: 'Vehicle not found' }, status: :not_found
        end

        listing = @company.listings.new(listing_params)
        listing.vehicle = vehicle

        if listing.save
          render json: { 
            listing: listing_json(listing, detailed: true),
            message: 'Listing created successfully'
          }, status: :created
        else
          render json: { errors: listing.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/listings/:id
      def update
        if @listing.update(listing_params)
          render json: { 
            listing: listing_json(@listing, detailed: true),
            message: 'Listing updated successfully'
          }
        else
          render json: { errors: @listing.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/listings/:id
      def destroy
        @listing.soft_delete!
        render json: { message: 'Listing deleted successfully' }
      end

      # POST /api/v1/listings/:id/publish
      def publish
        unless @listing.valid_for_publishing?
          missing_fields = @listing.missing_required_fields
          return render json: { 
            error: 'Cannot publish listing with missing required fields',
            missing_fields: missing_fields 
          }, status: :unprocessable_entity
        end

        @listing.publish!
        render json: { 
          listing: listing_json(@listing, detailed: true),
          message: 'Listing published successfully'
        }
      end

      # POST /api/v1/listings/:id/unpublish
      def unpublish
        @listing.unpublish!
        render json: { 
          listing: listing_json(@listing, detailed: true),
          message: 'Listing unpublished successfully'
        }
      end

      # GET /api/v1/listings/stats
      def stats
        listings = @company.listings.active
        
        # Apply strict location filter - only listings for vehicles explicitly assigned to selected location
        if Current.location_filtered?
          listings = listings.joins(:vehicle).where(vehicles: { location_id: Current.location_id })
        end
        
        # Count by vehicle type
        vehicle_type_counts = listings.joins(:vehicle)
          .group('vehicles.listing_type')
          .count
        
        Rails.logger.info "[Listings#stats] Vehicle type counts: #{vehicle_type_counts.inspect}"
        
        render json: {
          total: listings.count,
          published: listings.published.count,
          draft: listings.draft.count,
          active: listings.where(status: 'active').count,
          by_status: listings.group(:status).count,
          by_offer_type: listings.group(:offer_type).count,
          by_vehicle_type: vehicle_type_counts,
          for_sale: listings.for_sale.count,
          for_rent: listings.for_rent.count,
          mh_village_ready: listings.select(&:mh_village_ready?).count,
          mits_ready: listings.select(&:mits_ready?).count
        }
      end

      private

      def set_company
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "[ListingsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "[ListingsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "[ListingsController] Company scope set: #{@company.name} (ID: #{@company.id}) for user: #{current_user.email}"
      end

      def set_listing
        # STRICT TENANT ISOLATION: Only find listings within company
        # RBAC: Location-tier users only access listings for vehicles in their assigned locations
        @listing = if current_user.uses_rbac? && !current_user.effective_admin?  # Use RBAC-aware admin check
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # Strict location filtering - only assigned locations
            @company.listings.active.joins(:vehicle)
                    .where(vehicles: { location_id: location_ids })
                    .find(params[:id])
          else
            @company.listings.active.find(params[:id])
          end
        else
          @company.listings.active.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Listing not found or access denied' }, status: :not_found
      end

      def listing_params
        params.require(:listing).permit(
          :vehicle_id,
          :status,
          :offer_type,
          :sale_price,
          :rent_price,
          :rent_period,
          :description,
          :contact_email,
          :contact_phone,
          :features,
          :package_type,
          :location_type,
          :community_name,
          :lot_rent,
          :financing_available,
          :delivery_available,
          :setup_included,
          :has_garage,
          :has_fireplace,
          :has_deck,
          :has_shed,
          :has_appliances,
          :has_ac,
          :is_furnished,
          :pets_allowed,
          :seller_name,
          :seller_phone,
          :seller_email,
          :agent_name,
          :agent_phone,
          :agent_email,
          :property_name,
          :unit_number,
          :floor_plan_name,
          :security_deposit,
          :application_fee,
          :admin_fee,
          :lease_terms,
          :available_date,
          :effective_rent,
          :latitude,
          :longitude,
          :concessions,
          :promotional_text,
          # New rental fields
          :pet_deposit,
          :key_deposit,
          :other_deposit,
          :other_deposit_description,
          :pet_rent,
          :parking_fee,
          :storage_fee,
          :trash_fee,
          :min_lease_term,
          :max_lease_term,
          :lease_type,
          :floor_number,
          :unit_type,
          :specials_description,
          :move_in_date_type,
          :immediately_available,
          :income_requirement_multiplier,
          :credit_check_required,
          :background_check_required,
          office_hours: [],
          parking_details: {},
          pet_policy: {},
          property_amenities: [],
          unit_amenities: [],
          utilities_included: {},
          additional_features: {}
        )
      end

      def listing_json(listing, detailed: false)
        vehicle = listing.vehicle
        
        json = {
          id: listing.id.to_s,
          vehicleId: vehicle.id.to_s,
          status: listing.status,
          offerType: listing.offer_type,
          salePrice: listing.sale_price&.to_f,
          rentPrice: listing.rent_price&.to_f,
          rentPeriod: listing.rent_period,
          description: listing.description,
          contactEmail: listing.contact_email,
          contactPhone: listing.contact_phone,
          features: listing.features,
          displayName: listing.display_name,
          priceDisplay: listing.price_display,
          
          # Status flags
          published: listing.published?,
          mhVillageReady: listing.mh_village_ready?,
          mitsReady: listing.mits_ready?,
          
          # MH Village fields
          packageType: listing.package_type,
          locationType: listing.location_type,
          communityName: listing.community_name,
          lotRent: listing.lot_rent&.to_f,
          financingAvailable: listing.financing_available,
          deliveryAvailable: listing.delivery_available,
          setupIncluded: listing.setup_included,
          
          # Feature flags
          hasGarage: listing.has_garage?,
          hasFireplace: listing.has_fireplace?,
          hasDeck: listing.has_deck?,
          hasShed: listing.has_shed?,
          hasAppliances: listing.has_appliances?,
          hasAc: listing.has_ac?,
          isFurnished: listing.is_furnished?,
          petsAllowed: listing.pets_allowed?,
          
          # Contact info
          sellerName: listing.seller_name,
          sellerPhone: listing.seller_phone,
          sellerEmail: listing.seller_email,
          agentName: listing.agent_name,
          agentPhone: listing.agent_phone,
          agentEmail: listing.agent_email,
          
          # MITS fields
          propertyName: listing.property_name,
          unitNumber: listing.unit_number,
          floorPlanName: listing.floor_plan_name,
          securityDeposit: listing.security_deposit&.to_f,
          applicationFee: listing.application_fee&.to_f,
          adminFee: listing.admin_fee&.to_f,
          leaseTerms: listing.lease_terms,
          availableDate: listing.available_date,
          effectiveRent: listing.effective_rent&.to_f,
          latitude: listing.latitude&.to_f,
          longitude: listing.longitude&.to_f,
          officeHours: listing.formatted_office_hours,
          parkingDetails: listing.formatted_parking,
          petPolicy: listing.formatted_pet_policy,
          propertyAmenities: listing.formatted_property_amenities,
          unitAmenities: listing.formatted_unit_amenities,
          concessions: listing.concessions,
          promotionalText: listing.promotional_text,
          
          # New rental fields
          petDeposit: listing.pet_deposit&.to_f,
          keyDeposit: listing.key_deposit&.to_f,
          otherDeposit: listing.other_deposit&.to_f,
          otherDepositDescription: listing.other_deposit_description,
          petRent: listing.pet_rent&.to_f,
          parkingFee: listing.parking_fee&.to_f,
          storageFee: listing.storage_fee&.to_f,
          trashFee: listing.trash_fee&.to_f,
          utilitiesIncluded: listing.utilities_included,
          minLeaseTerm: listing.min_lease_term,
          maxLeaseTerm: listing.max_lease_term,
          leaseType: listing.lease_type,
          floorNumber: listing.floor_number,
          unitType: listing.unit_type,
          specialsDescription: listing.specials_description,
          moveInDateType: listing.move_in_date_type,
          immediatelyAvailable: listing.immediately_available,
          incomeRequirementMultiplier: listing.income_requirement_multiplier&.to_f,
          creditCheckRequired: listing.credit_check_required,
          backgroundCheckRequired: listing.background_check_required,
          
          # Timestamps
          publishedAt: listing.published_at,
          lastSyncedAt: listing.last_synced_at,
          createdAt: listing.created_at,
          updatedAt: listing.updated_at,
          
          # Associated vehicle summary
          vehicle: {
            id: vehicle.id.to_s,
            inventoryId: vehicle.inventory_id,
            listingType: vehicle.listing_type,
            displayName: vehicle.display_name,
            year: vehicle.year,
            make: vehicle.make,
            model: vehicle.model,
            bedrooms: vehicle.bedrooms,
            bathrooms: vehicle.bathrooms,
            squareFeet: vehicle.square_feet,
            images: convert_image_urls_to_https(vehicle.images),
            location: {
              city: vehicle.location_city,
              state: vehicle.location_state,
              zip: vehicle.location_zip
            }
          }
        }
        
        # Add detailed vehicle data if requested
        if detailed
          json[:vehicle].merge!({
            serialNumber: vehicle.serial_number,
            vin: vehicle.vin,
            length: vehicle.length,
            width: vehicle.width,
            condition: vehicle.condition,
            images: convert_image_urls_to_https(vehicle.images),
            features: vehicle.features || []
          })
        end
        
        json
      end

      # Helper to convert image URLs to HTTPS protocol
      # Fixes mixed content issues when frontend is served over HTTPS
      def convert_image_urls_to_https(images)
        Rails.logger.info "[ListingsController] convert_image_urls_to_https called with: #{images.inspect}"
        return [] if images.blank?
        
        images_array = images.is_a?(String) ? JSON.parse(images) : images
        return [] unless images_array.is_a?(Array)
        
        converted = images_array.map do |url|
          next url if url.blank? || !url.is_a?(String)
          # Convert http:// to https:// for external URLs
          converted_url = url.start_with?('http://') ? url.sub('http://', 'https://') : url
          Rails.logger.info "[ListingsController] Converted: #{url} -> #{converted_url}"
          converted_url
        end.compact
        
        Rails.logger.info "[ListingsController] Final images array: #{converted.inspect}"
        converted
      rescue JSON::ParserError => e
        Rails.logger.error "[ListingsController] JSON parse error: #{e.message}"
        []
      end
    end
  end
end
