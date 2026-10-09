# frozen_string_literal: true

# The TrueBuild factory readiness board (backlog E64): every factory's price
# book, drawings and checks, and releasing a factory so it can be given to
# dealers. Platform data, platform admins only, so no company scope.
class Api::Admin::TruebuildFactoriesController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_factory, only: %i[release unrelease preview]

  # GET /api/admin/truebuild_factories?refresh=1
  def index
    render json: Truebuild::FactoryReadiness.board(refresh: params[:refresh].present?)
  end

  # POST /api/admin/truebuild_factories/:id/release { note }
  # Below the drawn bar it takes a reason: some factories pull models that
  # will never draw well and are still worth selling.
  def release
    row = Truebuild::FactoryReadiness.row(@factory.id)
    note = params[:note].to_s.strip
    below = row[:share] < Truebuild::FactoryReadiness.ready_share
    if below && note.blank?
      return render json: { error: "Only #{(row[:share] * 100).round}% of its photographed models are drawn. Say why it is ready anyway." },
                    status: :unprocessable_entity
    end

    @factory.update!(truebuild_released_at: Time.current, truebuild_released_by_id: current_user&.id, truebuild_release_note: note.presence)
    Truebuild::FactoryReadiness.bust!
    render json: Truebuild::FactoryReadiness.row(@factory.id)
  end

  # DELETE /api/admin/truebuild_factories/:id/release
  # Every dealer given it stops showing its homes at once; they keep it on
  # their list, so releasing it again brings it back for them.
  def unrelease
    @factory.update!(truebuild_released_at: nil, truebuild_released_by_id: nil, truebuild_release_note: nil)
    Truebuild::FactoryReadiness.bust!
    render json: Truebuild::FactoryReadiness.row(@factory.id)
  end

  # POST /api/admin/truebuild_factories/:id/preview { company_id }
  # Preview as a buyer, before the factory is released: its models a
  # published book prices, the dealers to price through, and a pass the
  # buyer designer takes in place of a dealer's token (Truebuild::PreviewPass).
  # Without company_id, the first dealer given the factory, or any dealer
  # with pricing.
  def preview
    dealers = preview_dealers
    company = dealers.find { |c| c.id == params[:company_id].to_i } || dealers.first
    return render json: { error: 'No dealer has TrueBuild pricing to preview with' }, status: :unprocessable_entity unless company

    render json: {
      pass: Truebuild::PreviewPass.issue(company: company, factory: @factory, user: current_user),
      company: { id: company.id, name: company.name, logo: company.branding_settings.to_h['logo'],
                 primary_color: company.branding_settings.to_h['primaryColor'].presence || '#3b82f6' },
      dealers: dealers.map { |c| { id: c.id, name: c.name, given: given_ids.include?(c.id) } },
      models: preview_models
    }
  end

  # PUT /api/admin/truebuild_factories/ready_share { share } (0.5 to 1)
  def update_ready_share
    share = params[:share].to_f
    return render json: { error: 'Use a share between 50% and 100%' }, status: :unprocessable_entity unless share.between?(0.5, 1)

    Setting.set('platform', nil, Truebuild::FactoryReadiness::SETTING, share.to_s)
    Truebuild::FactoryReadiness.bust!
    render json: Truebuild::FactoryReadiness.board
  end

  private

  def given_ids
    @given_ids ||= DealerFactory.where(factory_id: @factory.id).pluck(:company_id).to_set
  end

  # Dealers given this factory first, then the rest with TrueBuild pricing.
  def preview_dealers
    priced = DealerMarkupRule.active.select(:company_id)
    Company.where(id: given_ids.to_a).or(Company.where(id: priced)).order(:name).to_a
           .sort_by { |c| [given_ids.include?(c.id) ? 0 : 1, c.name.to_s.downcase] }
  end

  def preview_models
    variants = CatalogPlanVariant.joins(:catalog_plan).where(catalog_plans: { factory_id: @factory.id }, status: 'active')
                                 .includes(:catalog_plan).order('catalog_plans.series, catalog_plans.name, catalog_plan_variants.model_number').to_a
    ready = Truebuild::ModelList.trueview_ready(variants.map(&:id))
    variants.select { |v| Truebuild::BookResolver.current_for(v) }.map do |v|
      photo = Array(v.media.to_h['photos']).first
      { id: v.id, model_number: v.model_number, name: v.catalog_plan.name, series: v.catalog_plan.series,
        width_ft: v.width_ft, length_ft: v.length_ft, beds: v.beds, baths: v.baths&.to_f, trueview: ready.include?(v.id),
        photo: photo.is_a?(Hash) ? photo['url'] : photo }
    end
  end

  def set_factory
    @factory = Factory.find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @factory
  end
end
