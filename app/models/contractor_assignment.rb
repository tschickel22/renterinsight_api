# frozen_string_literal: true

class ContractorAssignment < ApplicationRecord
  belongs_to :contractor
  belongs_to :assignable, polymorphic: true
  belongs_to :company
  belongs_to :assigned_by, class_name: 'User', optional: true

  validates :status, inclusion: { in: %w[assigned accepted in_progress completed declined] }
end
