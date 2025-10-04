# frozen_string_literal: true
class Account < ApplicationRecord
  has_many :leads, foreign_key: :converted_account_id, dependent: :nullify
end
