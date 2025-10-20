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
