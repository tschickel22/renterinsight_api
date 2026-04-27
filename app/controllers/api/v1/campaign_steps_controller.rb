class Api::V1::CampaignStepsController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign
  before_action :set_step, only: %i[update destroy]

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
    params.require(:campaign_step).permit(
      :position, :channel, :wait_days, :wait_hours,
      :subject, :preheader, :sms_body, :media_url, :is_active,
      body_blocks: [], inventory_block_config: {}
    )
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
      is_active: s.is_active
    }
  end
end
