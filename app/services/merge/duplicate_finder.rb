# frozen_string_literal: true

module Merge
  # Finds likely duplicates of an existing CRM record, for the "Find & merge
  # duplicates" action on a lead, contact or account.
  #
  # Scored rather than boolean, because the useful matches are rarely exact.
  # "Bob Smith / bob@x.com / (720) 555-1234" and "Robert Smith / BOB@X.COM /
  # 7205551234" are the same person and no equality check finds them.
  #
  # Email and phone are normalised before comparison and weighted highest: they
  # are identifiers, whereas a name is a label two different people can share.
  # A name match alone deliberately scores below the confirm threshold, so the
  # two Dave Johnsons a dealer actually has do not get proposed as one person.
  class DuplicateFinder
    WEIGHTS = {
      email:      50,
      phone:      35,
      full_name:  20,
      last_name:   8,
      company:    10
    }.freeze

    # Below this a candidate is not worth showing at all.
    MIN_SCORE = 20
    # At or above this the UI can pre-select it as a confident match.
    STRONG_SCORE = 50

    MATCHERS = {
      'Lead'    => { name_parts: %w[first_name last_name], org: 'company_name' },
      'Contact' => { name_parts: %w[first_name last_name], org: 'company_name' },
      'Account' => { name_parts: %w[name],                 org: nil }
    }.freeze

    Candidate = Struct.new(:record, :score, :reasons, :strong, keyword_init: true)

    def self.call(...) = new(...).call

    def initialize(record:, company:, limit: 25)
      @record  = record
      @company = company
      @limit   = limit
      @config  = MATCHERS.fetch(record.class.name) { raise ArgumentError, "not mergeable: #{record.class.name}" }
    end

    def call
      return [] if signature_blank?

      candidates.filter_map do |other|
        score, reasons = score_against(other)
        next if score < MIN_SCORE

        Candidate.new(record: other, score: score, reasons: reasons, strong: score >= STRONG_SCORE)
      end.sort_by { |c| -c.score }.first(@limit)
    end

    private

    def email = normalize_email(@record.email)
    def phone = normalize_phone(@record.phone)

    def full_name
      @config[:name_parts].map { |p| @record[p] }.compact.join(' ').downcase.strip
    end

    def signature_blank? = email.blank? && phone.blank? && full_name.blank?

    def normalize_email(v) = v.to_s.strip.downcase.presence

    # Last 10 digits: the same number is stored as +17205551234, 7205551234 and
    # (720) 555-1234 across the app depending on which form wrote it.
    def normalize_phone(v)
      digits = v.to_s.gsub(/\D/, '')
      return nil if digits.length < 10

      digits.last(10)
    end

    # Deliberately over-fetches on cheap indexed predicates and scores in Ruby.
    # Doing the fuzzy part in SQL would need pg_trgm, which is not installed.
    def candidates
      scope = @company.public_send(@record.class.name.tableize)
                      .where.not(id: @record.id)
                      .where(merged_into_id: nil)
      scope = scope.where(is_deleted: [false, nil]) if @record.class.column_names.include?('is_deleted')

      clauses = []
      values  = []

      if email.present?
        clauses << 'LOWER(email) = ?'
        values << email
      end
      if phone.present?
        clauses << "RIGHT(regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g'), 10) = ?"
        values << phone
      end
      @config[:name_parts].each do |part|
        next if @record[part].blank?

        clauses << "LOWER(#{part}) = ?"
        values << @record[part].to_s.downcase.strip
      end

      return klass_none if clauses.empty?

      scope.where(clauses.join(' OR '), *values).limit(200)
    end

    def klass_none = @record.class.none

    def score_against(other)
      score   = 0
      reasons = []

      other_email = normalize_email(other.email)
      if email.present? && other_email.present? && email == other_email
        score += WEIGHTS[:email]
        reasons << 'same email'
      end

      other_phone = normalize_phone(other.phone)
      if phone.present? && other_phone.present? && phone == other_phone
        score += WEIGHTS[:phone]
        reasons << 'same phone'
      end

      other_name = @config[:name_parts].map { |p| other[p] }.compact.join(' ').downcase.strip
      if full_name.present? && other_name.present? && full_name == other_name
        score += WEIGHTS[:full_name]
        reasons << 'same name'
      elsif @config[:name_parts].include?('last_name') &&
            @record.last_name.present? &&
            @record.last_name.to_s.casecmp?(other.last_name.to_s)
        score += WEIGHTS[:last_name]
        reasons << 'same surname'
      end

      if @config[:org].present?
        mine   = @record[@config[:org]].to_s.downcase.strip
        theirs = other[@config[:org]].to_s.downcase.strip
        if mine.present? && mine == theirs
          score += WEIGHTS[:company]
          reasons << 'same company'
        end
      end

      [score, reasons]
    end
  end
end
