# frozen_string_literal: true

# GET /api/v1/accounts/:account_id/deal_people
#
# The people on the account's open deals and their roles, for the badges on
# the account's Contacts tab ("Buyer on Smith home"). Open means not won and
# not lost, against the company's own pipeline stages.
class Api::V1::AccountDealPeopleController < ApplicationController
  before_action :set_company_scope

  def index
    return unless authorize_action!('crm', 'read')

    account = @company.accounts.find_by(id: params[:account_id])
    return render(json: { error: 'Not found' }, status: :not_found) unless account

    deals = @company.deals.where(account_id: account.id, deleted_at: nil)
    if current_user.uses_rbac? && !current_user.effective_admin?
      location_ids = permission_service.accessible_location_ids
      deals = location_ids.any? ? deals.where(location_id: location_ids) : deals.none
    end
    open_deals = deals.to_a.reject(&:closed?)
    return render(json: []) if open_deals.empty?

    labels = @company.resolved_labels
    rows = EntityBuyer.active.where(buyable_type: 'Deal', buyable_id: open_deals.map(&:id)).ordered
                      .pluck(:buyable_id, :contact_id, :role)
    # A deal whose card has not been opened since the card started following
    # the deal's Buyer / Co-Buyer columns: read the columns (no writes here).
    carded = rows.map(&:first).to_set
    open_deals.each do |deal|
      next if carded.include?(deal.id)

      Deal::PEOPLE_POINTERS.each { |role, column| rows << [deal.id, deal[column], role] if deal[column] }
    end

    by_id = open_deals.index_by(&:id)
    render json: rows.map { |deal_id, contact_id, role|
      { contact_id: contact_id, role: role,
        role_label: labels[EntityBuyer::LABEL_KEYS[role]].presence || role.titleize,
        deal_id: deal_id, deal_name: by_id[deal_id].name }
    }
  end
end
