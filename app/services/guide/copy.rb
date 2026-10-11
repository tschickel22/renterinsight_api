# frozen_string_literal: true

module Guide
  # Help and tour copy is stored as data, so it cannot call the brand kernel
  # the way a mailer template does. Authors write {{brand}} instead of the
  # platform name and it is filled in when the copy is served.
  module Copy
    BRAND_TOKEN = '{{brand}}'

    def self.render(text, company: nil)
      return text if text.blank? || !text.include?(BRAND_TOKEN)

      text.gsub(BRAND_TOKEN, Brand.current(company: company).name.to_s)
    end
  end
end
