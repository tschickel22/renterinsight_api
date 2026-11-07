# frozen_string_literal: true

# DealerTide's side of each client's onboarding list (backlog E97): the
# clients with a list, one client's items, activity and followers, and the
# standard list every new client starts from. Platform admins only; a
# client's own users work their side in Getting started.
class Api::Admin::OnboardingController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_client, except: %i[index template create_template update_template destroy_template]
  before_action :set_item, only: %i[update_item destroy_item done reopen not_needed note upload download save_to_standard]

  # GET /api/admin/onboarding
  # Clients with a list, the ones waiting longest on top; plus every tenant to start one.
  def index
    ids = OnboardingItem.distinct.pluck(:company_id)
    clients = Company.where(id: ids).order(:name).map do |c|
      last = c.onboarding_events.maximum(:created_at)
      { id: c.id, name: c.name, progress: Onboarding::View.progress(c), last_activity_at: last&.iso8601 }
    end
    render json: { clients: clients, tenants: Company.where.not(id: ids).order(:name).limit(500).pluck(:id, :name).map { |id, name| { id: id, name: name } } }
  end

  # GET /api/admin/onboarding/:company_id
  def show
    render json: client_json
  end

  # POST /api/admin/onboarding/:company_id/start
  def start
    added = checklist.start_from_standard!
    render json: client_json.merge(added: added.size)
  end

  # POST /api/admin/onboarding/:company_id/items { section, title, detail, owed_by, assignee_id, due_on }
  def create_item
    answer { checklist.add!(item_params) }
  end

  # PATCH /api/admin/onboarding/:company_id/items/:id
  def update_item
    answer { checklist.update!(@item, item_params) }
  end

  # DELETE /api/admin/onboarding/:company_id/items/:id
  def destroy_item
    checklist.remove!(@item)
    render json: client_json
  end

  def done = answer { checklist.complete!(@item) }
  def reopen = answer { checklist.reopen!(@item, note: params[:note]) }
  def not_needed = answer { checklist.not_needed!(@item) }
  def note = answer { checklist.note!(@item, params[:body]) }
  def upload = answer { checklist.upload!(@item, params[:file]) }

  # GET /api/admin/onboarding/:company_id/items/:id/files/:file_id
  def download
    file = @item.files.find_by(id: params[:file_id])
    return render(json: { error: 'Not found' }, status: :not_found) unless file

    redirect_to file.blob.url(expires_in: 5.minutes, disposition: 'attachment'), allow_other_host: true
  end

  # POST /api/admin/onboarding/:company_id/items/:id/save_to_standard
  def save_to_standard
    answer { checklist.save_to_standard!(@item) && @item }
  end

  # POST /api/admin/onboarding/:company_id/followers { user_id }
  def add_follower
    user = User.find_by(id: params[:user_id])
    return render(json: { error: 'Pick someone at this client or at DealerTide' }, status: :unprocessable_entity) unless user && (user.company_id == @client.id || user.platform_admin?)

    checklist.follow!(user)
    render json: client_json
  end

  # DELETE /api/admin/onboarding/:company_id/followers/:user_id
  def remove_follower
    @client.onboarding_followers.where(user_id: params[:user_id]).delete_all
    render json: client_json
  end

  # GET /api/admin/onboarding_template
  # The standard list, with how long each item takes clients (median days
  # from the client's first item to this one done) and how many had it.
  def template
    items = OnboardingTemplateItem.active.ordered.to_a
    starts = OnboardingItem.group(:company_id).minimum(:created_at)
    copies = OnboardingItem.where(template_item_id: items.map(&:id)).pluck(:template_item_id, :company_id, :status, :done_at)
    render json: { items: items.map do |t|
      mine = copies.select { |c| c[0] == t.id }
      days = mine.select { |c| c[2] == 'done' && c[3] && starts[c[1]] }.map { |c| ((c[3] - starts[c[1]]) / 1.day).round(1) }.sort
      median = days.empty? ? nil : (days.size.odd? ? days[days.size / 2] : ((days[days.size / 2 - 1] + days[days.size / 2]) / 2.0).round(1))
      template_json(t).merge(clients: mine.map { |c| c[1] }.uniq.size, done: days.size, median_days: median)
    end }
  end

  # POST /api/admin/onboarding_template { section, title, detail, owed_by }
  def create_template
    t = OnboardingTemplateItem.create!(template_params.merge(position: template_params[:position].presence || ((OnboardingTemplateItem.where(section: template_params[:section]).maximum(:position) || 0) + 1)))
    render json: template_json(t), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  # PATCH /api/admin/onboarding_template/:id
  def update_template
    t = OnboardingTemplateItem.find(params[:id])
    t.update!(template_params)
    render json: template_json(t)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  # DELETE /api/admin/onboarding_template/:id  (clients already started keep their copy)
  def destroy_template
    OnboardingTemplateItem.find(params[:id]).update!(active: false)
    head :no_content
  end

  private

  def set_client
    @client = Company.find(params[:company_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  def set_item
    @item = @client.onboarding_items.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  def checklist = Onboarding::Checklist.new(@client, actor: original_user, side: 'dealertide')

  def item_params
    params.permit(:section, :title, :detail, :owed_by, :assignee_id, :due_on, :position).to_h
  end

  def template_params
    params.permit(:section, :title, :detail, :owed_by, :position).to_h.symbolize_keys
  end

  def template_json(t) = { id: t.id, section: t.section, title: t.title, detail: t.detail, owed_by: t.owed_by, position: t.position }

  def client_json
    people = User.where(company_id: @client.id).active.order(:first_name, :last_name).to_a + User.where(role: 'platform_admin').active.order(:first_name).to_a
    {
      client: { id: @client.id, name: @client.name }, items: Onboarding::View.items(@client),
      progress: Onboarding::View.progress(@client), events: Onboarding::View.events(@client),
      people: people.uniq.map { |u| Onboarding::View.person(u) },
      followers: User.where(id: @client.onboarding_followers.select(:user_id)).map { |u| Onboarding::View.person(u) }
    }
  end

  def answer
    yield
    render json: client_json
  rescue Onboarding::Checklist::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end
end
