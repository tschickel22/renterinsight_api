# frozen_string_literal: true

# Monthly campaign email allowance per company, mirroring sms_monthly_limit.
#
# This is a billing ceiling, deliberately separate from the per-mailbox send pacing added
# on 2026-08-02. Rate is a deliverability concern measured per mailbox per minute; volume is
# a billing concern measured per company per month. Folding them together would make both
# harder to reason about, and a tenant who is under their monthly allowance still must not
# burst past a provider's rate ceiling.
class AddEmailMonthlyLimitToCompanies < ActiveRecord::Migration[8.0]
  def change
    # 0 means unlimited, matching the sms_monthly_limit convention.
    add_column :companies, :email_monthly_limit, :integer, default: 10_000, null: false
  end
end
