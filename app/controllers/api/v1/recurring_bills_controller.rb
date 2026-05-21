# frozen_string_literal: true

class Api::V1::RecurringBillsController < ApplicationController
  before_action :set_company_scope
  before_action :set_recurring_bill, only: [:show, :update, :destroy, :generate_now]

  def index
    return unless authorize_action!('accounting', 'read')

    bills = @company.recurring_bills.includes(:expense_account, :vendor).ordered
    bills = bills.active if params[:active_only] == 'true'

    render json: {
      items: bills.as_json(
        include: {
          expense_account: { only: [:id, :account_number, :name] },
          vendor: { only: [:id, :name] }
        }
      )
    }
  end

  def show
    return unless authorize_action!('accounting', 'read')
    render json: @recurring_bill
  end

  def create
    return unless authorize_action!('accounting', 'create')

    bill = @company.recurring_bills.build(recurring_bill_params)
    if bill.save
      render json: bill, status: :created
    else
      render json: { errors: bill.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('accounting', 'update')

    if @recurring_bill.update(recurring_bill_params)
      render json: @recurring_bill
    else
      render json: { errors: @recurring_bill.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('accounting', 'delete')

    @recurring_bill.destroy
    head :no_content
  end

  def generate_now
    return unless authorize_action!('accounting', 'create')

    je = @recurring_bill.generate_entry!(force: true)
    if je
      render json: { message: "Generated JE #{je.entry_number}", journal_entry: je }
    else
      err = @recurring_bill.last_error || { code: 'generate_failed', message: 'Failed to generate entry' }
      render json: err, status: :unprocessable_entity
    end
  end

  private

  def set_recurring_bill
    @recurring_bill = @company.recurring_bills.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  def recurring_bill_params
    permitted = params.require(:recurring_bill).permit(
      :name, :vendor_id, :supplier_id, :contact_id, :amount, :frequency,
      :next_due_date, :end_date, :expense_account_id, :payment_account_id,
      :posting_type, :auto_post, :is_active, :memo, :invoice_number_pattern,
      :location_id, :department
    )

    # Back-compat: FE may still send supplier_id from a vendors-populated picker;
    # the suppliers FK rejects vendor ids that don't exist as supplier rows.
    if permitted[:supplier_id].present? && permitted[:vendor_id].blank?
      permitted[:vendor_id] = permitted.delete(:supplier_id)
    else
      permitted.delete(:supplier_id)
    end

    permitted
  end
end
