# frozen_string_literal: true

class Api::V1::RecurringJournalEntriesController < ApplicationController
  before_action :set_company_scope
  before_action :set_recurring_entry, only: [:show, :update, :destroy, :generate_now]

  def index
    return unless authorize_action!('journal_entries', 'read')

    entries = @company.recurring_journal_entries.order(:name)
    entries = entries.active if params[:active_only] == 'true'

    render json: { items: entries }
  end

  def show
    return unless authorize_action!('journal_entries', 'read')
    render json: @recurring_entry
  end

  def create
    return unless authorize_action!('journal_entries', 'create')

    entry = @company.recurring_journal_entries.build(recurring_params)

    if entry.save
      render json: entry, status: :created
    else
      render json: { errors: entry.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('journal_entries', 'update')

    if @recurring_entry.update(recurring_params)
      render json: @recurring_entry
    else
      render json: { errors: @recurring_entry.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('journal_entries', 'delete')

    @recurring_entry.destroy
    head :no_content
  end

  # POST /api/v1/recurring_journal_entries/:id/generate_now
  def generate_now
    return unless authorize_action!('journal_entries', 'create')

    je = @recurring_entry.generate_entry!

    if je
      render json: { message: "Generated JE #{je.entry_number}", journal_entry: je }
    else
      render json: { error: 'Failed to generate entry' }, status: :unprocessable_entity
    end
  end

  private

  def set_recurring_entry
    @recurring_entry = @company.recurring_journal_entries.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  def recurring_params
    params.require(:recurring_journal_entry).permit(
      :name, :frequency, :next_run_date, :end_date,
      :auto_post, :is_active, :memo,
      template_lines: [:chart_of_account_id, :debit_amount, :credit_amount, :memo, :department, :location_id]
    )
  end
end
