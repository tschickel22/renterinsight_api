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
      before_action :set_vehicle, only: [:show, :update, :destroy, :print, :clone]

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
        
        # Apply strict location filter - only vehicles explicitly assigned to selected location
        if Current.location_filtered?
          vehicles = vehicles.where(location_id: Current.location_id)
        end
        
        # Filters
        vehicles = vehicles.by_type(params[:type]) if params[:type].present?
        vehicles = vehicles.by_status(params[:status]) if params[:status].present?
        vehicles = vehicles.by_year(params[:year]) if params[:year].present?
        vehicles = vehicles.by_make(params[:make]) if params[:make].present?
        vehicles = vehicles.by_model(params[:model]) if params[:model].present?
        
        # Search
        vehicles = vehicles.search(params[:search]) if params[:search].present?

        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order] || 'desc'
        vehicles = vehicles.order("#{sort_by} #{sort_order}")

        # Pagination
        page = params[:page]&.to_i || 1
        per_page = [params[:per_page]&.to_i || 25, 100].min
        total_count = vehicles.count
        vehicles = vehicles.offset((page - 1) * per_page).limit(per_page)

        render json: {
          vehicles: vehicles.map { |v| vehicle_json(v) },
          meta: {
            current_page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      def show
        render json: { vehicle: vehicle_json(@vehicle, detailed: true) }
      end

      def create
        vehicle = @company.vehicles.new(vehicle_params)
        
        # Auto-assign location from selector (if user selected a specific location)
        vehicle.location_id ||= Current.location_id if Current.location_id.present?
        
        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        if vehicle.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          vehicle.location_id ||= location_ids.first if location_ids.any?
        end

        if vehicle.save
          render json: { vehicle: vehicle_json(vehicle, detailed: true) }, status: :created
        else
          render json: { errors: vehicle.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @vehicle.update(vehicle_params)
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
        
        # Generate a new inventory ID
        new_vehicle.inventory_id = generate_inventory_id
        
        # Reset status to available for the clone
        new_vehicle.status = 'available'
        
        # Clear dates that should be fresh
        new_vehicle.date_in_stock = Date.today
        new_vehicle.date_sold = nil
        
        # Clear any sale-related fields
        new_vehicle.sale_pending = false
        
        # Duplicate arrays (features, images, etc.)
        new_vehicle.features = @vehicle.features&.dup || []
        new_vehicle.images = @vehicle.images&.dup || []
        new_vehicle.videos = @vehicle.videos&.dup || []
        new_vehicle.appliances = @vehicle.appliances&.dup || []
        
        if new_vehicle.save
          render json: { vehicle: vehicle_json(new_vehicle, detailed: true) }, status: :created
        else
          render json: { errors: new_vehicle.errors.full_messages }, status: :unprocessable_entity
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
          @vehicle.images.each do |img_url|
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
            sale: vehicles.sum(:sale_price).to_f,
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
        # Handle CSV import
        return render json: { error: 'No file provided' }, status: :bad_request unless params[:file]

        require 'csv'
        
        file = params[:file]
        imported = []
        errors = []

        CSV.foreach(file.path, headers: true, header_converters: :symbol) do |row|
          vehicle = @company.vehicles.new(csv_row_to_params(row))
          
          if vehicle.save
            imported << vehicle
          else
            errors << { row: row.to_h, errors: vehicle.errors.full_messages }
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

      private

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
          squareFeet: :square_feet,
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
          virtualTour: :virtual_tour,
          salesPhoto: :sales_photo
        }
        
        # Copy and transform camelCase fields
        field_mappings.each do |camel, snake|
          if raw_params[camel].present?
            transformed[snake] = raw_params[camel]
          end
        end
        
        # Copy direct fields (already in snake_case or same in both)
        direct_fields = [
          :vin, :year, :make, :model, :trim, :color, :status,
          :description, :notes, :mileage, :condition,
          :bedrooms, :bathrooms, :length, :width, :sleeps, :weight,
          :width1, :length1, :width2, :length2, :width3, :length3,
          :garage, :carport, :deck, :patio, :fireplace, :msrp, :cost,
          :transmission, :features, :images, :videos, :appliances,
          :awning, :generator, :utilities, :terms,
          :repo, :refrigerator, :microwave, :oven, :dishwasher,
          :thermopane, :gutters, :shutters, :skylight, :pantry,
          :basement
        ]
        
        direct_fields.each do |field|
          if raw_params[field].present?
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
          features: [], images: [], videos: [], appliances: []
        )
      end

      def vehicle_json(vehicle, detailed: false)
        # Helper to convert relative image URLs to full URLs
        base_url = Rails.env.production? ? "https://#{request.host}" : "http://#{request.host}:#{request.port}"
        
        # Convert image URLs
        full_image_urls = (vehicle.images || []).map do |url|
          if url.start_with?('http')
            url  # Already a full URL
          else
            "#{base_url}#{url}"  # Convert relative to full URL
          end
        end
        
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
            city: vehicle.location_city,
            state: vehicle.location_state,
            zip: vehicle.location_zip
          },
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
          listingUrl: vehicle.listing_url,
          sellerName: vehicle.seller_name,
          sellerPhone: vehicle.seller_phone,
          sellerAddressStreet: vehicle.seller_address_street,
          sellerAddressCity: vehicle.seller_address_city,
          sellerAddressState: vehicle.seller_address_state,
          sellerAddressZip: vehicle.seller_address_zip
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
            availability: vehicle.status
          })
        elsif vehicle.is_manufactured_home?
          json.merge!({
            vin: vehicle.vin,
            serialNumber: vehicle.serial_number,
            bedrooms: vehicle.bedrooms,
            bathrooms: vehicle.bathrooms,
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
            squareFeet: vehicle.square_feet,
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
            virtualTour: vehicle.virtual_tour,
            salesPhoto: vehicle.sales_photo,
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
            clothesDryer: vehicle.clothes_dryer
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
        # Map CSV columns to vehicle params
        # This is a basic mapping - can be enhanced based on actual CSV structure
        {
          listing_type: row[:type] || row[:listing_type],
          status: row[:status] || 'available',
          inventory_id: row[:inventory_id] || row[:stock_number],
          year: row[:year],
          make: row[:make],
          model: row[:model],
          trim: row[:trim],
          color: row[:color],
          sale_price: row[:sale_price] || row[:price],
          rent_price: row[:rent_price],
          description: row[:description],
          vin: row[:vin],
          serial_number: row[:serial_number],
          mileage: row[:mileage],
          bedrooms: row[:bedrooms],
          bathrooms: row[:bathrooms],
          location_city: row[:city],
          location_state: row[:state],
          location_zip: row[:zip]
        }.compact
      end
    end
  end
end
