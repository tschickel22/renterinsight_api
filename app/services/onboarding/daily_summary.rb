# frozen_string_literal: true

module Onboarding
  # The morning email about onboarding lists (backlog E97): one per person,
  # only on days something changed or something is overdue.
  #
  # A client's people (whoever has items, their admins, their followers) hear
  # what DealerTide added, reopened, wrote or finished, and what they owe that
  # is overdue. Our people (platform admins following a client) hear what each
  # client did, in one email across every client.
  module DailySummary
    module_function

    WINDOW = 24.hours
    WORDS = { 'added' => 'Added', 'done' => 'Finished', 'reopened' => 'Reopened', 'not_needed' => 'Not needed',
              'note' => 'Note', 'upload' => 'File', 'assigned' => 'Assigned',
              'handed_back' => 'Sent for your review' }.freeze

    # @return [Integer] emails sent
    def call(now: Time.current)
      since = now - WINDOW
      per_user = Hash.new { |h, k| h[k] = [] }
      company_ids = (OnboardingEvent.where.not(kind: 'seen').where('created_at >= ?', since).distinct.pluck(:company_id) +
                     OnboardingItem.open.where('due_on < ?', now.to_date).distinct.pluck(:company_id)).uniq

      Company.where(id: company_ids).find_each do |company|
        events = company.onboarding_events.where.not(kind: 'seen').where('created_at >= ?', since).includes(:user, onboarding_item: :assignee).order(:created_at).to_a
        overdue = company.onboarding_items.open.where('due_on < ?', now.to_date).order(:due_on).to_a

        theirs = lines(events.select { |e| e.side == 'dealertide' }) + overdue.select(&:client_owes?).map { |i| "Overdue since #{i.due_on.strftime('%b %-d')}: #{i.title}#{assigned_to(i)}" }
        if theirs.any?
          Checklist.client_people(company).each { |u| per_user[u] << { company: company, lines: theirs, client: true } }
          # Whoever has an item that changed or is overdue, even if not an admin.
          assignees = (events.select { |e| e.side == 'dealertide' }.filter_map { |e| e.onboarding_item&.assignee } + overdue.select(&:client_owes?).filter_map(&:assignee))
          assignees.uniq.select { |u| u.company_id == company.id && u.active? }.each do |u|
            per_user[u] << { company: company, lines: theirs, client: true } unless per_user[u].any? { |s| s[:company] == company }
          end
        end

        ours = lines(events.select { |e| e.side == 'client' }) + overdue.map { |i| "Overdue (#{i.client_owes? ? company.name : 'us'}): #{i.title}#{assigned_to(i)}" }
        Checklist.our_people(company).each { |u| per_user[u] << { company: company, lines: ours, client: false } } if ours.any?
      end

      per_user.count do |user, sections|
        OnboardingMailer.daily(user, sections.map { |s| { name: s[:company].name, company_id: s[:company].id, lines: s[:lines], client: s[:client] } }).deliver_now
        true
      rescue StandardError => e
        Rails.logger.error("[Onboarding] summary to user #{user.id} failed: #{e.class} #{e.message}")
        false
      end
    end

    def lines(events)
      events.map do |e|
        what = e.onboarding_item&.title || e.body
        extra = %w[note upload reopened assigned].include?(e.kind) && e.body.present? && e.onboarding_item ? ": #{e.body.truncate(200)}" : ''
        # An assigned line already names the person.
        who = e.kind == 'assigned' ? '' : assigned_to(e.onboarding_item)
        "#{WORDS[e.kind]}#{e.user ? " by #{e.user.full_name}" : ''}: #{what}#{who}#{extra}"
      end
    end

    def assigned_to(item)
      name = item&.assignee&.full_name.presence
      name ? " (assigned to #{name})" : ''
    end
  end
end
