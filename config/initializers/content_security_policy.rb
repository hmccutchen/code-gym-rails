Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri    :self
    policy.object_src  :none
    policy.frame_ancestors :none
    policy.form_action :self
    policy.connect_src :self
    policy.img_src     :self, :data
    policy.font_src    :self, :data
    policy.style_src   :self, :unsafe_inline
    policy.script_src  :self, "https://cdn.jsdelivr.net"
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
