# frozen_string_literal: true

module Onboarding
  # A client's onboarding list as both screens show it: Getting started for
  # the client, the Onboarding page for platform admins. Files are listed by
  # id; downloads go through each side's own controller, never a raw S3 link.
  module View
    module_function

    def items(company)
      notes = notes_by_item(company.onboarding_events.where(kind: 'note'))
      updates = client_updates(company)
      company.onboarding_items.ordered.includes(:assignee, :done_by, files_attachments: :blob).map { |i| item(i, notes[i.id] || [], updates[i.id]) }
    end

    # What the client did on each item since we last touched it (a note, a
    # file, finishing or reopening it). Anything we do on the item, including
    # "Seen", answers it. Keyed by item id; items with nothing new are absent.
    CLIENT_KINDS = %w[note upload done handed_back reopened].freeze

    def client_updates(company, item_ids = nil)
      scope = company.onboarding_events.where.not(onboarding_item_id: nil)
      scope = scope.where(onboarding_item_id: item_ids) if item_ids
      ours = scope.where(side: 'dealertide').group(:onboarding_item_id).maximum(:created_at)
      theirs = scope.where(side: 'client', kind: CLIENT_KINDS).includes(:user).order(:created_at).to_a.group_by(&:onboarding_item_id)
      theirs.each_with_object({}) do |(id, events), out|
        fresh = events.select { |e| ours[id].nil? || e.created_at > ours[id] }
        next if fresh.empty?

        out[id] = { at: fresh.last.created_at.iso8601, who: fresh.last.user&.full_name,
                    what: fresh.map { |e| UPDATE_WORDS[e.kind] }.uniq }
      end
    end

    UPDATE_WORDS = { 'note' => 'note', 'upload' => 'file', 'done' => 'finished', 'handed_back' => 'finished',
                     'reopened' => 'reopened' }.freeze

    # How many items at a client need us: in review, or updated since we last looked.
    def needs_us(company)
      (company.onboarding_items.in_review.pluck(:id) + client_updates(company).keys).uniq.size
    end

    # The notes on each item, oldest first: the conversation both sides see.
    def notes_by_item(scope)
      scope.where.not(onboarding_item_id: nil).includes(:user).order(:created_at).group_by(&:onboarding_item_id).transform_values do |es|
        es.map { |e| { id: e.id, side: e.side, who: e.user&.full_name, body: e.body, at: e.created_at.iso8601 } }
      end
    end

    def item(i, notes = nil, update = :look)
      notes ||= notes_by_item(i.events.where(kind: 'note'))[i.id] || []
      update = client_updates(i.company, [i.id])[i.id] if update == :look
      { id: i.id, section: i.section, title: i.title, detail: i.detail, owed_by: i.owed_by, status: i.status,
        overdue: i.overdue?, due_on: i.due_on&.iso8601, position: i.position, template_item_id: i.template_item_id,
        assignee: i.assignee && person(i.assignee), done_at: i.done_at&.iso8601, done_by: i.done_by&.full_name,
        files: i.files.map { |f| { id: f.id, name: f.filename.to_s, size: f.byte_size, at: f.created_at.iso8601 } },
        notes: notes, client_update: update }
    end

    def events(company, limit: 30)
      company.onboarding_events.where.not(kind: 'seen').order(created_at: :desc).limit(limit).includes(:user, :onboarding_item).map do |e|
        { id: e.id, kind: e.kind, side: e.side, body: e.body, at: e.created_at.iso8601, who: e.user&.full_name,
          item_id: e.onboarding_item_id, item: e.onboarding_item&.title }
      end
    end

    def person(u) = { id: u.id, name: u.full_name.presence || u.email, dealertide: u.platform_admin? }

    def progress(company)
      scope = company.onboarding_items
      { total: scope.count, done: scope.where(status: %w[done not_needed]).count, review: scope.in_review.count,
        client_open: scope.open.where(owed_by: 'client').count, ours_open: scope.open.where(owed_by: 'dealertide').count,
        overdue: scope.open.where('due_on < ?', Date.current).count }
    end
  end
end
