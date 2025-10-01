class NurtureStep < ApplicationRecord
  belongs_to :nurture_sequence
  belongs_to :template, optional: true
end
