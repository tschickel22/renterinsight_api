# frozen_string_literal: true

module Onboarding
  # Every change to a client's onboarding list goes through here (backlog E97),
  # so each one is recorded once (OnboardingEvent, which the activity feed and
  # the daily summary read) and the other side hears about the ones they act on.
  #
  # side: 'client' for the client's own users in Getting started, 'dealertide'
  # for a platform admin managing the list.
  #
  # Bells ring at once only for what someone acts on: the client finishing,
  # uploading or writing to us; us adding or reopening something they owe, or
  # writing to them; an item assigned to someone. Email is the daily summary
  # (Onboarding::DailySummary), never one per click.
  class Checklist
    class Invalid < StandardError; end

    attr_reader :company, :actor, :side

    def initialize(company, actor:, side:)
      raise ArgumentError, 'side must be client or dealertide' unless OnboardingEvent::SIDES.include?(side)

      @company = company
      @actor = actor
      @side = side
    end

    def us? = side == 'dealertide'

    def add!(attrs)
      us_only!
      item = company.onboarding_items.new(item_attrs(attrs).merge(created_by: actor, status: 'open'))
      item.position = next_position(item.section) if attrs[:position].blank?
      item.save!
      follow!(actor)
      record!(item, 'added')
      if item.client_owes?
        tell_client(item, "New for you: #{item.title}")
      end
      tell_assignee(item) if item.assignee
      item
    end

    def update!(item, attrs)
      us_only!
      before = item.assignee_id
      item.update!(item_attrs(attrs))
      if item.assignee_id != before && item.assignee
        record!(item, 'assigned', item.assignee.full_name)
        tell_assignee(item)
      end
      item
    end

    def complete!(item)
      return item unless item.open?

      item.update!(status: 'done', done_at: Time.current, done_by: actor)
      record!(item, 'done')
      tell_us(item, "#{company.name} finished: #{item.title}") unless us?
      item
    end

    def not_needed!(item)
      us_only!
      item.update!(status: 'not_needed', done_at: Time.current, done_by: actor)
      record!(item, 'not_needed')
      item
    end

    def reopen!(item, note: nil)
      item.update!(status: 'open', done_at: nil, done_by: nil)
      record!(item, 'reopened', note.presence)
      if us?
        tell_client(item, "Reopened: #{item.title}#{note.present? ? ". #{note}" : ''}") if item.client_owes?
      else
        tell_us(item, "#{company.name} reopened: #{item.title}")
      end
      item
    end

    def note!(item, body)
      body = body.to_s.strip
      raise Invalid, 'Write a note first' if body.blank?

      record!(item, 'note', body.first(4000))
      us? ? tell_client(item, "Note on #{item.title}: #{body.truncate(160)}") : tell_us(item, "#{company.name} on #{item.title}: #{body.truncate(160)}")
      item
    end

    def upload!(item, file)
      raise Invalid, 'Choose a file' unless file.respond_to?(:original_filename)
      raise Invalid, 'That file is over 40 MB' if file.size > 40.megabytes

      item.files.attach(file)
      record!(item, 'upload', File.basename(file.original_filename.to_s))
      us? ? tell_client(item, "New file on #{item.title}: #{file.original_filename}") : tell_us(item, "#{company.name} uploaded #{file.original_filename} to #{item.title}")
      item
    end

    def remove!(item)
      us_only!
      item.files.purge_later
      item.destroy!
    end

    # A new client's list from the standard list; items already copied are skipped.
    def start_from_standard!
      us_only!
      have = company.onboarding_items.where.not(template_item_id: nil).pluck(:template_item_id).to_set
      added = OnboardingTemplateItem.active.ordered.reject { |t| have.include?(t.id) }.map do |t|
        company.onboarding_items.create!(template_item: t, section: t.section, title: t.title, detail: t.detail,
                                         owed_by: t.owed_by, position: t.position, created_by: actor)
      end
      follow!(actor)
      OnboardingEvent.create!(company: company, user: actor, side: side, kind: 'added', body: "#{added.size} items from the standard list") if added.any?
      added
    end

    # Puts a client's item on the standard list, so the next client gets it.
    def save_to_standard!(item)
      us_only!
      return item.template_item if item.template_item

      t = OnboardingTemplateItem.create!(section: item.section, title: item.title, detail: item.detail, owed_by: item.owed_by,
                                         position: (OnboardingTemplateItem.where(section: item.section).maximum(:position) || 0) + 1)
      item.update!(template_item: t)
      t
    end

    def follow!(user)
      return unless user && (user.company_id == company.id || user.platform_admin?)

      company.onboarding_followers.find_or_create_by!(user: user)
    end

    # Our people for this client: platform admins following it.
    def self.our_people(company)
      User.where(id: company.onboarding_followers.select(:user_id), role: 'platform_admin').select(&:active?)
    end

    # The client's people for an item: whoever it is assigned to, else their
    # admins, plus anyone at the client following the list.
    def self.client_people(company, item = nil)
      assignee = item&.assignee if item&.assignee&.company_id == company.id
      base = assignee ? [assignee] : User.where(company_id: company.id).select { |u| u.active? && u.effective_admin? && !u.platform_admin? }
      followers = User.where(id: company.onboarding_followers.select(:user_id), company_id: company.id).to_a
      (base + followers).uniq.select(&:active?)
    end

    private

    def us_only!
      raise Invalid, 'Only DealerTide changes this' unless us?
    end

    def item_attrs(attrs)
      a = attrs.to_h.symbolize_keys.slice(:section, :title, :detail, :owed_by, :due_on, :position, :assignee_id)
      if a.key?(:assignee_id) && a[:assignee_id].present?
        user = User.find_by(id: a[:assignee_id])
        raise Invalid, 'Pick someone at this client or at DealerTide' unless user && (user.company_id == company.id || user.platform_admin?)
      end
      a[:assignee_id] = nil if a.key?(:assignee_id) && a[:assignee_id].blank?
      a
    end

    def next_position(section)
      (company.onboarding_items.where(section: section).maximum(:position) || 0) + 1
    end

    def record!(item, kind, body = nil)
      OnboardingEvent.create!(company: company, onboarding_item: item, user: actor, side: side, kind: kind, body: body)
    end

    def tell_us(item, message)
      ring(self.class.our_people(company), item, message, "/admin/onboarding?company_id=#{company.id}")
    end

    def tell_client(item, message)
      ring(self.class.client_people(company, item), item, message, '/?getting_started=1')
    end

    def tell_assignee(item)
      who = item.assignee
      return unless who && who != actor

      url = who.company_id == company.id ? '/?getting_started=1' : "/admin/onboarding?company_id=#{company.id}"
      ring([who], item, "Assigned to you: #{item.title}", url)
    end

    def ring(users, item, message, url)
      users.reject { |u| u == actor }.each do |user|
        NotificationService.create(recipient: user, notification_type: :onboarding_update, notifiable: item, actor: actor,
                                   message: message, action_url: url, action_text: 'Open the checklist',
                                   company_id: user.company_id, location_id: nil)
      end
    rescue StandardError => e
      Rails.logger.error("[Onboarding] notice failed for item #{item&.id}: #{e.class} #{e.message}")
    end
  end
end
