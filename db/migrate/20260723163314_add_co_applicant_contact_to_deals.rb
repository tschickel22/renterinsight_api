# frozen_string_literal: true

# Links a Deal to its co-applicant (co-borrower) Contact.
#
# Lead conversion already creates a second Contact on the account from the
# lead's co_applicant_* fields, but nothing pointed at it from the deal — so
# the co-applicant was reachable from the Account and invisible on the Deal.
#
# Deliberately a FK to the existing Contact rather than a copy of the four
# co_applicant_* columns: the Contact is the source of truth, so editing it
# updates the deal view instead of leaving two records to drift apart.
class AddCoApplicantContactToDeals < ActiveRecord::Migration[8.0]
  def change
    add_reference :deals, :co_applicant_contact,
                  null: true,
                  index: true,
                  foreign_key: { to_table: :contacts, on_delete: :nullify }
  end
end
