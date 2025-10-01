class Api::Crm::Nurture::SequencesController < ApplicationController
  def index
    sequences = NurtureSequence.order(:id).includes(:nurture_steps)
    render json: sequences.as_json(
      only: [:id, :name, :description, :is_active, :created_at, :updated_at],
      include: { nurture_steps: { only: [:id, :step_type, :position, :wait_days, :subject, :body, :template_id, :created_at, :updated_at] } }
    )
  end

  def create
    seq = nil
    ActiveRecord::Base.transaction do
      seq = NurtureSequence.create!(create_params.slice(:name, :description, :is_active))
      Array(create_params[:steps]).each { |st| seq.nurture_steps.create!(step_attrs(st)) }
    end
    render json: seq.as_json(
      only: [:id, :name, :description, :is_active, :created_at, :updated_at],
      include: { nurture_steps: { only: [:id, :step_type, :position, :wait_days, :subject, :body, :template_id] } }
    ), status: :created
  end

  def update
    seq = NurtureSequence.find(params[:id])
    ActiveRecord::Base.transaction do
      seq.update!(create_params.slice(:name, :description, :is_active))
      if create_params.key?(:steps)
        seq.nurture_steps.delete_all
        Array(create_params[:steps]).each { |st| seq.nurture_steps.create!(step_attrs(st)) }
      end
    end
    render json: seq.as_json(
      only: [:id, :name, :description, :is_active, :created_at, :updated_at],
      include: { nurture_steps: { only: [:id, :step_type, :position, :wait_days, :subject, :body, :template_id] } }
    )
  end

  def destroy
    seq = NurtureSequence.find_by(id: params[:id])
    return head :not_found unless seq
    # use destroy to honor dependent: :destroy hooks and FKs
    seq.destroy!
    head :no_content
  end

  # { upsert:[{id?, name, description?, is_active, steps:[...]}], delete:[ids] }
  def bulk
    payload = bulk_params
    upsert  = Array(payload[:upsert]).map { |h| h.to_h.symbolize_keys }
    deletes = Array(payload[:delete])

    ActiveRecord::Base.transaction do
      upsert.each do |s|
        seq = s[:id].present? ? NurtureSequence.find_by(id: s[:id]) : NurtureSequence.new
        seq.assign_attributes(s.slice(:name, :description, :is_active))
        seq.save!

        if s.key?(:steps)
          seq.nurture_steps.delete_all
          Array(s[:steps]).each { |st| seq.nurture_steps.create!(step_attrs(st.symbolize_keys)) }
        end
      end
      NurtureSequence.where(id: deletes).destroy_all if deletes.present?
    end
    head :no_content
  end

  private

  def create_params
    base = params[:sequence].is_a?(ActionController::Parameters) ? params.require(:sequence) : params
    base.permit(:name, :description, :is_active,
      steps: [:step_type, :position, :wait_days, :subject, :body, :template_id])
  end
  alias update_params create_params

  def bulk_params
    base = params[:sequence].is_a?(ActionController::Parameters) ? params.require(:sequence) : params
    base.permit(
      { delete: [] },
      upsert: [
        :id, :name, :description, :is_active,
        { steps: [:step_type, :position, :wait_days, :subject, :body, :template_id] }
      ]
    )
  end

  def step_attrs(st)
    st.slice(:step_type, :position, :wait_days, :subject, :body, :template_id).to_h
  end
end
