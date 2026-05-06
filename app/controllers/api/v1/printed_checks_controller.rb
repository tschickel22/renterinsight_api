# frozen_string_literal: true

class Api::V1::PrintedChecksController < ApplicationController
  before_action :set_company_scope

  def index
    return unless authorize_action!('accounting', 'read')

    checks = @company.printed_checks.includes(:bank_account, :contact).ordered
    checks = checks.where(status: params[:status]) if params[:status].present?
    checks = checks.where(bank_account_id: params[:bank_account_id]) if params[:bank_account_id].present?

    render json: {
      items: checks.as_json(
        include: {
          bank_account: { only: [:id, :bank_name] },
          contact: { only: [:id, :first_name, :last_name, :company_name] }
        }
      )
    }
  end

  def create
    return unless authorize_action!('accounting', 'create')

    check = @company.printed_checks.build(check_params)
    if check.save
      render json: check, status: :created
    else
      render json: { errors: check.errors }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/printed_checks/print_batch
  def print_batch
    return unless authorize_action!('accounting', 'update')

    check_ids = params[:check_ids] || []
    starting_number = params[:starting_check_number].to_i
    checks = @company.printed_checks.queued.where(id: check_ids).order(:created_at)

    printed = 0
    checks.each_with_index do |check, i|
      check.print!(starting_number + i)
      printed += 1
    end

    render json: { printed: printed }
  end

  # POST /api/v1/printed_checks/:id/void
  def void
    return unless authorize_action!('accounting', 'update')

    check = @company.printed_checks.find(params[:id])
    check.void!
    render json: check
  end

  private

  def check_params
    params.require(:printed_check).permit(
      :bank_account_id, :paid_to, :amount, :memo, :description, :contact_id, :journal_entry_id
    )
  end
end
