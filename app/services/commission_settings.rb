# frozen_string_literal: true

# When a company's commissions become payable. Most dealers wait for accounting
# to approve the deal to the general ledger. A dealer who keeps their books
# elsewhere never does that, so they can pay once the deal closes instead.
class CommissionSettings
  KEY = 'commission_payable_at'
  GL_APPROVAL = 'gl_approval'
  DEAL_CLOSED = 'deal_closed'
  PAYABLE_AT = [GL_APPROVAL, DEAL_CLOSED].freeze

  def self.payable_at(company)
    value = Setting.get('Company', company.id, KEY, GL_APPROVAL)
    PAYABLE_AT.include?(value) ? value : GL_APPROVAL
  end

  def self.set_payable_at(company, value)
    Setting.set('Company', company.id, KEY, value)
  end

  def self.at_close?(company)
    company.present? && payable_at(company) == DEAL_CLOSED
  end

  def self.not_payable_message(company)
    return 'This commission can be approved once the deal is closed.' if at_close?(company)

    'Cannot approve commission: deal has not been GL-approved yet. Approve the deal first in Accounting > Deals & Commissions.'
  end
end
