# frozen_string_literal: true

class Api::V1::PrintedChecksController < ApplicationController
  before_action :set_company_scope

  def index
    return unless authorize_action!('accounting', 'read')

    scope = @company.printed_checks.includes(:bank_account, :contact)

    stats = {
      total:   scope.count,
      queued:  scope.where(status: PrintedCheck::STATUS_QUEUED).count,
      printed: scope.where(status: PrintedCheck::STATUS_PRINTED).count,
      voided:  scope.where(status: PrintedCheck::STATUS_VOIDED).count
    }

    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(bank_account_id: params[:bank_account_id]) if params[:bank_account_id].present?

    if params[:search].present?
      term = "%#{params[:search]}%"
      scope = scope.where('paid_to ILIKE ? OR check_number ILIKE ?', term, term)
    end

    scope = scope.ordered
    filtered_count = scope.count

    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    scope = scope.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: scope.as_json(
        include: {
          bank_account: { only: [:id, :bank_name] },
          contact: { only: [:id, :first_name, :last_name, :company_name] }
        }
      ),
      meta: {
        total: filtered_count,
        page: page,
        per_page: per_page,
        total_pages: (filtered_count.to_f / per_page).ceil,
        stats: stats
      }
    }
  end

  def create
    return unless authorize_action!('accounting', 'create')

    bank_account = company_scoped_bank_accounts.find_by(id: check_params[:bank_account_id])
    return render json: { error: 'Bank account not found' }, status: :not_found unless bank_account
    unless bank_account.check_printing_enabled
      return render json: { error: 'Check printing is not enabled for this bank account' },
                    status: :unprocessable_entity
    end

    check = @company.printed_checks.build(check_params)
    check.status = PrintedCheck::STATUS_QUEUED

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
    checks = @company.printed_checks.queued
                     .where(id: check_ids)
                     .includes(:bank_account, :contact)
                     .order(:created_at)

    return render json: { error: 'No queued checks found for the given IDs' }, status: :not_found if checks.empty?

    printed = []
    checks.each_with_index do |check, i|
      check.print!(starting_number + i)
      printed << check
    end

    pdf_bytes = CheckPrintingService.generate_pdf_bytes(printed)

    render json: {
      printed: printed.size,
      check_ids: printed.map(&:id),
      pdf_base64: Base64.strict_encode64(pdf_bytes)
    }
  end

  # POST /api/v1/printed_checks/reprint
  # Generates a PDF for already-printed checks. Status is unchanged.
  def reprint
    return unless authorize_action!('accounting', 'update')

    check_ids = params[:check_ids] || []
    checks = @company.printed_checks
                     .where(status: PrintedCheck::STATUS_PRINTED, id: check_ids)
                     .includes(:bank_account, :contact)
                     .order(:check_number)

    return render json: { error: 'No printed checks found for the given IDs' }, status: :not_found if checks.empty?

    pdf_bytes = CheckPrintingService.generate_pdf_bytes(checks)

    render json: {
      count: checks.size,
      check_ids: checks.map(&:id),
      pdf_base64: Base64.strict_encode64(pdf_bytes)
    }
  end

  # GET /api/v1/printed_checks/check_settings
  # Bank accounts available for check printing, with their next-check details.
  def check_settings
    return unless authorize_action!('accounting', 'read')

    accounts = company_scoped_bank_accounts.where(check_printing_enabled: true).order(:bank_name)

    render json: {
      bank_accounts: accounts.map do |ba|
        {
          id: ba.id,
          bank_name: ba.bank_name,
          check_number: ba.check_number,
          check_format: ba.check_format,
          check_company_name: ba.check_company_name,
          check_signor_name: ba.check_signor_name
        }
      end
    }
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

  # Bank accounts may be tagged directly with company_id OR scoped only via
  # their location's company. Mirrors BankAccountsController#company_scoped_bank_accounts.
  def company_scoped_bank_accounts
    BankAccount
      .joins('LEFT JOIN locations ON locations.id = bank_accounts.location_id')
      .where('bank_accounts.company_id = ? OR locations.company_id = ?', @company.id, @company.id)
      .where(is_deleted: [false, nil])
  end
end
