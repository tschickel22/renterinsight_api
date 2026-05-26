class Api::V1::CampaignStepsController < ApplicationController
  MAX_ATTACHMENT_SIZE = 25.megabytes
  ALLOWED_DELIVERY_MODES = %w[tracked_link inline_attachment].freeze

  before_action :set_company_scope
  before_action :set_campaign
  before_action :set_step, only: %i[update destroy upload_attachment remove_attachment update_attachment_mode]

  def create
    return unless authorize_action!('campaigns', 'update')
    return render(json: { error: 'Campaign is locked. Pause it to edit.' }, status: :unprocessable_entity) unless editable?

    attrs = step_params
    if attrs[:position].blank?
      max_position = @campaign.campaign_steps.maximum(:position) || -1
      attrs[:position] = max_position + 1
    end

    step = @campaign.campaign_steps.build(attrs)
    if step.save
      render json: step_json(step), status: :created
    else
      render json: { errors: step.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('campaigns', 'update')
    return render(json: { error: 'Campaign is locked. Pause it to edit.' }, status: :unprocessable_entity) unless editable?

    if @step.update(step_params)
      render json: step_json(@step)
    else
      render json: { errors: @step.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('campaigns', 'update')
    return render(json: { error: 'Campaign is locked. Pause it to edit.' }, status: :unprocessable_entity) unless editable?

    @step.destroy
    head :no_content
  end

  # POST /api/v1/campaigns/:campaign_id/steps/:id/upload_attachment
  def upload_attachment
    return unless authorize_action!('campaigns', 'update')
    return render(json: { error: 'Campaign is locked. Pause it to edit.' }, status: :unprocessable_entity) unless editable?

    file = params[:file]
    return render(json: { error: 'No file provided' }, status: :unprocessable_entity) if file.blank?

    if file.size > MAX_ATTACHMENT_SIZE
      return render(json: { error: "File too large. Maximum size is #{MAX_ATTACHMENT_SIZE / 1.megabyte}MB" },
                    status: :unprocessable_entity)
    end

    delivery_mode = params[:delivery_mode].presence || 'tracked_link'
    unless ALLOWED_DELIVERY_MODES.include?(delivery_mode)
      return render(json: { error: 'Invalid delivery_mode (tracked_link|inline_attachment)' },
                    status: :unprocessable_entity)
    end

    begin
      s3_service = S3UploadService.new
      folder = "campaign_attachments/#{@company.id}/#{@campaign.id}/#{@step.id}"
      s3_result = s3_service.upload(file, folder: folder)

      entry = {
        's3_key'        => s3_result[:key],
        'filename'      => file.original_filename,
        'size'          => s3_result[:size],
        'content_type'  => s3_result[:content_type],
        'delivery_mode' => delivery_mode
      }

      attachments = Array(@step.attachments).map(&:deep_stringify_keys)
      attachments << entry
      @step.update!(attachments: attachments)

      render json: { attachments: attachments }, status: :created
    rescue => e
      Rails.logger.error "[CampaignSteps] upload_attachment failed: #{e.message}"
      render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
    end
  end

  # DELETE /api/v1/campaigns/:campaign_id/steps/:id/remove_attachment
  def remove_attachment
    return unless authorize_action!('campaigns', 'update')
    return render(json: { error: 'Campaign is locked. Pause it to edit.' }, status: :unprocessable_entity) unless editable?

    s3_key = params[:s3_key]
    return render(json: { error: 'No s3_key provided' }, status: :unprocessable_entity) if s3_key.blank?

    expected_prefix = "campaign_attachments/#{@company.id}/"
    return render(json: { error: 'Access denied' }, status: :forbidden) unless s3_key.start_with?(expected_prefix)

    begin
      S3UploadService.new.delete(s3_key)
      remaining = Array(@step.attachments).map(&:deep_stringify_keys).reject { |a| a['s3_key'] == s3_key }
      @step.update!(attachments: remaining)
      render json: { attachments: remaining }
    rescue => e
      Rails.logger.error "[CampaignSteps] remove_attachment failed: #{e.message}"
      render json: { error: "Delete failed: #{e.message}" }, status: :internal_server_error
    end
  end

  # PATCH /api/v1/campaigns/:campaign_id/steps/:id/update_attachment_mode
  def update_attachment_mode
    return unless authorize_action!('campaigns', 'update')
    return render(json: { error: 'Campaign is locked. Pause it to edit.' }, status: :unprocessable_entity) unless editable?

    s3_key = params[:s3_key]
    delivery_mode = params[:delivery_mode]
    return render(json: { error: 'No s3_key provided' }, status: :unprocessable_entity) if s3_key.blank?
    unless ALLOWED_DELIVERY_MODES.include?(delivery_mode)
      return render(json: { error: 'Invalid delivery_mode (tracked_link|inline_attachment)' },
                    status: :unprocessable_entity)
    end

    attachments = Array(@step.attachments).map(&:deep_stringify_keys)
    match = attachments.find { |a| a['s3_key'] == s3_key }
    return render(json: { error: 'Attachment not found' }, status: :not_found) unless match

    match['delivery_mode'] = delivery_mode
    @step.update!(attachments: attachments)
    render json: { attachments: attachments }
  end

  private

  def set_campaign
    @campaign = @company.campaigns.active.find(params[:campaign_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Campaign not found' }, status: :not_found
  end

  def set_step
    @step = @campaign.campaign_steps.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Step not found' }, status: :not_found
  end

  def editable?
    %w[draft scheduled].include?(@campaign.status)
  end

  def step_params
    permitted = params.require(:campaign_step).permit(
      :position, :channel, :wait_days, :wait_hours,
      :subject, :preheader, :sms_body, :media_url, :is_active,
      inventory_block_config: {},
      attachments: [:s3_key, :filename, :size, :content_type, :delivery_mode]
    )

    if params[:campaign_step][:body_blocks].present?
      raw_blocks = params[:campaign_step][:body_blocks]
      permitted[:body_blocks] = if raw_blocks.respond_to?(:map)
        raw_blocks.map { |b| b.respond_to?(:to_unsafe_h) ? b.to_unsafe_h : b.to_h }
      else
        []
      end
    end

    permitted
  end

  def step_json(s)
    {
      id: s.id,
      position: s.position,
      channel: s.channel,
      wait_days: s.wait_days,
      wait_hours: s.wait_hours,
      subject: s.subject,
      preheader: s.preheader,
      body_blocks: s.body_blocks,
      sms_body: s.sms_body,
      media_url: s.media_url,
      inventory_block_config: s.inventory_block_config,
      attachments: Array(s.attachments),
      is_active: s.is_active
    }
  end
end
