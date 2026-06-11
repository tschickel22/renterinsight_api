# frozen_string_literal: true

require 'csv'

class Api::Company::ManufacturersController < ApplicationController
  before_action :set_company_scope
  before_action :set_company_manufacturer, only: [:update, :destroy]
  
  # GET /api/company/manufacturers
  # Get manufacturers available for this company based on industry type
  def index
    return unless authorize_action!('company_settings', 'read')
    
    # Get company's industry type from settings or locations
    industry_types = determine_company_industry_types
    
    # Get all manufacturers the company can see (global set + its own), matching
    # the company's industry types.
    available_manufacturers = Manufacturer.active
      .visible_to_company(@company.id)
      .where('industry_type IN (?) OR industry_type = ?', industry_types, 'both')
      .alphabetical
    
    # Preload this company's join rows + warranty-claim counts (avoid N+1)
    company_manufacturers_by_mfr = @company.company_manufacturers.index_by(&:manufacturer_id)
    selected_ids = company_manufacturers_by_mfr.keys
    claim_counts = warranty_claim_counts(available_manufacturers.map(&:id))

    # Build response with selection status, contacts, and claim counts
    manufacturers_data = available_manufacturers.map do |manufacturer|
      company_manufacturer = company_manufacturers_by_mfr[manufacturer.id]

      {
        id: manufacturer.id,
        name: manufacturer.name,
        industryType: manufacturer.industry_type,
        # Effective contact (company override if set, else factory default)
        contactName: company_manufacturer&.effective_contact_name || manufacturer.contact_name,
        contactEmail: company_manufacturer&.effective_contact_email || manufacturer.contact_email,
        contactPhone: company_manufacturer&.effective_contact_phone || manufacturer.contact_phone,
        # This company's own override (nil = inherit factory default)
        contactNameOverride: company_manufacturer&.contact_name,
        contactEmailOverride: company_manufacturer&.contact_email,
        contactPhoneOverride: company_manufacturer&.contact_phone,
        # Factory defaults (read-only reference)
        factoryContactName: manufacturer.contact_name,
        factoryContactEmail: manufacturer.contact_email,
        factoryContactPhone: manufacturer.contact_phone,
        # Claim submission target (where warranty claims are sent)
        claimEmail: company_manufacturer&.effective_claim_email || manufacturer.claim_email || manufacturer.contact_email,
        claimContactName: company_manufacturer&.effective_claim_contact_name || manufacturer.claim_contact_name,
        claimEmailOverride: company_manufacturer&.claim_email,
        claimContactNameOverride: company_manufacturer&.claim_contact_name,
        factoryClaimEmail: manufacturer.claim_email,
        factoryClaimContactName: manufacturer.claim_contact_name,
        website: manufacturer.website,
        active: manufacturer.active,
        owned: manufacturer.company_id == @company.id,
        selected: selected_ids.include?(manufacturer.id),
        dealerCode: company_manufacturer&.dealer_code,
        companyManufacturerId: company_manufacturer&.id,
        notes: company_manufacturer&.notes,
        claims: claim_counts[manufacturer.id]
      }
    end
    
    render json: {
      manufacturers: manufacturers_data,
      selectedCount: selected_ids.count,
      industryTypes: industry_types
    }
  end
  
  # POST /api/company/manufacturers
  # Select a manufacturer for this company
  def create
    return unless authorize_action!('company_settings', 'update')
    
    manufacturer = Manufacturer.find(params[:manufacturer_id])
    
    company_manufacturer = @company.company_manufacturers.find_or_initialize_by(
      manufacturer_id: manufacturer.id
    )
    
    company_manufacturer.assign_attributes(
      dealer_code: params[:dealer_code],
      notes: params[:notes],
      contact_name: params[:contact_name],
      contact_email: params[:contact_email],
      contact_phone: params[:contact_phone],
      claim_email: params[:claim_email],
      claim_contact_name: params[:claim_contact_name],
      active: true
    )
    
    if company_manufacturer.save
      Rails.logger.info("[Company Settings] #{current_user.email} added manufacturer #{manufacturer.name} to company #{@company.name}")
      render json: serialize_company_manufacturer(company_manufacturer), status: :created
    else
      render json: { errors: company_manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end
  
  # PATCH /api/company/manufacturers/:id
  # Update dealer code or notes for a company-manufacturer relationship
  def update
    return unless authorize_action!('company_settings', 'update')
    
    if @company_manufacturer.update(update_params)
      Rails.logger.info("[Company Settings] #{current_user.email} updated manufacturer #{@company_manufacturer.manufacturer.name} for company #{@company.name}")
      render json: serialize_company_manufacturer(@company_manufacturer)
    else
      render json: { errors: @company_manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end
  
  # DELETE /api/company/manufacturers/:id
  # Remove a manufacturer from this company
  def destroy
    return unless authorize_action!('company_settings', 'update')
    
    manufacturer_name = @company_manufacturer.manufacturer.name
    
    if @company_manufacturer.destroy
      Rails.logger.info("[Company Settings] #{current_user.email} removed manufacturer #{manufacturer_name} from company #{@company.name}")
      head :no_content
    else
      render json: { errors: @company_manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end
  
  # POST /api/company/manufacturers/owned
  # Create a manufacturer owned by this company (not a global one).
  def create_owned
    return unless authorize_action!('company_settings', 'update')

    manufacturer = Manufacturer.new(owned_manufacturer_params)
    manufacturer.company_id = @company.id # tenant-owned; never from params

    if manufacturer.save
      # Link it to the company so it behaves like a selected manufacturer.
      @company.company_manufacturers.find_or_create_by(manufacturer_id: manufacturer.id) do |cm|
        cm.active = true
      end
      Rails.logger.info("[Company Settings] #{current_user.email} created owned manufacturer #{manufacturer.name} for company #{@company.name}")
      render json: serialize_owned_manufacturer(manufacturer), status: :created
    else
      render json: { errors: manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/company/manufacturers/owned/:id
  def update_owned
    return unless authorize_action!('company_settings', 'update')

    manufacturer = Manufacturer.owned_by(@company.id).find_by(id: params[:id])
    return render json: { error: 'Manufacturer not found' }, status: :not_found unless manufacturer

    if manufacturer.update(owned_manufacturer_params)
      render json: serialize_owned_manufacturer(manufacturer)
    else
      render json: { errors: manufacturer.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/company/manufacturers/owned/:id
  def destroy_owned
    return unless authorize_action!('company_settings', 'update')

    manufacturer = Manufacturer.owned_by(@company.id).find_by(id: params[:id])
    return render json: { error: 'Manufacturer not found' }, status: :not_found unless manufacturer

    if manufacturer.warranty_claims.exists?
      return render json: { error: 'Cannot delete a manufacturer with warranty claims; deactivate it instead' },
                    status: :unprocessable_entity
    end

    @company.company_manufacturers.where(manufacturer_id: manufacturer.id).destroy_all
    manufacturer.destroy
    head :no_content
  end

  # POST /api/company/manufacturers/import
  # Bulk-create company-owned manufacturers from a CSV upload.
  # Recognized headers (case-insensitive): name (required), industry_type|industry,
  # code, contact_name, contact_email, contact_phone, claim_email,
  # claim_contact_name, website. Existing company-owned names are skipped.
  def import
    return unless authorize_action!('company_settings', 'update')

    csv_text = read_import_csv
    return render json: { error: 'No CSV provided' }, status: :unprocessable_entity if csv_text.blank?

    created = 0
    skipped = 0
    errors = []
    existing_names = Manufacturer.owned_by(@company.id).pluck(:name).map { |n| n.to_s.downcase.strip }

    begin
      rows = CSV.parse(csv_text, headers: true)
    rescue CSV::MalformedCSVError => e
      return render json: { error: "Could not parse CSV: #{e.message}" }, status: :unprocessable_entity
    end

    rows.each_with_index do |row, i|
      attrs = manufacturer_attrs_from_row(row)
      if attrs[:name].blank?
        errors << { row: i + 2, message: 'Missing name' }
        next
      end
      if existing_names.include?(attrs[:name].downcase.strip)
        skipped += 1
        next
      end

      manufacturer = Manufacturer.new(attrs.merge(company_id: @company.id))
      if manufacturer.save
        @company.company_manufacturers.find_or_create_by(manufacturer_id: manufacturer.id) { |cm| cm.active = true }
        existing_names << attrs[:name].downcase.strip
        created += 1
      else
        errors << { row: i + 2, message: manufacturer.errors.full_messages.join(', ') }
      end
    end

    render json: { created: created, skipped: skipped, errors: errors }
  end

  private

  def read_import_csv
    if params[:file].respond_to?(:read)
      params[:file].read
    else
      params[:csv].presence
    end
  end

  VALID_INDUSTRY_TYPES = %w[rv manufactured_home both].freeze

  def manufacturer_attrs_from_row(row)
    h = row.to_h.transform_keys { |k| k.to_s.downcase.strip }
    industry = (h['industry_type'] || h['industry']).to_s.downcase.strip
    industry = 'both' unless VALID_INDUSTRY_TYPES.include?(industry)
    {
      name: h['name'].to_s.strip,
      industry_type: industry,
      code: h['code'].presence,
      website: h['website'].presence,
      contact_name: h['contact_name'].presence,
      contact_email: h['contact_email'].presence,
      contact_phone: h['contact_phone'].presence,
      claim_email: h['claim_email'].presence,
      claim_contact_name: h['claim_contact_name'].presence,
      active: true
    }
  end

  # One grouped query → { manufacturer_id => { submitted:, pending:, approved:, denied:, total: } }
  def warranty_claim_counts(manufacturer_ids)
    return Hash.new { |h, k| h[k] = default_claim_counts } if manufacturer_ids.blank?

    grouped = WarrantyClaim
      .where(company_id: @company.id, manufacturer_id: manufacturer_ids)
      .group(:manufacturer_id, :status)
      .count

    result = Hash.new { |h, k| h[k] = default_claim_counts }
    grouped.each do |(manufacturer_id, status), count|
      bucket = result[manufacturer_id]
      bucket[:total] += count
      case status
      when 'submitted', 'resubmitted' then bucket[:submitted] += count
      when 'under_review'             then bucket[:pending]   += count
      when 'approved'                 then bucket[:approved]  += count
      when 'denied', 'short_paid'     then bucket[:denied]    += count
      end
    end
    result
  end

  def default_claim_counts
    { submitted: 0, pending: 0, approved: 0, denied: 0, total: 0 }
  end

  def owned_manufacturer_params
    # NOTE: company_id is set server-side, never permitted (tenant isolation).
    params.require(:manufacturer).permit(
      :name, :industry_type, :code, :website, :active,
      :contact_name, :contact_email, :contact_phone,
      :claim_email, :claim_contact_name
    )
  end

  def serialize_owned_manufacturer(manufacturer)
    {
      id: manufacturer.id,
      manufacturerId: manufacturer.id,
      name: manufacturer.name,
      industryType: manufacturer.industry_type,
      code: manufacturer.code,
      website: manufacturer.website,
      active: manufacturer.active,
      owned: true,
      contactName: manufacturer.contact_name,
      contactEmail: manufacturer.contact_email,
      contactPhone: manufacturer.contact_phone,
      claimEmail: manufacturer.claim_email,
      claimContactName: manufacturer.claim_contact_name,
      createdAt: manufacturer.created_at,
      updatedAt: manufacturer.updated_at
    }
  end

  def set_company_manufacturer
    @company_manufacturer = @company.company_manufacturers.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Company manufacturer not found' }, status: :not_found
  end
  
  def update_params
    params.permit(:dealer_code, :notes, :active, :contact_name, :contact_email, :contact_phone,
                  :claim_email, :claim_contact_name)
  end
  
  def determine_company_industry_types
    # Since locations don't have a location_type column,
    # we'll default to showing all manufacturer types (both)
    # Companies can select any manufacturers they work with
    ['rv', 'manufactured_home', 'both']
  end
  
  def serialize_company_manufacturer(company_manufacturer)
    manufacturer = company_manufacturer.manufacturer
    {
      id: company_manufacturer.id,
      companyId: company_manufacturer.company_id,
      manufacturerId: company_manufacturer.manufacturer_id,
      manufacturerName: manufacturer.name,
      industryType: manufacturer.industry_type,
      dealerCode: company_manufacturer.dealer_code,
      active: company_manufacturer.active,
      notes: company_manufacturer.notes,
      # Effective contact (company override if set, else factory default)
      contactName: company_manufacturer.effective_contact_name,
      contactEmail: company_manufacturer.effective_contact_email,
      contactPhone: company_manufacturer.effective_contact_phone,
      # This company's own override (nil = inherit factory default)
      contactNameOverride: company_manufacturer.contact_name,
      contactEmailOverride: company_manufacturer.contact_email,
      contactPhoneOverride: company_manufacturer.contact_phone,
      # Factory defaults (read-only reference)
      factoryContactName: manufacturer.contact_name,
      factoryContactEmail: manufacturer.contact_email,
      factoryContactPhone: manufacturer.contact_phone,
      # Claim submission target (where warranty claims are sent)
      claimEmail: company_manufacturer.effective_claim_email,
      claimContactName: company_manufacturer.effective_claim_contact_name,
      claimEmailOverride: company_manufacturer.claim_email,
      claimContactNameOverride: company_manufacturer.claim_contact_name,
      factoryClaimEmail: manufacturer.claim_email,
      factoryClaimContactName: manufacturer.claim_contact_name,
      createdAt: company_manufacturer.created_at,
      updatedAt: company_manufacturer.updated_at
    }
  end
end
