# frozen_string_literal: true

# TEMPORARY GATE. Remove once Meta approves the permissions below.
#
# Meta's 2026-09 App Review approved every permission we asked for except
# pages_manage_engagement and read_insights, which were resubmitted. The OAuth
# dialog quietly leaves an unapproved permission out for anyone without a role
# on the app, so a dealer's connection succeeds but carries neither. Every call
# that needs one then fails with a raw "(#200) ..." from Graph, on a button we
# showed them.
#
# Until approval, the features behind them are switched off rather than left to
# fail:
#   pages_manage_engagement  reply to, hide, unhide and delete comments; the
#                            Page's own Like on Brand Health posts
#   read_insights            Page insights on Brand Health (reach, impressions,
#                            engagement) and per-post reach/impressions/clicks
#
# Lifting it needs no deploy. Set META_PERMISSIONS_AWAITING_REVIEW to the
# permissions still waiting (comma separated), or to an empty string once both
# are approved. Unset, the list below applies.
#
# META_REVIEW_COMPANY_IDS (comma separated, per environment) lifts the gate for
# named tenants, so the flows can still be shown to Meta's reviewers and
# recorded for the resubmission. App admins and testers are granted unapproved
# permissions, so the features genuinely work for them.
#
# Removal checklist lives in the backlog under "Meta App Review gate".
module MetaAppReview
  AWAITING = %w[pages_manage_engagement read_insights].freeze

  ENGAGEMENT = 'pages_manage_engagement'
  INSIGHTS   = 'read_insights'

  ENGAGEMENT_PENDING_MESSAGE =
    'Replying to, hiding, deleting and liking Facebook content from here is waiting on ' \
    "Facebook's approval. Do it on Facebook for now."

  module_function

  def awaiting
    raw = ENV['META_PERMISSIONS_AWAITING_REVIEW']
    return AWAITING if raw.nil?

    raw.split(',').map(&:strip).reject(&:blank?)
  end

  def approved?(permission, company: nil)
    return true if review_company?(company)

    !awaiting.include?(permission.to_s)
  end

  def engagement?(company)
    approved?(ENGAGEMENT, company: company)
  end

  def insights?(company)
    approved?(INSIGHTS, company: company)
  end

  # What the frontend needs to decide which controls to draw.
  def capabilities(company)
    { engagement: engagement?(company), insights: insights?(company) }
  end

  def review_company?(company)
    return false if company.nil?

    ENV['META_REVIEW_COMPANY_IDS'].to_s.split(',').map(&:strip).include?(company.id.to_s)
  end
end
