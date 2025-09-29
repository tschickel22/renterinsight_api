class Task < ApplicationRecord; belongs_to :company; belongs_to :lead; enum status: { open: 0, done: 1 }; end
