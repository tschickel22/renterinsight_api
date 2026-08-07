# frozen_string_literal: true

# One visitor's session on one landing page.
#
# Created and updated by the tracking beacon rather than by the page request,
# because published pages are served through a 5-minute edge cache — most page
# views never reach Rails at all, so counting requests at the origin would
# undercount by whatever Cloudflare's hit rate is, silently, and worst on the
# most popular pages.
class PageVisit < ApplicationRecord
  belongs_to :company
  belongs_to :website_page
  belongs_to :campaign, optional: true
  belongs_to :identified_entity, polymorphic: true, optional: true

  has_many :page_visit_events, dependent: :destroy

  validates :visitor_token, :session_token, presence: true

  scope :real, -> { where(is_bot: false) }
  scope :identified, -> { where.not(identified_entity_id: nil) }
  scope :anonymous, -> { where(identified_entity_id: nil) }
  scope :converted, -> { where(converted: true) }
  scope :in_window, ->(from, to) { where(first_seen_at: from..to) }

  def identified?
    identified_entity_id.present?
  end

  # Attribute this visit to a lead or contact.
  #
  # Called for the visit that converted AND, via back-stamping, for every
  # earlier anonymous visit from the same visitor. Idempotent, and never
  # re-points a visit that already resolved to someone else — two people
  # sharing a browser is rarer than a double-submitted form, and silently
  # reassigning the first person's session would be worse than missing it.
  def identify!(entity, at: Time.current)
    return false if entity.nil?
    return false if identified? && !identified_entity.nil? && identified_entity != entity

    update!(
      identified_entity: entity,
      identified_at: identified_at || at
    )
    true
  end

  def record_event!(type, payload = {}, at: Time.current)
    page_visit_events.create!(event_type: type, occurred_at: at, payload: payload)
  end
end
