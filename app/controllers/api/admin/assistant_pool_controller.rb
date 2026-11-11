# frozen_string_literal: true

# The shared texting numbers Quinn AI uses for a dealer whose own number is
# not live yet (E96). Platform admins choose which dealers may use them and
# switch the pool on or off. Adding a dealer does not text anyone by itself:
# Quinn starts on the next new lead, and only for a dealer with Quinn on.
class Api::Admin::AssistantPoolController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_target_company, only: %i[add_company remove_company]

  def show
    render json: payload
  end

  def update
    live = ActiveModel::Type::Boolean.new.cast(params[:live])
    if live && Assistant::Pool.entries.empty?
      return render(json: { error: 'There are no shared numbers set up in this environment' }, status: :unprocessable_entity)
    end

    Assistant::Pool.update!('live' => live)
    render json: payload
  end

  def add_company
    Assistant::Pool.add_company!(@target)
    render json: payload
  end

  def remove_company
    Assistant::Pool.remove_company!(@target)
    render json: payload
  end

  private

  def set_target_company
    @target = Company.find(params[:company_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  def payload
    entries = Assistant::Pool.company_entries
    companies = Company.where(id: entries.map { |e| e[:id] }).index_by(&:id)
    own = TwilioAccount.active.where(company_id: companies.keys).distinct.pluck(:company_id)
    {
      live: Assistant::Pool.config['live'] == true,
      numbers: Assistant::Pool.entries,
      companies: entries.filter_map do |e|
        c = companies[e[:id]]
        next unless c

        settings = Assistant::Settings.for(c)
        { id: c.id, name: c.name, added_at: e[:added_at],
          quinn_on: settings.enabled?,
          own_number: own.include?(c.id),
          first_pool_text_at: Assistant::Pool.first_pool_text_at(c),
          open_conversations: Conversation.open_now.where(company_id: c.id, pool: true).count }
      end,
      # Dealers with Quinn texting on who could be added.
      candidates: candidates(entries.map { |e| e[:id] })
    }
  end

  def candidates(taken)
    Company.where.not(id: taken).order(:name).select(:id, :name).filter_map do |c|
      s = Assistant::Settings.for(c)
      { id: c.id, name: c.name, quinn_on: s.enabled? } if s.add_on?
    end
  end
end
