# frozen_string_literal: true

# Splits the two ways a contractor gets into the portal, which have very
# different security profiles and lifetimes:
#
#   portal_access_token  - a 6-digit code, read aloud over the phone or typed
#                          from an email. Short-lived by necessity: it is low
#                          entropy, and `verify` matches it against EVERY
#                          contractor, so a guess hits whoever happens to hold
#                          that number.
#   portal_link_token    - high-entropy, embedded in an assignment email as a
#                          one-click link. Safe to live for days, which matters
#                          because an assignment email is routinely read the
#                          next morning and a 30-minute code would be dead on
#                          arrival.
#
# Separate columns so the dealer generating a phone code doesn't silently
# invalidate the link already sitting in the contractor's inbox.
class AddPortalLinkTokenToVendors < ActiveRecord::Migration[8.0]
  def change
    add_column :vendors, :portal_link_token, :string
    add_column :vendors, :portal_link_expires_at, :datetime

    add_index :vendors, :portal_link_token, unique: true
  end
end
