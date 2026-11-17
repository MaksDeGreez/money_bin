# The Content Security Policy: what a page may load and run. Every page is served with it.
# See https://guides.rubyonrails.org/security.html#content-security-policy-header
#
# - Scripts, styles, images and connections come from this app only. The two exceptions are the web fonts
#   that app/views/layouts/_head.html.slim loads: the stylesheet from fonts.googleapis.com and the font
#   files from fonts.gstatic.com.
# - Inline scripts and styles run only with the page's nonce. The importmap tags get it on their own; the
#   one inline script, the theme boot in the head, sets it itself; Turbo reads it from the csp-nonce meta
#   tag (csp_meta_tag) for the style of its progress bar. There is no 'unsafe-inline' and no
#   'unsafe-eval'.
# - The nonce is the id of the Rails session, as the Rails guide advises with Turbo: Turbo keeps the first
#   page's policy while it swaps in later pages, so the nonce must stay the same from page to page. It
#   changes when the session is reset (signing in and out), and those forms reload the whole page.
# - No page may be framed by another site, and forms post only to this app.
#
# Sidekiq Web sends its own policy, and Rails leaves a response that already has one alone.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :self
    policy.connect_src :self
    policy.font_src :self, "https://fonts.gstatic.com"
    policy.form_action :self
    policy.frame_ancestors :none
    policy.img_src :self, :data
    policy.object_src :none
    policy.script_src :self
    policy.style_src :self, "https://fonts.googleapis.com"
  end

  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s.presence || SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[ script-src style-src ]
end
