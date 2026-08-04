# frozen_string_literal: true

class Api::V1::VendorsController < ApplicationController
  before_action :set_company_scope
  before_action :set_vendor, only: [:show, :update, :destroy]

  def index
    return unless authorize_action!('vendors', 'read')

    vendors = @company.vendors.where(is_deleted: [false, nil])
    vendors = vendors.where(vendor_type: params[:vendor_type]) if params[:vendor_type].present?
    vendors = vendors.where(status: params[:status])           if params[:status].present?
    vendors = vendors.where(is_1099_eligible: true)            if truthy?(params[:is_1099_eligible])

    # Stats counted BEFORE search filter (for tiles)
    all_vendors_count = vendors.count
    active_count = vendors.where(status: 'active').count
    inactive_count = vendors.where(status: ['inactive', 'suspended']).count
    trade_type_counts = vendors.where("trade_type IS NOT NULL AND trade_type != ''").group(:trade_type).count

    if params[:search].present?
      term = "%#{params[:search]}%"
      vendors = vendors.where(
        'name ILIKE ? OR email ILIKE ? OR code ILIKE ? OR account_number ILIKE ? OR contact_name ILIKE ? OR trade_type ILIKE ?',
        term, term, term, term, term, term
      )
    end

    # Sort
    sort_by = params[:sort_by] || 'created_at'
    sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
    vendors = vendors.order(sort_by => sort_order)

    # Count after filters (for pagination)
    filtered_count = vendors.count

    page     = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    vendors  = vendors.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: vendors.map { |v| vendor_detail_json(v) },
      meta: {
        total: filtered_count,
        page: page,
        per_page: per_page,
        total_pages: (filtered_count.to_f / per_page).ceil,
        stats: {
          total: all_vendors_count,
          active: active_count,
          inactive: inactive_count,
          by_trade_type: trade_type_counts
        }
      }
    }
  end

  def show
    return unless authorize_action!('vendors', 'read')
    render json: vendor_detail_json(@vendor)
  end

  def create
    return unless authorize_action!('vendors', 'create')

    vendor = @company.vendors.build(vendor_params)
    vendor.created_by = current_user if vendor.respond_to?(:created_by=)

    if vendor.save
      render json: vendor_detail_json(vendor), status: :created
    else
      render json: { errors: vendor.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('vendors', 'update')

    @vendor.updated_by = current_user if @vendor.respond_to?(:updated_by=)
    if @vendor.update(vendor_params)
      render json: vendor_detail_json(@vendor)
    else
      render json: { errors: @vendor.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('vendors', 'delete')

    @vendor.soft_delete!
    head :no_content
  end

  private

  def set_vendor
    @vendor = @company.vendors.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Vendor not found' }, status: :not_found
  end

  def vendor_params
    params.require(:vendor).permit(
      :name, :vendor_type, :code, :contact_name, :email, :phone, :website,
      :address_line1, :address_line2, :city, :state, :zip_code, :country,
      :tax_id, :payment_terms, :default_lead_time_days, :qb_vendor_id,
      :account_number, :is_1099_eligible, :default_expense_account_id,
      :status, :active, :notes,
      # Contractor-specific fields
      :trade_type, :license_number, :license_state, :license_expiry,
      :insurance_provider, :insurance_policy_number, :insurance_expiry,
      :bonded, :bond_amount, :bond_expiry, :hourly_rate, :rating
    )
  end

  def vendor_json_columns
    %i[
      id company_id name vendor_type code contact_name email phone website
      address_line1 address_line2 city state zip_code country
      tax_id payment_terms default_lead_time_days qb_vendor_id
      account_number is_1099_eligible default_expense_account_id
      status active notes trade_type license_number license_state license_expiry
      insurance_provider insurance_policy_number insurance_expiry
      bonded bond_amount bond_expiry hourly_rate rating
      is_deleted created_at updated_at
    ]
  end

  def truthy?(val)
    %w[1 true t yes y].include?(val.to_s.downcase)
  end

  def vendor_detail_json(vendor)
    {
      id: vendor.id,
      companyId: vendor.company_id,
      name: vendor.name,
      vendorType: vendor.vendor_type,
      code: vendor.code,
      contactName: vendor.contact_name,
      email: vendor.email,
      phone: vendor.phone,
      website: vendor.website,
      addressLine1: vendor.address_line1,
      addressLine2: vendor.address_line2,
      city: vendor.city,
      state: vendor.state,
      zipCode: vendor.zip_code,
      country: vendor.country,
      taxId: vendor.tax_id,
      paymentTerms: vendor.payment_terms,
      accountNumber: vendor.account_number,
      is1099Eligible: vendor.is_1099_eligible,
      tradeType: vendor.trade_type,
      licenseNumber: vendor.license_number,
      licenseState: vendor.license_state,
      licenseExpiry: vendor.license_expiry,
      insuranceProvider: vendor.insurance_provider,
      insurancePolicyNumber: vendor.insurance_policy_number,
      insuranceExpiry: vendor.insurance_expiry,
      bonded: vendor.bonded,
      bondAmount: vendor.bond_amount,
      bondExpiry: vendor.bond_expiry,
      hourlyRate: vendor.hourly_rate,
      notes: vendor.notes,
      status: vendor.status,
      active: vendor.active,
      rating: vendor.rating,
      isVendor: vendor.respond_to?(:is_vendor) ? vendor.is_vendor : nil,
      customFieldValues: vendor.custom_field_values,
      smsConsent: vendor.sms_consent_json,
      createdAt: vendor.created_at,
      updatedAt: vendor.updated_at
    }
  end
end
