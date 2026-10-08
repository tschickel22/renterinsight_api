# frozen_string_literal: true

module Truebuild
  # Corrects a price in a price book, published or not, for every dealer on
  # it at once: a fix, not a new price list, so it skips the dealer review
  # hold. Each field changed is logged (CatalogPriceCorrection). Open deal
  # sheets priced from the book reprice when next opened (DealBuild.stale?);
  # signed ones never change. Buyers' saved designs are repriced in the
  # background.
  class PriceCorrector
    FIELDS = {
      'CatalogVariantPrice' => { 'net_base_price' => :money, 'total_base_price' => :money },
      'CatalogOptionPrice' => { 'dealer_cost' => :money, 'suggested_retail' => :money, 'is_standard' => :boolean,
                                # The option's factory code, for the factory PO: it belongs to the option
                                # (every book and model that offers it), not to this price row.
                                'factory_code' => :code }
    }.freeze

    class Invalid < StandardError; end

    def initialize(book:, user:)
      @book = book
      @user = user
    end

    # target: a CatalogVariantPrice or CatalogOptionPrice in this book.
    # changes: { 'dealer_cost' => '1295.00', ... }; a blank money value clears it
    # (except a base price, which every home needs).
    def apply(target, changes, reason: nil, request: nil)
      raise Invalid, 'That price is not in this book' unless target.catalog_price_book_id == @book.id

      allowed = FIELDS.fetch(target.class.name)
      changes = changes.to_h.stringify_keys
      unknown = changes.keys - allowed.keys
      raise Invalid, "Cannot change #{unknown.to_sentence}" if unknown.any?

      log = []
      CatalogPriceCorrection.transaction do
        changes.each do |field, raw|
          value = cast(allowed[field], raw)
          raise Invalid, 'A home needs a base price' if field == 'net_base_price' && (value.nil? || value <= 0)
          raise Invalid, "#{field.humanize} cannot be negative" if value.is_a?(BigDecimal) && value.negative?

          holder = field == 'factory_code' ? target.option : target
          old = holder.public_send(field)
          next if old == value || (old.is_a?(BigDecimal) && value.is_a?(BigDecimal) && old.round(2) == value.round(2))

          holder.public_send("#{field}=", value)
          holder.save! if holder != target
          log << { field: field, old_value: old&.to_s, new_value: value&.to_s }
        end
        next if log.empty?

        target.save!
        log.each do |entry|
          CatalogPriceCorrection.create!(price_book: @book, target_type: target.class.name, target_id: target.id,
                                         corrected_by: @user, reason: reason.presence, request: request, **entry)
        end
        @book.update!(metadata: @book.metadata.to_h.merge('corrected_at' => Time.current.iso8601(6)))
      end
      CatalogPriceCorrectionJob.perform_later(@book.id) if log.any?
      log
    end

    private

    def cast(type, raw)
      return ActiveModel::Type::Boolean.new.cast(raw) if type == :boolean
      return raw.to_s.strip.upcase.presence if type == :code
      return nil if raw.blank?

      BigDecimal(raw.to_s.delete(',$'))
    rescue ArgumentError
      raise Invalid, "#{raw} is not an amount"
    end
  end
end
