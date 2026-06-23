# frozen_string_literal: true

# Co-applicant (co-borrower) identity captured on the lead. On conversion these
# become a SECOND Contact on the same Account (primary applicant = first contact).
# This replaces the prior workaround of stuffing co-applicant identity into custom
# fields, which could not become a real Contact on conversion.
class AddCoApplicantToLeads < ActiveRecord::Migration[8.0]
  def change
    add_column :leads, :co_applicant_first_name, :string
    add_column :leads, :co_applicant_last_name,  :string
    add_column :leads, :co_applicant_email,      :string
    add_column :leads, :co_applicant_phone,      :string
  end
end
