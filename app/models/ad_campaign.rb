# frozen_string_literal: true

class AdCampaign < ApplicationRecord
  belongs_to :company

  validates :external_campaign_id, presence: true

  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :for_status, ->(status) { where(status: status) }

  # How long after a campaign stops a lead can still be credited to it. Meta's
  # own default is 7-day click, but a housing or RV purchase is a long
  # consideration cycle and the click that started it is often weeks earlier.
  ATTRIBUTION_TAIL = 30.days

  # Leads that plainly came from Facebook. Deliberately NOT used to attribute
  # revenue to a campaign — with several campaigns running, every one of them
  # would claim the same leads and cost-per-lead would be understated by the
  # number of campaigns. It answers a narrower question: how many Facebook
  # leads did no campaign account for? A large number means a link lost its
  # UTMs, which is exactly the failure that otherwise goes unnoticed.
  FACEBOOK_SOURCE_PATTERN = '%facebook%'

  def self.unattributed_facebook_leads(company)
    campaigns = company.ad_campaigns.active
    names     = campaigns.pluck(:name).compact_blank
    ids       = campaigns.pluck(:external_campaign_id).compact_blank

    scope = company.leads
                   .left_joins(:source)
                   .where(
                     "LOWER(leads.utm_source) LIKE :fb OR LOWER(leads.utm_source) = 'fb' " \
                     'OR LOWER(sources.name) LIKE :fb',
                     fb: FACEBOOK_SOURCE_PATTERN
                   )

    # Must mirror matched_leads_scope, or a lead that a campaign now claims is
    # still counted here as accounted for by nobody. utm_campaign carries the
    # id as often as the name, since that is what Meta's {{campaign.id}} puts
    # there.
    campaign_keys = (names + ids).uniq

    # NOT IN alone would drop rows with a NULL utm — which are exactly the
    # unattributed leads this is counting.
    scope = scope.where('leads.utm_campaign IS NULL OR leads.utm_campaign NOT IN (?)', campaign_keys) if campaign_keys.any?
    scope = scope.where('leads.utm_content IS NULL OR leads.utm_content NOT IN (?)', ids) if ids.any?
    scope
  end

  # Recompute leads_count / deals_count / revenue / cost metrics from our own
  # attribution data + the cached Meta spend/impressions. Safe to call often.
  def calculate_roi!
    matched_leads = matched_leads_scope
    self.leads_count = matched_leads.count

    converted_account_ids = matched_leads.where(is_converted: true)
                                         .where.not(converted_account_id: nil)
                                         .pluck(:converted_account_id).uniq

    if converted_account_ids.any?
      deals = Deal.where(account_id: converted_account_ids)
      self.deals_count = deals.count
      self.revenue     = deals.where(stage: company.won_stage_keys).sum(:value)
    else
      self.deals_count = 0
      self.revenue     = 0
    end

    self.cost_per_lead  = leads_count.positive? ? (spend.to_f / leads_count).round(2) : 0
    self.cost_per_deal  = deals_count.positive? ? (spend.to_f / deals_count).round(2) : 0
    self.roi_percentage = spend.to_f.positive? ? (((revenue.to_f - spend.to_f) / spend.to_f) * 100).round(2) : 0

    save!
  end

  private

  # Leads are attributed to this campaign when their utm_campaign matches
  # either the human-readable name or the Meta campaign id, or their utm_content
  # matches the campaign id.
  #
  # utm_campaign used to be compared against the name alone, which missed the
  # most common case there is. Meta's own dynamic URL parameters put
  # {{campaign.id}} in utm_campaign, so an ad tagged the standard way arrives
  # carrying the id and matched nothing. Our own Lead Ads job falls back to
  # campaign_id when Meta returns no campaign_name, and missed for the same
  # reason.
  #
  # Bounded by when the campaign ran. Without a window a campaign that stopped
  # a year ago keeps claiming every new lead whose utm_campaign still matches
  # its name, which quietly inflates its ROI forever. Dates are null on rows
  # that predate the columns and on campaigns Meta reports no dates for — those
  # stay unbounded rather than dropping to zero leads.
  def matched_leads_scope
    external_id = external_campaign_id.to_s.strip.presence
    # Blank keys would match every lead whose utm is an empty string.
    keys = [name.to_s.strip.presence, external_id].compact.uniq
    return company.leads.none if keys.empty?

    clauses = ['utm_campaign IN (:keys)']
    binds   = { keys: keys }

    if external_id
      clauses << 'utm_content = :external_id'
      binds[:external_id] = external_id
    end

    scope = company.leads.where(clauses.join(' OR '), binds)
    scope = scope.where(created_at: attribution_window) if attribution_window
    scope
  end

  def attribution_window
    return nil if started_at.blank?

    # Leads keep converting after the spend stops, so allow a tail past the end
    # date; an open-ended campaign runs to now.
    finish = (stopped_at || Time.current) + ATTRIBUTION_TAIL
    started_at..finish
  end
end
