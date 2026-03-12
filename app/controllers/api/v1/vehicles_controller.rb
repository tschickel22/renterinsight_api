# frozen_string_literal: true

module Api
  module V1
    class VehiclesController < ApplicationController
      include RbacAuthorization
      rbac_resource :inventory,
        read_actions: [:index, :show, :stats, :export, :print],
        create_actions: [:create, :clone, :import],
        update_actions: [:update, :bulk_update],
        delete_actions: [:destroy, :bulk_delete]

      before_action :set_company
      before_action :set_vehicle, only: [:show, :update, :destroy, :print, :clone, :tags, :add_tags, :remove_tag, :share]

      def index
        # STRICT TENANT ISOLATION: Only return vehicles from current user's company
        # RBAC: Location-tier users only see their assigned locations
        vehicles = if current_user.uses_rbac?
          if current_user.effective_admin?  # Use RBAC-aware admin check
            @company.vehicles.active
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              # Strict location filtering - only assigned locations
              @company.vehicles.active.where(location_id: location_ids)
            else
              @company.vehicles.active
            end
          end
        else
          @company.vehicles.active
        end
        
        # Apply location filter - skip if 'all_locations' param sent
        if params[:all_locations].present? && params[:all_locations] == 'true'
          # Show all locations - no location filter applied
        elsif params[:location_id].present? && params[:location_id] != 'all'
          vehicles = vehicles.where(location_id: params[:location_id])
        elsif Current.location_filtered?
          vehicles = vehicles.where(location_id: Current.location_id)
        end
        
        # Apply non-search filters
        vehicles = vehicles.by_type(params[:type]) if params[:type].present?
        vehicles = vehicles.by_status(params[:status]) if params[:status].present?
        vehicles = vehicles.by_year(params[:year]) if params[:year].present?
        vehicles = vehicles.by_make(params[:make]) if params[:make].present?
        vehicles = vehicles.by_model(params[:model]) if params[:model].present?
        
        # Advanced MH filters
        vehicles = vehicles.where(bedrooms: params[:bedrooms]) if params[:bedrooms].present?
        vehicles = vehicles.where(bathrooms: params[:bathrooms]) if params[:bathrooms].present?
        vehicles = vehicles.where('sale_price >= ?', params[:min_price].to_f) if params[:min_price].present?
        vehicles = vehicles.where('sale_price <= ?', params[:max_price].to_f) if params[:max_price].present?
        vehicles = vehicles.where(home_type: params[:home_type]) if params[:home_type].present?
        
        # Count stats BEFORE search filter (stats tiles show ALL vehicles)
        all_vehicles_count = vehicles.count
        status_counts = {
          available: vehicles.available.count,
          available_to_order: vehicles.available_to_order.count,
          reserved: vehicles.reserved.count,
          sold: vehicles.sold.count,
          pending: vehicles.pending.count
        }
        
        # Calculate total values BEFORE search filter
        total_sale_value = vehicles.includes(:inventory_packages).sum { |v| v.total_home_price.to_f }
        total_rent_value = vehicles.sum(:rent_price).to_f
        
        # Count by type BEFORE search filter
        rv_count = vehicles.rvs.count
        mh_count = vehicles.manufactured_homes.count
        
        # Apply search filter (searches year, make, model, trim, vin, serial_number, inventory_id, location_city)
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          vehicles = vehicles.where(
            "CAST(year AS TEXT) ILIKE ? OR make ILIKE ? OR model ILIKE ? OR trim ILIKE ? OR vin ILIKE ? OR serial_number ILIKE ? OR inventory_id ILIKE ? OR location_city ILIKE ?",
            search_term, search_term, search_term, search_term, search_term, search_term, search_term, search_term
          )
        end

        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order] || 'desc'
        vehicles = vehicles.order("#{sort_by} #{sort_order}")
        
        # Count AFTER search filter (for pagination)
        filtered_count = vehicles.count

        # Pagination
        page = params[:page]&.to_i || 1
        per_page = [params[:per_page]&.to_i || 25, 100].min
        vehicles = vehicles.includes(:location).offset((page - 1) * per_page).limit(per_page)

        render json: {
          vehicles: vehicles.map { |v| vehicle_json(v) },
          meta: {
            current_page: page,
            per_page: per_page,
            total_count: filtered_count,  # For pagination (filtered results)
            total_pages: (filtered_count.to_f / per_page).ceil,
            stats: status_counts.merge(
              total: all_vehicles_count,
              by_type: { rv: rv_count, manufactured_home: mh_count },
              total_value: { sale: total_sale_value, rent: total_rent_value }
            )  # For tiles (unfiltered totals)
          }
        }
      end

      def show
        render json: { vehicle: vehicle_json(@vehicle, detailed: true) }
      end

      def create
        vp = vehicle_params
        
        # UPSERT: If VIN/serial already exists for this company, update instead of fail
        # Check active records first, then soft-deleted (to restore them)
        existing = nil
        serial = vp[:serial_number].presence || vp[:vin].presence
        if serial.present?
          existing = @company.vehicles.where(is_deleted: [false, nil]).find_by(serial_number: serial)
          existing ||= @company.vehicles.where(is_deleted: [false, nil]).find_by(vin: serial)
          # Also check soft-deleted records (restore instead of failing on uniqueness)
          existing ||= @company.vehicles.where(is_deleted: true).find_by(serial_number: serial)
          existing ||= @company.vehicles.where(is_deleted: true).find_by(vin: serial)
        end
        
        if existing
          # Update existing vehicle with new data (skip nil values to preserve existing data)
          update_attrs = vp.to_h.reject { |_k, v| v.nil? || v == '' }
          
          # Restore soft-deleted records
          update_attrs[:is_deleted] = false if existing.is_deleted?
          
          # Assign location: CSV locationId/locationName > current location selector
          resolved_loc, loc_error = resolve_import_location_id
          if loc_error
            render json: { errors: [loc_error] }, status: :unprocessable_entity
            return
          end
          update_attrs[:location_id] = resolved_loc if resolved_loc.present?
          
          # Handle custom_field_values merge
          custom_field_values_param = params[:vehicle]&.dig(:custom_field_values) || params[:vehicle]&.dig(:customFieldValues)
          if custom_field_values_param.present?
            existing_custom = existing.custom_field_values || {}
            update_attrs[:custom_field_values] = existing_custom.merge(custom_field_values_param.to_unsafe_h)
          end
          
          if existing.update(update_attrs)
            render json: { vehicle: vehicle_json(existing, detailed: true), upsert: 'updated' }, status: :ok
          else
            Rails.logger.error "[VehiclesController#create] Update failed for #{existing.make} #{existing.model}: #{existing.errors.full_messages.join(', ')}"
            render json: { errors: existing.errors.full_messages }, status: :unprocessable_entity
          end
        else
          # Create new vehicle
          vehicle = @company.vehicles.new(vp)

          # Handle custom_field_values on create
          custom_field_values_param = params[:vehicle]&.dig(:custom_field_values) || params[:vehicle]&.dig(:customFieldValues)
          if custom_field_values_param.present?
            vehicle.custom_field_values = custom_field_values_param.to_unsafe_h
          end
          
          # Assign location: CSV locationId/locationName > current location selector > RBAC fallback
          resolved_loc, loc_error = resolve_import_location_id
          if loc_error
            render json: { errors: [loc_error] }, status: :unprocessable_entity
            return
          end
          vehicle.location_id ||= resolved_loc if resolved_loc.present?
          
          # RBAC fallback: Location-tier users auto-assign to their first location if no selector
          if vehicle.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
            location_ids = permission_service.accessible_location_ids
            vehicle.location_id ||= location_ids.first if location_ids.any?
          end

          if vehicle.save
            render json: { vehicle: vehicle_json(vehicle, detailed: true), upsert: 'created' }, status: :created
          else
            Rails.logger.error "[VehiclesController#create] Validation failed for #{vehicle.make} #{vehicle.model}: #{vehicle.errors.full_messages.join(', ')}"
            Rails.logger.error "[VehiclesController#create] listing_type=#{vehicle.listing_type} status=#{vehicle.status} vin=#{vehicle.vin} serial=#{vehicle.serial_number} bedrooms=#{vehicle.bedrooms} bathrooms=#{vehicle.bathrooms}"
            render json: { errors: vehicle.errors.full_messages }, status: :unprocessable_entity
          end
        end
      end

      def update
        params_to_update = vehicle_params

        # Handle custom_field_values merge (partial update pattern - same as contacts)
        # Read directly from params since vehicle_params transformation strips dynamic JSONB keys
        custom_field_values_param = params[:vehicle]&.dig(:custom_field_values) || params[:vehicle]&.dig(:customFieldValues)
        if custom_field_values_param.present?
          existing = @vehicle.custom_field_values || {}
          params_to_update = params_to_update.to_h.merge('custom_field_values' => existing.merge(custom_field_values_param.to_unsafe_h))
        end

        if @vehicle.update(params_to_update)
          render json: { vehicle: vehicle_json(@vehicle, detailed: true) }
        else
          render json: { errors: @vehicle.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @vehicle.soft_delete!
        head :no_content
      end

      # POST /api/v1/vehicles/:id/clone
      def clone
        new_identifier = params[:identifier]
        
        if new_identifier.blank?
          return render json: { error: 'New identifier is required' }, status: :unprocessable_entity
        end

        # Duplicate the vehicle with all attributes
        new_vehicle = @vehicle.dup
        
        # CRITICAL: Clear BOTH vin and serial_number to avoid constraint violations
        new_vehicle.vin = nil
        new_vehicle.serial_number = nil
        
        # Set the new unique identifier based on type
        if @vehicle.is_rv?
          new_vehicle.vin = new_identifier
        elsif @vehicle.is_manufactured_home?
          new_vehicle.serial_number = new_identifier
        end
        
        # Let the model generate a fresh inventory ID (clear the dup'd one)
        new_vehicle.inventory_id = nil
        
        # Clear public_id so a new unique one is generated (unique constraint)
        new_vehicle.public_id = nil
        
        # Clear QuickBooks sync so clone gets its own QB record
        new_vehicle.quickbooks_id = nil
        new_vehicle.quickbooks_synced_at = nil
        
        # Reset status to available for the clone
        new_vehicle.status = 'available'
        
        # Clear dates that should be fresh
        new_vehicle.date_in_stock = Date.today
        new_vehicle.date_sold = nil
        
        # Clear any sale-related fields
        new_vehicle.sale_pending = false
        
        # Clear discount fields so compute_discounted_price doesn't interfere
        new_vehicle.special_discount_enabled = false if new_vehicle.respond_to?(:special_discount_enabled)
        new_vehicle.discounted_price = nil if new_vehicle.respond_to?(:discounted_price)
        
        # Duplicate arrays (features, images, etc.)
        new_vehicle.features = @vehicle.features&.dup || []
        new_vehicle.images = @vehicle.images&.dup || []
        new_vehicle.videos = @vehicle.videos&.dup || []
        new_vehicle.appliances = @vehicle.appliances&.dup || []
        new_vehicle.floor_plan_images = @vehicle.floor_plan_images&.dup || []
        
        if new_vehicle.save
          render json: { vehicle: vehicle_json(new_vehicle, detailed: true) }, status: :created
        else
          render json: { errors: new_vehicle.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[VehiclesController] Clone failed: #{e.message}"
        Rails.logger.error e.backtrace&.first(10)&.join("\n")
        render json: { error: "Clone failed: #{e.message}" }, status: :internal_server_error
      end

      # POST /api/v1/vehicles/:id/share
      def share
        send_params = params.permit(
          :to_email,
          :to_phone,
          :custom_message,
          :from_email,
          :from_phone,
          :cc,
          :bcc,
          :contact_id,
          :lead_id,
          delivery_methods: []
        ).to_h
        
        # Extract contact_id and lead_id for activity tracking
        contact_id = send_params.delete(:contact_id)
        lead_id = send_params.delete(:lead_id)
        
        # Default to email if no delivery methods specified
        send_params[:delivery_methods] ||= ['email']
        
        # Convert to symbols for service
        send_params_symbolized = send_params.deep_symbolize_keys
        
        # USER EMAIL CONNECTION WATERFALL: Pass current user for email routing
        send_params_symbolized[:user] = current_user
        
        # CRITICAL FIX: Find the published listing for this vehicle
        # ListingSendingService expects a Listing object, not a Vehicle
        listing = @company.listings.active.published.find_by(vehicle_id: @vehicle.id)
        
        unless listing
          return render json: {
            success: false,
            error: 'No published listing found for this vehicle'
          }, status: :not_found
        end
        
        begin
          result = ListingSendingService.new(listing).send(**send_params_symbolized)
          
          if result[:sent].any?
            # Create activity if contact_id or lead_id provided
            activity = nil
            if contact_id.present?
              activity = create_contact_share_activity(contact_id, result, send_params)
            elsif lead_id.present?
              activity = create_lead_share_activity(lead_id, result, send_params)
            end
            
            render json: {
              success: true,
              listing: vehicle_json(@vehicle),
              sent_via: result[:sent].map { |r| { channel: r[:channel], to: r[:to] } },
              communications: result[:sent].map { |r| r[:communication]&.id },
              activity_id: activity&.id
            }
          else
            render json: {
              success: false,
              error: result[:errors].first || 'Failed to share listing',
              errors: result[:errors],
              failed: result[:failed]
            }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { success: false, error: e.message }, status: :bad_request
        rescue => e
          Rails.logger.error "Error sharing listing: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { success: false, error: e.message }, status: :internal_server_error
        end
      end

      # GET /api/v1/vehicles/:id/print
      def print
        @company = @vehicle.company
        company_settings = ::Setting.get('Company', @company.id, 'quotes', {}) || {}
        
        # Build images HTML
        images_html = ''
        if @vehicle.images.present? && @vehicle.images.any?
          images_html = '<h2>Photos</h2><div class="image-gallery">'
          @vehicle.images.each do |img_entry|
            img_url = img_entry.is_a?(Hash) ? (img_entry['url'] || img_entry[:url]) : img_entry
            next if img_url.blank?
            full_url = img_url.start_with?('http') ? img_url : "http://#{request.host}:#{request.port}#{img_url}"
            images_html += "<div class='gallery-item'><img src='#{full_url}' alt='Vehicle Photo' /></div>"
          end
          images_html += '</div>'
        end
        
        # Build RV-specific sections
        rv_specs_html = ''
        if @vehicle.is_rv?
          rv_specs_html = '<h2>RV Specifications</h2><table>'
          rv_specs_html += "<tr><th>RV Type</th><td>#{@vehicle.rv_type.titleize}</td></tr>" if @vehicle.rv_type.present?
          rv_specs_html += "<tr><th>Body Style</th><td>#{@vehicle.body_style}</td></tr>" if @vehicle.body_style.present?
          rv_specs_html += "<tr><th>Length</th><td>#{@vehicle.length} ft</td></tr>" if @vehicle.length.present?
          rv_specs_html += "<tr><th>Weight</th><td>#{@vehicle.weight} lbs</td></tr>" if @vehicle.weight.present?
          rv_specs_html += "<tr><th>Sleeps</th><td>#{@vehicle.sleeps}</td></tr>" if @vehicle.sleeps.present?
          rv_specs_html += "<tr><th>Slide Outs</th><td>#{@vehicle.slide_outs}</td></tr>" if @vehicle.slide_outs.present?
          rv_specs_html += "<tr><th>Mileage</th><td>#{@vehicle.mileage} #{@vehicle.mileage_unit}</td></tr>" if @vehicle.mileage.present?
          rv_specs_html += "<tr><th>Fuel Type</th><td>#{@vehicle.fuel_type}</td></tr>" if @vehicle.fuel_type.present?
          rv_specs_html += "<tr><th>Transmission</th><td>#{@vehicle.transmission}</td></tr>" if @vehicle.transmission.present?
          rv_specs_html += "<tr><th>Exterior Color</th><td>#{@vehicle.exterior_color}</td></tr>" if @vehicle.exterior_color.present?
          rv_specs_html += "<tr><th>Interior Color</th><td>#{@vehicle.interior_color}</td></tr>" if @vehicle.interior_color.present?
          rv_specs_html += "<tr><th>Interior Type</th><td>#{@vehicle.vehicle_interior_type}</td></tr>" if @vehicle.vehicle_interior_type.present?
          rv_specs_html += "<tr><th>Doors</th><td>#{@vehicle.number_of_doors}</td></tr>" if @vehicle.number_of_doors.present?
          rv_specs_html += "<tr><th>Seating Capacity</th><td>#{@vehicle.seating_capacity}</td></tr>" if @vehicle.seating_capacity.present?
          rv_specs_html += '</table>'
          
          # RV Features
          rv_features = []
          rv_features << 'Awning' if @vehicle.awning
          rv_features << 'Generator' if @vehicle.generator
          if rv_features.any?
            rv_specs_html += '<h2>RV Features</h2><ul>'
            rv_features.each { |f| rv_specs_html += "<li>#{f}</li>" }
            rv_specs_html += '</ul>'
          end
        end
        
        # Build Manufactured Home-specific sections
        mh_specs_html = ''
        if @vehicle.is_manufactured_home?
          mh_specs_html = '<h2>Home Specifications</h2><table>'
          mh_specs_html += "<tr><th>Home Type</th><td>#{@vehicle.home_type}</td></tr>" if @vehicle.home_type.present?
          mh_specs_html += "<tr><th>Dwelling Type</th><td>#{@vehicle.dwelling_type}</td></tr>" if @vehicle.dwelling_type.present?
          mh_specs_html += "<tr><th>Bedrooms</th><td>#{@vehicle.bedrooms}</td></tr>" if @vehicle.bedrooms.present?
          mh_specs_html += "<tr><th>Bathrooms</th><td>#{@vehicle.bathrooms}</td></tr>" if @vehicle.bathrooms.present?
          mh_specs_html += "<tr><th>Square Feet</th><td>#{@vehicle.square_feet}</td></tr>" if @vehicle.square_feet.present?
          
          # Dimensions
          if @vehicle.width.present? || @vehicle.length.present?
            mh_specs_html += "<tr><th>Dimensions</th><td>#{@vehicle.width}'W x #{@vehicle.length}'L</td></tr>"
          end
          if @vehicle.width1.present? && @vehicle.length1.present?
            mh_specs_html += "<tr><th>Section 1</th><td>#{@vehicle.width1}'W x #{@vehicle.length1}'L</td></tr>"
          end
          if @vehicle.width2.present? && @vehicle.length2.present?
            mh_specs_html += "<tr><th>Section 2</th><td>#{@vehicle.width2}'W x #{@vehicle.length2}'L</td></tr>"
          end
          if @vehicle.width3.present? && @vehicle.length3.present?
            mh_specs_html += "<tr><th>Section 3</th><td>#{@vehicle.width3}'W x #{@vehicle.length3}'L</td></tr>"
          end
          
          mh_specs_html += '</table>'
          
          # Construction Details
          construction_fields = []
          construction_fields << ['Foundation', @vehicle.foundation_type] if @vehicle.foundation_type.present?
          construction_fields << ['Roof Type', @vehicle.roof_type] if @vehicle.roof_type.present?
          construction_fields << ['Roof Material', @vehicle.roof_material] if @vehicle.roof_material.present?
          construction_fields << ['Siding Type', @vehicle.siding_type] if @vehicle.siding_type.present?
          construction_fields << ['Exterior Material', @vehicle.exterior_material] if @vehicle.exterior_material.present?
          construction_fields << ['Flooring', @vehicle.flooring_type] if @vehicle.flooring_type.present?
          construction_fields << ['Insulation', @vehicle.insulation_type] if @vehicle.insulation_type.present?
          construction_fields << ['Ceiling Type', @vehicle.ceiling_type] if @vehicle.ceiling_type.present?
          construction_fields << ['Wall Type', @vehicle.wall_type] if @vehicle.wall_type.present?
          
          if construction_fields.any?
            mh_specs_html += '<h2>Construction Details</h2><table>'
            construction_fields.each { |label, value| mh_specs_html += "<tr><th>#{label}</th><td>#{value}</td></tr>" }
            mh_specs_html += '</table>'
          end
          
          # Systems
          systems_fields = []
          systems_fields << ['Heating', @vehicle.heating_type] if @vehicle.heating_type.present?
          systems_fields << ['Cooling', @vehicle.cooling_type] if @vehicle.cooling_type.present?
          systems_fields << ['Water Heater', @vehicle.water_heater_type] if @vehicle.water_heater_type.present?
          
          if systems_fields.any?
            mh_specs_html += '<h2>Systems</h2><table>'
            systems_fields.each { |label, value| mh_specs_html += "<tr><th>#{label}</th><td>#{value}</td></tr>" }
            mh_specs_html += '</table>'
          end
          
          # Amenities
          amenities = []
          amenities << 'Fireplace' if @vehicle.fireplace
          amenities << 'Central Air' if @vehicle.central_air
          amenities << 'Deck' if @vehicle.deck
          amenities << 'Patio' if @vehicle.patio
          amenities << 'Garage' if @vehicle.garage
          amenities << 'Carport' if @vehicle.carport
          amenities << 'Storage' if @vehicle.has_storage
          amenities << 'Thermopane Windows' if @vehicle.thermopane
          amenities << 'Gutters' if @vehicle.gutters
          amenities << 'Shutters' if @vehicle.shutters
          amenities << 'Cathedral Ceiling' if @vehicle.cathedral_ceiling
          amenities << 'Ceiling Fan' if @vehicle.ceiling_fan
          amenities << 'Skylight' if @vehicle.skylight
          amenities << 'Walk-in Closet' if @vehicle.walkin_closet
          amenities << 'Laundry Room' if @vehicle.laundry_room
          amenities << 'Pantry' if @vehicle.pantry
          amenities << 'Sun Room' if @vehicle.sun_room
          amenities << 'Basement' if @vehicle.basement
          amenities << 'Garden Tub' if @vehicle.garden_tub
          
          if amenities.any?
            mh_specs_html += '<h2>Amenities & Features</h2><ul class="amenities-list">'
            amenities.each { |a| mh_specs_html += "<li>#{a}</li>" }
            mh_specs_html += '</ul>'
          end
          
          # Appliances
          appliances = []
          appliances << 'Refrigerator' if @vehicle.refrigerator
          appliances << 'Microwave' if @vehicle.microwave
          appliances << 'Oven' if @vehicle.oven
          appliances << 'Dishwasher' if @vehicle.dishwasher
          appliances << 'Garbage Disposal' if @vehicle.garbage_disposal
          appliances << 'Clothes Washer' if @vehicle.clothes_washer
          appliances << 'Clothes Dryer' if @vehicle.clothes_dryer
          
          if appliances.any?
            mh_specs_html += '<h2>Appliances</h2><ul class="amenities-list">'
            appliances.each { |a| mh_specs_html += "<li>#{a}</li>" }
            mh_specs_html += '</ul>'
          end
        end
        
        # Build location HTML
        location_html = ''
        if @vehicle.location_city.present? || @vehicle.location_state.present? || @vehicle.address1.present?
          location_html = '<h2>Location</h2><table>'
          location_html += "<tr><th>Address</th><td>#{@vehicle.address1}</td></tr>" if @vehicle.address1.present?
          location_html += "<tr><th>Address 2</th><td>#{@vehicle.address2}</td></tr>" if @vehicle.address2.present?
          location_html += "<tr><th>City</th><td>#{@vehicle.location_city}</td></tr>" if @vehicle.location_city.present?
          location_html += "<tr><th>State</th><td>#{@vehicle.location_state}</td></tr>" if @vehicle.location_state.present?
          location_html += "<tr><th>ZIP</th><td>#{@vehicle.location_zip}</td></tr>" if @vehicle.location_zip.present?
          location_html += "<tr><th>County</th><td>#{@vehicle.county_name}</td></tr>" if @vehicle.county_name.present?
          location_html += "<tr><th>Community</th><td>#{@vehicle.community_name}</td></tr>" if @vehicle.community_name.present?
          location_html += '</table>'
        end
        
        # Build features HTML
        features_html = ''
        if @vehicle.features.present? && @vehicle.features.any?
          features_html = '<h2>Additional Features</h2><ul class="features-list">'
          @vehicle.features.each { |f| features_html += "<li>#{f}</li>" }
          features_html += '</ul>'
        end
        
        html = <<~HTML
          <!DOCTYPE html>
          <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{@vehicle.display_name} - Inventory Details</title>
            <style>
              @media print {
                body { margin: 0; }
                .no-print { display: none; }
                .page-break { page-break-after: always; }
              }
              
              body { 
                font-family: Arial, sans-serif; 
                margin: 40px;
                font-size: 11pt;
                line-height: 1.4;
              }
              
              h1 { 
                margin-bottom: 10px;
                font-size: 24pt;
                color: #1a1a1a;
              }
              
              h2 { 
                margin-top: 25px;
                margin-bottom: 12px;
                border-bottom: 2px solid #333;
                padding-bottom: 5px;
                font-size: 14pt;
                color: #1a1a1a;
              }
              
              table { 
                width: 100%;
                border-collapse: collapse;
                margin-bottom: 20px;
              }
              
              th, td { 
                padding: 8px 10px;
                text-align: left;
                border-bottom: 1px solid #ddd;
              }
              
              th { 
                background-color: #f5f5f5;
                font-weight: 600;
                width: 35%;
              }
              
              .header { 
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 20px;
                border-bottom: 2px solid #333;
                margin-bottom: 20px;
              }
              
              .dealer-info { 
                text-align: right;
                font-size: 10pt;
                line-height: 1.5;
              }
              
              .dealer-name { 
                font-size: 16pt;
                font-weight: bold;
                margin-bottom: 5px;
              }
              
              .price-highlight {
                font-size: 20pt;
                font-weight: bold;
                color: #d32f2f;
              }
              
              .status-badge {
                display: inline-block;
                padding: 5px 12px;
                background-color: #4caf50;
                color: white;
                border-radius: 3px;
                font-size: 10pt;
                font-weight: bold;
                text-transform: uppercase;
                margin-bottom: 15px;
              }
              
              .description-box {
                background-color: #f9f9f9;
                padding: 15px;
                border-left: 4px solid #2196f3;
                margin: 20px 0;
              }
              
              .image-gallery {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                gap: 15px;
                margin: 20px 0;
              }
              
              .gallery-item img {
                width: 100%;
                height: 200px;
                object-fit: cover;
                border: 1px solid #ddd;
                border-radius: 4px;
              }
              
              .amenities-list, .features-list {
                column-count: 2;
                column-gap: 30px;
                list-style-type: disc;
                padding-left: 20px;
              }
              
              .amenities-list li, .features-list li {
                break-inside: avoid;
                padding: 3px 0;
              }
              
              .footer { 
                margin-top: 40px;
                padding-top: 20px;
                border-top: 1px solid #ccc;
                text-align: center;
                color: #666;
                font-size: 9pt;
              }
              
              .two-column {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 20px;
              }
            </style>
          </head>
          <body>
            <div class="header">
              <div>
                #{company_settings['logoUrl'].present? ? "<img src='#{company_settings['logoUrl']}' alt='Logo' style='max-height: 80px;'>" : ''}
              </div>
              <div class="dealer-info">
                #{company_settings['companyName'].present? ? "<div class='dealer-name'>#{company_settings['companyName']}</div>" : ''}
                #{company_settings['companyAddress'].present? ? "<div>#{company_settings['companyAddress']}</div>" : ''}
                #{company_settings['companyCity'].present? || company_settings['companyState'].present? ? "<div>#{[company_settings['companyCity'], company_settings['companyState']].compact.join(', ')} #{company_settings['companyZip']}</div>" : ''}
                #{company_settings['companyPhone'].present? ? "<div>Phone: #{company_settings['companyPhone']}</div>" : ''}
                #{company_settings['companyEmail'].present? ? "<div>Email: #{company_settings['companyEmail']}</div>" : ''}
              </div>
            </div>
            
            <h1>#{@vehicle.display_name}</h1>
            <div class="status-badge">#{@vehicle.status.upcase}</div>
            <p style="color: #666; margin-bottom: 20px;">Stock #: #{@vehicle.inventory_id}</p>
            
            #{images_html}
            
            <h2>Basic Information</h2>
            <table>
              #{@vehicle.year.present? ? "<tr><th>Year</th><td>#{@vehicle.year}</td></tr>" : ''}
              #{@vehicle.make.present? ? "<tr><th>Make</th><td>#{@vehicle.make}</td></tr>" : ''}
              #{@vehicle.model.present? ? "<tr><th>Model</th><td>#{@vehicle.model}</td></tr>" : ''}
              #{@vehicle.trim.present? ? "<tr><th>Trim</th><td>#{@vehicle.trim}</td></tr>" : ''}
              #{(@vehicle.vin || @vehicle.serial_number).present? ? "<tr><th>VIN/Serial</th><td>#{@vehicle.vin || @vehicle.serial_number}</td></tr>" : ''}
              #{@vehicle.condition.present? ? "<tr><th>Condition</th><td>#{@vehicle.condition.titleize}</td></tr>" : ''}
              #{@vehicle.color.present? ? "<tr><th>Color</th><td>#{@vehicle.color}</td></tr>" : ''}
              #{@vehicle.date_in_stock.present? ? "<tr><th>Date in Stock</th><td>#{@vehicle.date_in_stock}</td></tr>" : ''}
            </table>
            
            #{@vehicle.description.present? ? "<h2>Description</h2><div class='description-box'>#{@vehicle.description}</div>" : ''}
            
            <h2>Pricing Information</h2>
            <table>
              #{@vehicle.sale_price.present? ? "<tr><th>Sale Price</th><td class='price-highlight'>#{format_currency(@vehicle.sale_price)}</td></tr>" : ''}
              #{@vehicle.msrp.present? ? "<tr><th>MSRP</th><td>#{format_currency(@vehicle.msrp)}</td></tr>" : ''}
              #{@vehicle.cost.present? ? "<tr><th>Cost</th><td>#{format_currency(@vehicle.cost)}</td></tr>" : ''}
              #{@vehicle.rent_price.present? ? "<tr><th>Monthly Rent</th><td>#{format_currency(@vehicle.rent_price)}/month</td></tr>" : ''}
              #{@vehicle.rent_to_own_price.present? ? "<tr><th>Rent-to-Own</th><td>#{format_currency(@vehicle.rent_to_own_price)}/month</td></tr>" : ''}
              #{@vehicle.deposit_amount.present? ? "<tr><th>Deposit Amount</th><td>#{format_currency(@vehicle.deposit_amount)}</td></tr>" : ''}
              #{@vehicle.lot_rent.present? ? "<tr><th>Lot Rent</th><td>#{format_currency(@vehicle.lot_rent)}/month</td></tr>" : ''}
              #{@vehicle.utilities.present? ? "<tr><th>Utilities</th><td>#{format_currency(@vehicle.utilities)}/month</td></tr>" : ''}
            </table>
            
            #{rv_specs_html}
            #{mh_specs_html}
            #{location_html}
            #{features_html}
            
            #{@vehicle.notes.present? ? "<h2>Notes</h2><div class='description-box'>#{@vehicle.notes}</div>" : ''}
            
            <div class="footer">
              <p><strong>Generated on #{Time.current.strftime('%B %d, %Y at %I:%M %p')}</strong></p>
              <p>This document is for informational purposes only. All information subject to verification.</p>
            </div>
          </body>
          </html>
        HTML
        
        render html: html.html_safe
      end

      def stats
        vehicles = @company.vehicles.active
        
        # Apply strict location filter - only vehicles explicitly assigned to selected location
        if Current.location_filtered?
          vehicles = vehicles.where(location_id: Current.location_id)
        end
        
        render json: {
          total: vehicles.count,
          available: vehicles.available.count,
          reserved: vehicles.reserved.count,
          sold: vehicles.sold.count,
          pending: vehicles.pending.count,
          by_type: {
            rv: vehicles.rvs.count,
            manufactured_home: vehicles.manufactured_homes.count
          },
          by_status: vehicles.group(:status).count,
          total_value: {
            sale: vehicles.includes(:inventory_packages).sum { |v| v.total_home_price.to_f },
            rent: vehicles.sum(:rent_price).to_f
          }
        }
      end

      # GET /api/v1/vehicles/export
      def export
        vehicles = @company.vehicles.active
        
        # Apply strict location filter - only vehicles explicitly assigned to selected location
        if Current.location_filtered?
          vehicles = vehicles.where(location_id: Current.location_id)
        end
        
        # Apply same filters as index
        vehicles = vehicles.by_type(params[:type]) if params[:type].present?
        vehicles = vehicles.by_status(params[:status]) if params[:status].present?
        vehicles = vehicles.by_year(params[:year]) if params[:year].present?
        vehicles = vehicles.by_make(params[:make]) if params[:make].present?
        vehicles = vehicles.by_model(params[:model]) if params[:model].present?
        vehicles = vehicles.search(params[:search]) if params[:search].present?
        
        # Generate CSV
        require 'csv'
        csv_data = CSV.generate(headers: true) do |csv|
          # Headers
          csv << [
            'Inventory ID',
            'Type',
            'Year',
            'Make',
            'Model',
            'Status',
            'Sale Price',
            'Rent Price',
            'VIN/Serial',
            'City',
            'State',
            'Date Added'
          ]
          
          # Data rows
          vehicles.each do |vehicle|
            csv << [
              vehicle.inventory_id,
              vehicle.listing_type,
              vehicle.year,
              vehicle.make,
              vehicle.model,
              vehicle.status,
              vehicle.sale_price,
              vehicle.rent_price,
              vehicle.is_rv? ? vehicle.vin : vehicle.serial_number,
              vehicle.location_city,
              vehicle.location_state,
              vehicle.created_at&.strftime('%Y-%m-%d')
            ]
          end
        end
        
        # Send CSV file
        send_data csv_data,
          filename: "inventory-export-#{Date.today}.csv",
          type: 'text/csv',
          disposition: 'attachment'
      end

      def bulk_update
        vehicle_ids = params[:vehicle_ids] || []
        updates = params[:updates] || {}
        
        return render json: { error: 'No vehicles selected' }, status: :bad_request if vehicle_ids.empty?
        return render json: { error: 'No updates provided' }, status: :bad_request if updates.empty?

        vehicles = @company.vehicles.where(id: vehicle_ids)
        updated_count = 0

        vehicles.each do |vehicle|
          if vehicle.update(updates.permit(:status, :location_city, :location_state))
            updated_count += 1
          end
        end

        render json: { 
          success: true, 
          updated_count: updated_count,
          total_count: vehicle_ids.length
        }
      end

      def bulk_delete
        vehicle_ids = params[:vehicle_ids] || []
        
        return render json: { error: 'No vehicles selected' }, status: :bad_request if vehicle_ids.empty?

        vehicles = @company.vehicles.where(id: vehicle_ids)
        vehicles.each(&:soft_delete!)

        render json: { 
          success: true, 
          deleted_count: vehicles.count
        }
      end

      def import
        return render json: { error: 'No file provided' }, status: :bad_request unless params[:file]

        require 'csv'

        file = params[:file]
        imported = []
        errors = []
        row_number = 1

        CSV.foreach(file.path, headers: true, header_converters: :symbol) do |row|
          row_number += 1
          begin
            vehicle = @company.vehicles.new(csv_row_to_params(row))

            if vehicle.save
              # Option B: Split features on semicolons into individual records
              features_raw = row[:features] || row[:Features]
              if features_raw.present?
                feature_names = features_raw.to_s.split(';').map(&:strip).reject(&:blank?)
                feature_names.each do |feature_name|
                  vehicle.inventory_features.create(
                    name: feature_name,
                    company_id: @company.id,
                    is_standard: true
                  )
                rescue ActiveRecord::RecordInvalid
                  # Skip duplicates silently
                end

                # Also store as JSON array for backward compatibility
                vehicle.update_column(:features, feature_names)
              end

              # Split photo URLs on pipe into images array
              photo_raw = row[:photo_url] || row[:photoUrl] || row[:Photo_URL]
              if photo_raw.present? && photo_raw.to_s.include?('|')
                urls = photo_raw.to_s.split('|').map(&:strip).reject(&:blank?)
                vehicle.update_columns(
                  photo_url: urls.first,
                  images: urls.map { |url| { 'url' => url } }
                )
              elsif photo_raw.present?
                vehicle.update_column(:photo_url, photo_raw.to_s.strip)
              end

              # Floor plan URL → floor_plan_images array
              fp_raw = row[:floor_plan_url] || row[:floorPlanUrl] || row[:Floor_Plan_URL]
              if fp_raw.present?
                fp_urls = fp_raw.to_s.split('|').map(&:strip).reject(&:blank?)
                vehicle.update_column(:floor_plan_images, fp_urls.map { |url| { 'url' => url } })
              end

              imported << vehicle
            else
              errors << { row: row_number, errors: vehicle.errors.full_messages }
            end
          rescue => e
            errors << { row: row_number, errors: [e.message] }
          end
        end

        render json: {
          success: true,
          imported_count: imported.length,
          error_count: errors.length,
          vehicles: imported.map { |v| vehicle_json(v) },
          errors: errors
        }
      rescue CSV::MalformedCSVError => e
        render json: { error: "Invalid CSV format: #{e.message}" }, status: :bad_request
      rescue => e
        render json: { error: "Import failed: #{e.message}" }, status: :internal_server_error
      end

      # GET /api/v1/vehicles/:id/tags
      def tags
        # Get tags through the association
        tags = @vehicle.tags.map do |tag|
          {
            id: tag.id,
            name: tag.name,
            description: tag.description,
            color: tag.color,
            category: tag.category,
            type: tag.try(:tag_type),
            isSystem: tag.try(:is_system),
            isActive: tag.try(:is_active),
            usageCount: tag.usage_count,
            createdBy: tag.try(:created_by),
            createdAt: tag.created_at,
            updatedAt: tag.updated_at
          }.compact
        end
        
        render json: tags
      end

      # POST /api/v1/vehicles/:id/tags
      def add_tags
        tag_names = params[:tags] || []
        tag_names = tag_names.split(',') if tag_names.is_a?(String)
        
        tag_names.each do |tag_name|
          # Find or create tag within current company scope
          tag = @company.tags.find_or_create_by!(name: tag_name.strip) do |new_tag|
            new_tag.color = '#6B7280'
            new_tag.is_active = true
            new_tag.created_by = current_user&.id&.to_s || 'system'
          end
          
          # Create tag assignment using polymorphic association
          TagAssignment.find_or_create_by!(
            tag: tag,
            entity_type: 'Vehicle',
            entity_id: @vehicle.id
          ) do |assignment|
            assignment.company_id = @company.id
            assignment.assigned_by = current_user&.id&.to_s || 'system'
            assignment.assigned_at = Time.current
          end
        end
        
        # Reload tags association to get updated list
        @vehicle.reload
        render json: vehicle_json(@vehicle, detailed: true)
      end

      # DELETE /api/v1/vehicles/:id/tags/:tag_name
      def remove_tag
        # Find tag within company scope
        tag = @company.tags.find_by(name: params[:tag_name])
        
        if tag
          # Remove tag assignment using polymorphic association
          TagAssignment.where(
            tag: tag,
            entity_type: 'Vehicle',
            entity_id: @vehicle.id
          ).destroy_all
        end
        
        # Reload tags association to get updated list
        @vehicle.reload
        render json: vehicle_json(@vehicle, detailed: true)
      end

      private

      # Resolve location from import params: locationId > locationName > Current.location_id
      # Returns [location_id, error_message]
      def resolve_import_location_id
        # 1. Direct location_id from CSV
        loc_id = params[:vehicle]&.dig(:locationId) || params[:vehicle]&.dig(:location_id)
        if loc_id.present?
          loc = @company.locations.find_by(id: loc_id)
          if loc
            return [loc.id, nil]
          else
            available = @company.locations.pluck(:id, :name).map { |id, name| "#{id}: #{name}" }.join(', ')
            return [nil, "Location ID #{loc_id} not found. Available: #{available}"]
          end
        end
        
        # 2. Location name lookup from CSV
        loc_name = params[:vehicle]&.dig(:locationName) || params[:vehicle]&.dig(:location_name)
        if loc_name.present?
          loc = @company.locations.where('name ILIKE ?', loc_name.to_s.strip).first
          if loc
            return [loc.id, nil]
          else
            available = @company.locations.pluck(:name).join(', ')
            return [nil, "Location '#{loc_name}' not found. Available: #{available}"]
          end
        end
        
        # 3. No location specified in CSV — fall back to current location selector
        [Current.location_id, nil]
      end

      def generate_inventory_id
        # Generate a new unique inventory ID
        prefix = @company.vehicles.last&.inventory_id&.match(/^[A-Z]+/)&.to_s || 'INV'
        last_number = @company.vehicles.where("inventory_id LIKE ?", "#{prefix}%")
                               .order(inventory_id: :desc)
                               .first&.inventory_id&.match(/(\d+)$/)&.to_a&.[](1)&.to_i || 0
        "#{prefix}#{(last_number + 1).to_s.rjust(5, '0')}"
      end

      def set_company
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "[VehiclesController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "[VehiclesController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "[VehiclesController] Company scope set: #{@company.name} (ID: #{@company.id}) for user: #{current_user.email}"
      end

      def set_vehicle
        # STRICT TENANT ISOLATION: Only find vehicles within company
        # RBAC: Location-tier users only access their assigned locations
        @vehicle = if current_user.uses_rbac? && !current_user.effective_admin?  # Use RBAC-aware admin check
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # Strict location filtering - only assigned locations
            @company.vehicles.active.where(location_id: location_ids).find(params[:id])
          else
            @company.vehicles.active.find(params[:id])
          end
        else
          @company.vehicles.active.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Vehicle not found or access denied' }, status: :not_found
      end

      # Helper method to format currency like the quotes PDF generator
      def format_currency(amount)
        "$#{sprintf('%.2f', amount.to_f)}"
      end

      # Create activity record for listing share to contact
      def create_contact_share_activity(contact_id, result, send_params)
        # Verify contact belongs to this company for tenant isolation
        contact = @company.contacts.find_by(id: contact_id)
        return nil unless contact
        
        # Build activity description
        channels = result[:sent].map { |r| r[:channel] }.uniq.join(' and ')
        recipients = result[:sent].map { |r| r[:to] }.uniq
        
        listing_title = [@vehicle.year, @vehicle.make, @vehicle.model].compact.join(' ')
        
        description_parts = []
        description_parts << "Shared listing via #{channels}"
        description_parts << "Recipients: #{recipients.join(', ')}"
        description_parts << "Custom message: #{send_params[:custom_message]}" if send_params[:custom_message].present?
        
        # Build listing link
        base_url = request.base_url
        company_slug = @company.slug || 'demo'
        listing_url = "#{base_url}/public/#{company_slug}/listing/#{@vehicle.id}"
        listing_link = "\n\nView listing: #{listing_url}"
        
        description = description_parts.join("\n") + listing_link
        
        # Create the activity
        activity = ContactActivity.create!(
          contact: contact,
          user: current_user,
          activity_type: 'note',
          subject: "Shared listing: #{listing_title}",
          description: description,
          status: 'completed',
          priority: 'medium',
          completed_at: Time.current,
          metadata: {
            listing_id: @vehicle.id,
            listing_url: listing_url,
            listing_type: @vehicle.listing_type,
            channels_used: result[:sent].map { |r| r[:channel] },
            communications: result[:sent].map { |r| r[:communication]&.id }.compact
          }
        )
        
        Rails.logger.info "Created activity #{activity.id} for listing share to contact #{contact.id}"
        activity
      rescue => e
        Rails.logger.error "Failed to create share activity: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        nil
      end

      # Create activity record for listing share to lead
      def create_lead_share_activity(lead_id, result, send_params)
        # Verify lead belongs to this company for tenant isolation
        lead = Lead.where(company_id: @company.id).find_by(id: lead_id)
        return nil unless lead
        
        # Build activity description
        channels = result[:sent].map { |r| r[:channel] }.uniq.join(' and ')
        recipients = result[:sent].map { |r| r[:to] }.uniq
        
        listing_title = [@vehicle.year, @vehicle.make, @vehicle.model].compact.join(' ')
        
        description_parts = []
        description_parts << "Shared listing via #{channels}"
        description_parts << "Recipients: #{recipients.join(', ')}"
        description_parts << "Custom message: #{send_params[:custom_message]}" if send_params[:custom_message].present?
        
        # Build listing link
        base_url = request.base_url
        company_slug = @company.slug || 'demo'
        listing_url = "#{base_url}/public/#{company_slug}/listing/#{@vehicle.id}"
        listing_link = "\n\nView listing: #{listing_url}"
        
        description = description_parts.join("\n") + listing_link
        
        # Create the activity
        activity = LeadActivity.create!(
          lead: lead,
          user: current_user,
          activity_type: 'note',
          subject: "Shared listing: #{listing_title}",
          description: description,
          status: 'completed',
          priority: 'medium',
          completed_at: Time.current,
          metadata: {
            listing_id: @vehicle.id,
            listing_url: listing_url,
            listing_type: @vehicle.listing_type,
            channels_used: result[:sent].map { |r| r[:channel] },
            communications: result[:sent].map { |r| r[:communication]&.id }.compact
          }
        )
        
        Rails.logger.info "Created activity #{activity.id} for listing share to lead #{lead.id}"
        activity
      rescue => e
        Rails.logger.error "Failed to create lead share activity: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        nil
      end

      def vehicle_params
        # Get the raw vehicle params
        raw_params = params.require(:vehicle)
        
        # Convert to hash for easier manipulation
        transformed = {}
        
        # Handle nested location object first
        if raw_params[:location].present?
          location = raw_params[:location]
          transformed[:location_city] = location[:city]
          transformed[:location_state] = location[:state]
          transformed[:location_zip] = location[:zip]
        end
        
        # Map camelCase to snake_case fields
        field_mappings = {
          listingType: :listing_type,
          type: :listing_type,           # Overrides listingType if both sent (import sends listingType='rent' + type='rv'/'manufactured_home')
          serialNumber: :serial_number,
          homeType: :home_type,
          salePrice: :sale_price,
          rentPrice: :rent_price,
          rentToOwnPrice: :rent_to_own_price,
          depositAmount: :deposit_amount,
          bodyStyle: :body_style,
          fuelType: :fuel_type,
          roofType: :roof_type,
          sidingType: :siding_type,
          lotRent: :lot_rent,
          communityName: :community_name,
          centralAir: :central_air,
          dateInStock: :date_in_stock,
          dateSold: :date_sold,
          inventoryId: :inventory_id,
          stockNumber: :inventory_id,
          mileageUnit: :mileage_unit,
          exteriorColor: :exterior_color,
          interiorColor: :interior_color,
          vehicleInteriorType: :vehicle_interior_type,
          vehicleConfiguration: :vehicle_configuration,
          rvType: :rv_type,
          slideOuts: :slide_outs,
          numberOfDoors: :number_of_doors,
          seatingCapacity: :seating_capacity,
          priceCurrency: :price_currency,
          sellerName: :seller_name,
          sellerPhone: :seller_phone,
          sellerAddressStreet: :seller_address_street,
          sellerAddressCity: :seller_address_city,
          sellerAddressState: :seller_address_state,
          sellerAddressZip: :seller_address_zip,
          listingUrl: :listing_url,
          dwellingType: :dwelling_type,
          foundationType: :foundation_type,
          flooringType: :flooring_type,
          heatingType: :heating_type,
          coolingType: :cooling_type,
          waterHeaterType: :water_heater_type,
          masterBedroomLocation: :master_bedroom_location,
          # Important: map availability to status
          availability: :status,
          # Address fields - map plain city/state/zip to location_ columns
          city: :location_city,
          state: :location_state,
          zip: :location_zip,
          locationType: :location_type,
          communityKey: :community_key,
          address1: :address1,
          address2: :address2,
          zip9: :location_zip,
          countyName: :county_name,
          # Construction
          exteriorMaterial: :exterior_material,
          roofMaterial: :roof_material,
          insulationType: :insulation_type,
          ceilingType: :ceiling_type,
          wallType: :wall_type,
          squareFootage: :square_feet,  # Frontend sends squareFootage, not squareFeet
          # Boolean amenities
          hasFireplace: :fireplace,
          hasDeck: :deck,
          hasStorage: :has_storage,
          hasCarport: :carport,
          cathedralCeiling: :cathedral_ceiling,
          ceilingFan: :ceiling_fan,
          walkinCloset: :walkin_closet,
          laundryRoom: :laundry_room,
          sunRoom: :sun_room,
          gardenTub: :garden_tub,
          garbageDisposal: :garbage_disposal,
          clothesWasher: :clothes_washer,
          clothesDryer: :clothes_dryer,
          packageType: :package_type,
          salePending: :sale_pending,
          # Media
          photoURL: :photo_url,
          photoUrl: :photo_url,
          virtualTour: :virtual_tour,
          salesPhoto: :sales_photo,
          floorPlanImages: :floor_plan_images,
          # RVT.com Syndication Fields - NEW
          rvClass: :rv_class,
          engineMake: :engine_make,
          engineType: :engine_type,
          sleepingCapacity: :sleeping_capacity,
          numAirConditioners: :num_air_conditioners,
          slideouts: :slideouts,
          awnings: :awnings,
          freshWaterCapacity: :fresh_water_capacity,
          grayWaterCapacity: :gray_water_capacity,
          blackWaterCapacity: :black_water_capacity,
          propaneCapacity: :propane_capacity,
          dryWeight: :dry_weight,
          grossWeight: :gross_weight,
          hitchWeight: :hitch_weight,
          cargoCapacity: :cargo_capacity,
          levelingJacks: :leveling_jacks,
          selfContained: :self_contained,
          solarPanels: :solar_panels,
          backupCamera: :backup_camera,
          satelliteTv: :satellite_tv,
          generatorMake: :generator_make,
          generatorHours: :generator_hours,
          generatorFuelType: :generator_fuel_type,
          videoUrl: :video_url,
          virtualTourUrl: :virtual_tour_url,
          specialFeatures: :special_features,
          overlayText: :overlay_text,
          # RBAC Cost Detail Fields - NEW
          dealerCost: :dealer_cost,
          freightCost: :freight_cost,
          pdiCost: :pdi_cost,
          totalCost: :total_cost,
          holdbackAmount: :holdback_amount,
          floorPlanRate: :floor_plan_rate,
          targetGross: :target_gross,
          minimumPrice: :minimum_price,
          # Special Discount
          specialDiscountEnabled: :special_discount_enabled,
          discountType: :discount_type,
          discountValue: :discount_value,
          discountedPrice: :discounted_price,
          # Custom field values (Page Layout Editor)
          customFieldValues: :custom_field_values,
          # MH Standard Columns
          insulationRRoof: :insulation_r_roof,
          insulationRWall: :insulation_r_wall,
          insulationRFloor: :insulation_r_floor,
          floorJoistSize: :floor_joist_size,
          electricalService: :electrical_service,
          modularConversionCost: :modular_conversion_cost,
          # Media: floor plan URL string → virtual attr → floor_plan_images array
          floorPlanUrl: :floor_plan_url
        }
        
        # Copy and transform camelCase fields
        field_mappings.each do |camel, snake|
          if raw_params[camel].present?
            transformed[snake] = raw_params[camel]
          end
        end
        
        # Copy direct fields (already in snake_case or same in both)
        # CRITICAL: direct_fields must include ALL snake_case field names that inline edit sends.
        # The camelCase mappings above only handle keys like `serialNumber` -> :serial_number.
        # Inline edit sends snake_case directly (e.g., `serial_number`), so it must also be here.
        direct_fields = [
          # Core fields
          :vin, :year, :make, :model, :trim, :color, :status, :inventory_id,
          :description, :notes, :mileage, :condition, :listing_type,
          :serial_number, :home_type,
          # Dimensions
          :bedrooms, :bathrooms, :length, :width, :sleeps, :weight, :square_feet,
          :width1, :length1, :width2, :length2, :width3, :length3,
          :sections,
          # MH amenities & construction
          :garage, :carport, :deck, :patio, :fireplace, :central_air,
          :has_storage, :thermopane, :gutters, :shutters, :skylight, :pantry,
          :basement, :cathedral_ceiling, :ceiling_fan, :walkin_closet,
          :laundry_room, :sun_room, :garden_tub,
          :exterior_material, :roof_material, :roof_type, :siding_type,
          :insulation_type, :ceiling_type, :wall_type,
          :flooring_type, :heating_type, :cooling_type, :water_heater_type,
          :dwelling_type, :foundation_type, :master_bedroom_location,
          # MH appliances
          :garbage_disposal, :refrigerator, :microwave, :oven, :dishwasher,
          :clothes_washer, :clothes_dryer,
          # Pricing & terms
          :msrp, :cost, :sale_price, :rent_price, :rent_to_own_price,
          :deposit_amount, :lot_rent, :price_currency, :utilities, :terms,
          :repo, :sale_pending, :package_type,
          # Cost details
          :dealer_cost, :freight_cost, :pdi_cost, :total_cost,
          :holdback_amount, :floor_plan_rate, :target_gross, :minimum_price,
          # Special Discount
          :special_discount_enabled, :discount_type, :discount_value, :discounted_price,
          # RV fields
          :body_style, :fuel_type, :transmission, :mileage_unit,
          :exterior_color, :interior_color, :vehicle_interior_type,
          :vehicle_configuration, :rv_type, :slide_outs, :number_of_doors,
          :seating_capacity, :awning, :generator,
          # RV syndication fields
          :rv_class, :engine_make, :engine_type, :sleeping_capacity,
          :num_air_conditioners, :slideouts, :awnings,
          :fresh_water_capacity, :gray_water_capacity, :black_water_capacity,
          :propane_capacity, :dry_weight, :gross_weight, :hitch_weight,
          :cargo_capacity, :leveling_jacks, :self_contained, :solar_panels,
          :backup_camera, :satellite_tv, :generator_make, :generator_hours,
          :generator_fuel_type, :special_features, :overlay_text,
          # Seller
          :seller_name, :seller_phone, :seller_address_street,
          :seller_address_city, :seller_address_state, :seller_address_zip,
          # Media
          :photo_url, :virtual_tour, :sales_photo, :listing_url,
          :video_url, :virtual_tour_url,
          :features, :images, :videos, :appliances, :floor_plan_images,
          # Location
          :location_id, :use_location_address,
          :location_city, :location_state, :location_zip,
          :location_type, :community_key, :community_name, :county_name,
          :address1, :address2,
          # Dates
          :date_in_stock, :date_sold,
          # Custom fields
          :custom_field_values,
          # MH Standard Columns
          :insulation_r_roof, :insulation_r_wall, :insulation_r_floor,
          :floor_joist_size, :electrical_service, :modular_conversion_cost,
          # Media: virtual attr
          :floor_plan_url
        ]
        
        direct_fields.each do |field|
          # Use key? check instead of present? to handle boolean false and 0 values
          if raw_params.key?(field) && !raw_params[field].nil?
            transformed[field] = raw_params[field]
          end
        end
        
        # Return as ActionController::Parameters for permit
        ActionController::Parameters.new(transformed).permit(
          :listing_type, :status, :year, :make, :model, :trim, :color,
          :sale_price, :rent_price, :rent_to_own_price, :deposit_amount,
          :description, :notes,
          :location_city, :location_state, :location_zip,
          :date_in_stock, :date_sold, :inventory_id,
          :vin, :mileage, :mileage_unit, :body_style, :fuel_type, :transmission,
          :condition, :length, :weight, :sleeps, :exterior_color, :interior_color,
          :vehicle_interior_type, :vehicle_configuration, :rv_type, :slide_outs,
          :awning, :generator, :number_of_doors, :seating_capacity,
          :msrp, :cost, :price_currency,
          :serial_number, :bedrooms, :bathrooms, :home_type, :width, :length,
          :width1, :length1, :width2, :length2, :width3, :length3,
          :roof_type, :siding_type, :lot_rent, :community_name,
          :garage, :carport, :deck, :patio, :fireplace, :central_air,
          :seller_name, :seller_phone, :seller_address_street, :seller_address_city,
          :seller_address_state, :seller_address_zip,
          :listing_url,
          :dwelling_type, :foundation_type, :flooring_type, :heating_type,
          :cooling_type, :water_heater_type, :master_bedroom_location,
          # Address fields
          :location_type, :community_key, :address1, :address2, :county_name, :square_feet,
          # Construction
          :exterior_material, :roof_material, :insulation_type, :ceiling_type, :wall_type,
          # Amenities
          :has_storage, :thermopane, :gutters, :shutters, :cathedral_ceiling,
          :ceiling_fan, :skylight, :walkin_closet, :laundry_room, :pantry,
          :sun_room, :basement, :garden_tub,
          # Appliances
          :garbage_disposal, :refrigerator, :microwave, :oven, :dishwasher,
          :clothes_washer, :clothes_dryer,
          # Pricing and terms
          :utilities, :terms, :repo, :package_type, :sale_pending,
          # Media
          :photo_url, :virtual_tour, :sales_photo,
          # RVT.com Syndication Fields - NEW
          :rv_class, :engine_make, :engine_type, :sleeping_capacity, :num_air_conditioners,
          :slideouts, :awnings, :fresh_water_capacity, :gray_water_capacity, :black_water_capacity,
          :propane_capacity, :dry_weight, :gross_weight, :hitch_weight, :cargo_capacity,
          :leveling_jacks, :self_contained, :solar_panels, :backup_camera, :satellite_tv,
          :generator_make, :generator_hours, :generator_fuel_type,
          :video_url, :virtual_tour_url, :special_features, :overlay_text,
          # RBAC Cost Detail Fields - NEW
          :dealer_cost, :freight_cost, :pdi_cost, :total_cost,
          :holdback_amount, :floor_plan_rate, :target_gross, :minimum_price,
          # Special Discount
          :special_discount_enabled, :discount_type, :discount_value, :discounted_price,
          # Location ID and address override
          :location_id,
          :use_location_address,
          :sections,  # NEW: Number of sections for manufactured homes
          # MH Standard Columns
          :insulation_r_roof, :insulation_r_wall, :insulation_r_floor,
          :floor_joist_size, :electrical_service, :modular_conversion_cost,
          :floor_plan_url,  # Virtual attr: URL string → floor_plan_images array in model callback
          # Arrays
          features: [], images: [], videos: [], appliances: [], floor_plan_images: []
          # NOTE: custom_field_values is handled directly in update action (not here)
          # because dynamic JSONB keys get stripped by strong params
        )
      end

      def vehicle_json(vehicle, detailed: false)
        # Helper to convert relative image URLs to full URLs
        protocol = request.ssl? ? 'https' : 'http'
        base_url = "#{protocol}://#{request.host}:#{request.port}"
        
        # Helper to format decimal values (remove unnecessary .0)
        # 2.0 -> 2, 1.5 -> 1.5, 3.0 -> 3, 2.5 -> 2.5
        def format_decimal(value)
          return nil if value.nil?
          value.to_f % 1 == 0 ? value.to_i : value.to_f
        end
        
        # Convert image URLs - handle both plain string URLs and Hash objects (S3 uploads)
        full_image_urls = (vehicle.images || []).map do |url|
          raw = url.is_a?(Hash) ? (url['url'] || url[:url]) : url
          next nil if raw.blank?
          raw.start_with?('http') ? raw : "#{base_url}#{raw}"
        end.compact
        
        json = {
          id: vehicle.id.to_s,
          inventoryId: vehicle.inventory_id,
          listingType: vehicle.listing_type,
          status: vehicle.status,
          year: vehicle.year,
          make: vehicle.make,
          model: vehicle.model,
          trim: vehicle.trim,
          color: vehicle.color,
          salePrice: vehicle.sale_price&.to_f,
          rentPrice: vehicle.rent_price&.to_f,
          rentToOwnPrice: vehicle.rent_to_own_price&.to_f,
          depositAmount: vehicle.deposit_amount&.to_f,
          description: vehicle.description,
          notes: vehicle.notes,
          location: {
            city: vehicle.location_city.presence || vehicle.location&.city,
            state: vehicle.location_state.presence || vehicle.location&.state,
            zip: vehicle.location_zip.presence || vehicle.location&.zip_code,
            name: vehicle.location&.name
          },
          # Location fields for form
          locationId: vehicle.location_id,
          useLocationAddress: vehicle.use_location_address || false,
          displayName: vehicle.display_name,
          identifier: vehicle.identifier,
          dateInStock: vehicle.date_in_stock,
          dateSold: vehicle.date_sold,
          createdAt: vehicle.created_at,
          updatedAt: vehicle.updated_at,
          features: vehicle.features || [],
          images: full_image_urls,  # Use full URLs
          videos: vehicle.videos || [],
          msrp: vehicle.msrp&.to_f,
          cost: vehicle.cost&.to_f,
          priceCurrency: vehicle.price_currency,
          specialDiscountEnabled: vehicle.respond_to?(:special_discount_enabled) ? vehicle.special_discount_enabled : false,
          discountType: vehicle.respond_to?(:discount_type) ? vehicle.discount_type : nil,
          discountValue: vehicle.respond_to?(:discount_value) ? vehicle.discount_value&.to_f : nil,
          discountedPrice: vehicle.respond_to?(:discounted_price) ? vehicle.discounted_price&.to_f : nil,
          listingUrl: vehicle.listing_url,
          sellerName: vehicle.seller_name,
          sellerPhone: vehicle.seller_phone,
          sellerAddressStreet: vehicle.seller_address_street,
          sellerAddressCity: vehicle.seller_address_city,
          sellerAddressState: vehicle.seller_address_state,
          sellerAddressZip: vehicle.seller_address_zip,
          # Custom field values (Page Layout Editor)
          customFieldValues: vehicle.custom_field_values || {},
          # Packages
          inventoryPackages: vehicle.inventory_packages.ordered.map { |p|
            {
              id: p.id,
              vehicleId: p.vehicle_id,
              packageTemplateId: p.package_template_id,
              name: p.name,
              description: p.description,
              price: p.price&.to_f,
              cost: p.respond_to?(:cost) ? p.cost&.to_f : nil,
              includeInTotal: p.include_in_total,
              showPriceInMarketing: p.show_price_in_marketing,
              taxable: p.respond_to?(:taxable) ? (p.taxable || false) : false,
              taxRate: p.respond_to?(:tax_rate) ? p.tax_rate&.to_f : nil,
              position: p.position
            }
          },
          totalHomePrice: vehicle.total_home_price
        }

        # Add type-specific fields
        if vehicle.is_rv?
          json.merge!({
            vin: vehicle.vin,
            mileage: vehicle.mileage,
            mileageUnit: vehicle.mileage_unit,
            bodyStyle: vehicle.body_style,
            fuelType: vehicle.fuel_type,
            transmission: vehicle.transmission,
            condition: vehicle.condition,
            length: vehicle.length,
            weight: vehicle.weight,
            sleeps: vehicle.sleeps,
            exteriorColor: vehicle.exterior_color,
            interiorColor: vehicle.interior_color,
            vehicleInteriorType: vehicle.vehicle_interior_type,
            vehicleConfiguration: vehicle.vehicle_configuration,
            rvType: vehicle.rv_type,
            slideOuts: vehicle.slide_outs,
            awning: vehicle.awning,
            generator: vehicle.generator,
            numberOfDoors: vehicle.number_of_doors,
            seatingCapacity: vehicle.seating_capacity,
            availability: vehicle.status,
            # CRITICAL: Address fields at top level for form compatibility (same as MH)
            address1: vehicle.address1,
            address2: vehicle.address2,
            city: vehicle.location_city,
            state: vehicle.location_state,
            zipCode: vehicle.location_zip,
            # RVT.com Syndication Fields - NEW
            rvClass: vehicle.rv_class,
            engineMake: vehicle.engine_make,
            engineType: vehicle.engine_type,
            sleepingCapacity: vehicle.sleeping_capacity,
            numAirConditioners: vehicle.num_air_conditioners,
            slideouts: vehicle.slideouts,
            awnings: vehicle.awnings,
            freshWaterCapacity: vehicle.fresh_water_capacity,
            grayWaterCapacity: vehicle.gray_water_capacity,
            blackWaterCapacity: vehicle.black_water_capacity,
            propaneCapacity: vehicle.propane_capacity,
            dryWeight: vehicle.dry_weight,
            grossWeight: vehicle.gross_weight,
            hitchWeight: vehicle.hitch_weight,
            cargoCapacity: vehicle.cargo_capacity,
            levelingJacks: vehicle.leveling_jacks,
            selfContained: vehicle.self_contained,
            solarPanels: vehicle.solar_panels,
            backupCamera: vehicle.backup_camera,
            satelliteTv: vehicle.satellite_tv,
            generatorMake: vehicle.generator_make,
            generatorHours: vehicle.generator_hours,
            generatorFuelType: vehicle.generator_fuel_type,
            videoUrl: vehicle.video_url,
            virtualTourUrl: vehicle.virtual_tour_url,
            specialFeatures: vehicle.special_features,
            overlayText: vehicle.overlay_text,
            floorPlanImages: (vehicle.floor_plan_images || []).map { |u| raw = u.is_a?(Hash) ? (u['url'] || u[:url]) : u; raw.blank? ? nil : (raw.start_with?('http') ? raw : "#{base_url}#{raw}") }.compact,
            # RBAC Cost Detail Fields - NEW
            dealerCost: vehicle.dealer_cost&.to_f,
            freightCost: vehicle.freight_cost&.to_f,
            pdiCost: vehicle.pdi_cost&.to_f,
            totalCost: vehicle.total_cost&.to_f,
            holdbackAmount: vehicle.holdback_amount&.to_f,
            floorPlanRate: vehicle.floor_plan_rate&.to_f,
            targetGross: vehicle.target_gross&.to_f,
            minimumPrice: vehicle.minimum_price&.to_f
          })
        elsif vehicle.is_manufactured_home?
          json.merge!({
            vin: vehicle.vin,
            serialNumber: vehicle.serial_number,
            bedrooms: format_decimal(vehicle.bedrooms),
            bathrooms: format_decimal(vehicle.bathrooms),
            homeType: vehicle.home_type,
            condition: vehicle.condition,
            availability: vehicle.status,
            # Dimensions at top level for form compatibility
            width: vehicle.width,
            length: vehicle.length,
            width1: vehicle.width1,
            length1: vehicle.length1,
            width2: vehicle.width2,
            length2: vehicle.length2,
            width3: vehicle.width3,
            length3: vehicle.length3,
            sections: vehicle.sections,  # Number of sections (1, 2, or 3)
          squareFootage: vehicle.square_feet,  # Changed from squareFeet to match frontend
            roofType: vehicle.roof_type,
            sidingType: vehicle.siding_type,
            lotRent: vehicle.lot_rent&.to_f,
            communityName: vehicle.community_name,
            dwellingType: vehicle.dwelling_type,
            foundationType: vehicle.foundation_type,
            flooringType: vehicle.flooring_type,
            heatingType: vehicle.heating_type,
            coolingType: vehicle.cooling_type,
            waterHeaterType: vehicle.water_heater_type,
            appliances: vehicle.appliances || [],
            masterBedroomLocation: vehicle.master_bedroom_location,
            # Address details
            locationType: vehicle.location_type,
            communityKey: vehicle.community_key,
            address1: vehicle.address1,
            address2: vehicle.address2,
            city: vehicle.location_city,
            state: vehicle.location_state,
            zip9: vehicle.location_zip,
            countyName: vehicle.county_name,
            # Construction details
            exteriorMaterial: vehicle.exterior_material,
            roofMaterial: vehicle.roof_material,
            insulationType: vehicle.insulation_type,
            ceilingType: vehicle.ceiling_type,
            wallType: vehicle.wall_type,
            # Media URLs
            photoURL: vehicle.photo_url,
            videoUrl: vehicle.video_url,
            virtualTourUrl: vehicle.virtual_tour_url,
            salesPhoto: vehicle.sales_photo,
            floorPlanImages: (vehicle.floor_plan_images || []).map { |u| raw = u.is_a?(Hash) ? (u['url'] || u[:url]) : u; raw.blank? ? nil : (raw.start_with?('http') ? raw : "#{base_url}#{raw}") }.compact,
            # Pricing & terms
            utilities: vehicle.utilities&.to_f,
            terms: vehicle.terms,
            repo: vehicle.repo,
            packageType: vehicle.package_type,
            salePending: vehicle.sale_pending,
            # Individual amenity flags (at top level for form compatibility)
            hasFireplace: vehicle.fireplace,
            hasDeck: vehicle.deck,
            hasStorage: vehicle.has_storage,
            hasCarport: vehicle.carport,
            garage: vehicle.garage,
            centralAir: vehicle.central_air,
            patio: vehicle.patio,
            thermopane: vehicle.thermopane,
            gutters: vehicle.gutters,
            shutters: vehicle.shutters,
            cathedralCeiling: vehicle.cathedral_ceiling,
            ceilingFan: vehicle.ceiling_fan,
            skylight: vehicle.skylight,
            walkinCloset: vehicle.walkin_closet,
            laundryRoom: vehicle.laundry_room,
            pantry: vehicle.pantry,
            sunRoom: vehicle.sun_room,
            basement: vehicle.basement,
            gardenTub: vehicle.garden_tub,
            # Appliances
            garbageDisposal: vehicle.garbage_disposal,
            refrigerator: vehicle.refrigerator,
            microwave: vehicle.microwave,
            oven: vehicle.oven,
            dishwasher: vehicle.dishwasher,
            clothesWasher: vehicle.clothes_washer,
            clothesDryer: vehicle.clothes_dryer,
            # MH Standard Columns
            insulationRRoof: vehicle.insulation_r_roof,
            insulationRWall: vehicle.insulation_r_wall,
            insulationRFloor: vehicle.insulation_r_floor,
            floorJoistSize: vehicle.floor_joist_size,
            electricalService: vehicle.electrical_service,
            modularConversionCost: vehicle.modular_conversion_cost&.to_f,
            # Inventory features (Option B)
            inventoryFeatures: vehicle.inventory_features.order(:name).map { |f|
              { id: f.id, name: f.name, category: f.category, isStandard: f.is_standard }
            }
          })
        end

        # Add related data if detailed view requested
        if detailed
          json[:deals] = vehicle.deals.active.map { |d| deal_summary(d) }
          json[:quotes] = vehicle.quotes.active.map { |q| quote_summary(q) }
        end

        json
      end

      def deal_summary(deal)
        {
          id: deal.id.to_s,
          name: deal.name,
          stage: deal.stage,
          value: deal.value.to_f,
          customerName: deal.customer_display_name
        }
      end

      def quote_summary(quote)
        {
          id: quote.id.to_s,
          quoteNumber: quote.quote_number,
          status: quote.status,
          total: quote.total.to_f
        }
      end

      def csv_row_to_params(row)
        {
          listing_type: row[:type] || row[:listing_type] || 'manufactured_home',
          status: row[:status] || 'available',
          inventory_id: row[:inventory_id] || row[:stock_number] || row[:stockNumber],
          year: row[:year],
          make: row[:make],
          model: row[:model],
          trim: row[:trim],
          color: row[:color],
          condition: row[:condition] || 'new',
          sale_price: row[:sale_price] || row[:salePrice] || row[:price],
          rent_price: row[:rent_price] || row[:rentPrice],
          rent_to_own_price: row[:rent_to_own_price] || row[:rentToOwnPrice],
          deposit_amount: row[:deposit_amount] || row[:depositAmount],
          msrp: row[:msrp],
          cost: row[:cost],
          dealer_cost: row[:dealer_cost] || row[:dealerCost],
          freight_cost: row[:freight_cost] || row[:freightCost],
          pdi_cost: row[:pdi_cost] || row[:pdiCost],
          total_cost: row[:total_cost] || row[:totalCost],
          holdback_amount: row[:holdback_amount] || row[:holdbackAmount],
          floor_plan_rate: row[:floor_plan_rate] || row[:floorPlanRate],
          target_gross: row[:target_gross] || row[:targetGross],
          minimum_price: row[:minimum_price] || row[:minimumPrice],
          price_currency: row[:price_currency] || row[:priceCurrency] || 'USD',
          description: row[:description],
          notes: row[:notes],
          vin: row[:vin] || row[:vin_hud_label],
          serial_number: row[:serial_number] || row[:serialNumber],
          mileage: row[:mileage],
          bedrooms: row[:bedrooms],
          bathrooms: row[:bathrooms],
          home_type: row[:home_type] || row[:homeType],
          sections: row[:sections],
          dwelling_type: row[:dwelling_type] || row[:dwellingType],
          width: row[:width],
          length: row[:length],
          square_feet: row[:square_feet] || row[:squareFeet],
          width1: row[:width1],
          length1: row[:length1],
          width2: row[:width2],
          length2: row[:length2],
          width3: row[:width3],
          length3: row[:length3],
          # Construction
          roof_type: row[:roof_type] || row[:roofType],
          roof_material: row[:roof_material] || row[:roofMaterial],
          siding_type: row[:siding_type] || row[:sidingType],
          exterior_material: row[:exterior_material] || row[:exteriorMaterial],
          ceiling_type: row[:ceiling_type] || row[:ceilingType],
          wall_type: row[:wall_type] || row[:wallType],
          flooring_type: row[:flooring_type] || row[:flooringType],
          insulation_type: row[:insulation_type] || row[:insulationType],
          foundation_type: row[:foundation_type] || row[:foundationType],
          # Systems
          heating_type: row[:heating_type] || row[:heatingType],
          cooling_type: row[:cooling_type] || row[:coolingType],
          water_heater_type: row[:water_heater_type] || row[:waterHeaterType],
          # NEW MH standard columns
          insulation_r_roof: row[:insulation_r_roof] || row[:insulationRRoof] || row[:insulation_r_value_roof],
          insulation_r_wall: row[:insulation_r_wall] || row[:insulationRWall] || row[:insulation_r_value_wall],
          insulation_r_floor: row[:insulation_r_floor] || row[:insulationRFloor] || row[:insulation_r_value_floor],
          floor_joist_size: row[:floor_joist_size] || row[:floorJoistSize],
          electrical_service: row[:electrical_service] || row[:electricalService],
          modular_conversion_cost: row[:modular_conversion_cost] || row[:modularConversionCost],
          # Appliances (booleans)
          refrigerator: parse_csv_bool(row[:refrigerator]),
          microwave: parse_csv_bool(row[:microwave]),
          oven: parse_csv_bool(row[:oven]),
          dishwasher: parse_csv_bool(row[:dishwasher]),
          garbage_disposal: parse_csv_bool(row[:garbage_disposal] || row[:garbageDisposal]),
          clothes_washer: parse_csv_bool(row[:clothes_washer] || row[:clothesWasher]),
          clothes_dryer: parse_csv_bool(row[:clothes_dryer] || row[:clothesDryer]),
          # Amenities (booleans)
          central_air: parse_csv_bool(row[:central_air] || row[:centralAir]),
          ceiling_fan: parse_csv_bool(row[:ceiling_fan] || row[:ceilingFan]),
          cathedral_ceiling: parse_csv_bool(row[:cathedral_ceiling] || row[:cathedralCeiling]),
          skylight: parse_csv_bool(row[:skylight]),
          fireplace: parse_csv_bool(row[:fireplace]),
          walkin_closet: parse_csv_bool(row[:walkin_closet] || row[:walkinCloset]),
          laundry_room: parse_csv_bool(row[:laundry_room] || row[:laundryRoom]),
          pantry: parse_csv_bool(row[:pantry]),
          garden_tub: parse_csv_bool(row[:garden_tub] || row[:gardenTub]),
          sun_room: parse_csv_bool(row[:sun_room] || row[:sunRoom]),
          basement: parse_csv_bool(row[:basement]),
          garage: parse_csv_bool(row[:garage]),
          carport: parse_csv_bool(row[:carport]),
          deck: parse_csv_bool(row[:deck]),
          patio: parse_csv_bool(row[:patio]),
          has_storage: parse_csv_bool(row[:has_storage] || row[:hasStorage]),
          thermopane: parse_csv_bool(row[:thermopane]),
          gutters: parse_csv_bool(row[:gutters]),
          shutters: parse_csv_bool(row[:shutters]),
          master_bedroom_location: row[:master_bedroom_location] || row[:masterBedroomLocation],
          # Location
          location_city: row[:city] || row[:location_city] || row[:locationCity],
          location_state: row[:state] || row[:location_state] || row[:locationState],
          location_zip: row[:zip] || row[:location_zip] || row[:locationZip],
          address1: row[:address1],
          address2: row[:address2],
          county_name: row[:county_name] || row[:countyName],
          community_name: row[:community_name] || row[:communityName],
          community_key: row[:community_key] || row[:communityKey],
          location_type: row[:location_type] || row[:locationType],
          lot_rent: row[:lot_rent] || row[:lotRent],
          # Seller
          seller_name: row[:seller_name] || row[:sellerName],
          seller_phone: row[:seller_phone] || row[:sellerPhone],
          seller_address_street: row[:seller_address_street] || row[:sellerAddressStreet],
          seller_address_city: row[:seller_address_city] || row[:sellerAddressCity],
          seller_address_state: row[:seller_address_state] || row[:sellerAddressState],
          seller_address_zip: row[:seller_address_zip] || row[:sellerAddressZip],
          # Media
          listing_url: row[:listing_url] || row[:listingUrl],
          virtual_tour: row[:virtual_tour] || row[:virtualTour],
          video_url: row[:video_url] || row[:videoUrl],
          virtual_tour_url: row[:virtual_tour_url] || row[:virtualTourUrl],
          special_features: row[:special_features] || row[:specialFeatures],
          overlay_text: row[:overlay_text] || row[:overlayText],
          # Dates
          date_in_stock: row[:date_in_stock] || row[:dateInStock],
          date_sold: row[:date_sold] || row[:dateSold],
          # Misc
          sale_pending: parse_csv_bool(row[:sale_pending] || row[:salePending]),
          repo: parse_csv_bool(row[:repo]),
          package_type: row[:package_type] || row[:packageType],
          utilities: row[:utilities],
          terms: row[:terms],
        }.compact
      end

      def parse_csv_bool(val)
        return nil if val.nil?
        str = val.to_s.strip.downcase
        return true if ['true', '1', 'yes', 'y'].include?(str)
        return false if ['false', '0', 'no', 'n'].include?(str)
        nil
      end
    end
  end
end
