# frozen_string_literal: true

module Truebuild
  # Tells dealers who price with TrueBuild that a plant has a new book.
  #
  # hold_for_review runs inside the publish transaction, so a dealer who
  # reviews new prices never quotes from the new book before deciding: their
  # pending row exists the moment the book goes live. deliver runs in a job
  # afterwards and does the slow part, pricing the changes at each dealer's
  # markup and notifying their admins.
  module PriceBookNotifier
    module_function

    def hold_for_review(book)
      return unless book.supersedes

      subscribers(book.manufacturer_id).each do |company|
        previous = BookResolver.accepted_before(company, book)
        next unless previous

        company.dealer_price_book_adoptions.pending
               .joins(:price_book).where(catalog_price_books: { manufacturer_id: book.manufacturer_id, factory_id: book.factory_id })
               .update_all(status: 'superseded', updated_at: Time.current)
        adoption = company.dealer_price_book_adoptions.find_or_initialize_by(catalog_price_book_id: book.id)
        adoption.previous_book = previous
        if BookResolver.holds_for_review?(company, book.manufacturer_id)
          adoption.status = 'pending'
        else
          adoption.assign_attributes(status: 'adopted', decided_at: Time.current)
        end
        adoption.save!
      end
    end

    def deliver(book)
      book.dealer_adoptions.where(notified_at: nil).where.not(previous_book_id: nil).includes(:company, :previous_book).find_each do |adoption|
        diff = BookDiff.new(adoption.previous_book, book)
        summary = UpdateSummary.new(adoption.company, diff).call
        # Nothing a dealer prices moved: take it without asking.
        if adoption.status == 'pending' && summary['features_only']
          adoption.assign_attributes(status: 'adopted', decided_at: Time.current)
        end
        adoption.update!(summary: summary.deep_stringify_keys, notified_at: Time.current)
        DesignRepricer.call(adoption.company) if adoption.status == 'adopted'
        notify(adoption, book, summary)
      end
    end

    # Companies with any TrueBuild pricing set up for this manufacturer.
    def subscribers(manufacturer_id)
      ids = DealerMarkupRule.where(manufacturer_id: [nil, manufacturer_id]).distinct.pluck(:company_id) |
            DealerCatalogTerm.where(manufacturer_id: [nil, manufacturer_id]).distinct.pluck(:company_id)
      Company.where(id: ids).to_a
    end

    def notify(adoption, book, summary)
      mfr = book.manufacturer.name
      pending = adoption.status == 'pending'
      title = pending ? "New #{mfr} prices to review" : "#{mfr} prices updated"
      message = [headline(summary), pending ? 'Your prices stay the same until you accept.' : nil].compact.join(' ')
      admins(adoption.company).each do |user|
        NotificationService.create(
          recipient: user, notification_type: :truebuild_price_update, notifiable: adoption,
          title: title, message: message, company_id: adoption.company_id,
          priority: pending ? 'high' : 'normal',
          action_url: "/settings?tab=truebuild&update=#{adoption.id}",
          action_text: pending ? 'Review prices' : 'See what changed'
        )
      end
    end

    def headline(summary)
      h = summary['homes']
      o = summary['options']
      f = summary['features']
      parts = []
      parts << "#{h['changed']} #{h['changed'] == 1 ? 'home' : 'homes'} changed price (average #{signed(h['avg_pct'])}%)" if h['changed'].positive?
      parts << "#{o['changed']} option #{o['changed'] == 1 ? 'price' : 'prices'} changed" if o['changed'].positive?
      parts << "#{h['added']} new #{h['added'] == 1 ? 'home' : 'homes'}" if h['added'].positive?
      parts << "#{o['added_count']} new #{o['added_count'] == 1 ? 'option' : 'options'}" if o['added_count'].positive?
      parts << "#{f['added_count']} new standard #{f['added_count'] == 1 ? 'feature' : 'features'}" if f['added_count'].positive?
      parts.empty? ? 'Nothing you price changed.' : "#{parts.join(', ')}."
    end

    def signed(n) = n.to_f.positive? ? "+#{n}" : n.to_s

    def admins(company)
      company.users.active.select(&:company_admin?)
    end
  end
end
