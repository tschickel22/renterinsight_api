# frozen_string_literal: true

module Api
  class UploadsController < ApplicationController
    skip_before_action :authenticate, only: [:show]
    before_action :authenticate_user!, except: [:show]
    before_action :set_company_scope, except: [:show]
    
    # RBAC Authorization for uploads
    before_action :authorize_branding_upload!, only: [:logo]
    before_action :authorize_general_upload!, only: [:create]
    before_action :authorize_upload_delete!, only: [:destroy]

    # GET /api/uploads/*path
    def show
      file_path = params[:path]
      
      if file_path.include?('..') || file_path.include?("\0")
        Rails.logger.error "❌ [UploadsController] Potential path traversal attempt: #{file_path}"
        render json: { error: 'Invalid path' }, status: :bad_request
        return
      end
      
      # Use persistent disk in production, local path in development
      upload_base = ENV['UPLOAD_PATH'] || Rails.root.join('public', 'uploads')
      full_path = File.join(upload_base, file_path)
      
      Rails.logger.info "📁 [UploadsController] Serving file: #{file_path}"
      
      unless File.exist?(full_path)
        Rails.logger.error "❌ [UploadsController] File not found: #{full_path}"
        render json: { error: 'File not found' }, status: :not_found
        return
      end
      
      content_type = case File.extname(file_path).downcase
      when '.jpg', '.jpeg' then 'image/jpeg'
      when '.png' then 'image/png'
      when '.gif' then 'image/gif'
      when '.svg' then 'image/svg+xml'
      when '.webp' then 'image/webp'
      when '.ico' then 'image/x-icon'
      when '.pdf' then 'application/pdf'
      else 'application/octet-stream'
      end
      
      send_file full_path, 
        type: content_type,
        disposition: 'inline',
        status: :ok
    rescue => e
      Rails.logger.error "❌ [UploadsController] Error serving file: #{e.message}"
      render json: { error: 'Failed to serve file' }, status: :internal_server_error
    end

    # POST /api/uploads/logo
    def logo
      file = params[:file]
      upload_type = params[:type] || 'company'
      location_id = params[:location_id] # For location-specific logos

      unless file.present?
        return render json: { error: 'No file provided' }, status: :unprocessable_entity
      end

      unless valid_image?(file)
        return render json: { error: 'Invalid file type. Only images are allowed.' }, status: :unprocessable_entity
      end

      uploaded_file = upload_to_storage(file, "logos/#{upload_type}", location_id)

      render json: {
        url: uploaded_file[:url],
        filename: file.original_filename,
        content_type: file.content_type,
        size: file.size
      }
    rescue => e
      Rails.logger.error "Logo upload error: #{e.message}"
      render json: { error: "Failed to upload logo: #{e.message}" }, status: :internal_server_error
    end

    # POST /api/uploads
    def create
      file = params[:file]
      category = params[:category] || 'general'
      location_id = params[:location_id] # For location-specific uploads

      unless file.present?
        return render json: { error: 'No file provided' }, status: :unprocessable_entity
      end

      uploaded_file = upload_to_storage(file, category, location_id)

      render json: {
        url: uploaded_file[:url],
        filename: file.original_filename,
        content_type: file.content_type,
        size: file.size
      }
    rescue => e
      Rails.logger.error "File upload error: #{e.message}"
      render json: { error: "Failed to upload file: #{e.message}" }, status: :internal_server_error
    end

    # DELETE /api/uploads
    def destroy
      url = params[:url]

      unless url.present?
        return render json: { error: 'No URL provided' }, status: :unprocessable_entity
      end

      head :no_content
    end

    private

    # ============================================
    # RBAC Authorization Methods
    # ============================================

    def authorize_branding_upload!
      return if skip_rbac?
      unless current_user.has_permission?('branding', 'update', 'all', @company&.id)
        Rails.logger.warn "[RBAC] User #{current_user.id} denied UPLOAD access to branding for company #{@company&.id}"
        render json: { error: 'Permission denied: You do not have permission to upload logos' }, status: :forbidden
      end
    end

    def authorize_general_upload!
      return if skip_rbac?
      # For general uploads, check if user has any create permission
      # This covers inventory images, documents, etc.
      has_any_create = current_user.has_permission?('inventory', 'create', 'all', @company&.id) ||
                       current_user.has_permission?('branding', 'update', 'all', @company&.id) ||
                       current_user.has_permission?('crm', 'create', 'all', @company&.id)
      
      unless has_any_create
        Rails.logger.warn "[RBAC] User #{current_user.id} denied UPLOAD access for company #{@company&.id}"
        render json: { error: 'Permission denied: You do not have permission to upload files' }, status: :forbidden
      end
    end

    def authorize_upload_delete!
      return if skip_rbac?
      unless current_user.has_permission?('branding', 'delete', 'all', @company&.id)
        Rails.logger.warn "[RBAC] User #{current_user.id} denied DELETE access to uploads for company #{@company&.id}"
        render json: { error: 'Permission denied: You do not have permission to delete files' }, status: :forbidden
      end
    end

    def skip_rbac?
      return true if current_user.platform_admin?
      return true if current_user.super_admin?
      return true unless @company&.use_rbac_system
      false
    end

    # ============================================
    # Helper Methods
    # ============================================

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

    def upload_to_storage(file, category, location_id = nil)
      raise StandardError, 'Company not found - authentication required' unless @company
      
      max_size = 10.megabytes
      if file.size > max_size
        raise StandardError, "File size exceeds maximum allowed (#{max_size / 1.megabyte}MB)"
      end
      
      extension = File.extname(file.original_filename)
      filename = "#{SecureRandom.uuid}#{extension}"
      # Use persistent disk in production, local path in development
      upload_base = ENV['UPLOAD_PATH'] || Rails.root.join('public', 'uploads')
      
      # Use location_id if provided (for location-specific uploads)
      # Otherwise use company_id (for company-wide uploads)
      folder_id = location_id.present? ? location_id : @company.id
      
      path = "#{folder_id}/#{category}/#{filename}"
      full_path = File.join(upload_base, path)
      
      begin
        FileUtils.mkdir_p(File.dirname(full_path))
      rescue => e
        Rails.logger.error "Failed to create directory: #{e.message}"
        raise StandardError, "Failed to create upload directory"
      end

      begin
        File.open(full_path, 'wb') do |f|
          f.write(file.read)
        end
      rescue => e
        Rails.logger.error "File write failed: #{e.message}"
        raise StandardError, "Failed to save file to storage"
      end

      {
        url: "/uploads/#{path}",
        path: full_path.to_s
      }
    end
  end
end
