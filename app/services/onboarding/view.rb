# frozen_string_literal: true

module Onboarding
  # A client's onboarding list as both screens show it: Getting started for
  # the client, the Onboarding page for platform admins. Files are listed by
  # id; downloads go through each side's own controller, never a raw S3 link.
  module View
    module_function

    def items(company)
      company.onboarding_items.ordered.includes(:assignee, :done_by, files_attachments: :blob).map { |i| item(i) }
    end

    def item(i)
      { id: i.id, section: i.section, title: i.title, detail: i.detail, owed_by: i.owed_by, status: i.status,
        overdue: i.overdue?, due_on: i.due_on&.iso8601, position: i.position, template_item_id: i.template_item_id,
        assignee: i.assignee && person(i.assignee), done_at: i.done_at&.iso8601, done_by: i.done_by&.full_name,
        files: i.files.map { |f| { id: f.id, name: f.filename.to_s, size: f.byte_size, at: f.created_at.iso8601 } } }
    end

    def events(company, limit: 30)
      company.onboarding_events.order(created_at: :desc).limit(limit).includes(:user, :onboarding_item).map do |e|
        { id: e.id, kind: e.kind, side: e.side, body: e.body, at: e.created_at.iso8601, who: e.user&.full_name,
          item_id: e.onboarding_item_id, item: e.onboarding_item&.title }
      end
    end

    def person(u) = { id: u.id, name: u.full_name.presence || u.email, dealertide: u.platform_admin? }

    def progress(company)
      scope = company.onboarding_items
      { total: scope.count, done: scope.where.not(status: 'open').count,
        client_open: scope.open.where(owed_by: 'client').count, ours_open: scope.open.where(owed_by: 'dealertide').count,
        overdue: scope.open.where('due_on < ?', Date.current).count }
    end
  end
end
