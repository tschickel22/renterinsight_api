# frozen_string_literal: true

require 'rails_helper'
require 'zip'

RSpec.describe LandingPages::HtmlImporter do
  let(:company) { Company.create!(name: "HtmlImp-#{SecureRandom.hex(4)}") }
  # The same container a landing page really lands on.
  let(:website) { Marketing::MarketingSiteProvisioner.call(company: company) }

  # Stands in for S3 so the spec neither uploads nor needs credentials.
  let(:uploader) do
    Class.new do
      attr_reader :uploads

      def initialize = @uploads = []

      def upload(asset, folder:)
        @uploads << { name: asset.original_filename, type: asset.content_type, bytes: asset.size }
        key = "#{folder}/#{@uploads.size}-#{asset.original_filename}"
        { url: "https://bucket.s3.us-west-2.amazonaws.com/#{key}", key: key, size: asset.size,
          content_type: asset.content_type }
      end
    end.new
  end

  def importer = described_class.new(company: company, website: website, uploader: uploader)

  # 1x1 transparent PNG.
  PNG = Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=')

  def upload_of(body, filename)
    Rack::Test::UploadedFile.new(StringIO.new(body), nil, original_filename: filename)
  rescue StandardError
    # Rack::Test's constructor varies; a duck-typed double is enough here.
    double(read: body, size: body.bytesize, original_filename: filename)
  end

  describe 'assets' do
    it 'moves an inlined image into storage and rewrites the reference' do
      data = "data:image/png;base64,#{Base64.strict_encode64(PNG)}"
      html = %(<html><body><img src="#{data}" alt="Home"></body></html>)

      result = importer.call(upload_of(html, 'page.html'))

      expect(result.imported).to eq(1)
      expect(result.html).not_to include('data:image/png')
      expect(result.html).to include('bucket.s3.us-west-2.amazonaws.com')
      expect(uploader.uploads.first[:type]).to eq('image/png')
    end

    it 'rewrites a background image inside a style element' do
      data = "data:image/png;base64,#{Base64.strict_encode64(PNG)}"
      html = %(<html><head><style>.hero{background:url('#{data}')}</style></head><body><div class="hero"></div></body></html>)

      result = importer.call(upload_of(html, 'page.html'))

      expect(result.imported).to eq(1)
      expect(result.html).to include('.hero{background:url(')
      expect(result.html).not_to include('data:image/png')
    end

    # The whole reason this path exists: the design has to still look like itself.
    it 'keeps the CSS that makes it a design' do
      html = <<~HTML
        <html><head><style>:root{--brand:#c8102e}.pill{border-radius:4px;background:var(--brand)}</style></head>
        <body><span class="pill" style="letter-spacing:.08em">Websites</span></body></html>
      HTML

      result = importer.call(upload_of(html, 'page.html'))

      expect(result.html).to include('--brand:#c8102e')
      expect(result.html).to include('border-radius:4px')
      expect(result.html).to include('letter-spacing:.08em')
      expect(result.html).to include('class="pill"')
    end

    it 'reports an embedded asset of a type it will not take' do
      data = 'data:application/x-shockwave-flash;base64,AAAA'
      result = importer.call(upload_of(%(<body><img src="#{data}"></body>), 'page.html'))

      expect(result.skipped).to eq(1)
      expect(result.warnings.join).to match(/skipped an embedded/i)
    end
  end

  describe 'zip input' do
    def zip_with(files)
      buffer = Zip::OutputStream.write_buffer(StringIO.new) do |zos|
        files.each { |name, body| zos.put_next_entry(name); zos.write(body) }
      end
      buffer.string
    end

    it 'takes the HTML and its neighbouring assets' do
      bytes = zip_with(
        'index.html' => %(<body><img src="images/home.png"></body>),
        'images/home.png' => PNG
      )

      result = importer.call(upload_of(bytes, 'design.zip'))

      expect(result.imported).to eq(1)
      expect(result.html).to include('bucket.s3.us-west-2.amazonaws.com')
      expect(result.html).not_to include('images/home.png')
    end

    it 'says which referenced file the zip is missing rather than failing silently' do
      bytes = zip_with('index.html' => %(<body><img src="images/missing.png"></body>))

      result = importer.call(upload_of(bytes, 'design.zip'))

      expect(result.skipped).to eq(1)
      expect(result.warnings.join).to include('missing.png')
    end

    it 'refuses a zip with no page in it' do
      bytes = zip_with('notes.txt' => 'hello')

      expect { importer.call(upload_of(bytes, 'design.zip')) }
        .to raise_error(described_class::ImportError, /no HTML/i)
    end
  end

  describe 'what it refuses to carry' do
    # This markup is rendered into a page we serve, so anything executable in it
    # would run with our origin.
    it 'removes scripts' do
      html = %(<body><h1>Hi</h1><script>fetch('/api/v1/users')</script></body>)
      result = importer.call(upload_of(html, 'page.html'))

      expect(result.html).to include('<h1>Hi</h1>')
      expect(result.html).not_to include('<script')
      expect(result.html).not_to include('fetch(')
    end

    it 'removes inline event handlers' do
      result = importer.call(upload_of(%(<body><div onclick="steal()">x</div></body>), 'page.html'))

      expect(result.html).not_to include('onclick')
      expect(result.html).to include('<div>x</div>')
    end

    it 'removes a javascript: destination but keeps the link' do
      result = importer.call(upload_of(%(<body><a href="javascript:alert(1)">Go</a></body>), 'page.html'))

      expect(result.html).not_to include('javascript:')
      expect(result.html).to include('Go')
    end

    it 'drops an arbitrary iframe' do
      result = importer.call(upload_of(%(<body><iframe src="https://evil.test/x"></iframe></body>), 'page.html'))

      expect(result.html).not_to include('evil.test')
    end
  end

  describe 'video' do
    # Shipping the embed means the player's chrome, its related-video
    # suggestions and its cookies on a page whose whole job is to convert.
    it 'turns a YouTube embed into an empty slot rather than keeping the player' do
      result = importer.call(
        upload_of(%(<body><iframe src="https://www.youtube.com/embed/abc"></iframe></body>), 'page.html')
      )

      expect(result.html).not_to include('youtube.com')
      expect(result.html).to include('data-dt-slot="v1"')
      expect(result.video_slots).to eq([{ 'id' => 'v1', 'source' => 'youtube',
                                          'original_url' => 'https://www.youtube.com/embed/abc' }])
    end

    it 'does the same for Vimeo' do
      result = importer.call(
        upload_of(%(<body><iframe src="https://player.vimeo.com/video/123"></iframe></body>), 'page.html')
      )

      expect(result.html).not_to include('vimeo.com')
      expect(result.video_slots.first['source']).to eq('vimeo')
    end

    # The sizing belongs to the design, so the element carries it across.
    it 'keeps the class and dimensions the design gave the embed' do
      html = %(<body><iframe class="tour" width="960" height="540" src="https://player.vimeo.com/video/9"></iframe></body>)
      result = importer.call(upload_of(html, 'page.html'))

      expect(result.html).to include('class="tour"')
      expect(result.html).to include('width="960"')
      expect(result.html).to include('height="540"')
    end

    it 'numbers several slots so each can be filled separately' do
      html = %(<body><iframe src="https://player.vimeo.com/video/1"></iframe>) +
             %(<iframe src="https://www.youtube.com/embed/2"></iframe></body>)
      result = importer.call(upload_of(html, 'page.html'))

      expect(result.video_slots.map { |v| v['id'] }).to eq(%w[v1 v2])
    end

    it 'says the slots need filling' do
      result = importer.call(
        upload_of(%(<body><iframe src="https://player.vimeo.com/video/1"></iframe></body>), 'page.html')
      )
      expect(result.warnings.join).to match(/1 video became an empty slot|became empty slots/i)
    end

    it 'reports no slots for a page with no video' do
      result = importer.call(upload_of(%(<body><p>Copy</p></body>), 'page.html'))
      expect(result.video_slots).to be_empty
    end

    it 'says what it removed' do
      result = importer.call(upload_of(%(<body><script>x()</script></body>), 'page.html'))
      expect(result.warnings.join).to match(/removed 1 script/i)
    end
  end

  describe 'the fragment it produces' do
    # A design's typography is most of its character, and losing the stylesheet
    # reads as a broken import rather than a missing font.
    it 'keeps a webfont stylesheet but not an arbitrary one' do
      html = <<~HTML
        <html><head>
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo&display=swap">
        <link rel="stylesheet" href="https://evil.test/restyle.css">
        </head><body><p>Copy</p></body></html>
      HTML

      result = importer.call(upload_of(html, 'page.html'))

      expect(result.html).to include('fonts.googleapis.com')
      expect(result.html).not_to include('evil.test')
    end

    it 'returns head styles followed by the body, not a whole document' do
      html = %(<html><head><title>Ignore me</title><style>.a{color:red}</style></head><body><p>Copy</p></body></html>)
      result = importer.call(upload_of(html, 'page.html'))

      expect(result.html).to include('.a{color:red}')
      expect(result.html).to include('<p>Copy</p>')
      expect(result.html).not_to include('Ignore me')
      expect(result.html).not_to include('<body')
    end
  end
end
