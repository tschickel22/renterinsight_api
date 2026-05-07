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

    payment = @bill.record_payment!(payment_params.merge(created_by: current_user))
    render json: {
      message: 'Payment recorded',
      payment: payment.as_json(include: { journal_entry: { only: [:id, :entry_number] } }),
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
