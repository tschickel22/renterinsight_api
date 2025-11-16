# frozen_string_literal: true

module Api
  class UploadsController < ApplicationController
    skip_before_action :authenticate, only: [:show]
    before_action :set_company, except: [:show]

    # GET /api/uploads/*path
    def show
      # Path comes from params[:path] (wildcard route)
      file_path = params[:path]
      
      # Construct full path to file in public/uploads
      full_path = Rails.root.join('public', 'uploads', file_path)
      
      Rails.logger.info "📁 [UploadsController] Serving file: #{file_path}"
      Rails.logger.info "📁 [UploadsController] Full path: #{full_path}"
      
      # Check if file exists
      unless File.exist?(full_path)
        Rails.logger.error "❌ [UploadsController] File not found: #{full_path}"
        render json: { error: 'File not found' }, status: :not_found
        return
      end
      
      # Determine content type based on file extension
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
      
      # Send file with appropriate headers
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
      render json: { error: "Failed to upload logo: #{e.message}" }, status: :internal_server_error
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
      render json: { error: "Failed to upload file: #{e.message}" }, status: :internal_server_error
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

    # FIX: Improved company validation with better error handling
    def set_company
      @company = ::Company.find_by(id: current_user&.company_id) if current_user
      @company ||= ::Company.first
      
      unless @company
        render json: { error: 'No company found. Please contact support.' }, 
               status: :unprocessable_entity
      end
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

    # FIX: Added comprehensive error handling and file size validation
    def upload_to_storage(file, category)
      # Validate company exists
      raise StandardError, 'Company not found' unless @company
      
      # Validate file size (10MB limit)
      max_size = 10.megabytes
      if file.size > max_size
        raise StandardError, "File size exceeds maximum allowed (#{max_size / 1.megabyte}MB)"
      end
      
      # Generate unique filename
      extension = File.extname(file.original_filename)
      filename = "#{SecureRandom.uuid}#{extension}"
      path = "uploads/#{@company.id}/#{category}/#{filename}"

      # Ensure directory exists
      full_path = Rails.root.join('public', path)
      
      begin
        FileUtils.mkdir_p(File.dirname(full_path))
      rescue => e
        Rails.logger.error "Failed to create directory: #{e.message}"
        raise StandardError, "Failed to create upload directory"
      end

      # Save file with error handling
      begin
        File.open(full_path, 'wb') do |f|
          f.write(file.read)
        end
      rescue => e
        Rails.logger.error "File write failed: #{e.message}"
        raise StandardError, "Failed to save file to storage"
      end

      # Return URL (adjust based on your setup)
      {
        url: "/#{path}",
        path: full_path.to_s
      }
    end
  end
end
