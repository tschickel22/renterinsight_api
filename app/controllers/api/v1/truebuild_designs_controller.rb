# frozen_string_literal: true

# Homes buyers designed and saved, for the rep: what they chose, the price
# they were shown, what it would cost today, and whether the share link is
# being opened.
class Api::V1::TruebuildDesignsController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/truebuild_designs?lead_id=
  def index
    return unless authorize_action!('leads', 'read')

    designs = @company.truebuild_designs.includes(variant: :catalog_plan, vehicle: []).order(created_at: :desc)
    designs = designs.where(lead_id: params[:lead_id]) if params[:lead_id].present?
    render json: { designs: designs.limit(50).map { |d| design_json(d) } }
  end

  # POST /api/v1/truebuild_designs/:id/quote
  # A draft quote from the design: the home and each option at the price the
  # buyer was shown when prices are shown, else today's. Needs the lead
  # converted first, since quotes belong to a contact and account.
  def create_quote
    return unless authorize_action!('finance', 'create')

    design = @company.truebuild_designs.find(params[:id])
    return render json: { error: 'Convert this lead first. A quote belongs to a contact and account.' }, status: :unprocessable_entity unless design.contact_id
    return render json: quote_json(design.quote), status: :ok if design.quote && !design.quote.is_deleted

    quote = @company.quotes.create!(
      account_id: design.account_id, contact_id: design.contact_id, deal_id: design.deal_id,
      vehicle_id: design.vehicle_id&.to_s, location_id: design.vehicle&.location_id || Current.location_id,
      sales_rep_id: current_user.id, status: 'draft', items: quote_items(design),
      notes: "From the #{design.name} design the buyer saved on #{design.created_at.to_date.strftime('%b %-d, %Y')}."
    )
    design.update!(quote: quote, status: 'quote_requested')
    render json: quote_json(quote), status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  private

  def quote_json(quote)
    { id: quote.id, quote_number: quote.quote_number, total: quote.total.to_f, status: quote.status }
  end

  # Lines as the buyer saw them when the dealer showed prices; otherwise priced now.
  def quote_items(design)
    lines = design.price_snapshot['show_prices'] ? design.price_snapshot['lines'] : nil
    lines = Truebuild::PricingEngine.new(company: @company, variant: design.variant, option_ids: design.option_ids,
                                         location: design.vehicle&.location).call.retail_only[:lines].map(&:stringify_keys) if lines.blank?
    lines.each_with_index.map do |l, i|
      base = l['kind'] == 'base'
      { 'id' => SecureRandom.hex(5), 'description' => l['label'], 'quantity' => 1, 'unit_price' => l['retail'].to_f.to_s,
        'total' => l['retail'].to_f, 'discount' => 0, 'discount_type' => 'percentage',
        'category' => base ? 'home' : (l['kind'] == 'freight' ? 'fee' : 'package'), 'taxable' => l['kind'] != 'freight',
        'notes' => '', 'position' => i }
    end
  end

  def design_json(d)
    names = CatalogOption.where(id: d.option_ids).pluck(:id, :name).to_h
    shown = d.price_snapshot['show_prices'] ? d.price_snapshot['total'] : nil
    {
      id: d.id, name: d.name, status: d.status, created_at: d.created_at,
      buyer_name: d.buyer_name, lead_id: d.lead_id, contact_id: d.contact_id, deal_id: d.deal_id,
      quote_id: d.quote_id, quote_number: d.quote&.quote_number, vehicle_id: d.vehicle_id, stock_number: d.vehicle&.stock_number,
      options: d.option_ids.filter_map { |id| names[id] },
      price_shown: shown, price_today: price_today(d),
      view_count: d.view_count, last_viewed_at: d.last_viewed_at,
      link: Truebuild::DesignSaver.design_url(d)
    }
  end

  # The same home and options at today's prices, so a rep sees an increase
  # before the buyer does.
  def price_today(d)
    Truebuild::PricingEngine.new(company: @company, variant: d.variant, option_ids: d.option_ids,
                                 location: d.vehicle&.location).call.totals[:retail]
  rescue ArgumentError
    nil
  end
end
