require 'csv'

class Api::V1::AudiencesController < ApplicationController
  before_action :set_company_scope
  before_action :set_audience, only: %i[show update destroy preview refresh archive unarchive members export add_members remove_members]

  def index
    return unless authorize_action!('campaigns', 'read')

    @audiences = @company.audiences
    @audiences = params[:archived].to_s == 'true' ? @audiences.archived : @audiences.active
    @audiences = @audiences.where(source_type: params[:source_type]) if params[:source_type].present?

    if params[:search].present?
      term = "%#{params[:search]}%"
      @audiences = @audiences.where('name ILIKE ? OR description ILIKE ?', term, term)
    end

    base_for_stats = @company.audiences.active
    stats = {
      total: @company.audiences.count,
      active: base_for_stats.count,
      archived: @company.audiences.archived.count,
      lead: base_for_stats.where(source_type: 'Lead').count,
      contact: base_for_stats.where(source_type: 'Contact').count,
      account: base_for_stats.where(source_type: 'Account').count
    }

    @audiences = @audiences.order(updated_at: :desc)
    filtered_count = @audiences.count

    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    @audiences = @audiences.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: @audiences.map { |a| audience_json(a) },
      meta: { total: filtered_count, page: page, per_page: per_page, total_pages: (filtered_count.to_f / per_page).ceil, stats: stats }
    }
  end

  def show
    return unless authorize_action!('campaigns', 'read')
    render json: audience_json(@audience, full: true)
  end

  def create
    return unless authorize_action!('campaigns', 'create')

    @audience = @company.audiences.build(audience_params)
    @audience.created_by_user_id = current_user.id

    if @audience.save
      compute_estimate(@audience)
      render json: audience_json(@audience, full: true), status: :created
    else
      render json: { errors: @audience.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('campaigns', 'update')

    if @audience.update(audience_params)
      estimate_keys = %i[filter_tree exclude_filter_tree manual_include_ids manual_exclude_ids exclude_active_campaign_enrollees exclude_active_nurture_enrollees]
      compute_estimate(@audience) if estimate_keys.any? { |k| audience_params.key?(k) }
      render json: audience_json(@audience, full: true)
    else
      render json: { errors: @audience.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('campaigns', 'delete')

    if @audience.campaign_audiences.exists?
      return render(json: { error: 'Cannot delete audience used by one or more campaigns. Archive instead.' }, status: :unprocessable_entity)
    end

    if @audience.destroy
      head :no_content
    else
      render json: { error: 'Cannot delete audience: ' + @audience.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  rescue ActiveRecord::InvalidForeignKey
    render json: { error: 'Cannot delete audience: it is still referenced by other records. Try archiving instead.' }, status: :unprocessable_entity
  end

  def archive
    return unless authorize_action!('campaigns', 'update')
    @audience.update!(is_archived: true)
    render json: audience_json(@audience, full: true)
  end

  def unarchive
    return unless authorize_action!('campaigns', 'update')
    @audience.update!(is_archived: false)
    render json: audience_json(@audience, full: true)
  end

  def preview
    return unless authorize_action!('campaigns', 'read')

    filter_tree = params[:filter_tree].present? ? to_hash(params[:filter_tree]) : @audience.filter_tree
    exclude = params[:exclude_filter_tree].present? ? to_hash(params[:exclude_filter_tree]) : @audience.exclude_filter_tree
    manual_include_ids = params.key?(:manual_include_ids) ? Array(params[:manual_include_ids]) : @audience.manual_include_ids
    manual_exclude_ids = params.key?(:manual_exclude_ids) ? Array(params[:manual_exclude_ids]) : @audience.manual_exclude_ids
    exclude_active_campaign_enrollees = params.key?(:exclude_active_campaign_enrollees) ?
      ActiveModel::Type::Boolean.new.cast(params[:exclude_active_campaign_enrollees]) :
      @audience.exclude_active_campaign_enrollees
    exclude_active_nurture_enrollees = params.key?(:exclude_active_nurture_enrollees) ?
      ActiveModel::Type::Boolean.new.cast(params[:exclude_active_nurture_enrollees]) :
      @audience.exclude_active_nurture_enrollees

    compiler = Audiences::FilterCompiler.new(
      company: @company, source_type: @audience.source_type,
      filter_tree: filter_tree, exclude_filter_tree: exclude,
      manual_include_ids: manual_include_ids,
      manual_exclude_ids: manual_exclude_ids,
      exclude_active_campaign_enrollees: exclude_active_campaign_enrollees,
      exclude_active_nurture_enrollees: exclude_active_nurture_enrollees
    )

    render json: {
      count: compiler.count,
      sample: compiler.sample(limit: (params[:sample_size] || 5).to_i)
    }
  rescue Audiences::FilterCompiler::CompilationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def refresh
    return unless authorize_action!('campaigns', 'update')
    compute_estimate(@audience)
    render json: audience_json(@audience, full: true)
  end

  def preview_dry_run
    return unless authorize_action!('campaigns', 'read')

    source_type = params[:source_type] || 'Lead'
    filter_tree = to_hash(params[:filter_tree]) || {}
    exclude = params[:exclude_filter_tree].present? ? to_hash(params[:exclude_filter_tree]) : nil

    compiler = Audiences::FilterCompiler.new(
      company: @company, source_type: source_type,
      filter_tree: filter_tree, exclude_filter_tree: exclude,
      manual_include_ids: Array(params[:manual_include_ids]),
      manual_exclude_ids: Array(params[:manual_exclude_ids]),
      exclude_active_campaign_enrollees: ActiveModel::Type::Boolean.new.cast(params[:exclude_active_campaign_enrollees]),
      exclude_active_nurture_enrollees: ActiveModel::Type::Boolean.new.cast(params[:exclude_active_nurture_enrollees])
    )

    render json: {
      source_type: source_type,
      count: compiler.count,
      sample: compiler.sample(limit: (params[:sample_size] || 5).to_i)
    }
  rescue Audiences::FilterCompiler::CompilationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def members
    return unless authorize_action!('campaigns', 'read')

    scope = compiler_for(@audience).scope

    scope = apply_member_search(scope, params[:search]) if params[:search].present?

    total = scope.count
    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    records = scope.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: records.map { |r| member_row(r) },
      meta: {
        total: total, page: page, per_page: per_page,
        total_pages: (total.to_f / per_page).ceil
      }
    }
  rescue Audiences::FilterCompiler::CompilationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def export
    return unless authorize_action!('campaigns', 'read')

    scope = compiler_for(@audience).scope

    scope = apply_member_search(scope, params[:search]) if params[:search].present?

    headers = member_csv_headers
    csv_string = CSV.generate do |csv|
      csv << headers
      scope.find_each do |r|
        row = member_row(r)
        csv << headers.map { |h| row[h.to_sym] }
      end
    end

    filename = "audience-#{@audience.name.parameterize}-#{Date.current.iso8601}.csv"
    send_data csv_string, filename: filename, type: 'text/csv', disposition: 'attachment'
  rescue Audiences::FilterCompiler::CompilationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def ai_generate
    return unless authorize_action!('campaigns', 'create')

    prompt = params[:prompt].to_s.strip
    return render(json: { error: 'prompt is required' }, status: :unprocessable_entity) if prompt.blank?
    source_type = params[:source_type].presence || 'Lead'

    generation = Audiences::AiBuilder.new(company: @company, user: current_user).generate(prompt: prompt, source_type: source_type)

    compiler = Audiences::FilterCompiler.new(
      company: @company, source_type: source_type, filter_tree: generation.generated_filter_tree
    )
    preview = { count: compiler.count, sample: compiler.sample(limit: 5) }

    render json: {
      generation_id: generation.id,
      filter_tree: generation.generated_filter_tree,
      source_type: source_type,
      model_version: generation.model_version,
      input_tokens: generation.input_tokens,
      output_tokens: generation.output_tokens,
      preview: preview
    }
  rescue Audiences::AiBuilder::CreditLimitError => e
    render json: { error: e.message, code: 'credit_limit' }, status: :too_many_requests
  rescue Audiences::AiBuilder::GenerationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue Audiences::FilterCompiler::CompilationError => e
    render json: { error: "AI generated an invalid filter: #{e.message}" }, status: :unprocessable_entity
  end

  def ai_refine
    return unless authorize_action!('campaigns', 'create')

    generation = AudienceAiGeneration.find_by(id: params[:generation_id], company_id: @company.id)
    return render(json: { error: 'Generation not found' }, status: :not_found) unless generation

    feedback = params[:feedback].to_s.strip
    return render(json: { error: 'feedback is required' }, status: :unprocessable_entity) if feedback.blank?

    new_gen = Audiences::AiBuilder.new(company: @company, user: current_user).refine(generation: generation, feedback: feedback)

    compiler = Audiences::FilterCompiler.new(
      company: @company, source_type: new_gen.source_type, filter_tree: new_gen.generated_filter_tree
    )
    preview = { count: compiler.count, sample: compiler.sample(limit: 5) }

    render json: {
      generation_id: new_gen.id, filter_tree: new_gen.generated_filter_tree,
      source_type: new_gen.source_type, parent_id: generation.id, preview: preview
    }
  rescue Audiences::AiBuilder::CreditLimitError => e
    render json: { error: e.message, code: 'credit_limit' }, status: :too_many_requests
  rescue Audiences::AiBuilder::GenerationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def add_members
    return unless authorize_action!('campaigns', 'update')

    ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
    return render(json: { error: 'ids is required' }, status: :unprocessable_entity) if ids.empty?

    current_includes = Array(@audience.manual_include_ids).map(&:to_i)
    current_excludes = Array(@audience.manual_exclude_ids).map(&:to_i)

    new_includes = (current_includes + ids).uniq
    new_excludes = current_excludes - ids

    @audience.update!(manual_include_ids: new_includes, manual_exclude_ids: new_excludes)
    compute_estimate(@audience)
    render json: audience_json(@audience, full: true)
  end

  def remove_members
    return unless authorize_action!('campaigns', 'update')

    ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
    return render(json: { error: 'ids is required' }, status: :unprocessable_entity) if ids.empty?

    current_includes = Array(@audience.manual_include_ids).map(&:to_i)
    current_excludes = Array(@audience.manual_exclude_ids).map(&:to_i)

    new_excludes = (current_excludes + ids).uniq
    new_includes = current_includes - ids

    @audience.update!(manual_include_ids: new_includes, manual_exclude_ids: new_excludes)
    compute_estimate(@audience)
    render json: audience_json(@audience, full: true)
  end

  def ai_accept
    return unless authorize_action!('campaigns', 'create')

    generation = AudienceAiGeneration.find_by(id: params[:generation_id], company_id: @company.id)
    return render(json: { error: 'Generation not found' }, status: :not_found) unless generation

    name = params[:name].to_s.strip
    return render(json: { error: 'name is required' }, status: :unprocessable_entity) if name.blank?

    audience = Audiences::AiBuilder.new(company: @company, user: current_user).accept(
      generation: generation, name: name, description: params[:description]
    )
    render json: audience_json(audience, full: true), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def set_audience
    @audience = @company.audiences.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Audience not found' }, status: :not_found
  end

  def audience_params
    params.require(:audience).permit(
      :name, :description, :source_type, :location_id,
      :exclude_active_campaign_enrollees, :exclude_active_nurture_enrollees,
      filter_tree: {}, exclude_filter_tree: {}, metadata: {},
      manual_include_ids: [], manual_exclude_ids: []
    )
  end

  def compiler_for(audience)
    Audiences::FilterCompiler.new(
      company: @company,
      source_type: audience.source_type,
      filter_tree: audience.filter_tree,
      exclude_filter_tree: audience.exclude_filter_tree,
      manual_include_ids: audience.manual_include_ids,
      manual_exclude_ids: audience.manual_exclude_ids,
      exclude_active_campaign_enrollees: audience.exclude_active_campaign_enrollees,
      exclude_active_nurture_enrollees: audience.exclude_active_nurture_enrollees
    )
  end

  def to_hash(value)
    return nil if value.nil?
    return value.to_unsafe_h if value.is_a?(ActionController::Parameters)
    value
  end

  def compute_estimate(audience)
    compiler = compiler_for(audience)
    audience.update_columns(estimated_count: compiler.count, estimated_at: Time.current)
  rescue Audiences::FilterCompiler::CompilationError => e
    Rails.logger.warn "[AudiencesController] estimate compute failed: #{e.message}"
  end

  def audience_json(a, full: false)
    base = {
      id: a.id, name: a.name, description: a.description, source_type: a.source_type,
      estimated_count: a.estimated_count, estimated_at: a.estimated_at,
      is_archived: a.is_archived, location_id: a.location_id,
      exclude_active_campaign_enrollees: a.exclude_active_campaign_enrollees,
      exclude_active_nurture_enrollees: a.exclude_active_nurture_enrollees,
      manual_include_count: Array(a.manual_include_ids).size,
      manual_exclude_count: Array(a.manual_exclude_ids).size,
      created_by_user_id: a.created_by_user_id, created_at: a.created_at, updated_at: a.updated_at
    }
    return base unless full
    base.merge(
      filter_tree: a.filter_tree, exclude_filter_tree: a.exclude_filter_tree,
      manual_include_ids: Array(a.manual_include_ids),
      manual_exclude_ids: Array(a.manual_exclude_ids),
      generated_from_ai_generation_id: a.generated_from_ai_generation_id,
      campaigns_using_count: a.campaign_audiences.count,
      campaigns_using: a.campaign_audiences.includes(:campaign).map { |ca|
        { id: ca.campaign.id, name: ca.campaign.name, status: ca.campaign.status }
      }
    )
  end

  def apply_member_search(scope, search)
    term = "%#{search}%"
    case @audience.source_type
    when 'Lead', 'Contact'
      scope.where('first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ?', term, term, term)
    when 'Account'
      scope.where('name ILIKE ? OR website ILIKE ?', term, term)
    else
      scope
    end
  end

  def member_csv_headers
    case @audience.source_type
    when 'Lead'    then %w[id first_name last_name email phone status created_at]
    when 'Contact' then %w[id first_name last_name email phone account_id created_at]
    when 'Account' then %w[id name account_type website created_at]
    else []
    end
  end

  def member_row(r)
    case @audience.source_type
    when 'Lead'
      { id: r.id, first_name: r.first_name, last_name: r.last_name, email: r.email,
        phone: r.phone, status: r.status, created_at: r.created_at }
    when 'Contact'
      { id: r.id, first_name: r.first_name, last_name: r.last_name, email: r.email,
        phone: r.phone, account_id: r.account_id, created_at: r.created_at }
    when 'Account'
      { id: r.id, name: r.name, account_type: r.account_type, website: r.website,
        created_at: r.created_at }
    else
      { id: r.id }
    end
  end
end
