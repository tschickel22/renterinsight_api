class Api::V1::WebsiteMediaController < ApplicationController
  before_action :set_company_scope
  before_action :set_media, only: [:show, :destroy]

  def index
    return unless authorize_action!('websites', 'read')

    @media = @company.site_media.where(is_deleted: [false, nil])

    # Filter by website if provided
    if params[:website_id].present?
      @media = @media.where(website_id: params[:website_id])
    end

    # Filter by file type if provided
    if params[:file_type].present?
      @media = @media.where(file_type: params[:file_type])
    end

    render json: @media
  end

  def show
    return unless authorize_action!('websites', 'read')
    render json: @media
  end

  def create
    return unless authorize_action!('websites', 'create')

    # TODO: Replace with actual S3 upload in Phase 4-5
    # For now, create placeholder record
    @media = @company.site_media.build(media_params)
    @media.uploaded_by = current_user
    
    # Determine file_type from mime_type
    if @media.mime_type.present?
      @media.file_type = case @media.mime_type
      when /^image\//
        'image'
      when /^video\//
        'video'
      else
        'document'
      end
    end

    # Placeholder URL (Phase 4-5 will use S3)
    @media.url ||= "https://placeholder.example.com/#{@media.name}"

    if @media.save
      render json: @media, status: :created
    else
      render json: { errors: @media.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('websites', 'delete')

    @media.update!(is_deleted: true)
    
    # TODO: Delete from S3 in Phase 4-5
    
    head :no_content
  end

  private

  def set_media
    @media = @company.site_media.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Media not found' }, status: :not_found
  end

  def media_params
    params.require(:media).permit(
      :name,
      :url,
      :mime_type,
      :file_size,
      :width,
      :height,
      :website_id,
      :s3_key,
      :s3_bucket
    )
    # file_type is auto-determined from mime_type
  end
end
