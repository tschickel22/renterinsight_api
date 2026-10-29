# frozen_string_literal: true

# One way out for project and installer events (E87).
#
# The bell alone was not enough: nobody watches it. So every event here does up
# to three things, all in the company that receives it:
#
#   - rings the bell for each person, and emails and texts them as their own
#     Notification Center switches allow (ProjectNoticeDeliveryJob);
#   - opens (or refreshes) a Review Updates item, when the event is something
#     somebody has to deal with or should see;
#   - closes the item again from the service that did the work, via close!.
#
# Portal contractors are not users and never pass through here: they hear by
# email and text from ProjectNotificationService, on their vendor record's
# consent.
class ProjectNotices
  class << self
    # users: recipients in one company. item: attributes for a Review Updates
    # row (kind:, subject:, title: ...), or nil for a bell-only event.
    def deliver(users:, type:, title:, message:, notifiable:, company:, item: nil, action_url: nil)
      users = Array(users).compact.uniq.select { |u| u.company_id == company.id && u.active? }
      url = action_url || link_for(notifiable, company)
      users.each do |user|
        notification = NotificationService.create(
          recipient: user, notification_type: type, notifiable: notifiable,
          title: title, message: message, action_url: url, company_id: company.id,
          location_id: nil
        )
        # Email and text in the background, so the person who acted isn't
        # kept waiting on the mail and SMS providers.
        ProjectNoticeDeliveryJob.perform_later(notification.id) if notification
      rescue => e
        Rails.logger.error("[ProjectNotices] #{type} to user #{user.id}: #{e.class}: #{e.message}")
      end
      open!(company: company, link: url, **item) if item
    end

    # Opens an item, or refreshes the open one for the same thing.
    def open!(company:, kind:, subject:, title:, detail: nil, project: nil, phase: nil, from_name: nil,
              link: nil, assigned_user: nil, needs_action: nil, metadata: {})
      needs_action = ReviewItem::KINDS.dig(kind.to_s, 1) if needs_action.nil?
      attrs = {
        title: title.to_s.truncate(250), detail: detail, project_id: project&.id, project_phase_id: phase&.id,
        from_name: from_name, link: link || link_for(subject, company),
        assigned_user_id: usable_assignee(assigned_user, company)&.id,
        needs_action: needs_action, metadata: metadata.deep_stringify_keys
      }
      item = company.review_items.open.find_by(kind: kind.to_s, subject_type: subject.class.base_class.name, subject_id: subject.id)
      if item
        item.update!(attrs.merge(updated_at: Time.current))
      else
        item = company.review_items.create!(attrs.merge(kind: kind.to_s, subject: subject, status: 'open'))
      end
      item
    rescue ActiveRecord::RecordNotUnique
      retry
    rescue => e
      Rails.logger.error("[ProjectNotices] open #{kind} for #{subject.class.name} #{subject&.id}: #{e.class}: #{e.message}")
      nil
    end

    # Closes the open items for a record, in any company (a job offered to an
    # installer and answered there closes on the installer's side). kinds limits
    # it; resolution is a word for the Closed tab (approved, declined...).
    def close!(subject:, resolution:, by: nil, kinds: nil, company: nil)
      return 0 unless subject&.id

      scope = ReviewItem.open.where(subject_type: subject.class.base_class.name, subject_id: subject.id)
      scope = scope.where(kind: Array(kinds).map(&:to_s)) if kinds
      scope = scope.where(company_id: company.id) if company
      scope.update_all(status: 'closed', resolution: resolution.to_s, resolved_at: Time.current,
                       resolved_by_id: by.is_a?(User) ? by.id : nil, resolved_by_name: by_name(by),
                       updated_at: Time.current)
    rescue => e
      Rails.logger.error("[ProjectNotices] close #{subject.class.name} #{subject&.id}: #{e.class}: #{e.message}")
      0
    end

    # pairs: [[user, phase or nil (the whole project)], ...]. Nobody is told
    # about work they gave themselves.
    def employee_assigned(project, pairs, actor: nil)
      company = project.company
      pairs.group_by(&:first).each do |user, rows|
        next if actor && user.id == actor.id

        phases = rows.map(&:last).compact.uniq
        what = if rows.any? { |_, ph| ph.nil? } then project.name
               elsif phases.one? then "#{phases.first.name} on #{project.name}"
               else "#{phases.size} phases on #{project.name} (#{phases.map(&:name).first(3).to_sentence})"
               end
        by = actor ? " by #{actor.full_name.presence || actor.email}" : ''
        url = project.deal_id ? "/deals/#{project.deal_id}?tab=progress" : "/deals/projects/#{project.id}"
        deliver(
          users: [user], company: company, type: :project_assigned, notifiable: project, action_url: url,
          title: 'Project work assigned to you', message: "You were assigned #{what}#{by}.",
          item: { kind: 'assigned', subject: phases.one? && rows.none? { |_, ph| ph.nil? } ? phases.first : project,
                  title: "Assigned to you: #{what}", detail: "You were assigned #{what}#{by}.",
                  from_name: actor&.full_name, project: project, phase: phases.one? ? phases.first : nil,
                  assigned_user: user }
        )
      end
    rescue => e
      Rails.logger.error("[ProjectNotices] employee assigned on project #{project&.id}: #{e.class}: #{e.message}")
    end

    def link_for(record, company)
      return nil unless record

      Notification.new(notifiable: record, company_id: company.id).computed_action_url
    rescue => e
      Rails.logger.warn("[ProjectNotices] link for #{record.class.name}: #{e.message}")
      nil
    end

    private

    def usable_assignee(user, company)
      user if user.is_a?(User) && user.company_id == company.id && user.active?
    end

    def by_name(by)
      case by
      when User then by.full_name.presence || by.email
      when Company then by.name
      when String then by
      else by.try(:name)
      end
    end
  end
end
