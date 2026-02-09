class Api::V1::WebsiteMediaController < ApplicationController
  before_action :set_company_scope
  before_action :set_website, only: [:index, :create]
  before_action :set_media, only: [:show, :update, :destroy]

  # GET /api/v1/websites/:website_id/media
  def index
    return unless authorize_action!('websites', 'read')

    media_items = @website.website_media.where(is_deleted: [false, nil])

    # Apply search filter
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      media_items = media_items.where(
        "name ILIKE ?",
        search_term
      )
    end

    # Filter by file type
    if params[:file_type].present?
      media_items = media_items.where(file_type: params[:file_type])
    end

    # Sort by most recent
    sort_by = params[:sort_by] || 'created_at'
    sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
    media_items = media_items.order(sort_by => sort_order)

    # Paginate
    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 50).to_i
    per_page = [per_page, 200].min
    
    total_count = media_items.count
    media_items = media_items.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: media_items.as_json(methods: [:full_url]),
      meta: {
        total: total_count,
        page: page,
        per_page: per_page,
        total_pages: (total_count.to_f / per_page).ceil
      }
    }
  end

  # GET /api/v1/media/:id (global - not nested under website)
  def show
    return unless authorize_action!('websites', 'read')

    render json: @media.as_json(methods: [:full_url])
  end

  # POST /api/v1/websites/:website_id/media
  def create
    return unless authorize_action!('websites', 'create')

    # Check if file is provided
    unless params[:file].present?
      return render json: { error: 'No file provided' }, status: :unprocessable_entity
    end

    file = params[:file]

    # Upload to S3
    begin
      s3_service = S3UploadService.new
      s3_result = s3_service.upload(file, folder: "websites/#{@website.id}/media")

      # CRITICAL: Scoped to both @company AND @website
      media = @website.website_media.build(
        name: file.original_filename,
        url: s3_result[:url],
        s3_key: s3_result[:key],  # Store S3 key for presigned URLs
        s3_bucket: ENV['AWS_S3_BUCKET'],
        file_size: s3_result[:size],
        mime_type: s3_result[:content_type],
        file_type: determine_file_type(s3_result[:content_type])
      )
      media.company = @company  # Explicitly set company for dual scope

      if media.save
        render json: media.as_json(methods: [:full_url]), status: :created
      else
        # Rollback: delete from S3 if DB save fails
        s3_service.delete(s3_result[:key])
        render json: { errors: media.errors.full_messages }, status: :unprocessable_entity
      end
    rescue StandardError => e
      Rails.logger.error("S3 upload failed: #{e.message}")
      render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
    end
  end

  # PATCH/PUT /api/v1/media/:id
  def update
    return unless authorize_action!('websites', 'update')

    if @media.update(media_params)
      render json: @media.as_json(methods: [:full_url])
    else
      render json: { errors: @media.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/media/:id
  def destroy
    return unless authorize_action!('websites', 'delete')

    @media.update!(is_deleted: true, deleted_at: Time.current)
    head :no_content
  end

  # GET /api/v1/media/stats
  def stats
    return unless authorize_action!('websites', 'read')

    base_media = @company.website_media.where(is_deleted: [false, nil])

    # Filter by website if provided
    base_media = base_media.where(website_id: params[:website_id]) if params[:website_id].present?

    render json: {
      total: base_media.count,
      images: base_media.where(file_type: WebsiteMedia.file_types[:image]).count,
      videos: base_media.where(file_type: WebsiteMedia.file_types[:video]).count,
      documents: base_media.where(file_type: WebsiteMedia.file_types[:document]).count,
      total_size: base_media.sum(:file_size)
    }
  end

  private

  def set_website
    # CRITICAL: Always use @company scope
    @website = @company.websites.find(params[:website_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  def set_media
    # CRITICAL: Media belongs to company, not just website
    @media = @company.website_media.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Media not found' }, status: :not_found
  end

  def media_params
    # CRITICAL: NEVER permit company_id or website_id
    # company_id set via @company, website_id set via @website.website_media.build()
    # name, url, s3_key, s3_bucket are set programmatically during upload
    params.permit(
      :alt_text,
      :caption,
      :width,
      :height
    )
  end

  # Determine file type from MIME type
  def determine_file_type(mime_type)
    return 'image' if mime_type&.start_with?('image/')
    return 'video' if mime_type&.start_with?('video/')
    return 'document' if mime_type&.match?(/(pdf|msword|wordprocessingml|spreadsheet|presentation)/)
    'other'
  end
end
