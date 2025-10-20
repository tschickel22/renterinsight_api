#!/bin/bash

# Create Settings and Uploads controllers for Rails API

echo "Creating API controllers..."

# Create settings_controller.rb
cat > app/controllers/api/settings_controller.rb << 'EOF'
# frozen_string_literal: true

module Api
  class SettingsController < ApplicationController
    before_action :set_company

    # GET /api/settings/tenant
    def tenant
      render json: {
        tenant: serialize_tenant
      }
    end

    # PATCH /api/settings
    def update
      settings_params = params.require(:settings).permit!
      
      settings_params.each do |key, value|
        ::Setting.set('Company', @company.id, key, value)
      end

      render json: {
        tenant: serialize_tenant
      }
    end

    # PATCH /api/settings/branding
    def update_branding
      branding_params = params.require(:branding).permit(
        :primaryColor, :secondaryColor, :fontFamily, :logo,
        :sideMenuColor, :portalName, :portalLogo
      )

      ::Setting.set('Company', @company.id, 'branding', branding_params.to_h)

      render json: {
        tenant: serialize_tenant
      }
    end

    # PATCH /api/settings/quotes
    def update_quotes
      quotes_params = params.require(:quotes).permit(
        :defaultTaxRate, :defaultTermsConditions, :defaultValidityDays,
        :companyName, :logoUrl, :companyAddress, :companyCity,
        :companyState, :companyZip, :companyPhone, :companyEmail,
        :companyWebsite
      )

      ::Setting.set('Company', @company.id, 'quotes', quotes_params.to_h)

      render json: {
        tenant: serialize_tenant
      }
    end

    # GET /api/settings/custom_fields
    def custom_fields
      module_name = params[:module]
      
      fields = if module_name.present?
        @company.custom_fields.for_module(module_name).ordered
      else
        @company.custom_fields.ordered
      end

      render json: {
        custom_fields: fields.as_json
      }
    end

    # POST /api/settings/custom_fields
    def create_custom_field
      field_params = params.require(:custom_field).permit(
        :module, :name, :label, :field_type, :required, 
        :default_value, :display_order, options: []
      )

      field = @company.custom_fields.create!(field_params)

      render json: {
        custom_field: field.as_json
      }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # PATCH /api/settings/custom_fields/:id
    def update_custom_field
      field = @company.custom_fields.find(params[:id])
      
      field_params = params.require(:custom_field).permit(
        :label, :field_type, :required, :default_value, 
        :display_order, options: []
      )

      field.update!(field_params)

      render json: {
        custom_field: field.as_json
      }
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Custom field not found' }, status: :not_found
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # DELETE /api/settings/custom_fields/:id
    def destroy_custom_field
      field = @company.custom_fields.find(params[:id])
      field.destroy!

      head :no_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Custom field not found' }, status: :not_found
    end

    private

    def set_company
      @company = ::Company.first
    end

    def serialize_tenant
      {
        id: @company.id.to_s,
        name: @company.name,
        domain: @company.domain || "#{@company.name.parameterize}.renterinsight.com",
        settings: serialize_settings,
        branding: serialize_branding,
        customFields: @company.custom_fields.ordered.as_json,
        createdAt: @company.created_at,
        updatedAt: @company.updated_at
      }
    end

    def serialize_settings
      base_settings = {
        timezone: 'America/New_York',
        currency: 'USD',
        dateFormat: 'MM/dd/yyyy',
        businessHours: default_business_hours,
        features: {
          workflowAutomation: true
        }
      }

      # Merge in custom settings
      custom_settings = ::Setting.where(scope_type: 'Company', scope_id: @company.id)
        .where.not(key: ['branding', 'quotes'])
        .pluck(:key, :value)
        .to_h

      custom_settings.each do |key, value|
        begin
          base_settings[key.to_sym] = JSON.parse(value)
        rescue JSON::ParserError
          base_settings[key.to_sym] = value
        end
      end

      # Add quotes settings
      quotes_setting = ::Setting.get('Company', @company.id, 'quotes', {})
      base_settings[:quotes] = quotes_setting.deep_symbolize_keys if quotes_setting.present?

      base_settings
    end

    def serialize_branding
      branding = ::Setting.get('Company', @company.id, 'branding', {})
      
      default_branding = {
        primaryColor: '#3b82f6',
        secondaryColor: '#64748b',
        fontFamily: 'Inter'
      }

      default_branding.merge(branding.deep_symbolize_keys)
    end

    def default_business_hours
      {
        monday: { open: '09:00', close: '18:00', closed: false },
        tuesday: { open: '09:00', close: '18:00', closed: false },
        wednesday: { open: '09:00', close: '18:00', closed: false },
        thursday: { open: '09:00', close: '18:00', closed: false },
        friday: { open: '09:00', close: '18:00', closed: false },
        saturday: { open: '09:00', close: '17:00', closed: false },
        sunday: { open: '12:00', close: '17:00', closed: false }
      }
    end
  end
