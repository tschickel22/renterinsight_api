class Api::V1::InvoiceNotesTemplatesController < ApplicationController
  before_action :set_company_scope
  before_action :set_template, only: [:update, :destroy, :set_default]

  def index
    return unless authorize_action!('finance', 'read')
    templates = @company.invoice_notes_templates.active.order(:name)
    render json: templates.map { |t| serialize_template(t) }
  end

  def create
    return unless authorize_action!('finance', 'create')
    template = @company.invoice_notes_templates.build(template_params)
    if template.is_default
      @company.invoice_notes_templates.active.where(is_default: true).update_all(is_default: false)
    end
    if template.save
      render json: serialize_template(template), status: :created
    else
      render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('finance', 'update')
    if params.dig(:invoice_notes_template, :is_default) == true
      @company.invoice_notes_templates.active.where(is_default: true).where.not(id: @template.id).update_all(is_default: false)
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
    @company.invoice_notes_templates.active.where(is_default: true).update_all(is_default: false)
    @template.update(is_default: true)
    render json: serialize_template(@template.reload)
  end

  private

  def set_template
    @template = @company.invoice_notes_templates.active.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Notes template not found' }, status: :not_found
  end

  def template_params
    params.require(:invoice_notes_template).permit(:name, :notes, :is_default)
  end

  def serialize_template(template)
    { id: template.id, name: template.name, notes: template.notes, is_default: template.is_default,
      created_at: template.created_at, updated_at: template.updated_at }
  end
end
