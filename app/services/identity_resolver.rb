# frozen_string_literal: true

# IdentityResolver answers a single question: "within this company, does this
# email or phone already belong to someone?" — looking across leads, contacts,
# and accounts in one place.
#
# It is the shared lookup behind cross-entity duplicate warnings (manual forms)
# and the intake absorb/merge logic. Keep it PURE: it never mutates records.
#
# Matching rules:
#   - email compared lowercased
#   - phone compared digits-only so (303) 555-1212 == 3035551212
#   - email match always wins over phone match
#   - leads: non-converted preferred over converted
#
# Usage:
#   IdentityResolver.new(company, email: e, phone: p).resolve
#   => Match struct, or nil
#
#   IdentityResolver.new(company, email: e, phone: p).all
#   => Array<Match> across every entity type (for warnings)
class IdentityResolver
  # type     => :lead | :contact | :account
  # record   => the AR record
  # matched  => 'email' | 'phone'
  # converted=> true only for already-converted leads
  Match = Struct.new(:type, :record, :matched, :converted, keyword_init: true) do
    def name
      case type
      when :account
        record.name
      else
        [record.try(:first_name), record.try(:last_name)].compact.join(' ').strip
      end
    end

    def to_h
      {
        type: type,
        id: record.id,
        name: name.presence,
        email: record.try(:email),
        phone: record.try(:phone),
        matchedField: matched,
        converted: converted
      }
    end
  end

  def initialize(company, email: nil, phone: nil)
    @company = company
    @email   = email.to_s.strip.downcase
    @phone   = phone.to_s.gsub(/[^0-9]/, '')
  end

  # Best single match across all entity types, or nil.
  # Preference order: non-converted lead > contact > account > converted lead.
  def resolve(exclude: nil)
    matches = all(exclude: exclude)
    return nil if matches.empty?

    matches.min_by { |m| preference_rank(m) }
  end

  # All matches across leads, contacts, accounts.
  # `exclude` skips a specific record, e.g. { type: :lead, id: 5 } so a record
  # never matches itself.
  def all(exclude: nil)
    return [] if @email.blank? && @phone.blank?

    (lead_matches + contact_matches + account_matches).reject do |m|
      exclude && m.type == exclude[:type] && m.record.id == exclude[:id]
    end
  end

  private

  attr_reader :company, :email, :phone

  def preference_rank(match)
    case [match.type, match.converted]
    when [:lead, false] then 0
    when [:contact, nil], [:contact, false] then 1
    when [:account, nil], [:account, false] then 2
    when [:lead, true] then 3
    else 4
    end
  end

  def phone_sql(column = 'phone')
    "regexp_replace(COALESCE(#{column}, ''), '[^0-9]', '', 'g') = ?"
  end

  def lead_matches
    scope = company.leads
    matches = []

    if email.present?
      scope.where('LOWER(email) = ?', email).limit(5).each do |l|
        matches << Match.new(type: :lead, record: l, matched: 'email',
                             converted: !!l.try(:is_converted))
      end
    end
    if phone.present?
      scope.where(phone_sql, phone).limit(5).each do |l|
        next if matches.any? { |m| m.record.id == l.id }
        matches << Match.new(type: :lead, record: l, matched: 'phone',
                             converted: !!l.try(:is_converted))
      end
    end
    matches
  rescue => e
    Rails.logger.error "[IdentityResolver] lead lookup failed: #{e.message}"
    []
  end

  def contact_matches
    scope = company.contacts
    matches = []

    if email.present?
      scope.where('LOWER(email) = ?', email).limit(5).each do |c|
        matches << Match.new(type: :contact, record: c, matched: 'email', converted: nil)
      end
    end
    if phone.present?
      scope.where(phone_sql, phone).limit(5).each do |c|
        next if matches.any? { |m| m.record.id == c.id }
        matches << Match.new(type: :contact, record: c, matched: 'phone', converted: nil)
      end
    end
    matches
  rescue => e
    Rails.logger.error "[IdentityResolver] contact lookup failed: #{e.message}"
    []
  end

  def account_matches
    scope = company.accounts.where(is_deleted: [false, nil])
    matches = []

    if email.present?
      scope.where('LOWER(email) = ?', email).limit(5).each do |a|
        matches << Match.new(type: :account, record: a, matched: 'email', converted: nil)
      end
    end
    if phone.present?
      scope.where(phone_sql, phone).limit(5).each do |a|
        next if matches.any? { |m| m.record.id == a.id }
        matches << Match.new(type: :account, record: a, matched: 'phone', converted: nil)
      end
    end
    matches
  rescue => e
    Rails.logger.error "[IdentityResolver] account lookup failed: #{e.message}"
    []
  end
end
