# frozen_string_literal: true

class Api::V1::BillsController < ApplicationController
  include AccountingLocationScoping

  before_action :set_company_scope
  before_action :set_bill, only: [:show, :update, :destroy, :void, :record_payment, :upload_attachment, :delete_attachment]

  def index
    return unless authorize_action!('bills', 'read')

    bills = @company.bills.active
                    .includes(:vendor, :contact, :bill_line_items, :bill_payments, :location)

    bills = bills.where(location_id: accounting_location_id) if accounting_location_filtered?

    stats_scope = bills
    stats = {
      total: stats_scope.count,
      draft: stats_scope.where(status: 'draft').count,
      pending: stats_scope.where(status: 'pending').count,
      partially_paid: stats_scope.where(status: 'partially_paid').count,
      paid: stats_scope.where(status: 'paid').count,
      void: stats_scope.where(status: 'void').count,
      total_outstanding: stats_scope.where(status: %w[pending partially_paid]).sum(:balance_due)
    }

    bills = bills.where(status: params[:status]) if params[:status].present?

    if params[:start_date].present? && params[:end_date].present?
      bills = bills.where(bill_date: params[:start_date]..params[:end_date])
    end

    if params[:vendor_id].present? || params[:supplier_id].present?
      bills = bills.where(vendor_id: params[:vendor_id] || params[:supplier_id])
    end

    if params[:search].present?
      term = "%#{params[:search]}%"
      bills = bills.where(
        "bill_number ILIKE ? OR vendor_name ILIKE ? OR memo ILIKE ? OR reference_number ILIKE ?",
        term, term, term, term
      )
    end

    bills = bills.order(bill_date: :desc, created_at: :desc)

    filtered_count = bills.count
    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    bills = bills.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: bills.as_json(
        include: {
          vendor: { only: [:id, :name, :vendor_type] },
          contact: { only: [:id, :first_name, :last_name] },
          location: { only: [:id, :name] },
          bill_line_items: {
            include: { chart_of_account: { only: [:id, :account_number, :name] } }
          },
          bill_payments: { only: [:id, :amount, :payment_date, :payment_method, :check_number] }
        },
        methods: [:vendor_display_name]
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

  def show
    return unless authorize_action!('bills', 'read')

    render json: @bill.as_json(
      include: {
        vendor: { only: [:id, :name, :vendor_type] },
        contact: { only: [:id, :first_name, :last_name] },
        location: { only: [:id, :name] },
        bill_line_items: {
          include: {
            chart_of_account: { only: [:id, :account_number, :name] },
            location: { only: [:id, :name] }
          }
        },
        bill_payments: {
          include: {
            bank_account: { only: [:id, :bank_name, :account_purpose] },
            chart_of_account: { only: [:id, :account_number, :name] },
            journal_entry: { only: [:id, :entry_number] }
          }
        },
        journal_entry: { only: [:id, :entry_number] }
      },
      methods: [:vendor_display_name]
    )
  end

  def create
    return unless authorize_action!('bills', 'create')

    bill = @company.bills.build(bill_params)
    bill.created_by = current_user
    bill.location_id ||= Current.location_id

    bill.status = 'pending' if params[:submit].to_s == 'true' && bill.status == 'draft'

    if bill.save
      render json: serialize_bill(bill), status: :created
    else
      render json: { errors: bill.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('bills', 'update')

    if @bill.status == 'paid'
      return render json: { error: 'Cannot edit a fully paid bill' }, status: :unprocessable_entity
    end
    if @bill.status == 'void'
      return render json: { error: 'Cannot edit a voided bill' }, status: :unprocessable_entity
    end

    was_draft = @bill.status == 'draft'

    if @bill.update(bill_params)
      if was_draft && @bill.status == 'pending' && @bill.journal_entry_id.nil?
        @bill.send(:auto_post_bill_je)
      end

      render json: serialize_bill(@bill)
    else
      render json: { errors: @bill.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('bills', 'delete')

    if @bill.status == 'paid' || @bill.bill_payments.any?
      return render json: { error: 'Cannot delete a bill with payments. Void it instead.' }, status: :unprocessable_entity
    end

    je = @bill.journal_entry
    @bill.update!(is_deleted: true, journal_entry_id: nil)
    je&.destroy
    head :no_content
  end

  # POST /api/v1/bills/:id/void
  def void
    return unless authorize_action!('bills', 'update')
    @bill.void!
    render json: { message: 'Bill voided', bill: serialize_bill(@bill.reload) }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/bills/:id/record_payment
  def record_payment
    return unless authorize_action!('bills', 'update')

    attrs = payment_params
    method = attrs[:payment_method].to_s

    if method == BillPayment::PAYMENT_METHOD_PRINT_CHECK
      if attrs[:bank_account_id].blank?
        return render json: { error: 'bank_account_id is required for print_check payments' },
                      status: :unprocessable_entity
      end
      bank_account = BankAccount.find_by(id: attrs[:bank_account_id])
      unless bank_account&.check_printing_enabled
        return render json: { error: 'Bank account does not have check printing enabled' },
                      status: :unprocessable_entity
      end
      # check_number is assigned at print time — strip any value the client sent.
      attrs = attrs.except(:check_number)
    elsif method == BillPayment::PAYMENT_METHOD_CHECK
      if attrs[:check_number].blank?
        return render json: { error: 'check_number is required for check payments' },
                      status: :unprocessable_entity
      end
      if attrs[:bank_account_id].blank?
        return render json: { error: 'bank_account_id is required for check payments' },
                      status: :unprocessable_entity
      end
    end

    payment = @bill.record_payment!(attrs.merge(created_by: current_user))
    queued_check = payment.printed_checks.first if method == BillPayment::PAYMENT_METHOD_PRINT_CHECK

    render json: {
      message: queued_check ? 'Payment recorded — check queued for printing' : 'Payment recorded',
      payment: payment.as_json(include: { journal_entry: { only: [:id, :entry_number] } }),
      printed_check_id: queued_check&.id,
      bill: serialize_bill(@bill.reload)
    }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/bills/:id/upload_attachment
  def upload_attachment
    return unless authorize_action!('bills', 'update')

    file = params[:file]
    return render json: { error: 'No file provided' }, status: :bad_request unless file

    s3 = S3UploadService.new
    result = s3.upload(file, folder: "bills/#{@company.id}/#{@bill.id}")

    attachment = {
      'url' => result[:url],
      's3_key' => result[:key],
      'filename' => file.original_filename,
      'size' => result[:size],
      'content_type' => result[:content_type],
      'uploaded_at' => Time.current.iso8601,
      'uploaded_by_id' => current_user&.id
    }

    @bill.update!(attachments: (@bill.attachments || []) + [attachment])

    render json: attachment
  rescue => e
    Rails.logger.error("[Bills] Attachment upload failed for bill #{@bill.id}: #{e.message}")
    render json: { error: "Upload failed: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /api/v1/bills/bulk_action
  def bulk_action
    return unless authorize_action!('bills', 'update')

    bill_ids = params[:bill_ids] || []
    action = params[:action_type]

    return render json: { error: 'No bills selected' }, status: :bad_request if bill_ids.empty?
    return render json: { error: 'Invalid action' }, status: :bad_request unless %w[delete void post queue_for_printing].include?(action)

    bills = @company.bills.active.where(id: bill_ids)
    results = { success: 0, failed: 0, errors: [] }

    # Queue for printing requires a bank account
    bank_account = nil
    if action == 'queue_for_printing'
      bank_account = @company.bank_accounts.find_by(id: params[:bank_account_id])
      unless bank_account&.check_printing_enabled
        return render json: { error: 'Select a bank account with check printing enabled' }, status: :unprocessable_entity
      end
    end

    bills.each do |bill|
      begin
        case action
        when 'delete'
          if bill.status == 'paid' || bill.bill_payments.any?
            results[:errors] << "#{bill.bill_number}: Cannot delete a bill with payments"
            results[:failed] += 1
          else
            je = bill.journal_entry
            bill.update!(is_deleted: true, journal_entry_id: nil)
            je&.destroy
            results[:success] += 1
          end
        when 'void'
          bill.void!
          results[:success] += 1
        when 'post'
          if bill.status == 'draft'
            bill.update!(status: 'pending')
            bill.send(:auto_post_bill_je) if bill.journal_entry_id.nil?
            results[:success] += 1
          else
            results[:errors] << "#{bill.bill_number}: Only draft bills can be posted"
            results[:failed] += 1
          end
        when 'queue_for_printing'
          # Post draft bills first
          if bill.status == 'draft'
            bill.update!(status: 'pending')
            bill.send(:auto_post_bill_je) if bill.journal_entry_id.nil?
          end
          if bill.balance_due.to_d <= 0
            results[:errors] << "#{bill.bill_number}: No balance due"
            results[:failed] += 1
          else
            payment = bill.record_payment!(
              amount: bill.balance_due,
              payment_date: Date.current,
              payment_method: 'print_check',
              bank_account_id: bank_account.id,
              created_by: current_user
            )
            results[:success] += 1
          end
        end
      rescue => e
        results[:errors] << "#{bill.bill_number}: #{e.message}"
        results[:failed] += 1
      end
    end

    render json: results
  end

  # POST /api/v1/bills/scan_receipt
  def scan_receipt
    return unless authorize_action!('bills', 'create')

    file = params[:file]
    unless file.present?
      return render json: { error: 'No file provided. Upload a receipt or bill image.' }, status: :bad_request
    end

    begin
      service = Accounting::BillScanService.new(@company, current_user)
      result = service.scan(file)

      if result[:vendor_name].present?
        vendor = @company.vendors.where('name ILIKE ?', "%#{result[:vendor_name]}%").first
        result[:matched_vendor_id] = vendor&.id
        result[:matched_vendor_name] = vendor&.name
      end

      if result[:line_items].present?
        result[:line_items].each do |item|
          hint = item[:category_hint]
          next if hint.blank?
          account = find_expense_account_for_hint(hint)
          item[:suggested_account_id] = account&.id
          item[:suggested_account_name] = account ? "#{account.account_number} — #{account.name}" : nil
        end
      end

      render json: { scan: result }
    rescue Accounting::BillScanService::ScanError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/bills/:id/attachments/:s3_key
  def delete_attachment
    return unless authorize_action!('bills', 'update')

    key = params[:s3_key]
    remaining = (@bill.attachments || []).reject { |a| a['s3_key'] == key }
    S3UploadService.new.delete(key) rescue nil
    @bill.update!(attachments: remaining)
    head :no_content
  end

  private

  def set_bill
    @bill = @company.bills.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Bill not found' }, status: :not_found
  end

  def bill_params
    permitted = params.require(:bill).permit(
      :vendor_id, :supplier_id, :contact_id, :location_id, :vendor_name,
      :bill_date, :due_date, :status, :payment_terms,
      :tax_amount, :memo, :notes, :reference_number, :ap_account_id,
      bill_line_items_attributes: [
        :id, :chart_of_account_id, :amount, :description,
        :location_id, :department, :position, :_destroy
      ]
    )

    # Back-compat: callers may still send supplier_id; map to vendor_id.
    if permitted[:supplier_id].present? && permitted[:vendor_id].blank?
      permitted[:vendor_id] = permitted.delete(:supplier_id)
    else
      permitted.delete(:supplier_id)
    end

    permitted
  end

  def payment_params
    params.require(:payment).permit(
      :amount, :payment_date, :payment_method,
      :check_number, :bank_account_id, :chart_of_account_id, :memo
    )
  end

  # Match a category hint string from bill scanning to a COA expense account
  def find_expense_account_for_hint(hint)
    return nil if hint.blank?

    mappings = {
      'office_supplies' => %w[office supplies],
      'utilities' => %w[utilities electric gas water],
      'repairs' => %w[repairs maintenance],
      'travel' => %w[travel mileage],
      'meals' => %w[meals entertainment dining],
      'insurance' => %w[insurance],
      'rent' => %w[rent lease occupancy],
      'professional_services' => %w[professional legal accounting consulting],
      'advertising' => %w[advertising marketing promotion],
      'vehicle_expense' => %w[vehicle auto fuel gas],
      'equipment' => %w[equipment tools]
    }

    keywords = mappings[hint] || [hint.to_s.gsub('_', ' ')]

    keywords.each do |keyword|
      account = @company.chart_of_accounts
        .where(account_type: 'expense', is_active: true, is_header: false)
        .where('name ILIKE ?', "%#{keyword}%")
        .first
      return account if account
    end

    nil
  end

  def serialize_bill(bill)
    bill.as_json(
      include: {
        vendor: { only: [:id, :name, :vendor_type] },
        contact: { only: [:id, :first_name, :last_name] },
        location: { only: [:id, :name] },
        bill_line_items: {
          include: { chart_of_account: { only: [:id, :account_number, :name] } }
        },
        bill_payments: { only: [:id, :amount, :payment_date, :payment_method, :check_number] },
        journal_entry: { only: [:id, :entry_number] }
      },
      methods: [:vendor_display_name]
    )
  end
end