end
EOF

# Create uploads_controller.rb
cat > app/controllers/api/uploads_controller.rb << 'EOF'
# frozen_string_literal: true

module Api
  class UploadsController < ApplicationController
    before_action :set_company

    # POST /api/uploads/logo
    def logo
      file = params[:file]
      upload_type = params[:type] || 'company'

      unless file.present?
        return render json: { error: 'No file provided' }, status: :unprocessable_entity
      end

      # Validate file type
      unless valid_image?(file)
        return render json: { error: 'Invalid file type. Only images are allowed.' }, status: :unprocessable_entity
      end

      # Upload file
      uploaded_file = upload_to_storage(file, "logos/#{upload_type}")

      render json: {
        url: uploaded_file[:url],
        filename: file.original_filename,
        content_type: file.content_type,
        size: file.size
      }
    rescue => e
      Rails.logger.error "Logo upload error: #{e.message}"
      render json: { error: 'Failed to upload logo' }, status: :internal_server_error
    end

    # POST /api/uploads
    def create
      file = params[:file]
      category = params[:category] || 'general'

      unless file.present?
        return render json: { error: 'No file provided' }, status: :unprocessable_entity
      end

      # Upload file
      uploaded_file = upload_to_storage(file, category)

      render json: {
        url: uploaded_file[:url],
        filename: file.original_filename,
        content_type: file.content_type,
        size: file.size
      }
    rescue => e
      Rails.logger.error "File upload error: #{e.message}"
      render json: { error: 'Failed to upload file' }, status: :internal_server_error
    end

    # DELETE /api/uploads
    def destroy
      url = params[:url]

      unless url.present?
        return render json: { error: 'No URL provided' }, status: :unprocessable_entity
      end

      # In a real implementation, you would delete the file from storage
      # For now, we'll just return success
      head :no_content
    end

    private

    def set_company
      @company = ::Company.first
    end

    def valid_image?(file)
      return false unless file.respond_to?(:content_type)
      
      allowed_types = [
        'image/jpeg',
        'image/jpg',
        'image/png',
        'image/gif',
        'image/svg+xml',
        'image/webp'
      ]

      allowed_types.include?(file.content_type)
    end

    def upload_to_storage(file, category)
      # Generate unique filename
      extension = File.extname(file.original_filename)
      filename = "#{SecureRandom.uuid}#{extension}"
      path = "uploads/#{@company.id}/#{category}/#{filename}"

      # Ensure directory exists
      full_path = Rails.root.join('public', path)
      FileUtils.mkdir_p(File.dirname(full_path))

      # Save file
      File.open(full_path, 'wb') do |f|
        f.write(file.read)
      end

      # Return URL (adjust based on your setup)
      {
        url: "/#{path}",
        path: full_path.to_s
      }
    end
  end
end
EOF

echo "Controllers created successfully!"
echo ""
echo "Now restart your Rails server:"
echo "  cd /home/tschi/src/renterinsight_api"
echo "  bundle exec rails server -p 3001"
echo ""
echo "Then test:"
echo "  curl http://localhost:3001/api/settings/tenant"
