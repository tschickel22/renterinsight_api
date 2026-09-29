# frozen_string_literal: true

# Records on the document why its journal entry did not post.
#
# Posting failures used to leave only a log line, so an invoice or bill could
# sit outside the ledger with nobody knowing until the books didn't tie out.
# update_columns keeps this from re-running the document's own callbacks
# (which include the auto-post that just failed).
module GlPostTracking
  extend ActiveSupport::Concern

  def record_gl_post_failure!(reason)
    return unless persisted?

    update_columns(gl_post_error: reason.to_s.first(1000), gl_post_failed_at: Time.current)
    Rails.logger.error("[Accounting] #{self.class.name} #{id} not posted: #{reason}")
  end

  def clear_gl_post_failure!
    return unless persisted? && (gl_post_error.present? || gl_post_failed_at.present?)

    update_columns(gl_post_error: nil, gl_post_failed_at: nil)
  end

  def gl_post_failed?
    gl_post_error.present?
  end
end
