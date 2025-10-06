# frozen_string_literal: true
class Api::Crm::Nurture::SequencesController < ApplicationController
  # GET /api/crm/nurture/sequences
  def index
    sequences = NurtureSequence.order(:id).includes(:nurture_steps)
    render json: sequences.as_json(
      only: %i[id name description is_active created_at updated_at],
      include: {
        nurture_steps: {
          only: %i[id step_type position wait_days subject body template_id created_at updated_at]
        }
      }
    ), status: :ok
  end

  # POST /api/crm/nurture/sequences
  def create
    seq = nil
    ActiveRecord::Base.transaction do
      attrs = create_params
      seq = NurtureSequence.create!(attrs.slice(:name, :description, :is_active))
      Array(attrs[:steps]).each { |st| seq.nurture_steps.create!(step_attrs(st)) }
    end

    render json: seq.as_json(
      only: %i[id name description is_active created_at updated_at],
      include: { nurture_steps: { only: %i[id step_type position wait_days subject body template_id] } }
    ), status: :created
  end

  # PATCH/PUT /api/crm/nurture/sequences/:id
  def update
    seq = NurtureSequence.find(params[:id])

    ActiveRecord::Base.transaction do
      attrs = update_params
      seq.update!(attrs.slice(:name, :description, :is_active))
      if attrs.key?(:steps)
        # replace steps to keep ordering & deletions simple
        seq.nurture_steps.delete_all
        Array(attrs[:steps]).each { |st| seq.nurture_steps.create!(step_attrs(st)) }
      end
    end

    render json: seq.as_json(
      only: %i[id name description is_active created_at updated_at],
      include: { nurture_steps: { only: %i[id step_type position wait_days subject body template_id] } }
    ), status: :ok
  end

  # DELETE /api/crm/nurture/sequences/:id
  def destroy
    seq = NurtureSequence.find_by(id: params[:id])
    return head :not_found unless seq

    # use destroy to honor dependent hooks
    seq.destroy!
    head :no_content
  end

  # POST /api/crm/nurture/sequences/bulk
  # Body: { upsert:[{id?, name, description?, is_active, steps:[...]}], delete:[ids] }
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

  # Accept root or nested (:sequence) payloads
  def base_params
    params[:sequence].is_a?(ActionController::Parameters) ? params.require(:sequence) : params
  end

  def create_params
    base_params.permit(
      :name, :description, :is_active,
      steps: %i[step_type position wait_days subject body template_id]
    )
  end
  alias update_params create_params

  def bulk_params
    base = base_params
    base.permit(
      { delete: [] },
      upsert: [
        :id, :name, :description, :is_active,
        { steps: %i[step_type position wait_days subject body template_id] }
      ]
    )
  end

  def step_attrs(st)
    st.slice(:step_type, :position, :wait_days, :subject, :body, :template_id).to_h
  end
end
