# frozen_string_literal: true

module Public
  # The one line a dealer pastes into their own website to show Quinn's chat
  # (E96, 2026-11-07):
  #
  #   <script src="https://<api>/chat/<token>.js" async></script>
  #
  # It returns a small script that adds the chat as a frame from our app
  # (/chat-embed/<token>), sized to a bubble until it is opened. The chat only
  # answers on the sites the dealer listed in Quinn's settings: the frame reads
  # the page it sits on from the browser (document.referrer), not from
  # anything the page can set, and the chat endpoints check it. This script is
  # also withheld from a page the browser says is somewhere else.
  class ChatEmbedController < ActionController::API
    def show
      response.headers['Content-Type'] = 'application/javascript; charset=utf-8'
      response.headers['Cache-Control'] = 'public, max-age=300'
      company = Company.find_by(public_inventory_token: params[:token]) if params[:token].to_s.match?(/\A[\w-]{8,}\z/)
      return render(plain: "/* chat unavailable */\n") unless company && chat_on?(company)

      settings = Assistant::Settings.for(company)
      referer_host = (URI.parse(request.referer.to_s).host rescue nil)
      if referer_host.present? && !settings.chat_site_allowed?(referer_host)
        return render(plain: "/* this site is not listed for this chat; add it in Quinn AI settings */\n")
      end

      render plain: script(company)
    end

    private

    def chat_on?(company)
      ModuleAccessService.new(company).module_enabled?(Assistant::Settings::CHAT_MODULE_KEY)
    rescue StandardError
      false
    end

    def script(company)
      app = Brand.app_url(company: company).to_s.chomp('/')
      <<~JS
        (function () {
          if (window.__dealertideChat) return;
          window.__dealertideChat = true;
          var APP = #{app.to_json};
          var ORIGIN = new URL(APP).origin;
          var frame = document.createElement('iframe');
          frame.src = APP + '/chat-embed/' + #{company.public_inventory_token.to_json} +
            '?page=' + encodeURIComponent(location.href.slice(0, 400));
          frame.title = 'Chat';
          frame.setAttribute('allowtransparency', 'true');
          var closed = 'position:fixed;bottom:12px;right:12px;width:84px;height:84px;border:0;z-index:2147483000;background:transparent;color-scheme:normal;';
          frame.style.cssText = closed;
          function size(open) {
            if (!open) { frame.style.cssText = closed; return; }
            if (window.innerWidth < 640) {
              frame.style.cssText = 'position:fixed;inset:0;width:100%;height:100%;border:0;z-index:2147483000;background:transparent;color-scheme:normal;';
            } else {
              frame.style.cssText = 'position:fixed;bottom:12px;right:12px;width:420px;height:640px;max-height:calc(100% - 24px);border:0;z-index:2147483000;background:transparent;color-scheme:normal;';
            }
          }
          window.addEventListener('message', function (e) {
            var d = e.data || {};
            if (e.origin === ORIGIN && d.type === 'dealertide-chat-size') size(!!d.open);
            // A lead form from the same dealer (also our frame) finished: open
            // the chat on that lead so they can keep talking.
            if (e.origin === ORIGIN && d.type === 'dealertide:chat-open' && frame.contentWindow) {
              frame.contentWindow.postMessage(d, ORIGIN);
            }
          });
          function add() { document.body.appendChild(frame); }
          if (document.body) add(); else document.addEventListener('DOMContentLoaded', add);
        })();
      JS
    end
  end
end
