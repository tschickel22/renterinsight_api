# frozen_string_literal: true

# One dated import of a plant's price package. Prices hang off the book, so a
# new book never rewrites a quote made from an old one. At most one book per
# manufacturer and plant is published at a time; publishing supersedes the last.
class CatalogPriceBook < ApplicationRecord
  STATUSES = %w[draft extracting in_review published superseded rejected].freeze

  belongs_to :manufacturer
  belongs_to :factory, optional: true
  belongs_to :published_by, class_name: 'User', optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :supersedes, class_name: 'CatalogPriceBook', optional: true
  # Deal builds remember the books they were priced from; deleting a draft must not fail on them.
  has_many :deal_home_builds, foreign_key: :catalog_price_book_id, dependent: :nullify
  has_many :cost_deal_home_builds, class_name: 'DealHomeBuild', foreign_key: :cost_book_id, dependent: :nullify
  has_many :options_deal_home_builds, class_name: 'DealHomeBuild', foreign_key: :options_book_id, dependent: :nullify

  has_many :documents, class_name: 'CatalogPriceBookDocument', dependent: :destroy
  has_many :import_items, class_name: 'CatalogImportItem', dependent: :delete_all
  has_many :variant_prices, class_name: 'CatalogVariantPrice', dependent: :delete_all
  has_many :option_prices, class_name: 'CatalogOptionPrice', dependent: :delete_all
  has_many :standard_features, class_name: 'CatalogStandardFeature', dependent: :delete_all
  has_many :dealer_adoptions, class_name: 'DealerPriceBookAdoption', dependent: :restrict_with_error

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :factory_belongs_to_manufacturer

  scope :published, -> { where(status: 'published') }

  def self.current_for(manufacturer_id:, factory_id: nil)
    published.find_by(manufacturer_id: manufacturer_id, factory_id: factory_id)
  end

  def published? = status == 'published'
  def editable? = %w[draft extracting in_review].include?(status)

  def publish!(by:)
    raise ArgumentError, "Only a platform admin can publish a price book" unless by&.platform_admin? || by&.super_admin?
    unless editable?
      errors.add(:status, "is #{status}, not ready to publish")
      raise ActiveRecord::RecordInvalid, self
    end

    transaction do
      previous = self.class.published.where(manufacturer_id: manufacturer_id, factory_id: factory_id)
                     .where.not(id: id).lock.first
      previous&.update!(status: 'superseded')
      update!(status: 'published', published_at: Time.current, published_by: by,
              supersedes: supersedes || previous)
    end
  end

  private

  def factory_belongs_to_manufacturer
    return if factory.nil? || factory.manufacturer_id == manufacturer_id

    errors.add(:factory_id, 'must belong to the same manufacturer')
  end
end
