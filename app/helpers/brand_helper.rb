# frozen_string_literal: true

# Exposes the platform brand kernel (name, support/from emails, public URLs,
# logo) to mailer views. Templates call `brand.name`, `brand.support_email`,
# etc. — never hardcode "Renter Insight" / "RenterInsight" strings.
#
# Memoized per-render via @_brand so multiple calls in one template resolve
# to the same object. Picks up per-tenant whitelabel overrides when @company
# is set by the mailer action before rendering.
module BrandHelper
  def brand
    @_brand ||= Brand.current(company: @company)
  end
end
