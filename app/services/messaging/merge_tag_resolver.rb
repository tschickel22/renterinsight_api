module Messaging
  module MergeTagResolver
    TAG_PATTERN = /\{\{\s*([a-z0-9_.]+)\s*\}\}/i

    def self.resolve(text, context)
      return '' if text.nil?
      text.to_s.gsub(TAG_PATTERN) do
        path = $1.to_s.strip.downcase
        value = lookup(path, context)
        value.nil? ? '' : value.to_s
      end
    end

    def self.build_context(recipient:, company:, rep: nil, campaign_send: nil, urls: {})
      {
        'first_name' => extract_first_name(recipient),
        'last_name'  => extract_last_name(recipient),
        'full_name'  => extract_full_name(recipient),
        'email'      => extract_email(recipient),
        'phone'      => extract_phone(recipient),
        'rep_name'   => rep_full_name(rep),
        'rep_email'  => rep&.try(:email),
        'rep_phone'  => rep&.try(:phone),
        'company' => {
          'name'    => company&.name,
          'phone'   => company&.try(:phone),
          'email'   => company&.try(:email),
          'website' => company&.try(:website)
        },
        'public_inventory_url' => urls[:public_inventory_url] || urls['public_inventory_url'],
        'unsubscribe_url'      => urls[:unsubscribe_url]      || urls['unsubscribe_url'],
        'view_in_browser_url'  => urls[:view_in_browser_url]  || urls['view_in_browser_url'],
        'campaign_send_id'     => campaign_send&.id
      }
    end

    def self.lookup(path, context)
      parts = path.split('.')
      current = context
      parts.each do |part|
        return nil if current.nil?
        current = if current.is_a?(Hash)
                    current[part] || current[part.to_sym]
                  elsif current.respond_to?(part)
                    current.public_send(part)
                  else
                    nil
                  end
      end
      current
    end

    def self.extract_first_name(record)
      return nil unless record
      first = record.try(:first_name)
      return first if first.present?
      record.respond_to?(:name) ? record.name.to_s.split(/\s+/).first : nil
    end

    def self.extract_last_name(record)
      return nil unless record
      last = record.try(:last_name)
      return last if last.present?
      record.respond_to?(:name) ? record.name.to_s.split(/\s+/, 2).last : nil
    end

    def self.extract_full_name(record)
      return nil unless record
      first = extract_first_name(record)
      last = extract_last_name(record)
      combined = [first, last].compact.reject(&:blank?).join(' ')
      return combined if combined.present?
      record.try(:name) || record.try(:email)
    end

    def self.extract_email(record)
      record&.try(:email)
    end

    def self.extract_phone(record)
      record&.try(:phone)
    end

    def self.rep_full_name(rep)
      return nil unless rep
      [rep.try(:first_name), rep.try(:last_name)].compact.reject(&:blank?).join(' ').presence ||
        rep.try(:name) || rep.try(:email)
    end
  end
end
