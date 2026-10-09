# frozen_string_literal: true

# The hosted designer for one home (Truebuild::DesignLink): the page a dealer's
# own website links its Design this home button to. Rails serves the app's
# shell with the home and the dealer embedded, as it does a dealer site, and
# the app draws only the designer (HostedDesignApp). The designer then talks to
# the public TrueBuild API with the dealer's inventory token, as on their site.
#
# Shown only where the dealer offers TrueBuild on its own website: the add-on
# and the website designer setting (TruebuildReach). Otherwise, and for a home
# that cannot be designed, a plain page that says so.
class Public::DesignPagesController < ApplicationController
  skip_before_action :authenticate, raise: false
  skip_before_action :set_company_scope, raise: false
  skip_before_action :set_current_attributes, raise: false

  include TruebuildReach

  # GET https://<design host>/:dealer/:vehicle_id
  # GET /design/:dealer/:vehicle_id
  def show
    @company = Truebuild::DesignLink.company_for(params[:dealer])
    vehicle = @company&.vehicles&.where(is_deleted: [false, nil])&.find_by(id: params[:vehicle_id])
    return not_offered unless vehicle && @company.public_inventory_enabled && truebuild_reachable? &&
                              Truebuild::BuyerCatalog.designable_home?(@company, vehicle)

    html = Websites::SpaShell.fetch
    response.headers['Cache-Control'] = 'no-store'
    render html: page(html, vehicle).html_safe, content_type: 'text/html' # rubocop:disable Rails/OutputSafety
  rescue Websites::SpaShell::ShellUnavailable => e
    Rails.logger.error("[Public::DesignPages] #{e.message}")
    render plain: 'The designer is temporarily unavailable', status: :service_unavailable
  end

  private

  def page(html, vehicle)
    variant = vehicle.catalog_plan_variant
    title = [variant.catalog_plan&.name, variant.model_number].compact.join(' ')
    photo = Array(variant.media.to_h['photos']).first
    payload = {
      api_base: (ENV['RAILS_API_URL'].presence || request.base_url).chomp('/'),
      token: @company.public_inventory_token,
      vehicle_id: vehicle.id,
      title: title,
      image: photo.is_a?(Hash) ? photo['url'] : photo,
      dealer: { name: @company.name, logo: @company.branding_settings.to_h['logo'],
                primary_color: @company.branding_settings.to_h['primaryColor'].presence || '#3b82f6' }
    }
    # The JSON sits in a script tag: a "</" in any value must not end it.
    json = payload.to_json.gsub('</', '<\/')
    head = %(<title>#{ERB::Util.html_escape("Design the #{title} | #{@company.name}")}</title>) +
           %(<meta name="robots" content="noindex">)
    html.sub(%r{<title>.*?</title>}m, '').sub('</head>', "#{head}</head>")
        .sub('</body>', %(<script id="dealertide-design" type="application/json">#{json}</script></body>))
  end

  def not_offered
    response.headers['Cache-Control'] = 'no-store'
    render html: <<~HTML.html_safe, status: :not_found, content_type: 'text/html' # rubocop:disable Rails/OutputSafety
      <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <meta name="robots" content="noindex"><title>Not available</title></head>
      <body style="font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;color:#374151">
      <h1 style="font-size:1.25rem">This home cannot be designed online</h1>
      <p>Please contact the dealer about this home.</p></body></html>
    HTML
  end
end
