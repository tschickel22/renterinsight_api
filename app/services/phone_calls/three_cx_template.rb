# frozen_string_literal: true

module PhoneCalls
  # The CRM template a dealer's 3CX admin uploads (Admin Console, Integrations,
  # CRM, Add Template). It makes 3CX:
  #   - look up every caller in DealerTide (name on the phone, link to the record),
  #   - report every finished call (ReportCall, 3CX's call journaling),
  #   - optionally create a lead for a caller nobody has (off by default).
  #
  # Format follows 3CX's server-side CRM template, checked against public
  # templates that work on V20 (FreeITSM, Pipedrive, a clinic's own). 3CX sends
  # no call id, so PhoneCalls::Recorder dedupes on number + start + extension.
  #
  # The key is written into the template as the default of a Password parameter,
  # so the admin only uploads the file. It is a leads-only partner API key and is
  # only ever handed to a company admin.
  class ThreeCxTemplate
    NAME = 'DealerTide'

    def initialize(base_url:, api_key:, brand_name: NAME)
      @base = base_url.to_s.chomp('/')
      @key = api_key
      @brand = brand_name.presence || NAME
    end

    def to_xml
      <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <Crm xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" Country="US" Name="#{e(@brand)}" Version="1" SupportsEmojis="true">
          <Number Prefix="AsIs" MaxLength="[MaxLength]" />
          <Connection MaxConcurrentRequests="4" />
          <Parameters>
            <Parameter Name="Url" Type="String" Parent="General Configuration" Editor="String" Title="#{e(@brand)} address:" Default="#{e(@base)}" />
            <Parameter Name="ApiKey" Type="Password" Parent="General Configuration" Editor="String" Title="API key:" Default="#{e(@key)}" />
            <Parameter Name="ReportCallEnabled" Type="Boolean" Parent="Call Journaling" Editor="String" Title="Log calls on #{e(@brand)} activities" Default="True" />
            <Parameter Name="CreateContactEnabled" Type="Boolean" Parent="Contact Creation" Editor="String" Title="Create a lead for unknown callers" Default="False" />
          </Parameters>
          <Authentication Type="No" />
          <Scenarios>
            <Scenario Id="" Type="REST">
              <Request Url="[Url]/api/partner/v1/phone/lookup" MessagePasses="0" RequestContentType="application/json" RequestEncoding="Json" RequestType="Post" ResponseType="Json">
        #{headers}
                <PostValues Key="">
        #{v('number', '[Number]')}
                </PostValues>
              </Request>
              <Rules>
                <Rule Type="Any">contacts.id</Rule>
              </Rules>
              <Variables>
        #{variables}
              </Variables>
              <Outputs AllowEmpty="false">
        #{outputs}
              </Outputs>
            </Scenario>
            <Scenario Id="CreateContactRecord" Type="REST">
              <Request SkipIf="[CreateContactEnabled]!=True" Url="[Url]/api/partner/v1/phone/contacts" MessagePasses="0" RequestContentType="application/json" RequestEncoding="Json" RequestType="Post" ResponseType="Json">
        #{headers}
                <PostValues Key="">
        #{v('number', '[Number]')}
                </PostValues>
              </Request>
              <Rules>
                <Rule Type="Any">contacts.id</Rule>
              </Rules>
              <Variables>
        #{variables}
              </Variables>
              <Outputs AllowEmpty="false">
        #{outputs}
              </Outputs>
            </Scenario>
            <Scenario Id="ReportCall" Type="REST">
              <Request SkipIf="[ReportCallEnabled]!=True" Url="[Url]/api/partner/v1/phone/calls" MessagePasses="0" RequestContentType="application/json" RequestEncoding="Json" RequestType="Post" ResponseType="Json">
        #{headers}
                <PostValues Key="">
        #{report_values}
                </PostValues>
              </Request>
              <Variables />
              <Outputs AllowEmpty="true" />
            </Scenario>
          </Scenarios>
        </Crm>
      XML
    end

    private

    def headers
      <<~X.chomp
                <Headers>
                  <Value Key="Authorization" Passes="1" Type="String">Bearer [ApiKey]</Value>
                </Headers>
      X
    end

    def v(key, val, passes = 1)
      %(          <Value Key="#{key}" Passes="#{passes}" Type="String">#{val}</Value>)
    end

    def report_values
      [
        v('provider', '3cx', 0),
        v('call_type', '[CallType]'),
        v('direction', '[CallDirection]'),
        v('number', '[Number]'),
        v('agent', '[Agent]'),
        v('agent_email', '[AgentEmail]'),
        v('agent_name', '[AgentFirstName] [AgentLastName]'),
        v('duration', e('[[[DurationTimespan].get_TotalSeconds()].ToString("F0")]')),
        v('started_at', e('[[CallStartTimeUTC].ToString("yyyy-MM-ddTHH:mm:ssZ")]'), 2),
        v('entity_id', '[EntityId]'),
        v('contact_id', '[Contact::ContactID]'),
        v('queue_extension', '[QueueExtension]')
      ].join("\n")
    end

    VARS = {
      'ContactID' => 'contacts.id', 'FirstName' => 'contacts.first_name', 'LastName' => 'contacts.last_name',
      'Email' => 'contacts.email', 'CompanyName' => 'contacts.company', 'PhoneBusiness' => 'contacts.phone',
      'PhoneMobile' => 'contacts.mobile', 'ContactUrl' => 'contacts.url'
    }.freeze

    def variables
      VARS.map { |name, path| %(        <Variable Name="#{name}" Path="#{path}"><Filter /></Variable>) }.join("\n")
    end

    def outputs
      lines = VARS.keys.map { |name| %(        <Output Type="#{name}" Passes="0" Value="[#{name}]" />) }
      lines << %(        <Output Type="EntityId" Passes="0" Value="[ContactID]" />)
      lines << %(        <Output Type="EntityType" Passes="0" Value="Contacts" />)
      lines.join("\n")
    end

    def e(s)
      ERB::Util.html_escape(s.to_s)
    end
  end
end
