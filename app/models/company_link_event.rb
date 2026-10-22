# frozen_string_literal: true

# What crossed a company link and who did it (E68 step 5). Both companies on
# the link can read it.
class CompanyLinkEvent < ApplicationRecord
  belongs_to :company_link
  belongs_to :project_link, optional: true
  belongs_to :company, optional: true
  belongs_to :user, optional: true

  validates :kind, :summary, presence: true
end
