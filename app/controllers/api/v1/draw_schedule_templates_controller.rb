class Api::V1::DrawScheduleTemplatesController < ApplicationController
  before_action :set_company_scope
  before_action :set_template, only: [:show, :update, :destroy, :set_default]

  def index
    return unless authorize_action!('finance', 'read')

    templates = @company.draw_schedule_templates.active.order(:name)
    render json: templates.map { |t| serialize_template(t) }
  end

  def show
    return unless authorize_action!('finance', 'read')
    render json: serialize_template(@template)
  end

  def create
    return unless authorize_action!('finance', 'create')

    template = @company.draw_schedule_templates.build(template_params)

    # If marked as default, unset any existing default
    if template.is_default
      @company.draw_schedule_templates.active.where(is_default: true).update_all(is_default: false)
    end

    if template.save
      render json: serialize_template(template), status: :created
    else
      render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('finance', 'update')

    # If marking as default, unset others first
    if params.dig(:draw_schedule_template, :is_default) == true
      @company.draw_schedule_templates.active.where(is_default: true).where.not(id: @template.id).update_all(is_default: false)
    end

    if @template.update(template_params)
      render json: serialize_template(@template)
    else
      render json: { errors: @template.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('finance', 'delete')

    @template.update(is_deleted: true)
    head :no_content
  end

  def set_default
    return unless authorize_action!('finance', 'update')

    @company.draw_schedule_templates.active.where(is_default: true).update_all(is_default: false)
    @template.update(is_default: true)

    render json: serialize_template(@template.reload)
  end

  # Preview: Calculate draw amounts for a given total
  def preview
    return unless authorize_action!('finance', 'read')

    template = @company.draw_schedule_templates.active.find(params[:id])
    total = params[:total].to_f

    render json: {
      template_name: template.name,
      total_amount: total,
      draws: template.calculate_draws(total)
    }
  end

  private

  def set_template
    @template = @company.draw_schedule_templates.active.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Draw schedule template not found' }, status: :not_found
  end

  def template_params
    params.require(:draw_schedule_template).permit(
      :name,
      :is_default,
      :addon_mode,
      :tax_timing,
      draws: [
        :percentage,
        :description,
        :position,
        { sub_items: [:description, :position] }
      ]
    )
  end

  def serialize_template(template)
    {
      id: template.id,
      name: template.name,
      is_default: template.is_default,
      addon_mode: template.effective_addon_mode,
      tax_timing: template.tax_timing || 'per_draw',
      draws: template.draws,
      created_at: template.created_at,
      updated_at: template.updated_at
    }
  end
end
