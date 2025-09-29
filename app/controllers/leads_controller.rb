class LeadsController < ApplicationController
  before_action :set_lead, only: [:show, :update, :destroy]

  # GET /api/leads
  def index
    render json: Lead.where(company_id: current_company_id).order(created_at: :desc)
  end

  # GET /api/leads/:id
  def show
    render json: @lead
  end

  # POST /api/leads
  def create
    @lead = Lead.new(lead_params.merge(company_id: current_company_id))
    if @lead.save
      render json: @lead, status: :created
    else
      render json: { errors: @lead.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/leads/:id
  def update
    if @lead.update(lead_params)
      render json: @lead
    else
      render json: { errors: @lead.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/leads/:id
  def destroy
    @lead.destroy
    head :no_content
  end

  private

  def set_lead
    @lead = Lead.where(company_id: current_company_id).find(params[:id])
  end

  # IMPORTANT: do NOT permit company_id from client; controller sets it
  def lead_params
    params.require(:lead).permit(:first_name, :last_name, :email, :phone, :stage, :source, :owner_id, :notes_summary)
  end
end
