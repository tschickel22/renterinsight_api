class Lead < ApplicationRecord
  belongs_to :source, optional: true  # allow creating leads while testing
end
