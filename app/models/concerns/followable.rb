# frozen_string_literal: true

# Followers (backlog E86) for Lead, Account, Contact and Deal: extra reps who
# are told what the owner is told and can see the record outside their own
# locations. Anything that notifies "the owner" of one of these records should
# notify #notify_audience instead.
module Followable
  extend ActiveSupport::Concern

  included do
    has_many :record_followers, as: :followable, dependent: :delete_all
    has_many :followers, through: :record_followers, source: :user

    # Records any of these users follow. A subquery, not a join, so a record
    # followed by two of them is still one row (list counts drive pagination).
    scope :followed_by, lambda { |user_ids|
      where(id: RecordFollower.where(followable_type: name, user_id: Array(user_ids)).select(:followable_id))
    }
  end

  # The owner first, then followers, never the person who made the change.
  # Deals also count their legacy rep (user) when there is no owner.
  def notify_audience(except: Current.user)
    lead = respond_to?(:owner) ? owner : nil
    lead ||= user if is_a?(Deal)
    ([lead] + followers.to_a).compact.uniq.reject { |u| except && u.id == except.id }
                              .select { |u| u.respond_to?(:active?) ? u.active? : true }
  end

  def follower_ids_list
    record_followers.pluck(:user_id)
  end

  # Replaces the follower set. The owner is never a follower, users must be in
  # the record's company, and each newly added follower is told.
  def replace_followers!(user_ids, by: Current.user)
    wanted = company.users.where(id: Array(user_ids).map(&:to_i)).where.not(id: owner_id).pluck(:id)
    current = follower_ids_list
    added = wanted - current
    transaction do
      record_followers.where(user_id: current - wanted).delete_all
      added.each { |uid| record_followers.create!(company_id: company_id, user_id: uid, created_by_id: by&.id) }
    end
    record_followers.reset
    followers.reset
    notify_new_followers(added, by: by)
    added
  end

  # Adds without removing anyone (lead conversion, imports). No notices.
  def add_followers!(user_ids, by: nil)
    ids = company.users.where(id: Array(user_ids).map(&:to_i)).where.not(id: owner_id).pluck(:id) - follower_ids_list
    ids.each { |uid| record_followers.create!(company_id: company_id, user_id: uid, created_by_id: by&.id) }
    record_followers.reset
    followers.reset
    ids
  end

  def followers_json
    followers.map { |u| { id: u.id, name: u.name } }
  end

  def follow_label
    case self
    when Lead    then "lead '#{try(:full_name)}'"
    when Deal    then "deal '#{name}'"
    when Account then "customer '#{name}'"
    else              "contact '#{try(:full_name) || try(:name)}'"
    end
  end

  private

  def notify_new_followers(user_ids, by:)
    return if user_ids.empty?

    User.where(id: user_ids).find_each do |u|
      next if by && u.id == by.id

      NotificationService.create(
        recipient: u,
        notification_type: :follower_added,
        notifiable: self,
        actor: by,
        message: "#{by&.name || 'Someone'} added you as a follower on #{follow_label}",
        deliver_now: true,
        company_id: company_id,
        location_id: try(:location_id)
      )
    end
  rescue StandardError => e
    Rails.logger.error("[Followable] follower notice failed for #{self.class.name} #{id}: #{e.message}")
  end

  # Tells followers that the owner changed. The owner gets their own notice
  # from the Notifiable* concern.
  def notify_followers_of_owner_change
    return if followers.empty?

    new_owner = owner&.name || 'nobody'
    notify_audience.each do |u|
      next if u.id == owner_id

      NotificationService.create(
        recipient: u,
        notification_type: :followed_record_assigned,
        notifiable: self,
        actor: Current.user,
        message: "#{Current.user&.name || 'Someone'} assigned #{follow_label} to #{new_owner}",
        deliver_now: true,
        company_id: company_id,
        location_id: try(:location_id)
      )
    end
  rescue StandardError => e
    Rails.logger.error("[Followable] owner change notice failed for #{self.class.name} #{id}: #{e.message}")
  end
end
