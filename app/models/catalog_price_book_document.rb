# frozen_string_literal: true

# A source file from a factory package. Dealer net pricing is confidential:
# stored in a private bucket, never the public website-assets bucket.
class CatalogPriceBookDocument < ApplicationRecord
  KINDS = %w[price_list option_list order_form standards announcement image unknown].freeze
  EXTRACTION_STATUSES = %w[pending running extracted failed skipped].freeze

  belongs_to :price_book, class_name: 'CatalogPriceBook', foreign_key: :catalog_price_book_id, inverse_of: :documents
  has_many :import_items, class_name: 'CatalogImportItem', dependent: :nullify

  validates :filename, :checksum_sha256, presence: true
  validates :checksum_sha256, uniqueness: { scope: :catalog_price_book_id, message: 'is already in this price book' }
  validates :kind, inclusion: { in: KINDS }
  validates :extraction_status, inclusion: { in: EXTRACTION_STATUSES }
end
