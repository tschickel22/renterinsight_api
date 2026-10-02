# frozen_string_literal: true

# What TrueBuild has learned about a price book's options (CatalogOptionDecision):
# Claude's suggestions, applied as soon as they are made, for a platform admin
# to accept, turn down or correct. Every review is kept and taught back to
# Claude on the manufacturer's next book. Platform data: no company scope.
class Api::Admin::CatalogOptionDecisionsController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_book, only: %i[index review]
  before_action :set_decision, only: %i[update]

  # GET /api/admin/catalog_price_books/:id/option_decisions?unreviewed=1
  # Grouped as suggested: one entry per suggestion, with its options.
  def index
    options = CatalogOption.where(manufacturer_id: @book.manufacturer_id, id: @book.option_prices.select(:catalog_option_id))
                           .includes(:group).index_by(&:key)
    rows = CatalogOptionDecision.where(manufacturer_id: @book.manufacturer_id, option_key: options.keys).order(:created_at, :id)
    rows = rows.where(reviewed_at: nil) if params[:unreviewed].present?
    groups = rows.to_a.group_by { |r| r.suggestion || "decision-#{r.id}" }.map do |key, rs|
      first = rs.first
      { suggestion: key, id: first.id, kind: first.kind, value: first.value, source: first.source, status: first.status,
        note: first.note, reviewed_at: first.reviewed_at, reviewed_by: first.reviewed_by&.full_name,
        options: rs.filter_map { |r| (o = options[r.option_key]) && { id: o.id, name: o.name, group: o.group&.name } } }
    end
    render json: { items: groups, review: @book.metadata['option_review'],
                   unreviewed: CatalogOptionDecision.where(manufacturer_id: @book.manufacturer_id, option_key: options.keys,
                                                           reviewed_at: nil).distinct.count(:suggestion) }
  end

  # POST /api/admin/catalog_price_books/:id/option_review
  # Claude looks again at options with no decision (new ones, or after a reject was undone).
  def review
    @book.update!(metadata: @book.metadata.except('option_review'))
    CatalogOptionReviewJob.perform_later(@book.id)
    render json: { queued: true }, status: :accepted
  end

  # PATCH /api/admin/option_decisions/:id { status: active|rejected, value: }
  # Applies to every option suggested with it.
  def update
    status = params[:status].presence || @decision.status
    return render json: { error: 'Unknown status' }, status: :unprocessable_entity unless CatalogOptionDecision::STATUSES.include?(status)

    attrs = { status: status, reviewed_by_id: (original_user || current_user).id, reviewed_at: Time.current }
    attrs[:value] = params[:value].to_s.squish if params.key?(:value) && @decision.kind != 'not_family'
    scope = @decision.suggestion ? CatalogOptionDecision.where(suggestion: @decision.suggestion) : CatalogOptionDecision.where(id: @decision.id)
    CatalogOptionDecision.transaction { scope.find_each { |d| d.update!(attrs) } }
    render json: { updated: scope.count }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/admin/option_decisions { option_ids: [], kind:, value:, note: }
  # An admin's own decision, from the review list or the designer preview.
  def create
    kind = params[:kind].to_s
    return render json: { error: 'Unknown kind' }, status: :unprocessable_entity unless CatalogOptionDecision::KINDS.include?(kind)

    options = CatalogOption.where(id: Array(params[:option_ids])).to_a
    return render json: { error: 'Choose options' }, status: :unprocessable_entity if options.empty?
    return render json: { error: 'Options must share a manufacturer' }, status: :unprocessable_entity if options.map(&:manufacturer_id).uniq.size > 1

    suggestion = SecureRandom.uuid
    CatalogOptionDecision.transaction do
      options.each do |o|
        d = CatalogOptionDecision.find_or_initialize_by(manufacturer_id: o.manufacturer_id, option_key: o.key, kind: kind)
        d.update!(value: params[:value].to_s.squish.presence, source: 'admin', status: 'active', suggestion: suggestion,
                  note: params[:note].to_s.first(500).presence, reviewed_by_id: (original_user || current_user).id, reviewed_at: Time.current)
      end
    end
    render json: { suggestion: suggestion, created: options.size }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_book
    @book = CatalogPriceBook.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  def set_decision
    @decision = CatalogOptionDecision.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end
end
