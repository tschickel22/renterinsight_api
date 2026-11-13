# frozen_string_literal: true

# Account names are not unique (two families named Smith are two accounts).
# When a rep types a name already in use, Convert Lead and New Account answer
# 409 (code account_name_in_use) and ask: join / open one of those accounts,
# or make a new one with the same name.
#
# The question lists only accounts the rep can open. Same-name accounts in
# locations they cannot see are counted (hiddenCount) but never described.
#
# Needs FollowedRecords (or_followed) and ApplicationController's
# permission_service; both CRM controllers that use it include it.
module AccountNameMatches
  extend ActiveSupport::Concern

  private

  # `scope` narrowed to the accounts the current user can open. Mirrors the
  # RBAC part of AccountsController#index and #set_account: admins see all;
  # a location-restricted rep sees their locations, accounts with no
  # location, and accounts they follow; a rep with no location assignments
  # sees all (as the index does). The location selector is a view filter,
  # not access, so it is not applied here.
  def accounts_user_can_open(scope = @company.accounts.where(is_deleted: [false, nil]))
    return scope unless current_user.uses_rbac? && !current_user.effective_admin?

    location_ids = permission_service.accessible_location_ids
    return scope if location_ids.empty?

    or_followed(scope, scope.where('accounts.location_id IN (?) OR accounts.location_id IS NULL', location_ids))
  end

  # [visible matches (up to limit), count of same-name accounts the user
  # cannot open].
  def account_name_matches(account_name, limit: 10)
    all = Leads::Converter.accounts_named(@company, account_name)
    visible = accounts_user_can_open(all)
    [visible.limit(limit).to_a, all.count - visible.count]
  end

  # The 409 body: the visible accounts with that name, so the screen can ask
  # whether to join / open one of them or make a new one.
  def account_name_in_use_json(account_name, matches, hidden_count: 0)
    contact_counts = @company.contacts.where(account_id: matches.map(&:id), is_deleted: [false, nil])
                             .group(:account_id).count
    accounts = matches.map do |a|
      {
        id: a.id,
        name: a.name,
        email: a.email,
        phone: a.phone,
        city: a.billing_city,
        state: a.billing_state,
        accountType: a.account_type,
        status: a.status,
        contactsCount: contact_counts[a.id] || 0,
        createdAt: a.created_at&.iso8601
      }
    end
    {
      error: "An account named #{account_name} already exists.",
      code: 'account_name_in_use',
      accountName: account_name,
      existingAccount: accounts.first,
      accounts: accounts,
      hiddenCount: hidden_count
    }
  end
end
