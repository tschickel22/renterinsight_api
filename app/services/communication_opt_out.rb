# frozen_string_literal: true

# Has this person told us to stop, on this channel?
#
# Two records of an opt-out exist. A contact has its own columns, set from the
# contact page. Anyone can have a CommunicationPreference, which is where a STOP
# text lands and the only place a lead's opt-out lives. A STOP is also filed
# against just the first record with that number, so the same person as both a
# lead and a contact is matched by address as well as by record.
class CommunicationOptOut
  Result = Struct.new(:opted_out, :at, keyword_init: true) do
    alias_method :opted_out?, :opted_out
  end

  COLUMNS = {
    'sms' => %i[opt_out_sms opt_out_sms_at],
    'email' => %i[opt_out_email opt_out_email_at]
  }.freeze

  def self.check(channel:, company: nil, record: nil, address: nil)
    new(channel.to_s, company, record, address).check
  end

  def initialize(channel, company, record, address)
    @channel = channel
    @company = company
    @record = record
    @address = address
  end

  def check
    found = ([@record].compact + records_at_address).uniq.filter_map { |candidate| opted_out_at(candidate) }
    return Result.new(opted_out: false, at: nil) if found.empty?

    Result.new(opted_out: true, at: found.compact_blank.max)
  end

  private

  # false when this record has not opted out; a time (or true) when it has.
  def opted_out_at(candidate)
    flag, flag_at = COLUMNS.fetch(@channel)
    return candidate.try(flag_at) || true if candidate.try(flag) == true

    preference = CommunicationPreference.where(recipient: candidate, channel: @channel, category: nil).first
    return false unless preference && !preference.opted_in?

    preference.opted_out_at || true
  end

  def records_at_address
    return [] if @company.blank? || @address.blank?

    [@company.contacts, @company.leads].flat_map { |scope| matching(scope).limit(25).to_a }
  end

  def matching(scope)
    if @channel == 'sms'
      digits = @address.to_s.gsub(/\D/, '').last(10)
      return scope.none if digits.length < 10

      scope.where("#{Communication.normalized_phone_sql('phone')} = ?", digits)
    else
      scope.where('LOWER(TRIM(email)) = ?', @address.to_s.strip.downcase)
    end
  end
end
