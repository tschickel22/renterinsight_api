# frozen_string_literal: true

class Api::V1::AccountingImportsController < ApplicationController
  before_action :set_company_scope

  def index
    return unless authorize_action!('accounting', 'read')

    imports = @company.accounting_imports.recent
    render json: { items: imports }
  end

  def show
    return unless authorize_action!('accounting', 'read')

    import = @company.accounting_imports.find(params[:id])
    render json: import
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  # POST /api/v1/accounting_imports/preview
  def preview
    return unless authorize_action!('accounting', 'create')

    service = Accounting::ImportService.new(@company, current_user)
    result = service.preview(
      source_type: params[:source_type],
      config: build_config
    )

    render json: result
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/accounting_imports/run
  def run_import
    return unless authorize_action!('accounting', 'create')

    service = Accounting::ImportService.new(@company, current_user)
    result = service.run_import!(
      source_type: params[:source_type],
      config: build_config,
      cutover_date: params[:cutover_date].present? ? Date.parse(params[:cutover_date]) : nil,
      entities: params[:entities]
    )

    render json: result, status: :created
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/accounting_imports/parse_iif
  def parse_iif
    return unless authorize_action!('accounting', 'create')

    file_content = read_uploaded_text

    return render json: { error: 'No file provided' }, status: :bad_request if file_content.blank?

    adapter = Accounting::Adapters::QuickbooksDesktopAdapter.new(@company, { 'file_data' => file_content })

    render json: {
      accounts: adapter.fetch_accounts.first(20),
      contacts: adapter.fetch_contacts.first(20),
      vendors: adapter.fetch_vendors.first(20),
      totals: {
        accounts: adapter.count_accounts,
        contacts: adapter.count_contacts,
        vendors: adapter.count_vendors
      }
    }
  rescue => e
    render json: { error: "Failed to parse file: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /api/v1/accounting_imports/parse_csv
  def parse_csv
    return unless authorize_action!('accounting', 'create')

    require 'csv'

    file_content = read_uploaded_text
    return render json: { error: 'No file provided' }, status: :bad_request if file_content.blank?

    rows = CSV.parse(file_content, headers: false)
    headers = rows.first || []
    sample_rows = rows[1..5] || []

    render json: {
      headers: headers,
      sample_rows: sample_rows,
      total_rows: rows.count - 1,
      entity_type: params[:entity_type] || 'accounts'
    }
  rescue CSV::MalformedCSVError => e
    render json: { error: "Invalid CSV: #{e.message}" }, status: :unprocessable_entity
  end

  private

  def read_uploaded_text
    if params[:file].present? && params[:file].respond_to?(:read)
      params[:file].read.force_encoding('UTF-8')
    elsif params[:file_content].present?
      params[:file_content].to_s
    end
  end

  def build_config
    config = {}

    case params[:source_type]
    when 'quickbooks_desktop'
      if params[:file].present? && params[:file].respond_to?(:read)
        config['file_data'] = params[:file].read.force_encoding('UTF-8')
      elsif params[:file_content].present?
        config['file_data'] = params[:file_content].to_s
      elsif params[:parsed_data].present?
        config['parsed_data'] = params[:parsed_data].to_unsafe_h
      end
    when 'csv'
      config['data']     = params[:data].to_unsafe_h     if params[:data].present?
      config['mappings'] = params[:mappings].to_unsafe_h if params[:mappings].present?
    when 'freshbooks'
      config['access_token'] = params[:access_token]
      config['account_id']   = params[:account_id]
    end

    config
  end
end
