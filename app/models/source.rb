class Source < ApplicationRecord
  has_many :leads, dependent: :nullify
end
